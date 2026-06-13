# protocol.pyx

from dataclasses import dataclass
import zlib

cimport cython

WIRE_VERSION_STR = "1.0"

FRAME_SYSINFO = 0
FRAME_EVENT = 1
FRAME_PROCS = 2
FRAME_PERF = 3

COMP_DEFLATE = 0

MAGIC = b"BRGMTWP\x00"
MASK = 0xB3484307
FIELD_DELIM = b"\xff"
ROW_DELIM = b"\xfe"

@dataclass
cdef class SystemInfo:
    hostname: str
    kernelver: str
    distro: str
    ipaddr: str
    macaddr: str
    processor: str
    processor_vend: str
    ram_gbs: int

@dataclass
cdef class Event:
    ts_s: int
    ts_ms: int
    pid: int
    type: str
    subtype: str
    arg1: str
    arg2: str
    retval: int

@dataclass
cdef class Proc:
    pid: int
    ppid: int
    uid: int
    threads: int
    cpu_ticks: int
    vm_rss_kb: int
    comm: str

@dataclass
cdef class ProcSnapshot:
     ts_s: int
     ts_ms: int
     processes: list[Proc]

@dataclass
cdef class Perf:
    ts_s: int
    ts_ms: int
    cores: int
    avg_cpu_pct: int
    mem_total_kb: int
    mem_free_kb: int
    mem_available_kb: int
    mem_cached_kb: int
    load_1m: float
    load_5m: float
    load_15m: float
    cores_json: str



cdef bytes _encode_field(object value):
    cdef bytes raw

    if value is None or value == "" or value == b"":
        value = " "

    if type(value) is bytes:
        raw = value
    else:
        raw = str(value).encode("utf-8", errors="replace")

    return raw.replace(FIELD_DELIM, b" ").replace(ROW_DELIM, b" ") + FIELD_DELIM


cdef bytes _compress(bytes data):
    cdef bytearray masked
    cdef bytes compressed
    cdef bytes mask_bytes
    cdef Py_ssize_t i

    compressed = zlib.compress(data, level=6)
    masked = bytearray(compressed)
    mask_bytes = MASK.to_bytes(4, "big")

    for i in range(len(masked)):
        masked[i] ^= mask_bytes[i % 4]

    return bytes(masked)


cdef bytes _genflags(int kind, int data_len, int compressed_len):
    cdef int packed

    if data_len <= 0 or compressed_len <= 0:
        raise ValueError("frame body may not be empty")

    if data_len > 0xFFF:
        data_len = 1
    if compressed_len > 0xFFF:
        compressed_len = 1

    # TODO comment about the bitpacking

    packed = (
        ((1 - 1) & 0xF)
        | ((0 & 0xF) << 4)
        | ((COMP_DEFLATE & 0x3) << 8)
        | ((6 - 1) << 10)
        | ((kind & 0x7) << 13)
        | ((data_len - 1) << 16)
        | ((compressed_len - 1) << 28)
    )

    return packed.to_bytes(5, "big") + MASK.to_bytes(4, "big") + FIELD_DELIM + ROW_DELIM


cdef bytes _compile_system_info(object obj):
    cdef bytes data = b""

    data += _encode_field(obj.hostname)
    data += _encode_field(obj.kernelver)
    data += _encode_field(obj.distro)
    data += _encode_field(obj.ipaddr)
    data += _encode_field(obj.macaddr)
    data += _encode_field(obj.processor)
    data += _encode_field(obj.processor_vend)
    data += _encode_field(obj.ram_gbs)

    return data


cdef bytes _compile_event(list objs):
    cdef bytes data = b""
    cdef object obj

    for obj in objs:
        data += _encode_field(obj.ts_s)
        data += _encode_field(obj.ts_ms)
        data += _encode_field(obj.pid)
        data += _encode_field(obj.type)
        data += _encode_field(obj.subtype)
        data += _encode_field(obj.arg1)
        data += _encode_field(obj.arg2)
        data += _encode_field(obj.retval)
        data += ROW_DELIM

    return data


cdef bytes _compile_proc_snapshot(object obj):
    cdef bytes data = b""
    cdef object proc

    data += _encode_field(obj.ts_s)
    data += _encode_field(obj.ts_ms)
    data += ROW_DELIM

    for proc in obj.processes:
        data += _encode_field(proc.pid)
        data += _encode_field(proc.ppid)
        data += _encode_field(proc.uid)
        data += _encode_field(proc.threads)
        data += _encode_field(proc.cpu_ticks)
        data += _encode_field(proc.vm_rss_kb)
        data += _encode_field(proc.comm)
        data += ROW_DELIM

    return data


cdef bytes _compile_perf(object obj):
    cdef bytes data = b""

    data += _encode_field(obj.ts_s)
    data += _encode_field(obj.ts_ms)
    data += _encode_field(obj.cores)
    data += _encode_field(obj.avg_cpu_pct)
    data += _encode_field(obj.mem_total_kb)
    data += _encode_field(obj.mem_free_kb)
    data += _encode_field(obj.mem_available_kb)
    data += _encode_field(obj.mem_cached_kb)
    data += _encode_field(obj.load_1m)
    data += _encode_field(obj.load_5m)
    data += _encode_field(obj.load_15m)
    data += _encode_field(obj.cores_json)

    return data


def gen_system_info(object obj):
    cdef bytes body
    cdef bytes compressed

    body = _compile_system_info(obj)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_SYSINFO, len(body), len(compressed)) + compressed


def gen_event(list objs):
    cdef bytes body
    cdef bytes compressed

    body = _compile_event(objs)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_EVENT, len(body), len(compressed)) + compressed


def gen_proc_snapshot(object obj):
    cdef bytes body
    cdef bytes compressed

    body = _compile_proc_snapshot(obj)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_PROCS, len(body), len(compressed)) + compressed


def gen_perf(object obj):
    cdef bytes body
    cdef bytes compressed

    body = _compile_perf(obj)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_PERF, len(body), len(compressed)) + compressed


def event_frame_size_bytes(object obj):
    return len(gen_event([obj]))


def object_frame_size_bytes(object obj):
    if isinstance(obj, ProcSnapshot):
        return len(gen_proc_snapshot(obj))
    if isinstance(obj, Perf):
        return len(gen_perf(obj))
    if isinstance(obj, SystemInfo):
        return len(gen_system_info(obj))
    if isinstance(obj, Event):
        return len(gen_event([obj]))
    return 0
