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
cdef float WIRE_SNAPSHOT_HZ
cdef int WIRE_BATCH_MAX
cdef int WIRE_REC_MAX
cdef int WIRE_TIMEOUT
cdef int WIRE_SNAPSHOT_SORT
cdef str PROC_PATH
# ── END CYTHON CDEFS ─────────────────────────────────────────────────────── #

BERGAMOT_VERSION = "1.0"

import contextlib
import json
import os
import platform
import queue
import socket
import struct
import sys
import threading
import time
import zlib

import underseer_workers

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
WIRE_PROTOCOL  = envvar_fetch("BERGAMOT_WIRE_PROTOCOL", str, "json").strip().lower()
WIRE_HZ        = envvar_fetch("BERGAMOT_WIRE_HZ", float, 3)
WIRE_SNAPSHOT_HZ = envvar_fetch("BERGAMOT_SNAPSHOT_HZ", float, 1)
WIRE_BATCH_MAX = envvar_fetch("BERGAMOT_BATCH_MAX", int, 128)
WIRE_EVENT_QUEUE_MAX = envvar_fetch("BERGAMOT_EVENT_QUEUE_MAX", int, 64)
WIRE_SNAPSHOT_QUEUE_MAX = envvar_fetch("BERGAMOT_SNAPSHOT_QUEUE_MAX", int, 8)
WIRE_MAX_FRAME_BYTES = envvar_fetch("BERGAMOT_WIRE_MAX_FRAME_BYTES", int,
                                    1024 * 1024)
WIRE_REC_MAX   = 30
WIRE_TIMEOUT   = 5
PROC_PATH      = "/proc/all_seer"

WIRE_MAGIC = b"BGW2"
WIRE_VERSION = 2
WIRE_KIND_SYSTEM_INFO = 1
WIRE_KIND_EVENT = 2
WIRE_KIND_PROC_SNAPSHOT = 3
WIRE_FLAG_CHECKSUM = 0x01

WIRE_TYPE_MAP = {
    "open": 1,
    "fork": 2,
    "connect": 3,
    "execve": 4,
    "accept": 5,
    "unlink": 6,
    "rename": 7,
    "setuid": 8,
    "setgid": 9,
    "setreuid": 10,
    "capset": 11,
    "keyctl": 12,
    "ptrace": 13,
    "getid": 14,
}

if WIRE_HZ <= 0:
    WIRE_HZ = 1
if WIRE_SNAPSHOT_HZ <= 0:
    WIRE_SNAPSHOT_HZ = 1
if WIRE_MAX_FRAME_BYTES < 256:
    WIRE_MAX_FRAME_BYTES = 256
if WIRE_PROTOCOL not in ("json", "binary"):
    WIRE_PROTOCOL = "json"


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


def _pack_str(val: object) -> bytes:
    data = str(val or "").encode("utf-8", errors="replace")
    if len(data) > 65535:
        data = data[:65535]
    return struct.pack("!H", len(data)) + data


def _encode_system_info_payload(obj: dict) -> bytes:
    return b"".join([
        _pack_str(obj.get("hostname", "")),
        _pack_str(obj.get("kernelver", "")),
        _pack_str(obj.get("distro", "")),
        _pack_str(obj.get("ipaddr", "")),
        _pack_str(obj.get("macaddr", "")),
        _pack_str(obj.get("processor", "")),
        _pack_str(obj.get("processor_vend", "")),
        struct.pack("!i", int(obj.get("ram_gbs", 0) or 0)),
    ])


def _encode_event_payload(obj: dict) -> bytes:
    ev_type = str(obj.get("type", "") or "")
    type_id = int(WIRE_TYPE_MAP.get(ev_type, 0))
    ts_s = int(obj.get("ts_s", 0) or 0)
    ts_ms = int(obj.get("ts_ms", 0) or 0)
    pid = int(obj.get("pid", 0) or 0)
    ppid = int(obj.get("ppid", 0) or 0)
    uid = int(obj.get("uid", 0) or 0)

    return b"".join([
        struct.pack("!qHiiiB", ts_s, ts_ms, pid, ppid, uid, type_id),
        _pack_str(obj.get("subtype", "")),
        _pack_str(obj.get("comm", "")),
        _pack_str(obj.get("arg1", obj.get("arg", ""))),
        _pack_str(obj.get("arg2", "")),
    ])


def _encode_snapshot_payload(obj: dict) -> bytes:
    ts_s = int(obj.get("ts_s", 0) or 0)
    ts_ms = int(obj.get("ts_ms", 0) or 0)
    rows = obj.get("processes", [])
    if not isinstance(rows, list):
        rows = []
    if len(rows) > 65535:
        rows = rows[:65535]

    chunks = [struct.pack("!qHH", ts_s, ts_ms, len(rows))]
    for row in rows:
        if not isinstance(row, dict):
            continue
        chunks.append(struct.pack(
            "!iiiH",
            int(row.get("pid", 0) or 0),
            int(row.get("ppid", 0) or 0),
            int(row.get("uid", 0) or 0),
            int(row.get("threads", 0) or 0),
        ))
        chunks.append(_pack_str(row.get("comm", "")))

    return b"".join(chunks)


