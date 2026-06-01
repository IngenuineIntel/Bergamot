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

import socket
import threading

from decode import wd
from state import store

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 12046          # override via environment in app.py if desired

# TODO this should not be allowing multiple agents, but I'm currently working
# around the framework already built

def _handle_client(conn: socket.socket, addr):
    """Handles current agent connection until it dies."""
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

    header_sz = wire_decoder.header_size

    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break

            buf += chunk

            while len(buf) >= header_sz:
                magic, version, kind, flags, _reserved, payload_len, checksum = wire_decoder.unpack_header(
                    buf[:header_sz]
                )
                metrics["frames_rx"] += 1

                metric_key, err = wire_decoder.validate_header(magic, version, flags, payload_len)
                if metric_key:
                    metrics[metric_key] += 1
                    print(f"[over-seer] protocol error from {addr}: {err}", flush=True)
                    return

                total = header_sz + payload_len
                if len(buf) < total:
                    break

                payload = buf[header_sz:total]
                buf = buf[total:]

                if not wire_decoder.checksum_matches(payload, checksum):
                    metrics["bad_checksum"] += 1
                    print(f"[over-seer] protocol error from {addr}: checksum mismatch", flush=True)
                    return

                try:
                    ev = wire_decoder.decode_payload(kind, payload)
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
    global LISTEN_PORT
    LISTEN_PORT = port # for /api/backend-port
    t = threading.Thread(target=store.conn_uptime_thread, args=(),
                         daemon=True, name="bergamot-uptime-manager")
    u = threading.Thread(target=_tcp_server_loop, args=(host, port), daemon=True,
                         name="begamot-tcp-listener")
    t.start()
    u.start()
