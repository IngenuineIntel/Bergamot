# querying.py
# Data Management primitives

import sqlite3
import threading
import warnings

from sqlfetcher import sql


# ── UTILITY OBJECTS ──────────────────────────────────────────────────────── #

class DataManagementUsageWarning(Warning):
    """
    Warning against unintended use of the calling object in order to minimize
    the spread of silent bugs.
    """

class DataManagementUsageError(Exception):
    """
    Exception against unintended use of the calling object where execution
    should not be allowed to continue.
    """

class DataManagementError(Exception):
    """
    Something didn't work, either an exception or a definition. This is
    acceptable in execution flow and should be handled accordingly.
    """

@dataclass(slots=True)
class DatabaseListing:
    """
    Internal object for database listings.
    """
    
    db_name: str
    db_time: str
    overseer_ver: str
    path: str

    def __dict__(self) -> dict[str, str]:
        return {
            "db_name": self.db_name,
            "db_time": self.db_time,
            "overseer_ver": self.overseer_ver,
            "path": self.path,
        }


# ── QUERYING SYSTEMS - PastDataManager ───────────────────────────────────── #

class PastDataManager:
    """
    Connection and querying manager for database analysis.

    Attributes:
    
    .database
    .min_ts (read-only)
    .max_ts (read-only)
    .min_min_ts (read-only)
    .max_max_ts (read-only)
    
    Methods:

    .connected()
    .calculate_timestamps()
    .setbounds()
    .getmeta()
    .getoverview()
    .getprocoverview()
    .getprocs()
    .getperf()
    .geteps()
    TODO syscall_specific SQL

    Notes:
    - this docstring is incomplete (TODO)
    - incorrect usage of any sort throws a DataManagementUsageError
    """

    def __init__(self, db_dir="db", sql_dir="sql"):

        self.__base_dir: str = os.path.dirname(os.path.abspath(__file__))
        self.__db_dir:   str = os.path.join(self.__base_dir, db_dir)

        self.__db:     str | None                = None
        self.__conn:   sqlite3.Connection | None = None
        self.__cursor: sqlite3.Cursor | None     = None

        self.__min_ts:     int | None            = None
        self.__max_ts:     int | None            = None
        self.__min_min_ts: int | None            = None
        self.__max_max_ts: int | None            = None

    # BACKEND METHODS

    @property
    def min_ts(self):
        """
        The timestamp used as the lower barrier when querying, measured in UNIX
        time. `None` when not connected to a database.
        """
        return self.__min_ts

    @min_ts.setter
    def min_ts(self, val):
        raise DataManagementUsageError("Attribute `min_ts` can only be defined through method `PastDataManager.setbounds()`")
    
    @property
    def max_ts(self):
        """
        The timestamp used as the upper barrier when querying, measured in UNIX
        time. `None` when not connected to a database.
        """
        return self.__max_ts
    
    @max_ts.setter
    def max_ts(self, val):
        raise DataManagementUsageError("Attribute `max_ts` can only be defined through method `PastDataManager.setbounds()`")

    @property
    def min_min_ts(self):
        """
        The lowest possible value of a barrier timestamp when querying,
        measured in UNIX time. Populated by
        `<PastDataManager object>.calculate_timestamps()`. Resets to `None`
        when not connected to a database.
        """
        return self.__min_min_ts

    @min_min_ts.setter
    def min_min_ts(self, val):
        raise DataManagementUsageError("Attribute `min_min_ts` is read-only")

    @property
    def max_max_ts(self):
        """
        The highest possible value of a barrier timestamp when querying,
        measured in UNIX time. Populated by
        `<PastDataManaget object>.calculate_timestamps()`. Resets to `None`
        when not connected to a database.
        """
        return self.__max_max_ts

    @max_max_ts.setter
    def max_max_ts(self, val):
        raise DataManagementUsageError("Attribute `max_max_ts` is read-only")

    @property
    def database(self):
        """
        The database that is connected to. `None` if not connected to any.
        """
        return self.__db
    
    def __open_database(self, db: str):
        """
        Opens a database. Upon error, all values are cleared and a
        DataManagementError is thrown.
        """
        try:
            self.__db = os.path.join(
                self.__db_dir,
                db + ".db" if not db.endswith(".db") else db
            )
            self.__conn = sqlite3.connect(self.__db)
            self.__cursor = self.__conn.cursor()
        except sqlite3.OperationalError:
            __close_database()
            raise DataManagementError(f"Failed to connect to database {self.__db}")

    def __close_database(self):
        try:
            self.__conn.close()
        
        self.__db, self.__conn, self.__cursor, self.__min_ts, self.__max_ts,
        self.__min_min_ts, self.__max_max_ts =
        (None,) * 7

    @database.setter
    def database(self, val):
        """Connects to or disconnects from a database. Attributes are altered
        accordingly. Connect to a database by supplying a path to one;
        disconnect from a database by supplying `None`.
        """
        if val is None:
            __close_database()
        else:
            __open_database(val)

    def __fetchone(self, cmd: str, params=None) -> tuple | sqlite3.Row:
        """
        Confirms SQLite connection and executes SQL `cmd` and returns a single
        row. `__fetchall()` returns all rows
        """
        if not self.__cursor:
            raise DataManagementUsageError("Not connected to a database!")
        return self.__cursor.execute(cmd, params).fetchone()

    def __fetchall(self, cmd: str, params=None) -> list[tuple]:
        """
        Confirms SQLite connection and executes SQL `cmd` and returns all data.
        """
        if not self.__cursor:
            raise DataManagementUsageError("Not connected to a database!")
        return self.__cursor.execute(cmd, params).fetchone()

    def __confirm_bounds(self):
        if not self.__min_ts or not self.__max_ts:
            raise DataManagementUsageError("Must set bounds!")

    def __defaultparams(self, **kwargs) -> dict:
        """Most of the params for SQL are the same, so here's a wrapper."""
        ret = {
            "min_ts": self.__min_ts,
            "max_ts": self.__max_ts
        }.update(kwargs)
        return ret

    # FRONT FACING METHODS

    def connected(self) -> bool:
        """"""
        return False if not self.__db else True

    def calculate_timestamps(self) -> tuple(int, int):
        """Calculates the bottom most and top most timestamps of the connected
        database. Throws a DataManagementUsageError if called without an
        active connection. Populates `self.min_min_ts` and `self.max_max_ts`, but also
        returns the values as a tuple.
        """
        if self.__conn is None:
            raise DataManagementUsageError(
                "Method `calculate_timestamps` must not be called without an active database connection (there isn't one.)"
            )
        else:
            self.__min_min_ts, self.__max_max_ts = self.__cursor.execute(sql.getminmaxts).fetchone()

        return self.__min_min_ts, self.__max_max_ts

    def setbounds(self, **kwargs):
        """
        Sets minimum and maximum timestamp values to use during querying.
        Improper values cause a DataManagementError
        """
        try:
            min, max = kwargs["min"], kwargs["max"]
        except KeyError:
            raise DataManagementUsageError("Method setbounds requires kwargs 'min' and 'max'.")

        if max < min or min < self.__min_min_ts or max > self.__max_max_ts:
            raise DataManagementError("Invalid values for method `setbounds()`")

        self.__min_ts, self.__max_ts = min, max

    def _unsafe_getcursor(self):
        """
        Direct access to the sqlite3.Cursor object. Unsafe, for debugging only.
        This method must not be used in any code that is deemed `functional`.
        """
        warnings.warn(
            "`PastDataManager._unsafe_getcursor()` is UNSAFE and for debugging only.",
            DataManagerUsageWarning,
            stacklevel=2,
            source=None
        )
        return self.__cursor

    def getmeta(self) -> tuple:
        """Database meta info."""
        return self.__fetchone(sql.getmeta)

    def getoverview(self) -> tuple:
        """Agent system info."""
        return self.__fetchone(sql.getoverview)

    def proc_overview(self) -> tuple:
        """Process overview info within bounds."""
        self.__confirm_bounds()
        return self.__fetchone(sql.getprocsoverview, self.__defaultparams())

    def getprocs(self) -> list:
        """All procs within bounds."""
        self.__confirm_bounds()
        return self.__fetchall(sql.getprocs, self.__defaultparams())

    def getperf(self) -> list:
        """All performance info within bounds."""
        self.__confirm_bounds()
        return self.__fetchall(sql.getcpu, self.__defaultparams())

    def geteps(self) -> list:
        """Events per second within bounds."""
        self.__confirm_bounds()
        return self.__fetchall(sql.geteps, self.__defaultparams())


# ── QUERYING SYSTEMS - LiveDataManager ───────────────────────────────────── #

class LiveDataManager:
    """
    Connection and query manager for querying live databases.
    """
    pass # TODO
