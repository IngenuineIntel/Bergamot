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

import os
import sqlite3
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
        self.fork_events: deque = deque(maxlen=1000)
        self.execve_events: deque = deque(maxlen=1000)
        self.fork_exec_events: deque = deque(maxlen=1500)

        # All recent events (combined) for the /api/events endpoint
        self.recent_events: deque = deque(maxlen=2000)

        # Stats
        self.start_time: float       = time.time()
        self.agent_count: int        = 0
        # Keep all timestamps within the rolling rate window.
        self._event_timestamps: deque = deque()
        self._rate_window: int       = rate_window

        # SQLite persistence (configured at app startup)
        self._db_conn: sqlite3.Connection | None = None
        self._db_path: str | None = None
        self._db_insert_event_sql: str | None = None
        self._db_insert_proc_sql: str | None = None
        self._db_update_proc_seen_sql: str | None = None
        self._db_update_proc_end_sql: str | None = None
        self._pending_writes: int = 0
        self._last_commit_mono: float = time.monotonic()

        # Active process lifecycle row mapping (pid -> procs.id)
        self._active_proc_row_ids: dict[int, int] = {}

        # Lifecycle tracking for UI/API snapshots.
        # Active rows are keyed by pid; completed rows are archived in
        # _dead_lifecycle_rows so they remain visible even when recent_events rolls.
        self._active_lifecycle_rows: dict[int, dict] = {}
        self._dead_lifecycle_rows: deque = deque()

    # ── Persistence setup / teardown ───────────────────────────────────────

    def configure_sqlite(self, db_path: str, sql_dir: str,
                         db_name: str, db_time: str,
                         overseer_ver: str):
        """Initialize per-session SQLite persistence from SQL files."""
        with self._lock:
            if self._db_conn is not None:
                self._close_locked()

            self._db_path = db_path
            conn = sqlite3.connect(db_path, timeout=5.0, check_same_thread=False)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA busy_timeout=5000")

            newdb_path = os.path.join(sql_dir, "newdb.sql")
            evententry_path = os.path.join(sql_dir, "evententry.sql")
            procentry_path = os.path.join(sql_dir, "procentry.sql")

            with open(newdb_path, "r", encoding="utf-8") as f:
                newdb_sql = f.read()

            self._run_sql_statements_with_named_params(conn, newdb_sql, {
                "db_name": db_name,
                "db_time": db_time,
                "overseer_ver": overseer_ver,
            })

            with open(evententry_path, "r", encoding="utf-8") as f:
                self._db_insert_event_sql = f.read().strip()

            with open(procentry_path, "r", encoding="utf-8") as f:
                proc_sql_chunks = [chunk.strip() for chunk in f.read().split(";") if chunk.strip()]

            if len(proc_sql_chunks) != 3:
                raise ValueError("procentry.sql must contain exactly 3 SQL statements")

            (self._db_insert_proc_sql,
             self._db_update_proc_seen_sql,
             self._db_update_proc_end_sql) = proc_sql_chunks

            conn.commit()

            self._db_conn = conn
            self._pending_writes = 0
            self._last_commit_mono = time.monotonic()
            self._active_proc_row_ids.clear()

    def close(self):
        with self._lock:
            self._close_locked()

    def _close_locked(self):
        if self._db_conn is None:
            return

        self._flush_commits_locked(force=True)
        self._db_conn.close()
        self._db_conn = None
        self._db_insert_event_sql = None
        self._db_insert_proc_sql = None
        self._db_update_proc_seen_sql = None
        self._db_update_proc_end_sql = None
        self._db_path = None
        self._active_proc_row_ids.clear()

    def _run_sql_statements_with_named_params(self, conn: sqlite3.Connection,
                                              sql_text: str,
                                              params: dict[str, str]):
        for statement in sql_text.split(";"):
            stmt = statement.strip()
            if not stmt:
                continue
            if ":" in stmt:
                conn.execute(stmt, params)
            else:
                conn.execute(stmt)

    def _flush_commits_locked(self, force: bool = False):
        if self._db_conn is None or self._pending_writes <= 0:
            return

        now = time.monotonic()
        elapsed = now - self._last_commit_mono
        should_commit = force or (self._pending_writes >= 100 and elapsed >= 2.0)
        if not should_commit:
            return

        self._db_conn.commit()
        self._pending_writes = 0
        self._last_commit_mono = now

    def _new_lifecycle_row(self, pid: int, ppid: int, uid: int,
                           comm: str, ts_s: int, ts_ms: int,
                           running: bool) -> dict:
        return {
            "pid": pid,
            "ppid": ppid,
            "uid": uid,
            "comm": comm,
            "exec_arg": "",
            "fork_seen": False,
            "exec_seen": False,
            "open_count": 0,
            "connect_count": 0,
            "first_open": "",
            "first_connect": "",
            "start_ts_s": ts_s,
            "start_ts_ms": ts_ms,
            "last_ts_s": ts_s,
            "last_ts_ms": ts_ms,
            "running": bool(running),
        }

    def _update_lifecycle_row_from_event(self, row: dict, ev: dict,
                                         ts_s: int, ts_ms: int):
        row["ppid"] = int(ev.get("ppid", row["ppid"]) or 0)
        row["uid"] = int(ev.get("uid", row["uid"]) or 0)

        comm_val = str(ev.get("comm", row["comm"]) or row["comm"])
        row["comm"] = comm_val

        if (ts_s, ts_ms) < (row["start_ts_s"], row["start_ts_ms"]):
            row["start_ts_s"] = ts_s
            row["start_ts_ms"] = ts_ms

        if (ts_s, ts_ms) >= (row["last_ts_s"], row["last_ts_ms"]):
            row["last_ts_s"] = ts_s
            row["last_ts_ms"] = ts_ms

        ev_type = str(ev.get("type", "") or "")
        if ev_type == "fork":
            row["fork_seen"] = True
        elif ev_type == "execve":
            row["exec_seen"] = True
            row["exec_arg"] = str(ev.get("arg", "") or "")
        elif ev_type == "open":
            row["open_count"] += 1
            if not row["first_open"]:
                row["first_open"] = str(ev.get("arg", "") or "")
        elif ev_type == "connect":
            row["connect_count"] += 1
            if not row["first_connect"]:
                row["first_connect"] = str(ev.get("arg", "") or "")

    def _mark_lifecycle_rows_from_snapshot_locked(self, ts_s: int, ts_ms: int,
                                                  old_processes: dict[int, dict],
                                                  new_processes: dict[int, dict]):
        old_pids = set(old_processes.keys())
        new_pids = set(new_processes.keys())

        # Processes that disappeared from the latest snapshot are archived as dead.
        for pid in old_pids - new_pids:
            row = self._active_lifecycle_rows.pop(pid, None)
            if row is None:
                continue

            if (ts_s, ts_ms) > (row["last_ts_s"], row["last_ts_ms"]):
                row["last_ts_s"] = ts_s
                row["last_ts_ms"] = ts_ms
            row["running"] = False
            self._dead_lifecycle_rows.appendleft(row)

        # New or still-running processes are represented in active rows.
        for pid in new_pids:
            proc = new_processes[pid]
            row = self._active_lifecycle_rows.get(pid)

            if row is None:
                row = self._new_lifecycle_row(
                    pid=pid,
                    ppid=int(proc.get("ppid", 0) or 0),
                    uid=int(proc.get("uid", 0) or 0),
                    comm=str(proc.get("comm", "") or ""),
                    ts_s=ts_s,
                    ts_ms=ts_ms,
                    running=True,
                )
                self._active_lifecycle_rows[pid] = row
            else:
                row["running"] = True
                row["ppid"] = int(proc.get("ppid", row["ppid"]) or row["ppid"])
                row["uid"] = int(proc.get("uid", row["uid"]) or row["uid"])
                row["comm"] = str(proc.get("comm", row["comm"]) or row["comm"])
                if (ts_s, ts_ms) > (row["last_ts_s"], row["last_ts_ms"]):
                    row["last_ts_s"] = ts_s
                    row["last_ts_ms"] = ts_ms

    def _db_write_failed(self, op_name: str, exc: Exception):
        print(f"[over-seer] db write failed during {op_name}: {exc}", flush=True)

    def _persist_event_locked(self, ev: dict):
        if self._db_conn is None or not self._db_insert_event_sql:
            return

        params = {
            "ts_s": int(ev.get("ts_s", 0) or 0),
            "ts_ms": int(ev.get("ts_ms", 0) or 0),
            "pid": int(ev.get("pid", 0) or 0),
            "ppid": int(ev.get("ppid", 0) or 0),
            "uid": int(ev.get("uid", 0) or 0),
            "type": str(ev.get("type", "") or ""),
            "subtype": str(ev.get("subtype", "none") or "none"),
            "comm": str(ev.get("comm", "") or ""),
            "arg1": str(ev.get("arg1", ev.get("arg", "")) or ""),
            "arg2": str(ev.get("arg2", "") or ""),
        }

        try:
            self._db_conn.execute(self._db_insert_event_sql, params)
            self._pending_writes += 1
            self._flush_commits_locked(force=False)
        except sqlite3.Error as exc:
            self._db_write_failed("event insert", exc)

    def _get_or_create_proc_row_id_locked(self, pid: int, row: dict,
                                          ts_s: int, ts_ms: int) -> int | None:
        if self._db_conn is None or self._db_insert_proc_sql is None:
            return None

        existing_id = self._active_proc_row_ids.get(pid)
        if existing_id is not None:
            return existing_id

        params = {
            "pid": pid,
            "first_seen_ts_s": ts_s,
            "first_seen_ts_ms": ts_ms,
            "last_seen_ts_s": ts_s,
            "last_seen_ts_ms": ts_ms,
            "ended_ts_s": None,
            "ended_ts_ms": None,
            "first_uid": int(row.get("uid", 0) or 0),
            "first_ppid": int(row.get("ppid", 0) or 0),
            "first_comm": str(row.get("comm", "") or ""),
            "last_uid": int(row.get("uid", 0) or 0),
            "last_ppid": int(row.get("ppid", 0) or 0),
            "last_comm": str(row.get("comm", "") or ""),
        }

        try:
            cur = self._db_conn.execute(self._db_insert_proc_sql, params)
            row_id = int(cur.lastrowid)
            self._active_proc_row_ids[pid] = row_id
            self._pending_writes += 1
            return row_id
        except sqlite3.Error as exc:
            self._db_write_failed("process start", exc)
            return None

    def _persist_proc_snapshot_locked(self, ts_s: int, ts_ms: int,
                                      old_processes: dict[int, dict],
                                      new_processes: dict[int, dict]):
        if (
            self._db_conn is None
            or self._db_update_proc_seen_sql is None
            or self._db_update_proc_end_sql is None
        ):
            return

        old_pids = set(old_processes.keys())
        new_pids = set(new_processes.keys())

        # New and still-running process rows refresh last_seen and last_* fields.
        for pid in new_pids:
            row = new_processes[pid]
            row_id = self._get_or_create_proc_row_id_locked(pid, row, ts_s, ts_ms)
            if row_id is None:
                continue

            try:
                self._db_conn.execute(
                    self._db_update_proc_seen_sql,
                    {
                        "id": row_id,
                        "last_seen_ts_s": ts_s,
                        "last_seen_ts_ms": ts_ms,
                        "last_uid": int(row.get("uid", 0) or 0),
                        "last_ppid": int(row.get("ppid", 0) or 0),
                        "last_comm": str(row.get("comm", "") or ""),
                    },
                )
                self._pending_writes += 1
            except sqlite3.Error as exc:
                self._db_write_failed("process heartbeat", exc)

        # Missing pids are marked as ended at the current snapshot timestamp.
        disappeared = old_pids - new_pids
        for pid in disappeared:
            row_id = self._active_proc_row_ids.get(pid)
            if row_id is None:
                continue

            try:
                self._db_conn.execute(
                    self._db_update_proc_end_sql,
                    {
                        "id": row_id,
                        "ended_ts_s": ts_s,
                        "ended_ts_ms": ts_ms,
                    },
                )
                self._active_proc_row_ids.pop(pid, None)
                self._pending_writes += 1
            except sqlite3.Error as exc:
                self._db_write_failed("process end", exc)

        self._flush_commits_locked(force=False)

    # ── Ingest ───────────────────────────────────────────────────────────────

    def add_event(self, ev: dict):
        """Ingest event ."""
        with self._lock:
            if ev.get("kind") == "proc_snapshot":
                self._apply_process_snapshot_locked(ev)
                return

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
            ev["subtype"] = str(ev.get("subtype", "none") or "none")

            comm = ev.get("comm", "")

            ev_type = ev.get("type", "")
            arg     = ev.get("arg", "")

            record = {
                "ts_s": ts_s,
                "ts_ms": ts_ms,
                "pid":  pid,
                "ppid": ev.get("ppid", 0),
                "uid": ev.get("uid", 0),
                "comm": comm,
                "arg":  arg,
                "type": ev_type,
            }

            if ev_type == "open":
                self.file_opens.append(record)
            elif ev_type == "connect":
                self.network.append(record)
            elif ev_type == "fork":
                fork_record = {
                    "ts_s":  ts_s,
                    "ts_ms": ts_ms,
                    "pid":   pid,
                    "ppid":  ev.get("ppid", 0),
                    "uid":   ev.get("uid", 0),
                    "type":  ev_type,
                    "comm":  comm,
                    "arg":   arg,
                }
                self.fork_events.append(fork_record)
                self.fork_exec_events.append(fork_record)
            elif ev_type == "execve":
                exec_record = {
                    "ts_s":  ts_s,
                    "ts_ms": ts_ms,
                    "pid":   pid,
                    "ppid":  ev.get("ppid", 0),
                    "uid":   ev.get("uid", 0),
                    "type":  ev_type,
                    "comm":  comm,
                    "arg":   arg,
                }
                self.execve_events.append(exec_record)
                self.fork_exec_events.append(exec_record)

            self.recent_events.append(ev)
            now = time.monotonic()
            self._event_timestamps.append(now)

            cutoff = now - self._rate_window
            while self._event_timestamps and self._event_timestamps[0] < cutoff:
                self._event_timestamps.popleft()

            if pid > 0:
                row = self._active_lifecycle_rows.get(pid)
                if row is None:
                    row = self._new_lifecycle_row(
                        pid=pid,
                        ppid=int(ev.get("ppid", 0) or 0),
                        uid=int(ev.get("uid", 0) or 0),
                        comm=str(ev.get("comm", "") or ""),
                        ts_s=ts_s,
                        ts_ms=ts_ms,
                        running=pid in self.processes,
                    )
                    self._active_lifecycle_rows[pid] = row

                self._update_lifecycle_row_from_event(row, ev, ts_s, ts_ms)
                row["running"] = pid in self.processes

            self._persist_event_locked(ev)

    def _apply_process_snapshot_locked(self, snap: dict):
        ts_s = int(snap.get("ts_s", 0) or 0)
        ts_ms = int(snap.get("ts_ms", 0) or 0)
        rows = snap.get("processes", [])
        old_processes = self.processes

        new_processes: dict[int, dict] = {}
        for row in rows:
            if not isinstance(row, dict):
                continue
            try:
                pid = int(row.get("pid", 0) or 0)
                ppid = int(row.get("ppid", 0) or 0)
                uid = int(row.get("uid", 0) or 0)
                threads = int(row.get("threads", 0) or 0)
                comm = str(row.get("comm", "") or "")
            except (TypeError, ValueError):
                continue

            if pid <= 0:
                continue

            new_processes[pid] = {
                "pid": pid,
                "ppid": ppid,
                "uid": uid,
                "comm": comm,
                "threads": threads,
                "last_seen_s": ts_s,
                "last_seen_ms": ts_ms,
            }

        self.processes = new_processes
        self._mark_lifecycle_rows_from_snapshot_locked(ts_s, ts_ms, old_processes, new_processes)
        self._persist_proc_snapshot_locked(ts_s, ts_ms, old_processes, new_processes)

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

    def get_fork(self, limit: int = 200) -> list[dict]:
        with self._lock:
            items = list(self.fork_events)
        return items[-limit:]

    def get_execve(self, limit: int = 200) -> list[dict]:
        with self._lock:
            items = list(self.execve_events)
        return items[-limit:]

    def get_fork_exec(self, limit: int = 300) -> list[dict]:
        with self._lock:
            items = list(self.fork_exec_events)
        return items[-limit:]

    def get_lifecycle(self, limit: int = 200) -> list[dict]:
        with self._lock:
            active_rows = [dict(row) for row in self._active_lifecycle_rows.values()]
            dead_rows = [dict(row) for row in self._dead_lifecycle_rows]

        ordered = sorted(
            active_rows + dead_rows,
            key=lambda r: (r["last_ts_s"], r["last_ts_ms"], r["pid"]),
            reverse=True,
        )
        return ordered[:limit]

    def get_dead_processes(self, limit: int | None = None, offset: int = 0) -> list[dict]:
        with self._lock:
            dead_rows = [dict(row) for row in self._dead_lifecycle_rows]

        ordered = sorted(
            dead_rows,
            key=lambda r: (r["last_ts_s"], r["last_ts_ms"], r["pid"]),
            reverse=True,
        )
        if offset < 0:
            offset = 0

        if offset >= len(ordered):
            return []

        if limit is None:
            return ordered[offset:]

        if limit <= 0:
            return []

        return ordered[offset:offset + limit]

    def get_recent_events(self, limit: int = 200) -> list[dict]:
        with self._lock:
            items = list(self.recent_events)
        return items[-limit:]

    def get_stats(self) -> dict:
        with self._lock:
            now = time.monotonic()
            cutoff = now - self._rate_window

            while self._event_timestamps and self._event_timestamps[0] < cutoff:
                self._event_timestamps.popleft()

            recent = len(self._event_timestamps)
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
