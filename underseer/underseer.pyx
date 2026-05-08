#!/usr/bin/env python3
"""
System info handshake (first JSON object on each TCP connection):
    {"kind": "system_info", "hostname": "<str>", "kernelver": "<str>",
     "distro": "<str>", "ipaddr": "<str>", "macaddr": "<str>",
     "processor": "<str>", "processor_vend": "<str>",
     "ram_gbs": <int>}

Syscall wire format (one JSON object per line):
    {"ts_s": <unix-seconds>, "ts_ms": <0-999>, "pid": <int>,
     "ppid": <int>, "uid": <int>,
    "type": "open"|"fork"|"connect"|"execve", "subtype": "<str>",
    "comm": "<str>", "arg": "<str>", "arg1": "<str>",
    "arg2": "<str>"}

Process snapshot wire format (one JSON object per line):
        {"kind": "proc_snapshot", "ts_s": <unix-seconds>, "ts_ms": <0-999>,
         "processes": [{"pid": <int>, "ppid": <int>, "uid": <int>,
                                        "comm": "<str>", "threads": <int>}, ...]}
"""
# ── CYTHON CDEFS ─────────────────────────────────────────────────────────── #
cdef str BERGAMOT_VERSION
cdef str WIRE_DST
cdef int WIRE_PORT
cdef float WIRE_HZ
cdef int WIRE_BATCH_MAX
cdef int WIRE_REC_MAX
cdef int WIRE_TIMEOUT
cdef str PROC_PATH
# ── END CYTHON CDEFS ─────────────────────────────────────────────────────── #

BERGAMOT_VERSION = "1.0"

import contextlib
import json
import os
import platform
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
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return valtype(raw)
    except Exception:
        return default

# ── SWITCHES ─────────────────────────────────────────────────────────────── #
"""
WIRE_DST        The IP of the Overseer instance. Default is localhost.
WIRE_PORT       The port of the Overseer instance, default is the port used for
                texture downloads in Second Life 2.
WIRE_HZ         The frequency the procfile is read and a network packet sent.
WIRE_BATCH_MAX  The max amount of data to be read or sent ever iteration.
WIRE_REC_MAX    The seconds we'll wait to reestablish the wire protocol.
"""
WIRE_DST       = envvar_fetch("BERGAMOT_HOST", str, "127.0.0.1")
WIRE_PORT      = envvar_fetch("BERGAMOT_WIRE_PORT", int, 12046)
WIRE_HZ        = envvar_fetch("BERGAMOT_WIRE_HZ", float, 0.25)
WIRE_BATCH_MAX = envvar_fetch("BERGAMOT_BATCH_MAX", int, 128)
WIRE_REC_MAX   = 30
WIRE_TIMEOUT   = 5
PROC_PATH      = "/proc/all_seer"


