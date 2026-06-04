# protocol.pyx

from dataclass import dataclass
import zlib


# ── PROTOCOL SETTINGS ────────────────────────────────────────────────────── #

@dataclass(slots=True)
cdef class FrameKinds:
    cdef int sysinfo = 0
    cdef int event   = 1
    cdef int procs   = 2
    cdef int perf    = 3

@dataclass(slots=True)
class CompressionKinds:
    cdef int deflate_flag = 0
    #cdef int lz4_flag    = 1
    #cdef int lzma_flag   = 2
    # etc.

    @classmethod
    def getflag(cls, str algorithm):
        match algorithm:
            case "deflate":
                return cls.deflate_flag
            case _:
                return cls.deflate_flag

@dataclass(slots=True)
cdef class ProtocolSettings:

    # compression settings
    cdef str algorithm = "deflate"
    cdef int compression_lvl = 6
    
    cdef object comp = CompressionKinds()
    cdef object kinds = FrameKinds()

    # start magic
    cdef int magic = b"BRGMTWP\x00"

    # version settings
    cdef int version_major = 1
    cdef int version_minor = 0
    
    # XOR mask
    cdef int mask = 0xB3484307

    # field delimiter
    cdef int delim = 0xFF.to_bytes(1)

    # row delimiter
    cdef int rowdelim = 0xFE.to_bytes(1)

    class FlagGenError(Exception):
        """Errors in flag generation are handled like this."""

    # TODO should I make this in C?
    @classmethod
    cdef bytes genflags(cls, int kind, int data_len, int compressed_len):
        """
        Generates the flags for a frame via bitpacking.
        Note that all values that can't be 0 are -1 in transit to extend
        potential values.

        Example:

        (first bit at top, last bit at bottom)

        1 +--- protocol version (major) - 4 bits  - max 16
        0 |
        0 |
        0 /

        0 +--- protocol version (minor) - 4 bits  - max 15
        0 |
        0 |
        0 /

        0 +--- compression type - 2 bits - max 4
        0 /

        1 +--- compression level (if applicable) - 3 bits  - max 8
        0 |
        1 /

        0 +--- frame type - 3 bits  - max 4
        0 |
        0 /

        0 +--- data size (before compression) - 12 bits - max 4096
        1 |
        0 |
        [SNIP]
        1 |
        0 /

        0 +--- data size (after compression) - 12 bits - max 4096
        0 |
        1 |
        [SNIP]
        1 |
        0 /

        0 +--- XOR mask - 4 bytes - N/A
        1 |
        1 |
        [SNIP]
        1 |
        0 /

        0 +--- field delimiter - 1 byte  - N/A
        1 |
        0 |
        [SNIP]
        0 |
        0 /

        1 +--- row delimiter - 1 byte - N/A
        1 |
        1 |
        [SNIP]
        1 |
        1 /

        Total: 11 bytes

        Notes:
        1. if data sizes are >1024, the minimum value will be put
        2. if other values are more than their maximum, None is returned
        """

        cdef double ret

        ### data fetching ###

        cdef int compression_flag = cls.comp.getflag(cls.algorithm)


        ### size checking ###

        # zlib compression level cannot be more than 9
        if cls.compression_flag == cls.comp.deflate_flag and cls.compression_lvl > 9:
            raise cls.FlagGenError("compression level cannot be more than 9 for deflate")


        ### preparing ###
        
        # + is higher in the order of operations than <<
        ret = (
            cls.version_major -1
            + (cls.version_minr       << 4)
            + (compression_flag       << 8)
            + (cls.compression_lvl -1 << 10)
            + (king                   << 13)
            + (data_len            -1 << 16)
            + (compressed_len      -1 << 28)
        )

        return ret.to_bytes(5) + cls.mask.to_bytes(4) + cls.delim + cls.rowdelim


sets = ProtocolSettings()


# ── COMPILATION & COMPRESSION ────────────────────────────────────────────── #

@dataclass(slots=True)
cdef class SystemInfo:
    cdef str hostname
    cdef str kernelver
    cdef str distro
    cdef str ipaddr
    cdef str macaddr
    cdef str processor
    cdef str processor_vend
    cdef int ram_gbs

@dataclass(slots=True)
cdef class Event:
    cdef int ts_s
    cdef int ts_ms
    cdef int pid
    cdef str type
    cdef str subtype
    cdef str arg1
    cdef str arg2
    cdef int retval

@dataclass(slots=True)
cdef class ProcSnapshot:
    cdef int ts_s
    cdef int ts_ms
    cdef list processes

@dataclass(slots=True)
cdef class Proc:
    cdef int pid
    cdef int ppid
    cdef int uid
    cdef int threads
    cdef int cpu_ticks
    cdef int vm_rss_kb
    cdef str comm

