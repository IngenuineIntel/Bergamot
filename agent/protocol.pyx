"""Bergamot wire protocol constants and frame encoding helpers."""

import struct
import zlib

WIRE_MAGIC = b"BGW1"
WIRE_VERSION = 1          # wire byte; protocol version 1.0
WIRE_VERSION_STR = "1.0"
WIRE_KIND_SYSTEM_INFO = 1
WIRE_KIND_EVENT = 2
WIRE_KIND_RICH_PROC_SNAPSHOT = 4
WIRE_KIND_SYSTEM_PERF = 5
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


def _pack_str(val: object) -> bytes:
    data = str(val or "").encode("utf-8", errors="replace")
    if len(data) > 65535:
        data = data[:65535]
    return struct.pack("!H", len(data)) + data


def encode_system_info_payload(obj: dict) -> bytes:
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


def encode_event_payload(obj: dict) -> bytes:
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


def encode_rich_snapshot_payload(obj: dict) -> bytes:
    """Encode kind=4 rich_proc_snapshot: adds cpu_ticks (uint64) and vm_rss_kb (uint32) per row."""
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
            "!iiiHQI",
            int(row.get("pid", 0) or 0),
            int(row.get("ppid", 0) or 0),
            int(row.get("uid", 0) or 0),
            int(row.get("threads", 0) or 0),
            int(row.get("cpu_ticks", 0) or 0),
            int(row.get("vm_rss_kb", 0) or 0),
        ))
        chunks.append(_pack_str(row.get("comm", "")))

    return b"".join(chunks)


def encode_system_perf_payload(obj: dict) -> bytes:
    """Encode kind=5 system_perf: per-core CPU ticks, RAM 4-tuple, load avg 3-tuple."""
    ts_s = int(obj.get("ts_s", 0) or 0)
    ts_ms = int(obj.get("ts_ms", 0) or 0)
    cores = obj.get("cores", [])
    if not isinstance(cores, list):
        cores = []
    num_cores = min(len(cores), 255)

    mem = obj.get("mem", [0, 0, 0, 0])
    load = obj.get("load", [0.0, 0.0, 0.0])

    chunks = [struct.pack("!qHBx", ts_s, ts_ms, num_cores)]
    for core in cores[:num_cores]:
        if not isinstance(core, list) or len(core) < 7:
            core = [0] * 7
        chunks.append(struct.pack("!7Q", *[int(v) for v in core[:7]]))

    chunks.append(struct.pack("!4Q",
        int(mem[0]) if len(mem) > 0 else 0,
        int(mem[1]) if len(mem) > 1 else 0,
        int(mem[2]) if len(mem) > 2 else 0,
        int(mem[3]) if len(mem) > 3 else 0,
    ))
    # load avg stored as fixed-point x100, clamped to uint16 max (655.35)
    chunks.append(struct.pack("!3H",
        min(int(float(load[0] if len(load) > 0 else 0) * 100), 65535),
        min(int(float(load[1] if len(load) > 1 else 0) * 100), 65535),
        min(int(float(load[2] if len(load) > 2 else 0) * 100), 65535),
    ))

    return b"".join(chunks)


def encode_frame(kind: int, payload: bytes) -> bytes:
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


def encode_wire_payload(obj: dict) -> tuple[int, bytes]:
    if obj.get("kind") == "system_info":
        return WIRE_KIND_SYSTEM_INFO, encode_system_info_payload(obj)
    if obj.get("kind") == "rich_proc_snapshot":
        return WIRE_KIND_RICH_PROC_SNAPSHOT, encode_rich_snapshot_payload(obj)
    if obj.get("kind") == "system_perf":
        return WIRE_KIND_SYSTEM_PERF, encode_system_perf_payload(obj)
    return WIRE_KIND_EVENT, encode_event_payload(obj)


def event_frame_size_bytes(obj: dict) -> int:
    if not isinstance(obj, dict):
        return 0
    kind, payload = encode_wire_payload(obj)
    if kind != WIRE_KIND_EVENT:
        return 0
    return len(encode_frame(kind, payload))


def object_frame_size_bytes(obj: dict) -> int:
    if not isinstance(obj, dict):
        return 0
    kind, payload = encode_wire_payload(obj)
    return len(encode_frame(kind, payload))
