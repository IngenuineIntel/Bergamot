"""
server.py — Over-Seer TCP ingest endpoint for Under-Seer agents.

Inbound contract:
    Under-Seer sends NDJSON over TCP, one JSON object per newline.

This module:
    - accepts agent connections
    - reassembles newline frames
    - decodes JSON dict events
    - forwards each event to state.store.add_event()

Integration note:
    app.py wraps store.add_event() to fan out live events to SSE clients,
    so each ingest here updates both in-memory state and browser streams.

Handshake contract:
    The first JSON object on each TCP connection must be:
        {"kind": "system_info", ...}
    Over-Seer uses that payload to initialize the session database before
    accepting any event or proc_snapshot messages.

Start this before (or alongside) the Flask app:
    from server import start_tcp_server
    start_tcp_server()
"""

import json
import socket
import struct
import threading

from state import store

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 12046          # override via environment in app.py if desired

WIRE_MAGIC = b"BGW2"
WIRE_VERSION = 2
WIRE_KIND_SYSTEM_INFO = 1
WIRE_KIND_EVENT = 2
WIRE_KIND_PROC_SNAPSHOT = 3

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


def _decode_proc_snapshot(payload: bytes):
    header_sz = struct.calcsize("!qHH")
    if len(payload) < header_sz:
        raise ValueError("short snapshot header")
    ts_s, ts_ms, count = struct.unpack("!qHH", payload[:header_sz])
    pos = header_sz
    rows = []

    for _ in range(count):
        row_sz = struct.calcsize("!iiiH")
        if pos + row_sz > len(payload):
            raise ValueError("short snapshot row")
        pid, ppid, uid, threads = struct.unpack("!iiiH", payload[pos:pos + row_sz])
        pos += row_sz
        comm, pos = _read_str(payload, pos)
        rows.append({
            "pid": int(pid),
            "ppid": int(ppid),
            "uid": int(uid),
            "comm": comm,
            "threads": int(threads),
        })

    return {
        "kind": "proc_snapshot",
        "ts_s": int(ts_s),
        "ts_ms": int(ts_ms),
        "processes": rows,
    }


def _decode_binary_frame(kind: int, payload: bytes):
    if kind == WIRE_KIND_SYSTEM_INFO:
        return _decode_system_info(payload)
    if kind == WIRE_KIND_EVENT:
        return _decode_event(payload)
    if kind == WIRE_KIND_PROC_SNAPSHOT:
        return _decode_proc_snapshot(payload)
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
    mode = None

    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break

            buf += chunk

            if mode is None and len(buf) >= 4:
                if buf[:4] == WIRE_MAGIC:
                    mode = "binary"
                else:
                    mode = "json"

            if mode == "binary":
                header_sz = struct.calcsize("!4sBBBBI")
                while len(buf) >= header_sz:
                    magic, version, kind, _flags, _reserved, payload_len = struct.unpack(
                        "!4sBBBBI", buf[:header_sz]
                    )

                    if magic != WIRE_MAGIC:
                        print(f"[over-seer] protocol error from {addr}: bad magic", flush=True)
                        return
                    if version != WIRE_VERSION:
                        print(f"[over-seer] protocol error from {addr}: unsupported version {version}", flush=True)
                        return
                    if payload_len > (16 * 1024 * 1024):
                        print(f"[over-seer] protocol error from {addr}: frame too large ({payload_len})", flush=True)
                        return

                    total = header_sz + payload_len
                    if len(buf) < total:
                        break

                    payload = buf[header_sz:total]
                    buf = buf[total:]

                    try:
                        ev = _decode_binary_frame(kind, payload)
                        if not isinstance(ev, dict):
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
                        print(f"[over-seer] binary decode failed for {addr}: {exc}", flush=True)
                        return
            elif mode == "json":
                # Process all complete lines in the buffer
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        ev = json.loads(line.decode("utf-8", errors="replace"))
                        if not isinstance(ev, dict):
                            continue

                        if not handshake_done:
                            if ev.get("kind") != "system_info":
                                print(f"[over-seer] protocol error from {addr}: first message must be system_info",
                                      flush=True)
                                return

                            initialized, db_path = store.initialize_sqlite_from_handshake(ev)
                            if initialized and db_path:
                                print(f"[over-seer] session db initialized at {db_path}", flush=True)

                            handshake_done = True
                            continue

                        store.add_event(ev)
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        pass  # malformed line — skip silently
                    except Exception as exc:
                        print(f"[over-seer] connection setup failed for {addr}: {exc}",
                              flush=True)
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
