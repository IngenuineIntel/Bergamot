"""Shared SQL script loader for Over-Seer managers."""
# TODO I NEED COMMENTS

import contextlib
import os
from threading import RLock

class SQLManagementError(Exception):
    """
    If you've just seen this exception, it's either your fault, or the fault
    of this programs packaging.
    """

class SQLManager:
    __ALIASES = {
        # data inputs
        "initdb":     "in/initdb.sql",
        "entryevent": "in/entryevent.sql",
        "entryproc":  "in/entryproc.sql",
        "entryperf":  "in/entryperf.sql",

        # data outputs
        "getmeta":          "out/getmeta_past.sql",
        "getcpu":           "out/getcpu_past.sql",
        "geteps":           "out/geteps_past.sql",
        "getprocs":         "out/getprocs_past.sql",
        "getprocsoverview": "out/getprocsoverview.sql",
        "getminmaxts":      "out/getminmaxts_past.sql",
        "getoverview":      "out/getoverview_past.sql",
        "geteventsbytype":  "out/geteventsbytype.sql",
        "geteventsbypid":   "out/geteventsbypid.sql"
    }

    def __init__(self, sqldir="sql"):

        self.__internal_aliases = dict(self.__ALIASES)
        
        self.__getattr_rlock = RLock()

        path = ""
        for key in self.__internal_aliases:
            try:
                path = os.path.join(os.path.realpath(sqldir), self.__internal_aliases[key])

                with open(path, "r") as fd:
                    self.__internal_aliases[key] = fd.read().strip()

            except FileNotFoundError:
                raise SQLManagementError(f"Couldn't access file {path}")

    def __sub_getattr__(self, key):
        ret = None

        with contextlib.suppress(KeyError):
            ret = self.__internal_aliases[key]

        if not ret:
            raise AttributeError(
                f"'{type(self)}' as no attribute '{key}'. Try running "
                +"`SQLManager.dbg_index()` to get a list of SQL aliases."
            )

        return ret

    def __getattr__(self, key):
        with self.__getattr_rlock():
            return __sub_getattr__(key)

    def __setattr__(self, name, value):
        raise SQLManagementError(f"'{type(self)} is read-only.")

    @classmethod
    def dbg_index(cls):
        for i in cls.__ALIASES:
            print(f"{i}\t\t{cls.__ALIASES[i]}")

    def __dict__(self):
        return self.__internal_aliases

sql = SQLManager()
