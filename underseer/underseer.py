#!/usr/bin/env python3
"""
underseer.py — All-Seer polling/forwarding bridge.

Input interface (from All-Seer):
    Reads /proc/all_seer text lines produced by allseer.c:
        <ts_ns> <pid> <ppid> <uid> <type> <comm> <arg>

Output interface (to Over-Seer):
    Sends newline-delimited JSON over TCP, one event per line:
        {"ts":..., "pid":..., "ppid":..., "uid":...,
         "type":..., "comm":..., "arg":...}

Role in the system:
    This is the intended procfs consumer. Its open/read cycle claims the
    reader lock and drains kernel-buffered events for remote transport.

Configuration (environment variables):
  OVERSEER_HOST       IP or hostname of the Over-Seer machine  (required)
  OVERSEER_PORT       TCP port on the Over-Seer machine         (default: 9000)
  PROC_PATH           Path to the procfs file                   (default: /proc/all_seer)
  POLL_INTERVAL_MS    Milliseconds between read attempts        (default: 100)
  BATCH_MAX           Max events sent in one TCP write          (default: 64)
  RECONNECT_MAX_S     Max reconnect back-off in seconds         (default: 30)

Wire format (one JSON object per line):
  {"ts": <ns>, "pid": <int>, "ppid": <int>, "uid": <int>,
   "type": "open"|"fork"|"exec"|"connect", "comm": "<str>", "arg": "<str>"}
"""

import contextlib
import json
import os
import socket
import sys
import time

# ── SWITCHES ─────────────────────────────────────────────────────────────── #

OVERSEER_HOST    = os.environ.get("OVERSEER_HOST", "127.0.0.1")
try: OVERSEER_PORT = int(os.environ.get("OVERSEER_PORT", "12046"))
except TypeError: OVERSEER_PORT = 12046
PROC_PATH        = "/proc/all_seer"
PROC_CTL_PATH    = "/proc/all_seer_ctl"
POLL_INTERVAL_S  = 50
BATCH_MAX        = 128
RECONNECT_MAX_S  = 30

POLL_INTERVAL_S /= 1000.0

# ── Event type mapping (must match AS_TYPE_* constants in all_seer.h) ────────

_TYPE_NAMES = ("open", "fork", "exec", "connect")


def _write_ctl(command: str) -> None:
    with open(PROC_CTL_PATH, "w") as ctl:
        ctl.write(command)


def register_identity() -> bool:
    """
    Claim owner lease and install self-filter for this task group.

    Returns True when both operations succeed. Failures are non-fatal; caller
    may retry later because owner lease can be temporarily held by an old PID.
    """
    tgid = os.getpid()  # group leader pid == tgid for this process
    ok = True

    try:
        _write_ctl(f"claim_owner_tgid {tgid}\n")
        print(f"[under-seer] owner lease claimed tgid={tgid}", flush=True)
    except FileNotFoundError:
        print(f"[under-seer] {PROC_CTL_PATH} not found", flush=True)
        return False
    except PermissionError:
        print(f"[under-seer] permission denied writing {PROC_CTL_PATH}",
              flush=True)
        return False
    except OSError as exc:
        print(f"[under-seer] owner claim failed: {exc}", flush=True)
        ok = False

    try:
        _write_ctl(f"filter_add_tgid {tgid}\n")
    except OSError as exc:
        print(f"[under-seer] self-filter registration failed: {exc}",
              flush=True)
        ok = False

    return ok


def parse_line(line: str) -> dict | None:
    """
    Parse one space-separated procfs event line.

    Format:  <ts_ns> <pid> <ppid> <uid> <type> <comm> <arg>

    The arg field may contain spaces (e.g. command arguments), so we split
    into at most 7 tokens and treat everything after the 6th token as <arg>.
    """
    line = line.strip()
    if not line:
        return None

    parts = line.split(None, 6)          # split on whitespace, max 7 parts
    if len(parts) < 7:
        return None

    ts_raw, pid_raw, ppid_raw, uid_raw, type_raw, comm, arg = parts

    try:
        return {
            "ts":   int(ts_raw),
            "pid":  int(pid_raw),
            "ppid": int(ppid_raw),
            "uid":  int(uid_raw),
            "type": type_raw,
            "comm": comm,
            "arg":  arg,
        }
    except ValueError:
        return None


# ── TCP sender with reconnect back-off ───────────────────────────────────────

class Sender:
    def __init__(self, host: str, port: int):
        self._host = host
        self._port = port
        self._sock: socket.socket | None = None
        self._backoff = 1.0

    def _connect(self) -> bool:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(10)
            s.connect((self._host, self._port))
            s.settimeout(None)
            self._sock = s
            self._backoff = 1.0
            print(f"[under-seer] connected to {self._host}:{self._port}",
                  flush=True)
            return True
        except OSError as exc:
            print(f"[under-seer] connect failed: {exc}; "
                  f"retrying in {self._backoff:.0f}s", flush=True)
            time.sleep(self._backoff)
            self._backoff = min(self._backoff * 2, RECONNECT_MAX_S)
            return False

    def connect(self):
        while not self._connect():
            pass

    def send_batch(self, events: list[dict]) -> bool:
        """
        Encode and send a batch of events.  Returns False if the connection
        was lost; caller should reconnect and retry.
        """
        if not events:
            return True

        payload = "\n".join(json.dumps(e) for e in events) + "\n"
        data = payload.encode("utf-8")

        try:
            self._sock.sendall(data)
            return True
        except OSError as exc:
            print(f"[under-seer] send error: {exc}", flush=True)
            self._close()
            return False

    def _close(self):
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


# ── Main poll loop ────────────────────────────────────────────────────────────

def main():
    sender = Sender(OVERSEER_HOST, OVERSEER_PORT)
    sender.connect()
    register_identity()

    print(f"[under-seer] polling {PROC_PATH} every "
          f"{POLL_INTERVAL_S * 1000:.0f}ms", flush=True)

    last_claim_retry = 0.0

    while True:
        # ── Read all available events from the proc file ─────────────────
        # This open/read path is the kernel/userspace handoff. For All-Seer,
        # this process is expected to be the exclusive authorized reader.
        batch: list[dict] = []
        try:
            with open(PROC_PATH, "r") as fh:
                for raw_line in fh:
                    ev = parse_line(raw_line)
                    if ev:
                        batch.append(ev)
                    if len(batch) >= BATCH_MAX:
                        break
        except PermissionError:
            # Another process owns the proc file; wait and retry.
            time.sleep(POLL_INTERVAL_S)
            continue
        except FileNotFoundError:
            now = time.monotonic()
            if now - last_claim_retry >= 1.0:
                register_identity()
                last_claim_retry = now

            print(f"[under-seer] {PROC_PATH} unavailable — "
                  "lease not claimed yet or module not loaded",
                  file=sys.stderr, flush=True)
            time.sleep(5)
            continue
        except OSError as exc:
            print(f"[under-seer] read error: {exc}", flush=True)
            time.sleep(POLL_INTERVAL_S)
            continue

        # ── Forward events to Over-Seer ───────────────────────────────────
        if batch:
            if not sender.send_batch(batch):
                sender.connect()
                # Retry the same batch once after reconnect.
                sender.send_batch(batch)

        time.sleep(POLL_INTERVAL_S)


if __name__ == "__main__":
    main()
else: raise ImportError("Don't import me!!!")