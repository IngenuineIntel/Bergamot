"""Shared SQL script loader for Overseer managers."""

import contextlib
import os
from threading import RLock

class SQLManagementError(Exception):
    """
    If you've just seen this exception, it's either your fault, or the fault
    of this programs packaging. This shouldn't be caught.
    """

class SQLManager:
    """
    Developer interface for all SQL scripts pertaining to this program.
    """
    
    #### HOW IT WORKS ####

    # SQL scripts are stored in the below dictionary:
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
    # with values being the SQL scripts' paths. Upon initialization, this dict
    # is copied and the paths are replaced with the content of the files at the
    # paths. __getattr__ is hooked so that instead of referencing actual
    # attributes, you access the new dictionary, which is also the __dict__
    # value of the object. This object is thread protected, and so there is
    # only a need for a single, global instance, which is defined at the bottom
    # the of file.

    def __init__(self, sqldir="sql"):

        # dict() to create a copy, not a reference
        self.__internal_aliases = dict(self.__ALIASES)
        
        self.__l = RLock()

        path = ""
        for key in self.__internal_aliases:
            try:
                path = os.path.join(os.path.realpath(sqldir), self.__internal_aliases[key])

                with open(path, "r") as fd:
                    self.__internal_aliases[key] = fd.read().strip()

            except FileNotFoundError as e:
                raise SQLManagementError(e)

    def __sub_getattr(self, key):
        ret = None

        with contextlib.suppress(KeyError):
            ret = self.__internal_aliases[key]

        if not ret:
            raise AttributeError(
                f"'{type(self)}' has no attribute '{key}'. Try running "
                +"`SQLManager.dbg_index()` to get a list of SQL aliases."
            )

        return ret

    def __getattr__(self, key):
        with self.__l():
            return __sub_getattr(key)

    def __setattr__(self, name, value):
        raise SQLManagementError(f"'{type(self)} is read-only.")

    @classmethod
    def dbg_index(cls):
        for i in cls.__ALIASES:
            print(f"{i}\t\t{cls.__ALIASES[i]}")

    @property
    def __dict__(self):
        with self.__l():
            return self.__internal_aliases

sql = SQLManager()
