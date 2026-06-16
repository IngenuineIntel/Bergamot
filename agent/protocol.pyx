# protocol.pyx

from dataclasses import dataclass
import zlib

"""
Packet design

Each packet has 3 parts: the magic, the flags, and the body

The magic is always the same; it's the value of the `MAGIC` variable.

The flags are, in total, always 9 bytes, as follows:

   Protocol version (major number)     - 4 bits (max 16)
   |   Protocol version (minor number) - 4 bits (max 15)
   |   | Compression type              - 2 bits (max 4)
   |   | |  Compression level          - 3 bits (max 8)
   |   | |  |  Frame type              - 3 bits (max 7)
   |   | |  |  |           Data size (before compression)            - 12 bits
   |   | |  |  |           |           Data size (after compression) - 12 bits
   |   | |  |  |           |           |       Encoding mask                 - 1 byte
   |   | |  |  |           |           |       |       Field delimiter       - 1 byte
   |   | |  |  |           |           |       |       |       Row delimiter - 1 byte
   |   | |  |  |           |           |       |       |       |
,--+,--+,+,-+,-+,----------+,----------+,------+,------+,------+
0001000000101000010100110101001110110100011010011111111011111111

The body, compressed with the specified compression algorithm at a specified
level, makes up the remainder of the packet

Note: if either data size values are too large for the given space, the space
is filled with 0s to represent this.


Packet types:

System Info Packets
 - only one sent during connection startup
 - frame type = 0
 - holds 1 row
 - row values are represented in SystemInfo

Event Packets
 - sent multiple times a second
 - frame type = 1
 - holds any number of rows
 - row values are represented in Event

Process Snapshot Packets
 - sent a few times a second
 - frame type = 2
 - holds any number of rows
 - first row is timestamps, subsequent rows are a process each
 - first row is represented by ProcSnapshot, subsequent rows are represented by
   ProcSnapshot.processes

Performance Packets
 - sent a few times a second
 - frame type = 3
 - holds 1 row
 - row values are represented by Perf

"""

# static values for packet generation

# wire protocol version
WIRE_VERSION_STR = "1.0"
WIRE_VERSION_MAJOR = 1
WIRE_VERSION_MINOR = 0

# each kind of frame has its own identifying integer
FRAME_SYSINFO = 0
FRAME_EVENT   = 1
FRAME_PROCS   = 2
FRAME_PERF    = 3

# in the event different compression algorithms are used in the future
# (currently deflate is the only one), each supported algorithm gets its own
# identifying integer
COMP_DEFLATE = 0
#COMP_LZMA   = 1

# the choice of compression algorithm
COMPRESSION_ALGORITHM = COMP_DEFLATE

# level of compression used
COMPRESSION_LEVEL = 6

# every packet starts with the magic
MAGIC = b"BRGMTWP\x00"

# after compression, every byte is XOR'd with a mask
MASK = 0xB7

# every packet is separated into fields and rows, each with its own delimiter
# note: delimiter characters are escaped
FIELD_DELIM = b"\xff"
ROW_DELIM = b"\xfe"


# data types representative of different packet types
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
    """
    Casts `value` to a usable field bytestring
    """
    cdef bytes ret

    if value is None or value == "" or value == b"":
        value = " "

    if type(value) is bytes:
        ret = value
        ret = ret.replace(FIELD_DELIM, b" ")
        ret = ret.replace(ROW_DELIM, b" ")
    elif type(value) is str:
        ret = value.encode("utf-8", errors="replace")
        ret = ret.replace(FIELD_DELIM, b" ")
        ret = ret.replace(ROW_DELIM, b" ")
    elif type(value) is int:
        ret = str(int).encode("utf-8", errors="replace")
    elif type(value) is float:
        # preventing scientific representation
        ret = f"{value:.5f}".encode("utf-8", errors="replace")
    else:
        ret = b""

    return ret + FIELD_DELIM


cdef bytes _compress(bytes data):
    """
    Compresses data and XORs it
    """
    cdef bytearray compressed
    cdef Py_ssize_t i

    if COMPRESSION_ALGORITHM == COMP_DEFLATE:
        compressed = zlib.compress(data, level=COMPRESSION_LEVEL)
    else:
        return b""

    for i in range(len(compressed)):
        compressed[i] ^= MASK

    return compressed


cdef bytes _genflags(int kind, int data_len, int compressed_len):
    """
    Generates flags component of packet
    """
    cdef double packed

    if data_len <= 0 or compressed_len <= 0:
        raise ValueError("frame body may not be empty")

    # preventing overflows in data sizes
    if data_len > 0xFFF:
        data_len = 1
    if compressed_len > 0xFFF:
        compressed_len = 1

    packed = (
        ((WIRE_VERSION_MAJOR - 1) & 0b1111)
        | ((WIRE_VERSION_MINOR & 0b1111) << 4)
        | ((COMP_DEFLATE & 0b11) << 8)
        | (((COMPRESSION_LEVEL - 1) & 0b111) << 10)
        | ((kind & 0b111) << 13)
        | (((data_len - 1) & 0b111111111111) << 16)
        | (((compressed_len - 1) & 0b111111111111) << 28)
    )

    return packed.to_bytes(5, "big") + MASK.to_bytes(4, "big") + FIELD_DELIM + ROW_DELIM


cdef bytes _compile_system_info(object obj):
    """
    Turns SystemInfo object into an uncompressed packet body
    """
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
    """
    Turns Event objects into an uncompressed packet body
    """
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
    """
    Turns ProcSnapshot object into an uncompressed packet body
    """
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
    """
    Turns Perf object into an uncompressed packet body
    """
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


cpdef bytes gen_system_info(object obj):
    """
    Generates full packet from SystemInfo object
    """
    cdef bytes body
    cdef bytes compressed

    body = _compile_system_info(obj)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_SYSINFO, len(body), len(compressed)) + compressed


cpdef bytes gen_event(list objs):
    """
    Generates full packet from a list of Event objects
    """
    cdef bytes body
    cdef bytes compressed

    body = _compile_event(objs)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_EVENT, len(body), len(compressed)) + compressed


cpdef bytes gen_proc_snapshot(object obj):
    """
    Generates full packet from a ProcSnapshot object
    """
    cdef bytes body
    cdef bytes compressed

    body = _compile_proc_snapshot(obj)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_PROCS, len(body), len(compressed)) + compressed


cpdef bytes gen_perf(object obj):
    """
    Generates full packet from a Perf object
    """
    cdef bytes body
    cdef bytes compressed

    body = _compile_perf(obj)
    compressed = _compress(body)
    return MAGIC + _genflags(FRAME_PERF, len(body), len(compressed)) + compressed
