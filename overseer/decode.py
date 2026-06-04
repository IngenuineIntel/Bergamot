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
    pid: int
    ppid: int
    uid: int
    threads: int
    cpu_ticks: int
    vm_rss_kb: int
    comm: str

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

class FrameProcessingError(Exception):
    """A frame was malformed. Just catch."""


def _getf(f: bytes, desire: type) -> str | int | float:
    if desire is str:
        return bytes.decode("utf-8")
    elif desire is int:
        try:
            return int(bytes)
        except ValueError:
            raise FrameProcessingError(f"Garbage integer {bytes}")
    elif desire is float:
        try:
            return float(bytes)
        except ValueError:
            raise FrameProcessingError(f"Garbage float {bytes}")

def parse_system_info(body: bytes, field_delim: bytes, row_delim: bytes) -> SystemInfo:
    ret = SystemInfo()
    data = body.split(field_delim)
    try:
        ret.hostname       = _getf(data[0], str)
        ret.kernelver      = _getf(data[1], str)
        ret.distro         = _getf(data[2], str)
        ret.ipaddr         = _getf(data[3], str)
        ret.macaddr        = _getf(data[4], str)
        ret.processor      = _getf(data[5], str)
        ret.processor_vend = _getf(data[6], str)
        ret.ram_gbs        = _getf(data[7], int)

    # replace default errors with custom ones for handling
    except IndexError as e:
        raise FrameProcessingError(f"Insufficient number of fields @ {len(data)}") from e

    return ret

def parse_event(body: bytes, field_delim: bytes, row_delim: bytes) -> list[Event]:
    ret = []
    data = body.split(row_delim)
    try:
        for row in data:
           d = row.split(field_delim)
           e = Event()

            e.ts_s    = _getf(d[0], int)
            e.ts_ms   = _getf(d[1], int)
            e.pid     = _getf(d[2], int)
            e.type    = _getf(d[3], str)
            e.subtype = _getf(d[4], str)
            e.arg1    = _getf(d[5], str)
            e.arg2    = _getf(d[6], str)
            e.retval  = _getf(d[7], int)

            ret.append(e)
    
    except IndexError as e:
        raise FrameProcessingError(f"Insufficient number of fields in event") from e

    return ret

def parse_proc_snapshot(body: bytes, field_delim: bytes, row_delim: bytes) -> ProcSnapshot:
    ret = ProcSnapshot()
    data = body.split(row_delim)

    try:
        at1 = True
        for row in data:
            if at1:
                at1 = False
                ret.ts_s  = _getf(row[0], int)
                ret.ts_ms = _getf(row[1], int)
                continue
            # else:
        
            p = Proc()
            p.pid       = _getf(row[0], int)
            p.ppid      = _getf(row[1], int)
            p.uid       = _getf(row[2], int)
            p.threads   = _getf(row[3], int)
            p.cpu_ticks = _getf(row[4], int)
            p.vm_rss_kb = _getf(row[5], int)
            p.comm      = row[6].decode("utf-8")

            ret.processes.append(p)
        
    except IndexError as e:
        raise FrameProcessingError("Insufficient number of fields in proc") from e

    return ret


def parse_perf(body: bytes, field_delim: bytes, row_delim: bytes) -> Perf:
    ret = Perf()
    data = body.split(field_delim)

    try:
        ret.ts_s             = _getf(row[0], int)
        ret.ts_ms            = _getf(row[1], int)
        ret.cores            = _getf(row[2], int)
        ret.avg_cpu_pct      = _getf(row[3], float)
        ret.mem_total_kb     = _getf(row[4], int)
        ret.mem_free_kb      = _getf(row[5], int)
        ret.mem_available_kb = _getf(row[6], int)
        ret.mem_cached_kb    = _getf(row[7], int)
        ret.load_1m          = _getf(row[8], float)
        ret.load_5m          = _getf(row[9], float)
        ret.load_15m         = _getf(row[10], float)
        ret.cores_json       = _getf(row[11], str)

    except IndexError as e:
        raise FrameProcessingError("Insufficient number of fields in perf") from e

def parse_flags(flags: bytes) -> Flags:
    ret = Flags()

    sect1 = int.from_bytes(flags[0:4])

    ret.protocol_version_major = sect1 & 0x0000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    ret.protocol_version_minor = sect1 & 0xFFFF0000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF >> 4
    ret.compression_type       = sect1 & 0xFFFFFFFF00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFF >> 8
    ret.compression_level      = sect1 & 0xFFFFFFFFFF000FFFFFFFFFFFFFFFFFFFFFFFFFFF >> 10
    ret.frame_type             = sect1 & 0xFFFFFFFFFFFFF000FFFFFFFFFFFFFFFFFFFFFFFF >> 13
    ret.data_size              = sect1 & 0xFFFFFFFFFFFFFFFF000000000000FFFFFFFFFFFF >> 16
    ret.compressed_size        = sect1 & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000 >> 28

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
        raise FrameProcessingError(
            f"Frame didn't have magic, or magic was a garbage (expected {_p.magic})"
        )
    bytes.strip(_p.magic)

    # parsing flags (11 bytes)
    flags = parse_flags(frame[0:10])

    # size check #1
    if len(body) != flags.compressed_size:
        raise FrameProcessingError(
            f"Header claims compressed data is {flags.compressed_size} bytes, but it's really {len(body)} bytes."
        )

    body = decompress(
        flags.compression_type,
        flags.compression_level,
        flags.mask,
        frame[11:]
    )

    # size check #2
    if len(body) != flags.data_size:
        raise FrameProcessingError(
            f"Header claims decompressed data is {flags.data_size} bytes, but it's really {len(body)} bytes."
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
