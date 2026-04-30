"""
state.py — Shared in-memory contract hub for Over-Seer.

All ingest and delivery surfaces meet here:
    - server.py writes decoded Under-Seer events
    - app.py reads snapshot data for REST endpoints
    - app.py emits stats/event updates for SSE clients

This keeps one canonical schema and synchronization point between TCP
ingest, API responses, and browser rendering.
"""

"""
Notes while refactoring:

__init__ needs to start a SQLite connection whose name will be:
{UUID}-{UNIXTIME}.db
"""

import threading
import time
from collections import deque


class EventStore:
    def __init__(self, max_file_opens: int = 1000, max_network: int = 500,
                 rate_window: int = 10):
        self._lock = threading.Lock()

        # Live process table: pid (int) → dict
        self.processes: dict[int, dict] = {}

        # Scrolling logs
        self.file_opens: deque = deque(maxlen=max_file_opens)
        self.network:    deque = deque(maxlen=max_network)

        # All recent events (combined) for the /api/events endpoint
        self.recent_events: deque = deque(maxlen=2000)

        # Stats
        self.start_time: float       = time.time()
        self.agent_count: int        = 0
        self._event_timestamps: deque = deque(maxlen=1000)  # for rate calc
        self._rate_window: int       = rate_window

    # ── Ingest ───────────────────────────────────────────────────────────────

    def add_event(self, ev: dict):
        """Ingest event ."""
        with self._lock:
            pid = ev.get("pid", 0)
            ts_s = int(ev.get("ts_s", 0) or 0)
            ts_ms = int(ev.get("ts_ms", 0) or 0)

            # Backward compatibility for older Under-Seer payloads with a
            # single nanosecond timestamp field.
            if (ts_s == 0 and ts_ms == 0) and "ts" in ev:
                legacy_ns = int(ev.get("ts", 0) or 0)
                ts_s, rem_ns = divmod(legacy_ns, 1_000_000_000)
                ts_ms = rem_ns // 1_000_000

            ev["ts_s"] = ts_s
            ev["ts_ms"] = ts_ms

            # Update process table
            ppid = ev.get("ppid", 0)
            uid  = ev.get("uid", 0)
            comm = ev.get("comm", "")
            self.processes[pid] = {
                "pid":       pid,
                "ppid":      ppid,
                "uid":       uid,
                "comm":      comm,
                "last_seen_s": ts_s,
                "last_seen_ms": ts_ms,
            }

            ev_type = ev.get("type", "")
            arg     = ev.get("arg", "")

            record = {
                "ts_s": ts_s,
                "ts_ms": ts_ms,
                "pid":  pid,
                "comm": comm,
                "arg":  arg,
                "type": ev_type,
            }

            if ev_type == "open":
                self.file_opens.append(record)
            elif ev_type == "connect":
                self.network.append(record)

            self.recent_events.append(ev)
            self._event_timestamps.append(time.monotonic())

    def agent_connected(self):
        with self._lock:
            self.agent_count += 1

    def agent_disconnected(self):
        with self._lock:
            self.agent_count = max(0, self.agent_count - 1)

    # ── Snapshot helpers (return plain dicts/lists — safe to JSON-encode) ─

    def get_processes(self) -> list[dict]:
        with self._lock:
            return sorted(self.processes.values(), key=lambda p: p["pid"])

    def get_file_opens(self, limit: int = 100) -> list[dict]:
        with self._lock:
            items = list(self.file_opens)
        return items[-limit:]

    def get_network(self, limit: int = 100) -> list[dict]:
        with self._lock:
            items = list(self.network)
        return items[-limit:]

    def get_recent_events(self, limit: int = 200) -> list[dict]:
        with self._lock:
            items = list(self.recent_events)
        return items[-limit:]

    def get_stats(self) -> dict:
        with self._lock:
            now = time.monotonic()
            cutoff = now - self._rate_window
            recent = sum(1 for t in self._event_timestamps if t >= cutoff)
            rate = recent / self._rate_window
            uptime = int(time.time() - self.start_time)
            agents = self.agent_count
        return {
            "events_per_sec": round(rate, 2),
            "agent_count":    agents,
            "uptime_s":       uptime,
        }


# Singleton shared across the whole process
store = EventStore()
