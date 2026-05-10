"""
server.py — Over-Seer TCP ingest endpoint for Under-Seer agents.

Inbound contract:
    Under-Seer sends binary framed telemetry over TCP (BGW1 / version 1.0).

This module:
    - accepts agent connections
    - reassembles framed binary messages
    - decodes messages into event dictionaries
    - forwards each message to state.store.add_event()

Handshake contract:
    The first message on each TCP connection must be:
        {"kind": "system_info", ...}
    Over-Seer uses that payload to initialize the session database before
    accepting telemetry messages.
"""

import os
import socket
import struct
import threading
import zlib

from state import store

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 12046          # override via environment in app.py if desired

WIRE_MAGIC = b"BGW1"
WIRE_VERSION = 1          # wire byte; protocol version 1.0
WIRE_VERSION_STR = "1.0"
WIRE_KIND_SYSTEM_INFO = 1
WIRE_KIND_EVENT = 2
WIRE_KIND_RICH_PROC_SNAPSHOT = 4
WIRE_KIND_SYSTEM_PERF = 5
WIRE_FLAG_CHECKSUM = 0x01
WIRE_ALLOWED_FLAGS = WIRE_FLAG_CHECKSUM
try:
    WIRE_MAX_FRAME_BYTES = max(256, int(os.environ.get("BERGAMOT_WIRE_MAX_FRAME_BYTES", "1048576")))
except ValueError:
    WIRE_MAX_FRAME_BYTES = 1024 * 1024

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


def _read_u16(buf: bytes, pos: int):
    if pos + 2 > len(buf):
        raise ValueError("short u16")
    return struct.unpack("!H", buf[pos:pos + 2])[0], pos + 2


def _read_str(buf: bytes, pos: int):
    size, pos = _read_u16(buf, pos)
    end = pos + size
    if end > len(buf):
        raise ValueError("short string")
    return buf[pos:end].decode("utf-8", errors="replace"), end


def _decode_system_info(payload: bytes):
    pos = 0
    hostname, pos = _read_str(payload, pos)
    kernelver, pos = _read_str(payload, pos)
    distro, pos = _read_str(payload, pos)
    ipaddr, pos = _read_str(payload, pos)
    macaddr, pos = _read_str(payload, pos)
    processor, pos = _read_str(payload, pos)
    processor_vend, pos = _read_str(payload, pos)
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


def _decode_event(payload: bytes):
    base_sz = struct.calcsize("!qHiiiB")
    if len(payload) < base_sz:
        raise ValueError("short event header")
    ts_s, ts_ms, pid, ppid, uid, type_id = struct.unpack("!qHiiiB", payload[:base_sz])
    pos = base_sz
    subtype, pos = _read_str(payload, pos)
    comm, pos = _read_str(payload, pos)
    arg1, pos = _read_str(payload, pos)
    arg2, pos = _read_str(payload, pos)

    ev_type = WIRE_TYPE_MAP.get(type_id, "unknown")
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
    }


def _decode_rich_proc_snapshot(payload: bytes):
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
        comm, pos = _read_str(payload, pos)
        rows.append({
            "pid": int(pid),
            "ppid": int(ppid),
            "uid": int(uid),
            "comm": comm,
            "threads": int(threads),
            "cpu_ticks": int(cpu_ticks),
            "vm_rss_kb": int(vm_rss_kb),
        })

    return {
        "kind": "rich_proc_snapshot",
        "ts_s": int(ts_s),
        "ts_ms": int(ts_ms),
        "processes": rows,
    }


def _decode_system_perf(payload: bytes):
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
        cores.append({
            "user": vals[0], "nice": vals[1], "system": vals[2],
            "idle": vals[3], "iowait": vals[4], "irq": vals[5], "softirq": vals[6],
        })
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


def _decode_binary_frame(kind: int, payload: bytes):
    if kind == WIRE_KIND_SYSTEM_INFO:
        return _decode_system_info(payload)
    if kind == WIRE_KIND_EVENT:
        return _decode_event(payload)
    if kind == WIRE_KIND_RICH_PROC_SNAPSHOT:
        return _decode_rich_proc_snapshot(payload)
    if kind == WIRE_KIND_SYSTEM_PERF:
        return _decode_system_perf(payload)
    return None

# TODO this should not be allowing multiple agents, but I'm currently working
# around the framework already built