def _encode_frame(kind: int, payload: bytes) -> bytes:
    csum = zlib.crc32(payload) & 0xFFFFFFFF
    return struct.pack(
        "!4sBBBBII",
        WIRE_MAGIC,
        WIRE_VERSION,
        kind,
        WIRE_FLAG_CHECKSUM,
        0,
        len(payload),
        csum,
    ) + payload

cdef object parse_line(str line):
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

cdef dict collect_process_snapshot():
    now = time.time()
    ts_s = int(now)
    ts_ms = int((now - ts_s) * 1000)
    processes: list[dict] = []
    cdef int found
    cdef bint got_name
    cdef bint got_ppid
    cdef bint got_uid
    cdef bint got_threads

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
            found = 0
            got_name = False
            got_ppid = False
            got_uid = False
            got_threads = False
            with open(status_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if (not got_name) and line.startswith("Name:\t"):
                        comm = line.split("\t", 1)[1].strip()
                        got_name = True
                        found += 1
                    elif (not got_ppid) and line.startswith("PPid:\t"):
                        ppid = int(line.split("\t", 1)[1].strip() or 0)
                        got_ppid = True
                        found += 1
                    elif (not got_uid) and line.startswith("Uid:\t"):
                        uid = int(line.split("\t", 1)[1].split()[0])
                        got_uid = True
                        found += 1
                    elif (not got_threads) and line.startswith("Threads:\t"):
                        threads = int(line.split("\t", 1)[1].strip() or 0)
                        got_threads = True
                        found += 1

                    if found >= 4:
                        break

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

    return {
        "kind": "proc_snapshot",
        "ts_s": ts_s,
        "ts_ms": ts_ms,
        "processes": processes,
    }


def _queue_put_drop_oldest(q: object, item: object):
    try:
        q.put_nowait(item)
    except queue.Full:
        try:
            q.get_nowait()
        except queue.Empty:
            pass
        try:
            q.put_nowait(item)
        except queue.Full:
            pass


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

    cpdef void connect(self):
        while not self._connect():
            pass

    cpdef bint send_batch(self, list events):
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
        cdef object obj
        cdef bytes bin_payload
        cdef int kind
        cdef list frames
        cdef int dropped_frames = 0
        if self._sock is None:
            return False

        if WIRE_PROTOCOL == "binary":
            frames = []
            for obj in payloads:
                if not isinstance(obj, dict):
                    continue

                if obj.get("kind") == "system_info":
                    kind = WIRE_KIND_SYSTEM_INFO
                    bin_payload = _encode_system_info_payload(obj)
                elif obj.get("kind") == "proc_snapshot":
                    kind = WIRE_KIND_PROC_SNAPSHOT
                    bin_payload = _encode_snapshot_payload(obj)
                else:
                    kind = WIRE_KIND_EVENT
                    bin_payload = _encode_event_payload(obj)

                if len(bin_payload) > WIRE_MAX_FRAME_BYTES:
                    dropped_frames += 1
                    continue

                frames.append(_encode_frame(kind, bin_payload))

            if dropped_frames:
                print(f"[under-seer] dropped {dropped_frames} oversized frame(s)",
                      flush=True)

            if not frames:
                return True

            data = b"".join(frames)
        else:
            payload = "\n".join(
                json.dumps(e, separators=(",", ":"), ensure_ascii=False)
                for e in payloads
            ) + "\n"
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
    cdef double poll_interval
    cdef double snapshot_interval
    cdef object event_queue
    cdef object snapshot_queue
    cdef object stop_event
    cdef object event_thread
    cdef object snapshot_thread

    sender = Sender(WIRE_DST, WIRE_PORT)
    sender.connect()

    poll_interval = 1 / WIRE_HZ
    snapshot_interval = 1 / WIRE_SNAPSHOT_HZ

    print(f"[under-seer] polling /proc/all_seer every "
          f"{poll_interval * 1000:.0f}ms", flush=True)
    print(f"[under-seer] process snapshots every "
          f"{snapshot_interval:.2f}s", flush=True)
    print(f"[under-seer] wire protocol mode: {WIRE_PROTOCOL}", flush=True)
    print("[under-seer] threading enabled: event-reader, snapshot-worker, sender",
          flush=True)

    event_queue = queue.Queue(maxsize=max(1, WIRE_EVENT_QUEUE_MAX))
    snapshot_queue = queue.Queue(maxsize=max(1, WIRE_SNAPSHOT_QUEUE_MAX))
    stop_event = threading.Event()

    event_thread = threading.Thread(
        target=underseer_workers.event_reader_run,
        args=(
            event_queue,
            stop_event,
            poll_interval,
            PROC_PATH,
            WIRE_BATCH_MAX,
            parse_line,
            _queue_put_drop_oldest,
        ),
        daemon=True,
        name="underseer-event-reader",
    )
    snapshot_thread = threading.Thread(
        target=underseer_workers.snapshot_worker_run,
        args=(
            snapshot_queue,
            stop_event,
            snapshot_interval,
            collect_process_snapshot,
            _queue_put_drop_oldest,
        ),
        daemon=True,
        name="underseer-snapshot-worker",
    )

    event_thread.start()
    snapshot_thread.start()

    try:
        underseer_workers.sender_run(sender, event_queue, snapshot_queue,
                                     stop_event)
    finally:
        stop_event.set()


if __name__ == "__main__":
    main()
