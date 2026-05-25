"""Shared SQL connection/query primitives for data managers."""
# TODO I NEED COMMENTS

import sqlite3
import threading
from typing import Any, Iterable, Sequence

class DataManagementError(Exception):
    """
    If you're looking at this exception... you, the dev, failed to use the
    backend corrently. This exception should never surface, and if it does,
    it's to crash instead of break silently, and the bug is outside of the
    class that called this.
    """

class DataManagementQualityError(Exception):
    """
    If you're looking at this exception, there's something wrong with the
    data that's been pulled from the database...
    TODO really shouldn't raise for a problem like that, but this makes
    a convenient band-aid and will hopefully aid debugging
    """

class DataManager:

    def __init__(self):
        self._db_lock = threading.RLock()
        """
        `self.__db_lock` must be used for the following:
        """
        self._db_conn: sqlite3.Connection | None = None
        self._db: str | None = ""
        """ END `self.__db_lock` """

    """ DataManager().db
    Upon writing, connection is established and internal variables set
    If this fails, DataManager.db = None
    Upon reading, the database name is given
    """
    @property
    def db(self) -> sqlite3.Connection | None:
        return self._db_conn

    @db.setter
    def db(self, database_path: str, **connect_kwargs: Any):
        with self._db_lock:
            self._close_database()
            if database_path == None:
                return
            conn = sqlite3.connect(database_path)
            conn.row_factory = sqlite3.Row
            self._db_conn = conn

    def __close_database(self):
        with self._db_lock:
            if self._db_conn is None:
                return
            self._db_conn.close()
            self._db_conn = None
            self._db

    def __require_connection(self) -> sqlite3.Connection:
        if self._db_conn is None:
            raise DataManagementError("No SQL database connection is active")
        return self._db_conn

    def _execute(self, query: str, params: Sequence[Any] | dict[str, Any] | None = None):
        with self._db_lock:
            conn = self.__require_connection()
            if params is None:
                return conn.execute(query)
            return conn.execute(query, params)

    def fetch_one_dict(self, query: str, params: Sequence[Any] | dict[str, Any] | None = None) -> dict[str, Any] | None:
        row = self.execute(query, params).fetchone()
        if row is None:
            return None
        return self.row_to_dict(row)

    def fetch_all_dicts(self, query: str, params: Sequence[Any] | dict[str, Any] | None = None) -> list[dict[str, Any]]:
        rows = self.execute(query, params).fetchall()
        return self.rows_to_dicts(rows)

    @staticmethod
    def row_to_dict(row: sqlite3.Row | tuple | dict[str, Any]) -> dict[str, Any]:
        if isinstance(row, dict):
            return dict(row)
        if isinstance(row, sqlite3.Row):
            return dict(row)
        if isinstance(row, tuple):
            return {str(idx): value for idx, value in enumerate(row)}
        raise DataManagementQualityError(f"Unsupported row type: {type(row)!r}")

    @classmethod
    def rows_to_dicts(cls, rows: Iterable[sqlite3.Row | tuple | dict[str, Any]]) -> list[dict[str, Any]]:
        return [cls.row_to_dict(row) for row in rows]
