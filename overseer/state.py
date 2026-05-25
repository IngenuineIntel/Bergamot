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
import json
from collections import deque

from querying import DataManager
from sqlfetcher import SQLManager


def _normalize_system_info(system_info: dict | None) -> dict[str, str | int]:
    info = system_info or {}
    return {
        "hostname": str(info.get("hostname", "") or ""),
        "kernelver": str(info.get("kernelver", "") or ""),
        "distro": str(info.get("distro", "") or ""),
        "ipaddr": str(info.get("ipaddr", "") or ""),
        "macaddr": str(info.get("macaddr", "") or ""),
        "processor": str(info.get("processor", "") or ""),
        "processor_vend": str(info.get("processor_vend", "") or ""),
        "ram_gbs": int(info.get("ram_gbs", 0) or 0),
    }


class LiveDataManager(DataManager):
    def __init__(self, max_file_opens: int = 1000, max_network: int = 500,
                 rate_window: int = 10):
        super().__init__()
        # race condition? nah
        self._lock = threading.Lock()
        self._sql_manager = SQLManager()

        # live process table
        self.processes: dict[int, dict] = {}

        # scrolling logs
        self.file_opens: deque = deque(maxlen=max_file_opens)
        self.network:    deque = deque(maxlen=max_network)
        self.fork_events: deque = deque(maxlen=1000)
        self.execve_events: deque = deque(maxlen=1000)
        self.fork_exec_events: deque = deque(maxlen=1500)

        # all recent events (combined)
        self.recent_events: deque = deque(maxlen=2000)

        # stats
        self.conn_uptime = 0
        self.is_agent: bool        = False
        # keep all timestamps within the rolling rate window
        self._event_timestamps: deque = deque()
        self._rate_window: int       = rate_window

        # SQLite persistence (configured at app startup)
        self._db_path: str | None = None
        self._db_insert_event_sql: str | None = None
        self._db_insert_proc_sql: str | None = None
        self._db_insert_system_perf_sql: str | None = None
        self._db_update_proc_seen_sql: str | None = None
        self._db_update_proc_end_sql: str | None = None
        self._pending_writes: int = 0
        self._last_commit_mono: float = time.monotonic()
        self._session_db_config: dict[str, str] | None = None
        self._session_system_info: dict[str, str | int] | None = None

        # active process lifecycle row mapping (pid -> procs.id)
        self._active_proc_row_ids: dict[int, int] = {}

        # lifecycle tracking for UI/API snapshots
        # active rows are keyed by pid; completed rows are archived in
        # _dead_lifecycle_rows so they remain visible even when recent_events rolls
        self._active_lifecycle_rows: dict[int, dict] = {}
        self._dead_lifecycle_rows: deque = deque()

        # system performance telemetry (kind=5 frames)
        self.system_perf: dict | None = None
        # raw per-core tick vectors from previous system_perf frame
        self._prev_core_ticks: list[list[int]] | None = None
        # raw cpu_ticks (utime+stime) per PID from previous rich_proc_snapshot
        self._prev_proc_cpu_ticks: dict[int, int] = {}
        # monotonic timestamp of last rich_proc_snapshot (for tick delta calc)
        self._prev_proc_snap_mono: float | None = None

    # ── Persistence setup / teardown ───────────────────────────────────────

    def prepare_sqlite_session(self, db_path: str, sql_dir: str,
                               db_name: str, db_time: str,
                               overseer_ver: str):
        with self._lock:
            self._session_db_config = {
                "db_path": db_path,
                "sql_dir": sql_dir,
                "db_name": db_name,
                "db_time": db_time,
                "overseer_ver": overseer_ver,
            }
            self._session_system_info = None

    def configure_sqlite(self, db_path: str, sql_dir: str,
                         db_name: str, db_time: str,
                         overseer_ver: str,
                         system_info: dict | None = None):
        """Initialize per-session SQLite persistence from SQL files."""
        with self._lock:
            if self._db_conn is not None:
                self._close_locked()

            self._db_path = db_path
            self._sql_manager = SQLManager(sql_dir)
            conn = self.connect_database(db_path, timeout=5.0, check_same_thread=False)

            newdb_sql = self._sql_manager.get("initdb")

            normalized_info = _normalize_system_info(system_info)
            self._run_sql_statements_with_named_params(conn, newdb_sql, {
                "db_name": db_name,
                "db_time": db_time,
                "overseer_ver": overseer_ver,
                **normalized_info,
            })

            self._db_insert_event_sql = self._sql_manager.get("entryevent")

            self._db_insert_system_perf_sql = self._sql_manager.get("entryperf")

            proc_sql_chunks = [
                chunk.strip()
                for chunk in self._sql_manager.get("entryproc").split(";")
                if chunk.strip()
            ]

            if len(proc_sql_chunks) != 3:
                raise ValueError("procentry.sql must contain exactly 3 SQL statements")

            (self._db_insert_proc_sql,
             self._db_update_proc_seen_sql,
             self._db_update_proc_end_sql) = proc_sql_chunks

            conn.commit()

            self._pending_writes = 0
            self._last_commit_mono = time.monotonic()
            self._active_proc_row_ids.clear()
            self._session_system_info = normalized_info

    def initialize_sqlite_from_handshake(self, system_info: dict) -> tuple[bool, str | None]:
        with self._lock:
            normalized_info = _normalize_system_info(system_info)
            if self._db_conn is not None:
                if self._session_system_info != normalized_info:
                    print("[over-seer] agent system info differs from session origin; keeping existing database metadata",
                          flush=True)
                return False, self._db_path

            if self._session_db_config is None:
                raise RuntimeError("session database not prepared")

            config = dict(self._session_db_config)

        self.configure_sqlite(
            db_path=config["db_path"],
            sql_dir=config["sql_dir"],
            db_name=config["db_name"],
            db_time=config["db_time"],
            overseer_ver=config["overseer_ver"],
            system_info=normalized_info,
        )
        return True, config["db_path"]

    def close(self):
        with self._lock:
            self._close_locked()

    def _close_locked(self):
        if self._db_conn is None:
            return

        self._flush_commits_locked(force=True)
        self.close_database()
        self._db_insert_event_sql = None
        self._db_insert_proc_sql = None
        self._db_insert_system_perf_sql = None
        self._db_update_proc_seen_sql = None
        self._db_update_proc_end_sql = None
        self._db_path = None
        self._active_proc_row_ids.clear()
        self._session_system_info = None

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
        should_commit = force or self._pending_writes >= 100 or elapsed >= 2.0
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
            "cpu_pct": 0.0,
            "vm_rss_kb": 0,
            "start_ts_s": ts_s,
            "start_ts_ms": ts_ms,
            "last_ts_s": ts_s,
            "last_ts_ms": ts_ms,
            "running": bool(running),
        }

    def _update_lifecycle_row_from_event(self, row: dict, ev: dict,
                                         ts_s: int, ts_ms: int):
        arg_primary = str(ev.get("arg1", ev.get("arg", "")) or "")

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
            row["exec_arg"] = arg_primary
        elif ev_type == "open":
            row["open_count"] += 1
            if not row["first_open"]:
                row["first_open"] = arg_primary
        elif ev_type == "connect":
            row["connect_count"] += 1
            if not row["first_connect"]:
                row["first_connect"] = arg_primary

    def _normalize_event_payload(self, ev: dict) -> dict:
        ts_s = int(ev.get("ts_s", 0) or 0)
        ts_ms = int(ev.get("ts_ms", 0) or 0)

        # Backward compatibility for older Under-Seer payloads with a
        # single nanosecond timestamp field.
        if (ts_s == 0 and ts_ms == 0) and "ts" in ev:
            legacy_ns = int(ev.get("ts", 0) or 0)
            ts_s, rem_ns = divmod(legacy_ns, 1_000_000_000)
            ts_ms = rem_ns // 1_000_000

        ev_type = str(ev.get("type", "") or "")
        subtype = str(ev.get("subtype", "") or "")
        if subtype == "none":
            subtype = ""
        comm = str(ev.get("comm", "") or "")
        arg1 = str(ev.get("arg1", ev.get("arg", "")) or "")
        arg2_raw = ev.get("arg2", "")
        if ev_type == "ptrace":
            try:
                arg2 = int(arg2_raw)
            except (TypeError, ValueError):
                arg2 = str(arg2_raw or "")
        else:
            arg2 = str(arg2_raw or "")

        normalized = {
            "ts_s": ts_s,
            "ts_ms": ts_ms,
            "pid": int(ev.get("pid", 0) or 0),
            "ppid": int(ev.get("ppid", 0) or 0),
            "uid": int(ev.get("uid", 0) or 0),
            "type": ev_type,
            "subtype": subtype,
            "comm": comm,
            "arg1": arg1,
            "arg2": arg2,
            "retval": int(ev.get("retval", 0) or 0),
            # Keep legacy key for existing UI/client code paths.
            "arg": arg1,
        }
        return normalized

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

            # Carry latest process metrics into lifecycle/dead-process rows.
            row["cpu_pct"] = float(proc.get("cpu_pct", row.get("cpu_pct", 0.0)) or 0.0)
            row["vm_rss_kb"] = int(proc.get("vm_rss_kb", row.get("vm_rss_kb", 0)) or 0)

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
            "subtype": str(ev.get("subtype", "") or ""),
            "comm": str(ev.get("comm", "") or ""),
            "arg1": str(ev.get("arg1", ev.get("arg", "")) or ""),
            "arg2": ev.get("arg2", "") if isinstance(ev.get("arg2", ""), int)
            else str(ev.get("arg2", "") or ""),
            "retval": int(ev.get("retval", 0) or 0),
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

    def _persist_system_perf_locked(self, perf: dict):
        if self._db_conn is None or not self._db_insert_system_perf_sql:
            return

        cores = perf.get("cores", [])
        cpu_values = [c.get("cpu_pct") for c in cores if isinstance(c, dict) and c.get("cpu_pct") is not None]
        avg_cpu_pct = round(sum(cpu_values) / len(cpu_values), 2) if cpu_values else 0.0
        mem = perf.get("mem", {}) if isinstance(perf.get("mem", {}), dict) else {}
        load = perf.get("load", {}) if isinstance(perf.get("load", {}), dict) else {}

        params = {
            "ts_s": int(perf.get("ts_s", 0) or 0),
            "ts_ms": int(perf.get("ts_ms", 0) or 0),
            "core_count": int(len(cores)),
            "avg_cpu_pct": float(avg_cpu_pct),
            "mem_total_kb": int(mem.get("total_kb", 0) or 0),
            "mem_free_kb": int(mem.get("free_kb", 0) or 0),
            "mem_available_kb": int(mem.get("available_kb", 0) or 0),
            "mem_cached_kb": int(mem.get("cached_kb", 0) or 0),
            "load_1m": float(load.get("l1", 0.0) or 0.0),
            "load_5m": float(load.get("l5", 0.0) or 0.0),
            "load_15m": float(load.get("l15", 0.0) or 0.0),
            "cores_json": json.dumps(cores, separators=(",", ":")),
        }

        try:
            self._db_conn.execute(self._db_insert_system_perf_sql, params)
            self._pending_writes += 1
            self._flush_commits_locked(force=False)
        except sqlite3.Error as exc:
            self._db_write_failed("system_perf insert", exc)

    # ── Ingest ───────────────────────────────────────────────────────────────

    def add_event(self, ev: dict):
        """Ingest event ."""
        with self._lock:
            if ev.get("kind") == "rich_proc_snapshot":
                self._apply_process_snapshot_locked(ev)
                return
            if ev.get("kind") == "system_perf":
                self._apply_system_perf_locked(ev)
                return

            ev = self._normalize_event_payload(ev)
            pid = ev["pid"]
            ts_s = ev["ts_s"]
            ts_ms = ev["ts_ms"]
            ev_type = ev["type"]

            record = {
                "ts_s": ts_s,
                "ts_ms": ts_ms,
                "pid":  pid,
                "ppid": ev["ppid"],
                "uid": ev["uid"],
                "comm": ev["comm"],
                "arg": ev["arg"],
                "arg1": ev["arg1"],
                "arg2": ev["arg2"],
                "type": ev_type,
                "subtype": ev["subtype"],
            }

            # Database persistence is type-agnostic and does not depend on
            # hardcoded syscall names.
            self._persist_event_locked(ev)

            if ev_type == "open":
                self.file_opens.append(record)
            elif ev_type == "connect":
                self.network.append(record)
            elif ev_type == "fork":
                fork_record = {
                    "ts_s":  ts_s,
                    "ts_ms": ts_ms,
                    "pid":   pid,
                    "ppid":  ev["ppid"],
                    "uid":   ev["uid"],
                    "type":  ev_type,
                    "comm":  ev["comm"],
                    "arg":   ev["arg"],
                    "arg1":  ev["arg1"],
                    "arg2":  ev["arg2"],
                }
                self.fork_events.append(fork_record)
                self.fork_exec_events.append(fork_record)
            elif ev_type == "execve":
                exec_record = {
                    "ts_s":  ts_s,
                    "ts_ms": ts_ms,
                    "pid":   pid,
                    "ppid":  ev["ppid"],
                    "uid":   ev["uid"],
                    "type":  ev_type,
                    "comm":  ev["comm"],
                    "arg":   ev["arg"],
                    "arg1":  ev["arg1"],
                    "arg2":  ev["arg2"],
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
                        ppid=ev["ppid"],
                        uid=ev["uid"],
                        comm=ev["comm"],
                        ts_s=ts_s,
                        ts_ms=ts_ms,
                        running=pid in self.processes,
                    )
                    self._active_lifecycle_rows[pid] = row

                self._update_lifecycle_row_from_event(row, ev, ts_s, ts_ms)
                row["running"] = pid in self.processes

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
            # rich_proc_snapshot extra fields
            new_cpu_ticks = int(row.get("cpu_ticks", 0) or 0)
            vm_rss_kb = int(row.get("vm_rss_kb", 0) or 0)
            new_processes[pid]["vm_rss_kb"] = vm_rss_kb
            new_processes[pid]["cpu_ticks"] = new_cpu_ticks

        # Compute per-process CPU% from tick delta if we have a previous snapshot.
        now_mono = time.monotonic()
        prev_mono = self._prev_proc_snap_mono
        if prev_mono is not None and prev_mono > 0:
            elapsed = now_mono - prev_mono
            # Approximate clock ticks per second (USER_HZ = 100 on Linux)
            hz = 100.0
            elapsed_ticks = elapsed * hz
            if elapsed_ticks > 0:
                for pid, proc in new_processes.items():
                    prev_ticks = self._prev_proc_cpu_ticks.get(pid, 0)
                    delta = max(0, proc.get("cpu_ticks", 0) - prev_ticks)
                    proc["cpu_pct"] = round(min(delta / elapsed_ticks * 100.0, 6400.0), 2)

        # Update tick history for next delta computation.
        self._prev_proc_cpu_ticks = {
            pid: proc.get("cpu_ticks", 0) for pid, proc in new_processes.items()
        }
        self._prev_proc_snap_mono = now_mono

        self.processes = new_processes
        self._mark_lifecycle_rows_from_snapshot_locked(ts_s, ts_ms, old_processes, new_processes)
        self._persist_proc_snapshot_locked(ts_s, ts_ms, old_processes, new_processes)
    
    # ── Snapshot helpers (return plain dicts/lists — safe to JSON-encode) ─

    def get_processes(self) -> list[dict]:
        with self._lock:
            return sorted(self.processes.values(), key=lambda p: p["pid"])

    def get_file_opens(self, limit: int = 100) -> list[dict]:
        if self._db_conn is not None:
            return self.get_persisted_events(limit=limit, ev_type="open")
        with self._lock:
            items = list(self.file_opens)
        return items[-limit:]

    def get_network(self, limit: int = 100) -> list[dict]:
        if self._db_conn is not None:
            return self.get_persisted_events(limit=limit, ev_type="connect")
        with self._lock:
            items = list(self.network)
        return items[-limit:]

    def get_fork(self, limit: int = 200) -> list[dict]:
        if self._db_conn is not None:
            return self.get_persisted_events(limit=limit, ev_type="fork")
        with self._lock:
            items = list(self.fork_events)
        return items[-limit:]

    def get_execve(self, limit: int = 200) -> list[dict]:
        if self._db_conn is not None:
            return self.get_persisted_events(limit=limit, ev_type="execve")
        with self._lock:
            items = list(self.execve_events)
        return items[-limit:]

    def get_fork_exec(self, limit: int = 300) -> list[dict]:
        if self._db_conn is not None:
            with self._lock:
                self._flush_commits_locked(force=True)
                rows = self._db_conn.execute(
                    """
                    SELECT id, ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg1, arg2, retval
                    FROM events
                    WHERE type IN ('fork', 'execve')
                    ORDER BY id DESC
                    LIMIT ?
                    """,
                    (limit,),
                ).fetchall()

            out = []
            for row in rows:
                out.append({
                    "id": row[0],
                    "ts_s": row[1],
                    "ts_ms": row[2],
                    "pid": row[3],
                    "ppid": row[4],
                    "uid": row[5],
                    "type": row[6],
                    "subtype": row[7],
                    "comm": row[8],
                    "arg1": row[9] or "",
                    "arg2": row[10] or "",
                    "retval": row[11] or 0,
                    "arg": row[9] or "",
                })
            return out
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
        if self._db_conn is not None:
            return self.get_persisted_events(limit=limit)
        with self._lock:
            items = list(self.recent_events)
        return items[-limit:]

    def get_persisted_events(self, limit: int = 200, offset: int = 0,
                             ev_type: str | None = None,
                             subtype: str | None = None) -> list[dict]:
        with self._lock:
            if self._db_conn is None:
                return []

            if limit <= 0:
                return []

            if offset < 0:
                offset = 0

            # Flush any batched writes so recently ingested events are visible.
            self._flush_commits_locked(force=True)

            where = []
            params: list[object] = []

            if ev_type:
                where.append("type = ?")
                params.append(ev_type)
            if subtype:
                where.append("subtype = ?")
                params.append(subtype)

            where_clause = ""
            if where:
                where_clause = " WHERE " + " AND ".join(where)

            sql = (
                "SELECT id, ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg1, arg2, retval "
                "FROM events"
                f"{where_clause} "
                "ORDER BY id DESC "
                "LIMIT ? OFFSET ?"
            )
            params.extend([limit, offset])
            rows = self._db_conn.execute(sql, params).fetchall()

        out = []
        for row in rows:
            out.append({
                "id": row[0],
                "ts_s": row[1],
                "ts_ms": row[2],
                "pid": row[3],
                "ppid": row[4],
                "uid": row[5],
                "type": row[6],
                "subtype": row[7],
                "comm": row[8],
                "arg1": row[9] or "",
                "arg2": row[10] or "",
                "retval": row[11] or 0,
                # Legacy compatibility for existing readers expecting one arg.
                "arg": row[9] or "",
            })
        return out

    def _apply_system_perf_locked(self, perf: dict):
        """Compute per-core CPU% from tick deltas and store latest system_perf."""
        raw_cores = perf.get("cores", [])
        new_tick_vecs = []
        for c in raw_cores:
            if isinstance(c, dict):
                new_tick_vecs.append([
                    int(c.get("user", 0) or 0),
                    int(c.get("nice", 0) or 0),
                    int(c.get("system", 0) or 0),
                    int(c.get("idle", 0) or 0),
                    int(c.get("iowait", 0) or 0),
                    int(c.get("irq", 0) or 0),
                    int(c.get("softirq", 0) or 0),
                ])
            elif isinstance(c, list) and len(c) >= 7:
                new_tick_vecs.append([int(v) for v in c[:7]])
            else:
                new_tick_vecs.append([0] * 7)

        cores_out = []
        prev = self._prev_core_ticks
        for i, new_vec in enumerate(new_tick_vecs):
            user, nice, system, idle, iowait, irq, softirq = new_vec
            cpu_pct = None
            if prev is not None and i < len(prev):
                old_vec = prev[i]
                delta_user = max(0, user - old_vec[0])
                delta_nice = max(0, nice - old_vec[1])
                delta_system = max(0, system - old_vec[2])
                delta_idle = max(0, idle - old_vec[3])
                delta_iowait = max(0, iowait - old_vec[4])
                delta_irq = max(0, irq - old_vec[5])
                delta_softirq = max(0, softirq - old_vec[6])
                delta_busy = delta_user + delta_nice + delta_system + delta_irq + delta_softirq
                delta_total = delta_busy + delta_idle + delta_iowait
                cpu_pct = round(delta_busy / delta_total * 100.0, 2) if delta_total > 0 else 0.0
            cores_out.append({
                "user": user,
                "nice": nice,
                "system": system,
                "idle": idle,
                "iowait": iowait,
                "irq": irq,
                "softirq": softirq,
                "cpu_pct": cpu_pct,
            })

        self._prev_core_ticks = new_tick_vecs
        self.system_perf = {
            "kind": "system_perf",
            "ts_s": int(perf.get("ts_s", 0) or 0),
            "ts_ms": int(perf.get("ts_ms", 0) or 0),
            "cores": cores_out,
            "mem": perf.get("mem", {}),
            "load": perf.get("load", {}),
        }
        self._persist_system_perf_locked(self.system_perf)

    def get_system_perf(self) -> dict:
        with self._lock:
            return self.system_perf or {}

    def get_overview(self) -> dict | None:
        with self._lock:
            if self._db_conn is None:
                return None

            row = self._db_conn.execute(
                """
                SELECT hostname, kernelver, distro, ipaddr, macaddr,
                       processor, processor_vend, ram_gbs
                FROM overviewdata
                LIMIT 1
                """
            ).fetchone()

        if row is None:
            return None

        data = self.row_to_dict(row)
        return {
            key: value
            for key, value in data.items()
            if value not in (None, "", 0)
        }

    def get_eps(self) -> int:
        now = time.monotonic()
        cutoff = now - self._rate_window
        while self._event_timestamps and self._event_timestamps[0] < cutoff:
            self._event_timestamps.popleft()
        
        recent = len(self._event_timestamps)
        return recent / self._rate_window

    def conn_uptime_thread(self):
        while True:
            start = time.perf_counter()
            with self._lock:
                self._flush_commits_locked(force=False)
                if self.is_agent:
                    self.conn_uptime += 1
                else:
                    self.conn_uptime = 0

            elapsed = time.perf_counter() - start
            time.sleep(max(0.0, 1.0 - elapsed))
    
    def get_conn_uptime(self):
        with self._lock:
            return self.conn_uptime

# Singleton shared across the whole process
store = LiveDataManager()
