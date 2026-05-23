# research.py
# responsible for all database fetches and filter processing
# TODO make this exist

import os
import sqlite3
import threading
from typing import NamedTuple

# simplicity
__dir = os.path.dirname(os.path.abspath(__file__))

class __SQLScriptLib:
    """The collection of SQL scripts DataProcessor needs, as an object."""
    def __init__(self, sql_dir="sql/"):
        # the read text from the SQL scripts
        self.getmeta, self.getprocs, self.geteps, self.getcpu = (
            None, None, None, None
        )
        __sqlfiles = [
            "processing_getmeta.sql",
            "processing_getprocs.sql",
            "processing_geteps.sql",
            "processing_getcpu.sql"
        ]
        # TODO there's not way there's _not_ a better way to do this, but my os.path* knowledge is shaky
        __scripts = [
            os.path.join(__dir, sql_dir, script) for script in __sqlfiles
        ]
        
        __easyread = lambda fd: fd.read().strip()
        
        for script in __scripts:
            with open(script, "r") as fd:
                match script:
                    case __scripts[0]:
                        self.getmeta = __easyread(fd)
                    case __script[1]:
                        self.getprocs = __easyread(fd)
                    case __scripts[2]:
                        self.geteps = __easyread(fd)
                    case __scripts[3]:
                        self.getcpu = __easyread(fd)

# DEPRECATED UPON CREATION
class __ProcessorOperationalError(Exception):
    """Currently, flaws in the database cause a crash via this exception. TODO
    make this not happen, make the error show on the webserver."""
    pass

class __ProcessorDatabaseListing():
    """Reflects the `metadata` table in the databases the Overseer creates."""
    db_name: str
    db_time: str
    overseer_ver: str

class DataProcessor:

    def __init__(self, db_name: str):

        # WTF IS A RACE CONDITION!!!!
        self.__lock = threading.Lock()

        # the object-wide sqlite connection
        self.__conn: sqlite3.Connection = None
        # the choice of whatever database we have open rn
        self.__choice = None
        """self.conn must be None when self.choice is None, and vice versa"""

        self.__library = __SQLScriptLib()

        def load_db_listings(dbdir="db/") -> list[__ProcessorDatabaseListing]:
            ret = []
            for listing in os.listdir(os.path.join(__dir, dbdir)):
                listing_obj = __ProcessorDatabaseListing()
                listing_obj.db_name = listing

                c = sqlite3.connect(listing).cursor()

                listing_obj.db_time, listing_obj.overseer_ver = c.execute(__library.getmeta).fetchone()
                
                c.close()
                ret.append(listing_obj)
            return ret

        self.reload_listings = load_db_listings

    """ TODO the rest of DataProcessor """
