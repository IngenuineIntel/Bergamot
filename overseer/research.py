# research.py
# responsible for all database fetches and filter processing

"""

TODO
FIXME
THIS FILE IS AWFUL IN MANY PLACES

"""

import os
import sqlite3
import threading

# simplicity
# TODO undo simplicity
__dir = os.path.dirname(os.path.abspath(__file__))

class _SQLScriptLib:
    """The collection of SQL scripts DataProcessor needs, as an object."""
    def __init__(self, sql_dir="sql/"):

        def __contents(f):
            # TODO some os.path* magic
            with open(f, "r") as fd:
                return fd.read.strip()

        self.getmeta     = __contents("processing_getmeta.sql")
        self.getminmaxts = __contents("processing_getminmaxts.sql")
        self.getprocs    = __contents("processing_getprocs.sql")
        self.geteps      = __contents("processing_geteps.sql")
        self.getcpu      = __contents("processing_getcpu.sql")

class __ProcessorOperationalError(Exception):
    """If this is raised, the DataProcessor class was used incorrectly by the dev."""

class __ProcessorDatabaseListing():
    """Reflects the `metadata` table in the databases the Overseer creates."""
    db_name: str
    db_time: str
    overseer_ver: str

class DataProcessor:

    def __init__(self):

        # WTF IS A RACE CONDITION!!!!
        # TODO lock the shit outta everything
        self.__lock = threading.Lock()

        # the object-wide sqlite connection & cursor
        self.__conn:   sqlite3.Connection = None
        self.__cursor: sqlite3.Cursor = None
        # the choice of whatever database we have open rn
        # publically visible as `self.database` (@property)
        self.__choice = None

        """self.conn must be None when self.choice is None, and vice versa"""

        # operations and queries into the database are always accompanied by
        # a minimum and maximum timestamp (in theory both in UNIX time)
        self.__min_ts = 0
        self.__max_ts = 0
        # they are populated by @property wrappers because they need to be
        # tested against the min min ts and the max max ts, that is, the first
        # and smallest timestamp and the last and oldest timestamp respectively
        self.__min_min_ts = 0
        self.__max_max_ts = 0
        # none are defined on init because they don't need to be until the user
        # tries to define `self.timestamps`, additional to the fact that they
        # can't be until a database is chosen
        # likewise, note that all of these four attributes are cleared upon
        # database reselection

        # TODO more init-ing here

        self.__library = _SQLScriptLib()

        # a list of all avalible databases to connect to are stored in
        self.databases = []

        # this function is inline, but made an attribute function
        # we'll see if the interpreter will actually let me do this...
        # TODO even if it does I hate it and want it gone!
        def load_db_listings(self, dbdir="db/"):
            ret = []
            for listing in os.listdir(os.path.join(__dir, dbdir)):
                listing_obj = __ProcessorDatabaseListing()
                listing_obj.db_name = listing

                co = sqlite3.connect(listing)
                c = co.cursor()

                listing_obj.db_time, listing_obj.overseer_ver = c.execute(self.__library.getmeta).fetchone()
                
                co.close()
                ret.append(listing_obj)
            self.databases = ret

        load_db_listings(self)

        self.reload_listings = load_db_listings

    @property
    def database(self):
        return self.__choice

    def __database_clear(self):
        self.__conn, self.__cursor, self.__choice = (None, None, None)
        self.__min_min_ts, self.__max_max_ts = (0, 0)
        self.__min_ts, self__max_ts = (0, 0)

    @database.setter
    def database(self, listing: str):
        if listing == None:
            self.__database_clear()
            return
        self.__conn = sqlite3.connect(listing)
        if not self.__conn:
            self.__database_clear()
            return
        self.__cursor = self.__conn.cursor()
        self.__choice = listing
        self.__min_min_ts, self.__max_max_ts = (0, 0)
        self.__min_ts, self__max_ts = (0, 0)
    
    def get_min_max_min_max_ts(self):
        """
        Gets the minimum and maximum minimum and maximum timestamps.
        Runs SQL on first call since current database selection, but stashes
        the values privately for next call.
        """
        if self.__min_min_ts != 0 and self.__max_max_ts != 0:
            return (self.__min_min_ts, self.__max_max_ts)
        elif self.database == None:
            raise __ProcessorOperationalError("Choose a database before calling DataProcessor.get_min_max_min_max_ts()")
        self.__min_min_ts, self.__max_max_ts = self.__cursor.execute(self.__library.getminmaxts).fetchone()
        return (self.__min_min_ts, self.__max_max_ts)

    @property
    def timestamps(self):
        raise __ProcessorOperationalError("This value is read-only.")
    
    @timestamps.setter
    def timestamps(self, ts: tuple):
        if not self.__min_min_ts or not self.__max_max_ts:
            # database not initialized, can't set these values
            raise __ProcessorOperationalError(
                "DataProcessor.timestamps can't be defined while the timestamp boundaries aren't. "
                + "Call DataProcessor.get_min_max_min_max_ts() first, as it populates the boundaries"
            )
        self.__min_ts, self.__max_ts = ts
        if self.__min_ts < self.__min_min_ts or self.__min_ts > self.__max_max_ts:
            # one or both values extend past the boundaries, abort
            raise __ProcessorOperationalError(
                "bottom DataProcessor.timestamps value given exceeds ranges supplied in DataProcessor.get_min_max_min_max_ts()"
            )
        elif self.__max_ts < self.__min_min_ts or self.__max_ts > self__max_max_ts:
            raise __ProcessorOperationalError (
                "top DataProcessor.timestamps value given exceeds ranges supplied in DataProcessores.get_min_max_min_max_ts()"
            )

    """ TODO the rest of DataProcessor """
