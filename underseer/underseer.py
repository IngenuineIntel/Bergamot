#!/usr/bin/env python3
"""
Syscall wire format (one JSON object per line):
    {"ts_s": <unix-seconds>, "ts_ms": <0-999>, "pid": <int>,
     "ppid": <int>, "uid": <int>,
    "type": "open"|"fork"|"exec"|"connect", "subtype": "<str>",
    "comm": "<str>", "arg": "<str>"}

Process snapshot wire format (one JSON object per line):
        {"kind": "proc_snapshot", "ts_s": <unix-seconds>, "ts_ms": <0-999>,
         "processes": [{"pid": <int>, "ppid": <int>, "uid": <int>,
                                        "comm": "<str>", "threads": <int>}, ...]}
"""
BERGAMOT_VERSION = "0.1"

import contextlib
import json
import os
import socket
import sys
import time

# ── SWITCH HARDENING ─────────────────────────────────────────────────────── #
"""
Inline code hardening would have been very superfluous and messy, ergo, a
wrapper!
"""
def envvar_fetch(name: str, valtype: type, default):
    try: default = valtype(default)
    except TypeError: raise AssertionError(
        f"'default' {default} isn't of type {valtype} supplied as 'valtype'."
    )
    try: return valtype(os.environ[str])
    except: return default

# ── SWITCHES ─────────────────────────────────────────────────────────────── #
"""
WIRE_DST        The IP of the Overseer instance. Default is localhost.
WIRE_PORT       The port of the Overseer instance, default is the port used for
                texture downloads in Second Life 2.
WIRE_HZ         The frequency the procfile is read and a network packet sent.
WIRE_BATCH_MAX  The max amount of data to be read or sent ever iteration.
WIRE_REC_MAX    The seconds we'll wait to reestablish the wire protocol.
"""
WIRE_DST  = envvar_fetch("BERGAMOT_HOST", str, "127.0.0.1")
WIRE_PORT = envvar_fetch("BEGRAMOT_WIRE_PORT", int, 12046)
WIRE_HZ   = envvar_fetch("BEGAMOT_WIRE_HZ", float, 0.25)
WIRE_BATCH_MAX = envvar_fetch("BERGAMOT_BATCH_MAX", int, 128)
WIRE_REC_MAX   = 30
# ── Event type mapping (must match AS_TYPE_* constants in all_seer.h) ────────

_TYPE_NAMES = ("open", "fork", "exec", "connect")


def parse_line(line: str) -> dict | None:
    """
    Parse one space-separated procfs event line.

    Format:  <ts_ns> <pid> <ppid> <uid> <type> <subtype> <comm> <arg>

    The arg field may contain spaces (e.g. command arguments), so we split
    into at most 8 tokens and treat everything after the 7th token as <arg>.
    """
    line = line.strip()
    if not line:
        return None

    parts = line.split(None, 7)          # split on whitespace, max 8 parts
    if len(parts) < 8:
        return None

    ts_raw, pid_raw, ppid_raw, uid_raw, type_raw, subtype_raw, comm, arg = parts

    try:
        ts_ns = int(ts_raw)
        ts_s, rem_ns = divmod(ts_ns, 1_000_000_000)
        ts_ms = rem_ns // 1_000_000
        return {
            "ts_s": int(ts_s),
            "ts_ms": int(ts_ms),
            "pid":  int(pid_raw),
            "ppid": int(ppid_raw),
            "uid":  int(uid_raw),
            "type": type_raw,
            "subtype": subtype_raw,
            "comm": comm,
            "arg":  arg,
        }
    except ValueError:
        return None


def collect_process_snapshot() -> dict:
    now = time.time()
    ts_s = int(now)
    ts_ms = int((now - ts_s) * 1000)
    processes: list[dict] = []

    for entry in os.scandir("/proc"):
        if not entry.name.isdigit() or not entry.is_dir(follow_symlinks=False):
            continue

        pid = int(entry.name)
        status_path = f"/proc/{entry.name}/status"
        try:
            ppid = 0
            uid = 0
            comm = ""
            threads = 0
            with open(status_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if line.startswith("Name:\t"):
                        comm = line.split("\t", 1)[1].strip()
                    elif line.startswith("PPid:\t"):
                        ppid = int(line.split("\t", 1)[1].strip() or 0)
                    elif line.startswith("Uid:\t"):
                        uid = int(line.split("\t", 1)[1].split()[0])
                    elif line.startswith("Threads:\t"):
                        threads = int(line.split("\t", 1)[1].strip() or 0)

            processes.append({
                "pid": pid,
                "ppid": ppid,
                "uid": uid,
                "comm": comm,
                "threads": threads,
            })
        except (FileNotFoundError, ProcessLookupError, PermissionError, OSError, ValueError):
            # Process exited (or became unreadable) while being sampled.
            continue

    processes.sort(key=lambda p: p["pid"])
    return {
        "kind": "proc_snapshot",
        "ts_s": ts_s,
        "ts_ms": ts_ms,
        "processes": processes,
    }


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
            self._backoff = min(self._backoff * 2, WIRE_REC_MAX)
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
    sender = Sender(WIRE_DST, WIRE_PORT)
    sender.connect()

    print(f"[under-seer] polling /proc/all_seer every "
          f"{WIRE_HZ * 1000:.0f}ms", flush=True)
    print(f"[under-seer] process snapshots every "
          f"{WIRE_HZ:.2f}s", flush=True)
    lease_announced = False
    next_snapshot_at = time.monotonic()

    while True:
        # ── Read all available events from the proc file ─────────────────
        # This open/read path is the kernel/userspace handoff. For All-Seer,
        # this process is expected to be the exclusive authorized reader.
        batch: list[dict] = []
        try:
            with open("/proc/all_seer", "r") as fh:
                if not lease_announced:
                    print("[under-seer] /proc/all_seer access claimed",
                          flush=True)
                    lease_announced = True
                for raw_line in fh:
                    ev = parse_line(raw_line)
                    if ev:
                        batch.append(ev)
                    if len(batch) >= WIRE_BATCH_MAX:
                        break
        except PermissionError:
            # Another process owns the proc file; wait and retry.
            time.sleep(WIRE_HZ)
            continue
        except FileNotFoundError:
            print(f"[under-seer] {PROC_PATH} unavailable — "
                  "owned by another parent scope or module not loaded",
                  file=sys.stderr, flush=True)
            time.sleep(5)
            continue
        except OSError as exc:
            print(f"[under-seer] read error: {exc}", flush=True)
            time.sleep(WIRE_HZ)
            continue

        # ── Forward events to Over-Seer ───────────────────────────────────
        if batch:
            if not sender.send_batch(batch):
                sender.connect()
                # Retry the same batch once after reconnect.
                sender.send_batch(batch)

        now_mono = time.monotonic()
        if now_mono >= next_snapshot_at:
            snapshot = collect_process_snapshot()
            if not sender.send_batch([snapshot]):
                sender.connect()
                sender.send_batch([snapshot])

            while next_snapshot_at <= now_mono:
                next_snapshot_at += WIRE_HZ

        time.sleep(WIRE_HZ)


if __name__ == "__main__":
    main()
else: raise ImportError("Don't import me!!!")