"""Wire protocol decoding for Over-Seer ingest."""

import os
import struct
import zlib

@dataclass(slots=True)
class Rows:

    @dataclass(slots=True)
    class OvervRow:
        hostname:       str = "unknown"
        kernelver:      str = "unknown"
        distro:         str = "unknown"
        ipaddr:         str = "unknown"
        macaddr:        str = "unknown"
        processor:      str = "unknown"
        processor_vend: str = "unknown"
        ram_gbs:        int = 0


    # TODO Ken Thompson regretted `creat`, will I regret `EvntRow`?
    @dataclass(slots=True)
    class EvntRow:
        #id: int
        ts_s:    int
        ts_ms:   int
        pid:     int
        type:    str
        subtype: str | None
        arg1:    str | None
        arg2:    str | None
        retval:  int

    @dataclass(slots=True)
    class ProcRow:
        #id: int
        pid: int
        first_seen_ts_s:  int
        first_seen_ts_ms: int
        last_seen_ts_s:   int
        last_seen_ts_ms:  int
        ended_ts_s:       int | None
        ended_ts_ms:      int | None
        first_uid:        int
        first_ppid:       int
        first_comm:       str
        last_uid:         int | None
        last_ppid:        int | None
        last_comm:        str | None

    @dataclass(slots=True)
    class PerfRow:
        #id: int
        ts_s: int
        ts_ms: int
        core_count: int
        avg_cpu_pct: float

        @dataclass(slots=True)
        class mem:
            total_kb: int
            free_kb: int
            available_kb: int
            cached_kb: int

        load_1m: float
        load_5m: float
        load_15m: float
        # TODO this is silly?
        cores_json: str