def _handle_client(conn: socket.socket, addr):
    """Handles current underseer agent connection until it dies."""
    print(f"[over-seer] agent connected from {addr}", flush=True)
    with store._lock:
        store.is_agent = True
    buf = b""
    handshake_done = False
    metrics = {
        "frames_rx": 0,
        "bad_magic": 0,
        "bad_version": 0,
        "bad_flags": 0,
        "oversized": 0,
        "bad_checksum": 0,
        "decode_err": 0,
        "unknown_kind": 0,
    }

    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break

            buf += chunk

            header_sz = struct.calcsize("!4sBBBBII")
            while len(buf) >= header_sz:
                magic, version, kind, flags, _reserved, payload_len, checksum = struct.unpack(
                    "!4sBBBBII", buf[:header_sz]
                )
                metrics["frames_rx"] += 1

                if magic != WIRE_MAGIC:
                    metrics["bad_magic"] += 1
                    print(f"[over-seer] protocol error from {addr}: bad magic", flush=True)
                    return
                if version != WIRE_VERSION:
                    metrics["bad_version"] += 1
                    print(f"[over-seer] protocol error from {addr}: unsupported version {version}", flush=True)
                    return
                if flags & ~WIRE_ALLOWED_FLAGS:
                    metrics["bad_flags"] += 1
                    print(f"[over-seer] protocol error from {addr}: unknown flags 0x{flags:x}", flush=True)
                    return
                if not (flags & WIRE_FLAG_CHECKSUM):
                    metrics["bad_flags"] += 1
                    print(f"[over-seer] protocol error from {addr}: missing checksum flag", flush=True)
                    return
                if payload_len > WIRE_MAX_FRAME_BYTES:
                    metrics["oversized"] += 1
                    print(f"[over-seer] protocol error from {addr}: frame too large ({payload_len})", flush=True)
                    return

                total = header_sz + payload_len
                if len(buf) < total:
                    break

                payload = buf[header_sz:total]
                buf = buf[total:]

                calc_sum = zlib.crc32(payload) & 0xFFFFFFFF
                if checksum != calc_sum:
                    metrics["bad_checksum"] += 1
                    print(f"[over-seer] protocol error from {addr}: checksum mismatch", flush=True)
                    return

                try:
                    ev = _decode_binary_frame(kind, payload)
                    if not isinstance(ev, dict):
                        metrics["unknown_kind"] += 1
                        continue

                    if not handshake_done:
                        if ev.get("kind") != "system_info":
                            print(f"[over-seer] protocol error from {addr}: first message must be system_info", flush=True)
                            return

                        initialized, db_path = store.initialize_sqlite_from_handshake(ev)
                        if initialized and db_path:
                            print(f"[over-seer] session db initialized at {db_path}", flush=True)

                        handshake_done = True
                        continue

                    store.add_event(ev)
                except Exception as exc:
                    metrics["decode_err"] += 1
                    print(f"[over-seer] binary decode failed for {addr}: {exc}", flush=True)
                    return
    except OSError:
        pass
    finally:
        with store._lock:
            store.is_agent = False
        try:
            conn.close()
        except OSError:
            pass
        if any(v for v in metrics.values()):
            print(
                f"[over-seer] protocol stats {addr}: "
                f"frames_rx={metrics['frames_rx']} bad_magic={metrics['bad_magic']} "
                f"bad_version={metrics['bad_version']} bad_flags={metrics['bad_flags']} "
                f"oversized={metrics['oversized']} bad_checksum={metrics['bad_checksum']} "
                f"decode_err={metrics['decode_err']} unknown_kind={metrics['unknown_kind']}",
                flush=True,
            )
        print(f"[over-seer] agent disconnected from {addr}", flush=True)

def _tcp_server_loop(host: str = LISTEN_HOST, port: int = LISTEN_PORT):
    """Bind TCP listener and connection manager to a separate thread."""
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind((host, port))
    server_sock.listen(16)
    print(f"[overseer] TCP listener on {host}:{port}", flush=True)
    while True:
        try:
            print("[overseer] waiting for TCP connection from agent")
            conn, addr = server_sock.accept()
            print("[overseer] connection accepted...")
            _handle_client(conn, addr)
        except OSError:
            break # socket was closed (shutdown?)

def start_tcp_server(host: str = LISTEN_HOST, port: int = LISTEN_PORT):
    t = threading.Thread(target=store.conn_uptime_thread, args=(),
                         daemon=True, name="bergamot-uptime-manager")
    u = threading.Thread(target=_tcp_server_loop, args=(host, port), daemon=True,
                         name="begamot-tcp-listener")
    t.start()
    u.start()
