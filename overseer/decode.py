"""Wire protocol decoding for Over-Seer ingest."""

from dataclass import dataclass
import os
import zlib

# ─── DATA TYPES ──────────────────────────────────────────────────────────── #

@dataclass(slots=True)
class ProtocolData:

    # frame types
    frame_sysinfo_flag: int = 0
    frame_event_flag:   int = 1
    frame_procs_flag:   int = 2
    frame_perf_flag:    int = 3

    # compression types
    comp_deflate_flag: int = 0

    # protocol constants
    magic: bytes = b"BRGMTWP\x00"
    mask:  int   = 0xB3484307

_p = ProtocolData()

@dataclass(slots=True)
class SystemInfo:
    hostname: str
    kernelver: str
    distro: str
    ipaddr: str
    macaddr: str
    processor: str
    processor_vend: str
    ram_gbs: int

@dataclass(slots=True)
class Event:
    ts_s: int
    ts_ms: int
    pid: int
    type: str
    subtype: str
    arg1: str
    arg2: str
    retval: int

@dataclass(slots=True)
class Proc:
    pid
    ppid
    uid
    threads
    cpu_ticks
    vm_rss_kb
    comm

@dataclass(slots=True)
class ProcSnapshot:
    ts_s: int
    ts_ms: int
    processes: list[Proc]

@dataclass(slots=True)
class Perf:
    ts_s: int
    ts_ms: int
    cores: int
    avg_cpu_pct: float
    mem_total_kb: int
    mem_free_kb: int
    mem_available_kb: int
    mem_cached_kb: int
    load_1m: float
    load_5m: float
    load_15m: float
    cores_json: str

@dataclass(slots=True)
class Flags:
    protocol_version_major: int
    protocol_version_minor: int
    compression_type: int
    compression_level: int
    frame_type: int
    data_size: int
    compressed_size: int
    xor_mask: int
    field_delim: bytes
    row_delim: bytes

def parse_system_info(body: bytes, field_delim: bytes, row_delim: bytes) -> SystemInfo:
    pass # TODO

def parse_event(body: bytes, field_delim: bytes, row_delim: bytes) -> list[Event]:
    pass # TODO

def parse_proc_snapshot(body: bytes, field_delim: bytes, row_delim: bytes) -> ProcSnapshot:
    pass # TODO

def parse_perf(body: bytes, field_delim: bytes, row_delim: bytes) -> Perf:
    pass # TODO

def parse_flags(flags: bytes) -> Flags:
    ret = Flags()

    sect1 = int.from_bytes(flags[0:4])

    ret.protocol_version_major = sect1 & 0x0000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    ret.protocol_version_minor = sect1 & 0xFFFF0000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    ret.compression_type       = sect1 & 0xFFFFFFFF00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    ret.compression_level      = sect1 & 0xFFFFFFFFFF000FFFFFFFFFFFFFFFFFFFFFFFFFFF
    ret.frame_type             = sect1 & 0xFFFFFFFFFFFFF000FFFFFFFFFFFFFFFFFFFFFFFF
    ret.data_size              = sect1 & 0xFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFF
    ret.compressed_size        = sect1 & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000

    ret.xor_mask = int.from_bytes(flags[5:8])
    ret.field_delim = flags[9]
    ret.row_delim   = flags[10]

    return ret

def decompress(compression_type: int, compression_level: int, mask: int, b: bytes) -> bytes:
    ret = b

    for i in ret:
        i ^= mask

    match compression_type:
        case _p.comp_deflate_flag:
            return zlib.decompress(ret)
        case _: # deflate (there are no others)
            return zlib.decompress(ret)

def parse_frame(frame: bytes) -> SystemInfo | list[Event] | ProcSnapshot | Perf:

    # parsing magic
    if not bytes.startswith(_p.magic):
        pass # some sort of "aw HELL nah"
    bytes.strip(_p.magic)

    # parsing flags (11 bytes)
    flags = parse_flags(frame[0:10])

    body = decompress(
        flags.compression_type,
        flags.compression_level,
        flags.mask,
        frame[11:]
    )

    match flags.frame_type:
        case _p.frame_sysinfo_flag:
            return parse_system_info(body, flags.field_delim, flags.row_delim)
        case _p.frame_event_flag:
            return parse_event(body, flags.field_delim, flags.row_delim)
        case _p.procs_flag:
            return parse_proc_snapshot(body, flags.field_delim, flags.row_delim)
        case _p.perf:
            return parse_perf(body, flags.field_delim, flags.row_delim)
