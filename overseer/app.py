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

Environment variables:
  TCP_PORT     Under-Seer ingest port  (default: 9000)
  FLASK_HOST   Flask bind address      (default: 0.0.0.0)
  FLASK_PORT   Flask HTTP port         (default: 5000)

SSE stream (/api/stream):
  Browsers connect once and receive a continuous push of server-sent
  events.  Each SSE message is one JSON object on the "event" channel,
  plus periodic "stats" heartbeats every second.
"""

import json
import os
import queue
import threading
import time

from flask import Flask, Response, jsonify, render_template

from server import start_tcp_server
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


# ── API routes ───────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/stream")
def api_stream():
    """
    Server-Sent Events endpoint.  Clients receive:
      - event: event  — every new raw event as it arrives
      - event: stats  — a stats heartbeat once per second
      - event: ping   — keepalive every 15 s if no other traffic
    """
    def generate():
        q = subscribe()
        last_stats = time.monotonic()
        last_ping  = time.monotonic()
        try:
            while True:
                now = time.monotonic()

                # Drain all queued events (non-blocking)
                sent_any = False
                while True:
                    try:
                        msg = q.get_nowait()
                        yield f"event: event\ndata: {msg}\n\n"
                        sent_any = True
                    except queue.Empty:
                        break

                # Stats heartbeat — once per second
                if now - last_stats >= 1.0:
                    stats = json.dumps(store.get_stats())
                    yield f"event: stats\ndata: {stats}\n\n"
                    last_stats = now
                    last_ping  = now

                # Keepalive ping — if no traffic for 15 s
                if now - last_ping >= 15.0:
                    yield "event: ping\ndata: {}\n\n"
                    last_ping = now

                if not sent_any:
                    time.sleep(0.05)   # 50 ms idle sleep

        except GeneratorExit:
            pass
        finally:
            unsubscribe(q)

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no"})


@app.route("/api/events")
def api_events():
    """Return the most recent 200 raw events (for initial page load)."""
    return jsonify(store.get_recent_events(200))


@app.route("/api/processes")
def api_processes():
    """Return the current process table snapshot."""
    return jsonify(store.get_processes())


@app.route("/api/file_opens")
def api_file_opens():
    """Return the last 100 file-open events."""
    return jsonify(store.get_file_opens(100))


@app.route("/api/network")
def api_network():
    """Return the last 100 outbound TCP connection events."""
    return jsonify(store.get_network(100))


@app.route("/api/stats")
def api_stats():
    """Return events/sec, connected agent count, and uptime."""
    return jsonify(store.get_stats())


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    tcp_port  = int(os.environ.get("TCP_PORT",   "9000"))
    http_host = os.environ.get("FLASK_HOST", "0.0.0.0")
    http_port = int(os.environ.get("FLASK_PORT", "5000"))

    start_tcp_server(port=tcp_port)
    app.run(host=http_host, port=http_port, debug=False, threaded=True)
else: raise ImportError("Don't import me!!!")
