"""Wire protocol decoding for Over-Seer ingest."""

import os
import struct
import zlib


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
    def _to_int(val: str, name: str) -> int:
        try:
            return int(val)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"invalid integer field {name}: {val!r}") from exc

    @staticmethod
    def _to_float(val: str, name: str) -> float:
        try:
            return float(val)
        except (TypeError, ValueError) as exc:
            raise ValueError(f"invalid float field {name}: {val!r}") from exc

    @staticmethod
    def _split_fields(payload: bytes):
        if not payload:
            return []
        text = payload.decode("utf-8", errors="replace")
        fields = text.split("\x00")
        if fields and fields[-1] == "":
            fields.pop()
        return fields

    @staticmethod
    def _next(fields, idx: int, name: str):
        if idx >= len(fields):
            raise ValueError(f"missing field {name}")
        return fields[idx], idx + 1

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
        fields = self._split_fields(payload)
        if len(fields) != 8:
            raise ValueError(f"system_info expects 8 fields, got {len(fields)}")

        ram_gbs = self._to_int(fields[7], "ram_gbs")

        return {
            "kind": "system_info",
            "hostname": fields[0],
            "kernelver": fields[1],
            "distro": fields[2],
            "ipaddr": fields[3],
            "macaddr": fields[4],
            "processor": fields[5],
            "processor_vend": fields[6],
            "ram_gbs": ram_gbs,
        }

    def decode_event(self, payload: bytes):
        fields = self._split_fields(payload)
        if len(fields) != 11:
            raise ValueError(f"event expects 11 fields, got {len(fields)}")

        ts_s = self._to_int(fields[0], "ts_s")
        ts_ms = self._to_int(fields[1], "ts_ms")
        pid = self._to_int(fields[2], "pid")
        ppid = self._to_int(fields[3], "ppid")
        uid = self._to_int(fields[4], "uid")
        ev_type = fields[5] or "unknown"
        retval = self._to_int(fields[6], "retval")
        subtype = fields[7]
        comm = fields[8]
        arg1 = fields[9]
        arg2 = fields[10]

        out_arg2 = arg2
        if ev_type == "ptrace" and out_arg2:
            try:
                out_arg2 = int(out_arg2)
            except ValueError:
                pass

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
        fields = self._split_fields(payload)
        idx = 0
        ts_s_s, idx = self._next(fields, idx, "ts_s")
        ts_ms_s, idx = self._next(fields, idx, "ts_ms")
        count_s, idx = self._next(fields, idx, "count")

        ts_s = self._to_int(ts_s_s, "ts_s")
        ts_ms = self._to_int(ts_ms_s, "ts_ms")
        count = self._to_int(count_s, "count")
        if count < 0:
            raise ValueError("invalid negative process count")

        rows = []
        for _ in range(count):
            pid_s, idx = self._next(fields, idx, "pid")
            ppid_s, idx = self._next(fields, idx, "ppid")
            uid_s, idx = self._next(fields, idx, "uid")
            threads_s, idx = self._next(fields, idx, "threads")
            cpu_ticks_s, idx = self._next(fields, idx, "cpu_ticks")
            vm_rss_kb_s, idx = self._next(fields, idx, "vm_rss_kb")
            comm, idx = self._next(fields, idx, "comm")

            rows.append(
                {
                    "pid": self._to_int(pid_s, "pid"),
                    "ppid": self._to_int(ppid_s, "ppid"),
                    "uid": self._to_int(uid_s, "uid"),
                    "comm": comm,
                    "threads": self._to_int(threads_s, "threads"),
                    "cpu_ticks": self._to_int(cpu_ticks_s, "cpu_ticks"),
                    "vm_rss_kb": self._to_int(vm_rss_kb_s, "vm_rss_kb"),
                }
            )

        if idx != len(fields):
            raise ValueError("trailing rich snapshot payload fields")

        return {
            "kind": "rich_proc_snapshot",
            "ts_s": int(ts_s),
            "ts_ms": int(ts_ms),
            "processes": rows,
        }

    def decode_system_perf(self, payload: bytes):
        fields = self._split_fields(payload)
        idx = 0
        ts_s_s, idx = self._next(fields, idx, "ts_s")
        ts_ms_s, idx = self._next(fields, idx, "ts_ms")
        num_cores_s, idx = self._next(fields, idx, "num_cores")

        ts_s = self._to_int(ts_s_s, "ts_s")
        ts_ms = self._to_int(ts_ms_s, "ts_ms")
        num_cores = self._to_int(num_cores_s, "num_cores")
        if num_cores < 0:
            raise ValueError("invalid negative core count")

        cores = []
        for _ in range(num_cores):
            vals = []
            for name in ("user", "nice", "system", "idle", "iowait", "irq", "softirq"):
                raw, idx = self._next(fields, idx, f"core_{name}")
                vals.append(self._to_int(raw, f"core_{name}"))
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

        mem_total_s, idx = self._next(fields, idx, "mem_total_kb")
        mem_free_s, idx = self._next(fields, idx, "mem_free_kb")
        mem_available_s, idx = self._next(fields, idx, "mem_available_kb")
        mem_cached_s, idx = self._next(fields, idx, "mem_cached_kb")
        l1_s, idx = self._next(fields, idx, "load_1m")
        l5_s, idx = self._next(fields, idx, "load_5m")
        l15_s, idx = self._next(fields, idx, "load_15m")

        if idx != len(fields):
            raise ValueError("trailing system_perf payload fields")

        return {
            "kind": "system_perf",
            "ts_s": int(ts_s),
            "ts_ms": int(ts_ms),
            "cores": cores,
            "mem": {
                "total_kb": self._to_int(mem_total_s, "mem_total_kb"),
                "free_kb": self._to_int(mem_free_s, "mem_free_kb"),
                "available_kb": self._to_int(mem_available_s, "mem_available_kb"),
                "cached_kb": self._to_int(mem_cached_s, "mem_cached_kb"),
            },
            "load": {
                "l1": round(self._to_float(l1_s, "load_1m"), 2),
                "l5": round(self._to_float(l5_s, "load_5m"), 2),
                "l15": round(self._to_float(l15_s, "load_15m"), 2),
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