def _read_first_line(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.readline().strip()
    except OSError:
        return ""


def _read_os_release() -> str:
    pretty_name = ""
    name = ""
    version = ""

    try:
        with open("/etc/os-release", "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                value = value.strip().strip('"')
                if key == "PRETTY_NAME":
                    pretty_name = value
                elif key == "NAME":
                    name = value
                elif key == "VERSION":
                    version = value
    except OSError:
        return ""

    if pretty_name:
        return pretty_name
    return " ".join(part for part in (name, version) if part).strip()


def _get_primary_ipv4() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return str(sock.getsockname()[0] or "")
    except OSError:
        return ""


def _get_primary_interface() -> str:
    try:
        with open("/proc/net/route", "r", encoding="utf-8", errors="replace") as fh:
            next(fh, None)
            for line in fh:
                cols = line.split()
                if len(cols) >= 2 and cols[1] == "00000000":
                    return cols[0]
    except OSError:
        pass
    return ""


def _get_mac_address(iface: str) -> str:
    if not iface:
        return ""
    return _read_first_line(f"/sys/class/net/{iface}/address")


def _read_cpu_info() -> tuple[str, str]:
    model = ""
    vendor = ""
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                line = raw_line.strip()
                if not line or ":" not in line:
                    continue
                key, value = [part.strip() for part in line.split(":", 1)]
                if key == "model name" and not model:
                    model = value
                elif key == "vendor_id" and not vendor:
                    vendor = value
                if model and vendor:
                    break
    except OSError:
        return "", ""
    return model, vendor


def _read_ram_gbs() -> int:
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as fh:
            for raw_line in fh:
                if not raw_line.startswith("MemTotal:"):
                    continue
                parts = raw_line.split()
                if len(parts) < 2:
                    return 0
                kib = int(parts[1])
                return max(1, round(kib / (1024 * 1024)))
    except (OSError, ValueError):
        return 0
    return 0


def collect_system_info() -> dict:
    uname = platform.uname()
    primary_iface = _get_primary_interface()
    processor, processor_vend = _read_cpu_info()
    return {
        "kind": "system_info",
        "hostname": socket.gethostname(),
        "kernelver": " ".join(part for part in (uname.release, uname.machine) if part).strip(),
        "distro": _read_os_release(),
        "ipaddr": _get_primary_ipv4(),
        "macaddr": _get_mac_address(primary_iface),
        "processor": processor,
        "processor_vend": processor_vend,
        "ram_gbs": _read_ram_gbs(),
    }

def parse_line(line: str) -> dict | None:
    """
        Parse one procfs event line.

        Preferred format (tab-separated):
            <ts_ns>\t<pid>\t<ppid>\t<uid>\t<type>\t<subtype>\t<comm>\t<arg1>\t<arg2>

        Legacy format (space-separated):
            <ts_ns> <pid> <ppid> <uid> <type> <subtype> <comm> <arg>

        Legacy parsing keeps backward compatibility for old module builds.
    """

    cdef list parts
    cdef str ts_raw
    cdef str pid_raw
    cdef str ppid_raw
    cdef str uid_raw
    cdef str type_raw
    cdef str subtype_raw
    cdef str comm
    cdef str arg1
    cdef str arg2
    cdef object arg2_value
    cdef str arg_legacy
    cdef long long ts_ns
    cdef long long ts_s
    cdef long long rem_ns
    cdef int arg2_pos

    line = line.strip()
    if not line:
        return None

    if "\t" in line:
        parts = line.split("\t", 8)
        if len(parts) < 9:
            return None

        ts_raw = parts[0]
        pid_raw = parts[1]
        ppid_raw = parts[2]
        uid_raw = parts[3]
        type_raw = parts[4]
        subtype_raw = parts[5]
        if subtype_raw == "none":
            subtype_raw = ""
        comm = parts[6]
        arg1 = parts[7]
        arg2 = parts[8]
    else:
        parts = line.split(None, 7)
        if len(parts) < 8:
            return None

        ts_raw = parts[0]
        pid_raw = parts[1]
        ppid_raw = parts[2]
        uid_raw = parts[3]
        type_raw = parts[4]
        subtype_raw = parts[5]
        if subtype_raw == "none":
            subtype_raw = ""
        comm = parts[6]

        arg_legacy = parts[7]
        arg1 = arg_legacy
        arg2 = ""

        # Transitional parsing: if arg was encoded as "arg1=<x> arg2=<y>", split it.
        if arg_legacy.startswith("arg1="):
            arg2_pos = arg_legacy.find(" arg2=")
            if arg2_pos != -1:
                arg1 = arg_legacy[5:arg2_pos].strip()
                arg2 = arg_legacy[arg2_pos + 6:].strip()

    try:
        ts_ns = int(ts_raw)
        ts_s = ts_ns // 1_000_000_000
        rem_ns = ts_ns % 1_000_000_000

        arg2_value = arg2
        if type_raw == "ptrace" and arg2:
            try:
                arg2_value = int(arg2)
            except ValueError:
                arg2_value = arg2

        return {
            "ts_s": int(ts_s),
            "ts_ms": int(rem_ns // 1_000_000),
            "pid": int(pid_raw),
            "ppid": int(ppid_raw),
            "uid": int(uid_raw),
            "type": type_raw,
            "subtype": subtype_raw,
            "comm": comm,
            "arg": arg1,
            "arg1": arg1,
            "arg2": arg2_value,
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


# ── TCP sender with reconnect back-off ───────────────────────────────────── #

cdef class Sender:
    cdef str _host
    cdef int _port
    cdef object _sock
    cdef double _backoff
    cdef dict _system_info

    def __init__(self, str host, int port):
        self._host = host
        self._port = port
        self._sock = None
        self._backoff = 1.0
        self._system_info = collect_system_info()

    cdef bint _connect(self):
        cdef object s
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(WIRE_TIMEOUT)
            s.connect((self._host, self._port))
            s.settimeout(None)
            self._sock = s
            self._backoff = 1.0
            if not self._send_objects([self._system_info]):
                self._close()
                raise OSError("failed to send system_info handshake")
            print(f"[under-seer] connected to {self._host}:{self._port}",
                  flush=True)
            return True
        except OSError as exc:
            print(f"[under-seer] connect failed: {exc}; "
                  f"retrying in {self._backoff:.0f}s", flush=True)
            time.sleep(self._backoff)
            self._backoff = min(self._backoff * 2, WIRE_REC_MAX)
            return False

    cdef void connect(self):
        while not self._connect():
            pass

    cdef bint send_batch(self, list events):
        """
        Encode and send a batch of events.  Returns False if the connection
        was lost; caller should reconnect and retry.
        """
        if not events:
            return True

        return self._send_objects(events)

    cdef bint _send_objects(self, list payloads):
        cdef str payload
        cdef bytes data
        if self._sock is None:
            return False

        payload = "\n".join(json.dumps(e) for e in payloads) + "\n"
        data = payload.encode("utf-8")

        try:
            self._sock.sendall(data)
            return True
        except OSError as exc:
            print(f"[under-seer] send error: {exc}", flush=True)
            self._close()
            return False

    cdef void _close(self):
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None


# ── Main poll loop ────────────────────────────────────────────────────────────

cpdef main():
    cdef Sender sender
    cdef bint lease_announced
    cdef double poll_interval
    cdef double next_snapshot_at
    cdef double now_mono
    cdef list batch
    cdef object fh
    cdef str raw_line
    cdef object ev
    cdef dict snapshot

    sender = Sender(WIRE_DST, WIRE_PORT)
    sender.connect()

    poll_interval = WIRE_HZ

    print(f"[under-seer] polling /proc/all_seer every "
        f"{poll_interval * 1000:.0f}ms", flush=True)
    print(f"[under-seer] process snapshots every "
        f"{poll_interval:.2f}s", flush=True)
    lease_announced = False
    next_snapshot_at = time.monotonic()

    while True:
        # ── Read all available events from the proc file ─────────────────
        # This open/read path is the kernel/userspace handoff. For All-Seer,
        # this process is expected to be the exclusive authorized reader.
        batch = []
        try:
            with open(PROC_PATH, "r") as fh:
                if not lease_announced:
                    print(f"[under-seer] {PROC_PATH} access claimed",
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
            time.sleep(poll_interval)
            continue
        except FileNotFoundError:
            print(f"[under-seer] {PROC_PATH} unavailable — "
                  "owned by another parent scope or module not loaded",
                  file=sys.stderr, flush=True)
            time.sleep(5)
            continue
        except OSError as exc:
            print(f"[under-seer] read error: {exc}", flush=True)
            time.sleep(poll_interval)
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
                next_snapshot_at += poll_interval

        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
