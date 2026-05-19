"""
app.py — Over-Seer API and browser delivery layer.

Data path:
    Under-Seer -> server.py (TCP NDJSON) -> state.store -> app.py -> browser

Browser interfaces:
    - Snapshot REST endpoints for initial page load
    - SSE stream at /api/stream for live updates

SSE event types:
    - event: raw ingest event payloads
    - stats: periodic aggregate metrics
    - ping: keepalive to keep stream intermediaries open

Run:
    python app.py
  or:
    flask --app app run --host 0.0.0.0 --port 5000

SSE stream (/api/stream):
  Browsers connect once and receive a continuous push of server-sent
  events.  Each SSE message is one JSON object on the "event" channel,
  plus periodic "stats" heartbeats every second.
"""
BERGAMOT_VERSION = "0.1"

import atexit
import json
import os
import queue
import secrets
import threading
import time
import uuid

from flask import Flask, Response, jsonify, render_template, request, send_from_directory

import server
from state import store

app = Flask(__name__)

# ── SSE subscriber registry ───────────────────────────────────────────────────
#
# Each browser connection gets its own Queue.  When a new event arrives
# (injected by server.py via announce_event()), it is pushed into every
# registered queue so all connected clients receive it.

_subscribers: list[queue.Queue] = []
_subscribers_lock = threading.Lock()


def subscribe() -> queue.Queue:
    q: queue.Queue = queue.Queue(maxsize=512)
    with _subscribers_lock:
        _subscribers.append(q)
    return q


def unsubscribe(q: queue.Queue):
    with _subscribers_lock:
        try:
            _subscribers.remove(q)
        except ValueError:
            pass


def announce_event(ev: dict):
    """Called by server.py after inserting an event into EventStore."""
    msg = json.dumps(ev)
    with _subscribers_lock:
        dead = []
        for q in _subscribers:
            try:
                q.put_nowait(msg)
            except queue.Full:
                dead.append(q)   # slow client — drop it
        for q in dead:
            _subscribers.remove(q)


# Patch store so server.py can call announce_event transparently.
# server.py calls store.add_event(); we wrap it here after import.
_original_add_event = store.add_event


def _patched_add_event(ev: dict):
    _original_add_event(ev)
    announce_event(ev)


store.add_event = _patched_add_event  # type: ignore[method-assign]

def envvar_fetch(name: str, valtype: type, default):
    assert type(default) == valtype
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return valtype(raw)
    except Exception:
        return default


# ── ROUTES ───────────────────────────────────────────────────────────────── #

#%% HTML

@app.route("/")
def index():
    return render_template("index.html")

#%% API

@app.route("/api/backend-port")
def apt_backend_port():
    """Return port that the backend server is listening on"""
    return jsonify({"port": server.LISTEN_PORT})

@app.route("/api/uptime")
def api_uptime():
    """Return uptime since oldest living agent connection (*new way*)"""
    return jsonify({"uptime": store.get_conn_uptime()})

# ── Entry point ──────────────────────────────────────────────────────────────
def main():
    tcp_port = envvar_fetch("BERGAMOT_WIRE_PORT", int, 12046)
    http_host = "0.0.0.0"
    http_port = envvar_fetch("BERGAMOT_HTTP_PORT", int, 27960)

    app_dir = os.path.dirname(os.path.abspath(__file__))
    db_base_dir = os.environ.get("BERGAMOT_SQL_PATH", os.path.join(app_dir, "db"))
    sql_dir = os.path.join(app_dir, "sql")

    os.makedirs(db_base_dir, exist_ok=True)

    session_uuid = uuid.uuid4().hex
    session_salt = secrets.token_hex(4)
    session_start_unix = int(time.time())
    session_name = f"{session_uuid}-{session_salt}-{session_start_unix}.db"
    session_db_path = os.path.join(db_base_dir, session_name)

    store.prepare_sqlite_session(
        db_path=session_db_path,
        sql_dir=sql_dir,
        db_name=session_name,
        db_time=str(session_start_unix),
        overseer_ver=BERGAMOT_VERSION,
    )
    atexit.register(store.close)
    print(f"[over-seer] session db pending at {session_db_path}; waiting for agent handshake",
          flush=True)

    server.start_tcp_server(port=tcp_port)
    app.run(host=http_host, port=http_port, debug=False, threaded=True)

if __name__ == "__main__":
    main()
