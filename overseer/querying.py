# querying.py
# Data Management primitives

import sqlite3
import threading
import warnings

from sqlfetcher import sql


# ── UTILITY OBJECTS ──────────────────────────────────────────────────────── #
# Q: Why so many exceptions?
# A: Because it's really explicit, exception messages can help developers, and
# because its easier to try|except than it is to parse retcodes, not to mention
# the loss of readability that would be associated with retcode parsing.

class DataManagementUsageWarning(Warning):
    """
    Warning against unintended use of the callee object in order to minimize
    the spread of silent bugs.
    """

class DataManagementUsageError(Exception):
    """
    Exception against unintended use of the callee object where execution
    should not be allowed to continue. This exception should not be caught, as
    it should never be raised at all.
    """

class DataManagementError(Exception):
    """
    Something didn't work. This is acceptable in execution flow and should be
    handled accordingly. This exception is often used as a wrapper for other
    internal errors, but I've consolidated those errors so they can be handled
    by whichever code called whatever in this file threw the error.

    A PastDataManager or LiveDataManager object failed to do something
    correctly. These should be expected and handled in the calling code, not
    within the raising class.
    """

class DataPopulationError(Exception):
    """
    A DataPopulator object failed to do something correctly. These should be
    expected and handled in the method calling code.
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
    .geteventsbypid()
    .geteventsbytype()

    Notes:
    - this docstring is incomplete (TODO)
    - incorrect usage of any sort throws a DataManagementUsageError
    """

    def __init__(self, db_dir="db", sql_dir="sql"):

        # TODO I don't think that path calculations fit the scope of a class
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
        except:
            pass
        
        self.__db, self.__conn, self.__cursor, self.__min_ts, self.__max_ts,
        self.__min_min_ts, self.__max_max_ts = (None,) * 7

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

    def geteventsbytype(self, type: str) -> list:
        """Events filtered by syscall type within bounds."""
        self.__confirm_bounds()
        return self.__fetchall(sql.geteventsbytype, self.__defaultparams(type=type))

    def geteventsbypid(self, pid: int) -> list:
        """Events filtered by PID within bounds."""
        self.__confirm_bounds()
        return self.__fetchall(sql.geteventsbypid, self.__defaultparams(pid=pid))

    # TODO not the responsibility of a database management object, this needs
    # to go elsewhere
    @classmethod
    def database_listings(cls):
        pass


# ── QUERYING SYSTEMS - LiveDataManager ───────────────────────────────────── #

class LiveDataManager:
    """
    Connection and query manager for querying live databases.
    """
    def __init__(self, db: str, db_dir=""):
        pass # TODO

# ── DATABASE POPULATING ──────────────────────────────────────────────────── #

@dataclass
class OvervRow:
    hostname:       str = "unknown"
    kernelver:      str = "unknown"
    distro:         str = "unknown"
    ipaddr:         str = "unknown"
    macaddr:        str = "unknown"
    processor:      str = "unknown"
    processor_vend: str = "unknown"
    ram_gbs:        int = 0

# TODO Ken Thompson regretted `creat`, will I regret `EvntRow`?
@dataclass
class EvntRow:
    #id: int
    ts_s:    int
    ts_ms:   int
    pid:     int
    type:    str
    subtype: str | None
    arg1:    str | None
    arg2:    str | None
    retval:  int

@dataclass
class ProcRow:
    #id: int
    pid: int
    first_seen_ts_s:  int
    first_seen_ts_ms: int
    last_seen_ts_s:   int
    last_seen_ts_ms:  int
    ended_ts_s:       int | None
    ended_ts_ms:      int | None
    first_uid:        int
    first_ppid:       int
    first_comm:       str
    last_uid:         int | None
    last_ppid:        int | None
    last_comm:        str | None

@dataclass
class PerfRow:
    #id: int
    ts_s: int
    ts_ms: int
    core_count: int
    avg_cpu_pct: float
    mem_total_kb: int
    mem_free_kb: int
    mem_available_kb: int
    mem_cached_kb: int
    load_1m: float
    load_5m: float
    load_15m: float
    # TODO this is silly?
    cores_json: text

class DataPopulator:
    """Database populator."""
    def __init__(self, db: str):
        try:
            # expecting a full path from `db`; no path resolution inline here.
            # couldn't be bothered, its outside the scope of a class.
            # Also not going to check if there's already a database here; if
            # there is, it'll get written into :(
            self.__db = db
            self.__conn = sqlite3.connect(self.__db)
            self.__cursor = self.__conn.cursor()
        except sqlite3.OperationalError as e:
            del self
            raise DataManagementError(e)

    def __ins_row(self, row: EvntRow | ProcRow | PerfRow):
        pass # TODO

    def __cast_row(self, row: str) -> EvntRow | ProcRow | PerfRow:
        """Takes a row and 'casts' it into a *Row class."""
        pass # TODO

    def process_row(self, row: str) -> None:
        """Parses decompiled rows and inserts it into the database.
        Failures throw DataPopulationErrors.
        """
        self.__ins_row(self.__cast_row(row))

    def reload(self, db: str):
        """Better than redefinition"""
        self.__init__(db)

    # TODO

    @staticmethod
    def resolve_db(db: str):
        """Resolves path so __init__ doesn't have to"""
        # TODO I don't actually think this is right
        return os.path.realpath(db)

# ── GLOBALS ──────────────────────────────────────────────────────────────── #

# TODO maybe not globals..?
pdm = PastDataManager()
ldm = LiveDataManager()
dp  = DataPopulator()