@dataclass(slots=True)
cdef class Perf:
    cdef int ts_s
    cdef int ts_ms
    cdef int cores
    cdef float avg_cpu_pct
    cdef int mem_total_kb
    cdef int mem_free_kb
    cdef int mem_available_kb
    cdef int mem_cached_kb
    cdef float load_1m
    cdef float load_5m
    cdef float load_15m
    cdef str cores_json


# compression wrapper for simplicity dtl
cdef bytes compress(bytes b):
    cdef bytes ret
    match ProtocolSettings.algorithm:
        case "deflate":
            ret = zlib.compress(b, level=sets.compression_lvl)
        case _: # default is deflate
            ret = zlib.compress(b, level=sets.compression_lvl)

    for i in ret:
        i ^= sets.mask
    
    return ret

cdef bytes prep_field(object s):
    # protecting against empty fields
    # failure to do this will make the Overseer drop the packet over an empty
    # field
    if s is None or s == "":
        s = " "

    if type(s) is str:
        return s.encode("utf-8", errors="replace")
            .replace(sets.delim,    b" ")
            .replace(sets.rowdelim, b" ") + sets.delim
    elif type(s) is int:
        return str(s).encode("utf-8", errors="replace") + sets.delim
    elif type(s) is float:
        return str(s).encode("utf-8", errors="replace") + sets.delim


### SYSTEM_INFO ###

cdef bytes compile_system_info(obj):
    cdef bytes data
    
    data += prep_field(obj.hostname)
    data += prep_field(obj.kernelver)
    data += prep_field(obj.distro)
    data += prep_field(obj.ipaddr)
    data += prep_field(obj.macaddr)
    data += prep_field(obj.processor)
    data += prep_field(obj.processor_vend)
    data += prep_field(obj.ram_gbs)

    return data

cdef bytes gen_system_info(list objs):
    cdef bytes data
    cdef bytes body

    cdef int body_sz
    cdef int compressed_sz

    body = compile_system_info(objs)
    body_sz = len(body)

    body = compress(body)
    compressed_sz = len(body)

    data += sets.magic
    data += sets.genflags(sets.kinds.sysinfo, body_sz, compressed_sz)
    data += body

    return data


### EVENT ###

cdef bytes compile_event(list objs):
    cdef bytes data

    for obj in objs:
        data += prep_field(obj.ts_s)
        data += prep_field(obj.ts_ms)
        data += prep_field(obj.type)
        data += prep_field(obj.subtype)
        data += prep_field(obj.arg1)
        data += prep_field(obj.arg2)
        data += prep_field(obj.retval)

        data += sets.rowdelim
    
    return data

cdef bytes gen_event(list objs):
    cdef bytes data
    cdef bytes body

    cdef int body_sz
    cdef int compressed_sz

    body = compile_event(objs)
    body_sz = len(body)

    body = compress(body)
    compressed_sz = len(body)

    data += sets.magic
    data += sets.genflags(sets.kinds.event, body_sz, compressed_sz)
    data += body

    return data


### PROC_SNAPSHOT ###

cdef bytes compile_proc_snapshot(object obj):
    cdef bytes data

    data += prep_field(obj.ts_s)
    data += prep_field(obj.ts_ms)
        
    data += sets.rowdelim

    for proc in obj.processes:
        data += prep_field(obj.pid)
        data += prep_field(obj.ppid)
        data += prep_field(obj.uid)
        data += prep_field(obj.threads)
        data += prep_field(obj.cpu_ticks)
        data += prep_field(obj)

        data += sets.rowdelim
    
    return data

cdef bytes gen_proc_snapshot(object obj):
    cdef bytes data
    cdef bytes body

    cdef int body_sz
    cdef int compressed_sz

    body = compile_event(obj)
    body_sz = len(body)

    body = compress(body)
    compressed_sz = len(body)

    data += sets.magic
    data += sets.genflags(sets.kinds.procs, body_sz, compressed_sz)
    data += body

    return data


### PERF ###

cdef bytes compile_perf(object obj):
    cdef bytes data

    data += prep_field(obj.ts_s)
    data += prep_field(obj.ts_ms)
    data += prep_field(obj.cores)
    data += prep_field(obj.avg_cpu_pct)
    data += prep_field(obj.mem_total_kb)
    data += prep_field(obj.mem_free_kb)
    data += prep_field(obj.mem_available_kb)
    data += prep_field(obj.mem_cached_kb)
    data += prep_field(obj.load_1m)
    data += prep_field(obj.load_5m)
    data += prep_field(obj.load_15m)
    data += prep_field(obj.cores_json)

    return data

cdef bytes gen_perf(object obj):
    cdef bytes data
    cdef bytes body

    cdef int body_sz
    cdef int compressed_sz

    body = compile_perf(obj)
    body_sz = len(body)

    body = compress(body)
    compressed_sz = len(body)

    data += sets.magic
    data += sets.genflags(sets.kinds.perf, body_sz, compressed_sz)
