"""Historical SQL data manager for archived Overseer session databases."""

from __future__ import annotations

import os
import sqlite3
from dataclasses import dataclass

from querying import DataManager, DataManagementError
from sqlfetcher import SQLManager

@dataclass(slots=True)
class DatabaseListing:
    db_name: str
    db_time: str
    overseer_ver: str
    path: str

    def as_dict(self) -> dict[str, str]:
        return {
            "db_name": self.db_name,
            "db_time": self.db_time,
            "overseer_ver": self.overseer_ver,
            "path": self.path,
        }

# TODO I NEED COMMENTS

class PastDataManager(DataManager):
    """Reader for past session databases selected by the developer."""

    def __init__(self, db_dir: str = "db", sql_dir: str = "sql"):
        super().__init__()
        base_dir = os.path.dirname(os.path.abspath(__file__))
        self._base_dir = base_dir
        self._db_dir = os.path.join(base_dir, db_dir)
        self._sql_manager = SQLManager(os.path.join(base_dir, sql_dir))

        self._choice: str | None = None
        self._min_ts: int = 0
        self._max_ts: int = 0
        self._min_min_ts: int = 0
        self._max_max_ts: int = 0

        self.databases: list[DatabaseListing] = []
        self.reload_listings()

    @property
    def database(self) -> str | None:
        return self._choice

    @database.setter
    def database(self, listing: str | None):
        if listing is None:
            self._database_clear()
            return

        chosen_path = self._resolve_listing_path(listing)
        self.connect_database(chosen_path)
        self._choice = chosen_path
        self._min_ts = 0
        self._max_ts = 0
        self._min_min_ts = 0
        self._max_max_ts = 0

    @property
    def timestamps(self) -> tuple[int, int]:
        return (self._min_ts, self._max_ts)

    @timestamps.setter
    def timestamps(self, ts: tuple[int, int]):
        if self._choice is None:
            raise DataManagementError("Choose a database before setting timestamps")

        if self._min_min_ts == 0 and self._max_max_ts == 0:
            self.get_min_max_min_max_ts()

        min_ts, max_ts = ts
        if min_ts < self._min_min_ts or min_ts > self._max_max_ts:
            raise DataManagementError("timestamps lower bound exceeds available range")
        if max_ts < self._min_min_ts or max_ts > self._max_max_ts:
            raise DataManagementError("timestamps upper bound exceeds available range")
        if min_ts > max_ts:
            raise DataManagementError("timestamps lower bound cannot exceed upper bound")

        self._min_ts = int(min_ts)
        self._max_ts = int(max_ts)

    def _database_clear(self):
        self.close_database()
        self._choice = None
        self._min_ts = 0
        self._max_ts = 0
        self._min_min_ts = 0
        self._max_max_ts = 0

    def _resolve_listing_path(self, listing: str) -> str:
        if os.path.isabs(listing):
            if not os.path.isfile(listing):
                raise DataManagementError(f"Database does not exist: {listing}")
            return listing

        candidate = os.path.join(self._db_dir, listing)
        if not os.path.isfile(candidate):
            raise DataManagementError(
                f"Unknown database '{listing}'. Use show_databases() first."
            )
        return candidate

    def reload_listings(self) -> list[dict[str, str]]:
        self.databases = self._load_database_listings()
        return [listing.as_dict() for listing in self.databases]

    def show_databases(self) -> list[dict[str, str]]:
        if not self.databases:
            return self.reload_listings()
        return [listing.as_dict() for listing in self.databases]

    def _load_database_listings(self) -> list[DatabaseListing]:
        if not os.path.isdir(self._db_dir):
            return []

        meta_sql = self._sql_manager.get("processing_getmeta")
        listings: list[DatabaseListing] = []

        for name in sorted(os.listdir(self._db_dir)):
            path = os.path.join(self._db_dir, name)
            if not os.path.isfile(path) or not name.endswith(".db"):
                continue

            try:
                conn = sqlite3.connect(path)
                conn.row_factory = sqlite3.Row
                row = conn.execute(meta_sql).fetchone()
                conn.close()
            except sqlite3.Error:
                continue

            if row is None:
                db_time = ""
                overseer_ver = ""
            else:
                db_time = str(row["db_time"] or "")
                overseer_ver = str(row["overseer_ver"] or "")

            listings.append(DatabaseListing(
                db_name=name,
                db_time=db_time,
                overseer_ver=overseer_ver,
                path=path,
            ))

        return listings

    def _ensure_selected_database(self):
        if self._choice is None or self.connection is None:
            raise DataManagementError("No database selected; set PastDataManager.database first")

    def get_min_max_min_max_ts(self) -> tuple[int, int]:
        self._ensure_selected_database()
        if self._min_min_ts != 0 or self._max_max_ts != 0:
            return (self._min_min_ts, self._max_max_ts)

        bounds_sql = self._sql_manager.get("processing_getmaxmints")
        row = self.execute(bounds_sql).fetchone()
        if row is None:
            self._min_min_ts, self._max_max_ts = (0, 0)
        else:
            self._min_min_ts = int(row[0] or 0)
            self._max_max_ts = int(row[1] or 0)

        if self._min_ts == 0 and self._max_ts == 0 and self._max_max_ts >= self._min_min_ts:
            self._min_ts, self._max_ts = self._min_min_ts, self._max_max_ts

        return (self._min_min_ts, self._max_max_ts)

    def get_overview(self) -> dict | None:
        self._ensure_selected_database()
        row = self.fetch_one_dict(# TODO FIXME I belong in a SQL file
            """
            SELECT hostname, kernelver, distro, ipaddr, macaddr,
                   processor, processor_vend, ram_gbs
            FROM overviewdata
            LIMIT 1
            """
        )
        if row is None:
            return None
        return {key: value for key, value in row.items() if value not in (None, "", 0)}

    def get_persisted_events(self, limit: int = 200, offset: int = 0,
                             ev_type: str | None = None,
                             subtype: str | None = None) -> list[dict]:
        self._ensure_selected_database()
        if limit <= 0:
            return []
        if offset < 0:
            offset = 0

        where = []
        params: list[object] = []
        if ev_type:
            where.append("type = ?")
            params.append(ev_type)
        if subtype:
            where.append("subtype = ?")
            params.append(subtype)

        where_clause = f" WHERE {' AND '.join(where)}" if where else ""
        sql = (# TODO FIXME I belong in a SQL file
            "SELECT id, ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg1, arg2, retval "
            "FROM events"
            f"{where_clause} "
            "ORDER BY id DESC "
            "LIMIT ? OFFSET ?"
        )
        params.extend([limit, offset])

        rows = self.fetch_all_dicts(sql, params)
        for row in rows:
            row["arg1"] = row.get("arg1") or ""
            row["arg2"] = row.get("arg2") or ""
            row["retval"] = row.get("retval") or 0
            row["arg"] = row["arg1"]
        return rows

    def get_recent_events(self, limit: int = 200) -> list[dict]:
        return self.get_persisted_events(limit=limit)

    def get_file_opens(self, limit: int = 100) -> list[dict]:
        return self.get_persisted_events(limit=limit, ev_type="open")

    def get_network(self, limit: int = 100) -> list[dict]:
        return self.get_persisted_events(limit=limit, ev_type="connect")

    def get_fork(self, limit: int = 200) -> list[dict]:
        return self.get_persisted_events(limit=limit, ev_type="fork")

    def get_execve(self, limit: int = 200) -> list[dict]:
        return self.get_persisted_events(limit=limit, ev_type="execve")

    def get_fork_exec(self, limit: int = 300) -> list[dict]:
        self._ensure_selected_database()
        rows = self.fetch_all_dicts(# TODO FIXME I belong in a SQL file
            """
            SELECT id, ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg1, arg2, retval
            FROM events
            WHERE type IN ('fork', 'execve')
            ORDER BY id DESC
            LIMIT ?
            """,
            (limit,),
        )
        for row in rows:
            row["arg1"] = row.get("arg1") or ""
            row["arg2"] = row.get("arg2") or ""
            row["retval"] = row.get("retval") or 0
            row["arg"] = row["arg1"]
        return rows

    def get_processes(self, limit: int = 500) -> list[dict]:
        self._ensure_selected_database()
        if self._min_ts == 0 and self._max_ts == 0:
            self.get_min_max_min_max_ts()

        return self.fetch_all_dicts(# TODO FIXME I belong in a SQL file
            """
            SELECT pid,
                   first_seen_ts_s,
                   first_seen_ts_ms,
                   last_seen_ts_s,
                   last_seen_ts_ms,
                   ended_ts_s,
                   ended_ts_ms,
                   first_uid,
                   first_ppid,
                   first_comm,
                   last_uid,
                   last_ppid,
                   last_comm
            FROM procs
            WHERE first_seen_ts_s >= ?
              AND first_seen_ts_s <= ?
            ORDER BY id DESC
            LIMIT ?
            """,
            (self._min_ts, self._max_ts, limit),
        )

    def get_system_perf(self) -> list[dict]:
        self._ensure_selected_database()
        if self._min_ts == 0 and self._max_ts == 0:
            self.get_min_max_min_max_ts()

        cpu_sql = self._sql_manager.get("processing_getcpu")
        return self.fetch_all_dicts(cpu_sql, {
            "min_ts": self._min_ts,
            "max_ts": self._max_ts,
        })

    def get_eps(self) -> list[dict]:
        self._ensure_selected_database()
        if self._min_ts == 0 and self._max_ts == 0:
            self.get_min_max_min_max_ts()

        eps_sql = self._sql_manager.get("processing_geteps")
        return self.fetch_all_dicts(eps_sql, {
            "min_ts": self._min_ts,
            "max_ts": self._max_ts,
        })

    def get_process_overview(self) -> dict:
        self._ensure_selected_database()
        if self._min_ts == 0 and self._max_ts == 0:
            self.get_min_max_min_max_ts()

        procs_sql = self._sql_manager.get("processing_getprocs")
        row = self.fetch_one_dict(procs_sql, {
            "min_ts": self._min_ts,
            "max_ts": self._max_ts,
        })
        return row or {
            "processes_seen": 0,
            "spawns_seen": 0,
            "preexisting": 0,
            "deaths_seen": 0,
        }