class WireDecoder:
    WIRE_MAGIC = b"BGW1"
    WIRE_VERSION = 1
    WIRE_VERSION_STR = "1.0"

    WIRE_KIND_SYSTEM_INFO        = 1
    WIRE_KIND_EVENT              = 2
    WIRE_KIND_RICH_PROC_SNAPSHOT = 4
    WIRE_KIND_SYSTEM_PERF        = 5
    
    WIRE_FLAG_CHECKSUM = 0x01
    WIRE_ALLOWED_FLAGS = WIRE_FLAG_CHECKSUM
    HEADER_FORMAT = "!4sBBBBII"

    WIRE_TYPE_MAP = {
        1: "open",
        2: "fork",
        3: "connect",
        4: "execve",
        5: "accept",
        6: "unlink",
        7: "rename",
        8: "setuid",
        9: "setgid",
        10: "setreuid",
        11: "capset",
        12: "keyctl",
        13: "ptrace",
        14: "getid",
    }

    def __init__(self):
        try:
            self.max_frame_bytes = max(
                256,
                int(os.environ.get("BERGAMOT_WIRE_MAX_FRAME_BYTES", "1048576")),
            )
        except ValueError:
            self.max_frame_bytes = 1024 * 1024
        self.header_size = struct.calcsize(self.HEADER_FORMAT)

    @staticmethod
    def _read_u16(buf: bytes, pos: int):
        if pos + 2 > len(buf):
            raise ValueError("short u16")
        return struct.unpack("!H", buf[pos:pos + 2])[0], pos + 2

    def _read_str(self, buf: bytes, pos: int):
        size, pos = self._read_u16(buf, pos)
        end = pos + size
        if end > len(buf):
            raise ValueError("short string")
        return buf[pos:end].decode("utf-8", errors="replace"), end

    def unpack_header(self, data: bytes):
        if len(data) < self.header_size:
            raise ValueError("short frame header")
        return struct.unpack(self.HEADER_FORMAT, data[:self.header_size])

    def validate_header(self, magic: bytes, version: int, flags: int, payload_len: int):
        if magic != self.WIRE_MAGIC:
            return "bad_magic", "bad magic"
        if version != self.WIRE_VERSION:
            return "bad_version", f"unsupported version {version}"
        if flags & ~self.WIRE_ALLOWED_FLAGS:
            return "bad_flags", f"unknown flags 0x{flags:x}"
        if not (flags & self.WIRE_FLAG_CHECKSUM):
            return "bad_flags", "missing checksum flag"
        if payload_len > self.max_frame_bytes:
            return "oversized", f"frame too large ({payload_len})"
        return None, None

    @staticmethod
    def checksum_matches(payload: bytes, checksum: int):
        calc_sum = zlib.crc32(payload) & 0xFFFFFFFF
        return checksum == calc_sum

    def decode_system_info(self, payload: bytes):
        pos = 0
        hostname, pos = self._read_str(payload, pos)
        kernelver, pos = self._read_str(payload, pos)
        distro, pos = self._read_str(payload, pos)
        ipaddr, pos = self._read_str(payload, pos)
        macaddr, pos = self._read_str(payload, pos)
        processor, pos = self._read_str(payload, pos)
        processor_vend, pos = self._read_str(payload, pos)
        if pos + 4 > len(payload):
            raise ValueError("short ram_gbs")
        ram_gbs = struct.unpack("!i", payload[pos:pos + 4])[0]

        return {
            "kind": "system_info",
            "hostname": hostname,
            "kernelver": kernelver,
            "distro": distro,
            "ipaddr": ipaddr,
            "macaddr": macaddr,
            "processor": processor,
            "processor_vend": processor_vend,
            "ram_gbs": ram_gbs,
        }

    def decode_event(self, payload: bytes):
        base_sz = struct.calcsize("!qHiiiB")
        if len(payload) < base_sz:
            raise ValueError("short event header")
        ts_s, ts_ms, pid, ppid, uid, type_id = struct.unpack("!qHiiiB", payload[:base_sz])
        retval = 0

        def _decode_event_fields(start_pos: int):
            field_pos = start_pos
            subtype_val, field_pos = self._read_str(payload, field_pos)
            comm_val, field_pos = self._read_str(payload, field_pos)
            arg1_val, field_pos = self._read_str(payload, field_pos)
            arg2_val, field_pos = self._read_str(payload, field_pos)
            if field_pos != len(payload):
                raise ValueError("trailing event payload bytes")
            return subtype_val, comm_val, arg1_val, arg2_val

        retval_sz = struct.calcsize("!q")
        try:
            if len(payload) < base_sz + retval_sz:
                raise ValueError("short retval field")
            (retval,) = struct.unpack("!q", payload[base_sz:base_sz + retval_sz])
            subtype, comm, arg1, arg2 = _decode_event_fields(base_sz + retval_sz)
        except ValueError:
            retval = 0
            subtype, comm, arg1, arg2 = _decode_event_fields(base_sz)

        ev_type = self.WIRE_TYPE_MAP.get(type_id, "unknown")
        out_arg2 = arg2
        if ev_type == "ptrace" and arg2:
            try:
                out_arg2 = int(arg2)
            except ValueError:
                out_arg2 = arg2

        return {
            "ts_s": int(ts_s),
            "ts_ms": int(ts_ms),
            "pid": int(pid),
            "ppid": int(ppid),
            "uid": int(uid),
            "type": ev_type,
            "subtype": subtype,
            "comm": comm,
            "arg": arg1,
            "arg1": arg1,
            "arg2": out_arg2,
            "retval": int(retval),
        }

    def decode_rich_proc_snapshot(self, payload: bytes):
        header_sz = struct.calcsize("!qHH")
        if len(payload) < header_sz:
            raise ValueError("short rich snapshot header")
        ts_s, ts_ms, count = struct.unpack("!qHH", payload[:header_sz])
        pos = header_sz
        rows = []

        row_sz = struct.calcsize("!iiiHQI")
        for _ in range(count):
            if pos + row_sz > len(payload):
                raise ValueError("short rich snapshot row")
            pid, ppid, uid, threads, cpu_ticks, vm_rss_kb = struct.unpack(
                "!iiiHQI", payload[pos:pos + row_sz]
            )
            pos += row_sz
            comm, pos = self._read_str(payload, pos)
            rows.append(
                {
                    "pid": int(pid),
                    "ppid": int(ppid),
                    "uid": int(uid),
                    "comm": comm,
                    "threads": int(threads),
                    "cpu_ticks": int(cpu_ticks),
                    "vm_rss_kb": int(vm_rss_kb),
                }
            )

        return {
            "kind": "rich_proc_snapshot",
            "ts_s": int(ts_s),
            "ts_ms": int(ts_ms),
            "processes": rows,
        }

    def decode_system_perf(self, payload: bytes):
        header_sz = struct.calcsize("!qHBx")
        if len(payload) < header_sz:
            raise ValueError("short system_perf header")
        ts_s, ts_ms, num_cores = struct.unpack("!qHBx", payload[:header_sz])
        pos = header_sz

        core_sz = struct.calcsize("!7Q")
        cores = []
        for _ in range(num_cores):
            if pos + core_sz > len(payload):
                raise ValueError("short system_perf core block")
            vals = struct.unpack("!7Q", payload[pos:pos + core_sz])
            cores.append(
                {
                    "user": vals[0],
                    "nice": vals[1],
                    "system": vals[2],
                    "idle": vals[3],
                    "iowait": vals[4],
                    "irq": vals[5],
                    "softirq": vals[6],
                }
            )
            pos += core_sz

        mem_sz = struct.calcsize("!4Q")
        if pos + mem_sz > len(payload):
            raise ValueError("short system_perf mem block")
        mem_total, mem_free, mem_available, mem_cached = struct.unpack(
            "!4Q", payload[pos:pos + mem_sz]
        )
        pos += mem_sz

        load_sz = struct.calcsize("!3H")
        if pos + load_sz > len(payload):
            raise ValueError("short system_perf load block")
        l1_fp, l5_fp, l15_fp = struct.unpack("!3H", payload[pos:pos + load_sz])

        return {
            "kind": "system_perf",
            "ts_s": int(ts_s),
            "ts_ms": int(ts_ms),
            "cores": cores,
            "mem": {
                "total_kb": int(mem_total),
                "free_kb": int(mem_free),
                "available_kb": int(mem_available),
                "cached_kb": int(mem_cached),
            },
            "load": {
                "l1": round(l1_fp / 100, 2),
                "l5": round(l5_fp / 100, 2),
                "l15": round(l15_fp / 100, 2),
            },
        }

    def decode_payload(self, kind: int, payload: bytes):
        if kind == self.WIRE_KIND_SYSTEM_INFO:
            return self.decode_system_info(payload)
        if kind == self.WIRE_KIND_EVENT:
            return self.decode_event(payload)
        if kind == self.WIRE_KIND_RICH_PROC_SNAPSHOT:
            return self.decode_rich_proc_snapshot(payload)
        if kind == self.WIRE_KIND_SYSTEM_PERF:
            return self.decode_system_perf(payload)
        return None


wd = WireDecoder()
