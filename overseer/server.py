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

Start this before (or alongside) the Flask app:
    from server import start_tcp_server
    start_tcp_server()
"""

import json
import socket
import threading

from state import store

LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 9000          # override via environment in app.py if desired


def _handle_client(conn: socket.socket, addr):
    """One thread per connected Under-Seer agent."""
    print(f"[over-seer] agent connected from {addr}", flush=True)
    store.agent_connected()
    buf = b""

    try:
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break

            buf += chunk
            # Process all complete lines in the buffer
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line.decode("utf-8", errors="replace"))
                    if isinstance(ev, dict):
                        store.add_event(ev)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    pass  # malformed line — skip silently
    except OSError:
        pass
    finally:
        store.agent_disconnected()
        try:
            conn.close()
        except OSError:
            pass
        print(f"[over-seer] agent disconnected from {addr}", flush=True)


def _accept_loop(server_sock: socket.socket):
    while True:
        try:
            conn, addr = server_sock.accept()
        except OSError:
            break  # socket was closed (shutdown)
        t = threading.Thread(target=_handle_client, args=(conn, addr),
                             daemon=True, name=f"agent-{addr}")
        t.start()


def start_tcp_server(host: str = LISTEN_HOST, port: int = LISTEN_PORT):
    """Bind the TCP listener and start the accept loop in a daemon thread."""
    server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_sock.bind((host, port))
    server_sock.listen(16)
    print(f"[over-seer] TCP listener on {host}:{port}", flush=True)

    t = threading.Thread(target=_accept_loop, args=(server_sock,),
                         daemon=True, name="tcp-accept")
    t.start()
    return server_sock
