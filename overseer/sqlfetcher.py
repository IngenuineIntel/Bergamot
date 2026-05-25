"""Shared SQL script loader for Over-Seer managers."""
# TODO I NEED COMMENTS

from pathlib import Path

class SQLManagementError(Exception):
    """
    If you've seen this exception before, there's either something wrong with
    your codebase, this program's packaging, or the SQLManager class itself.
    """

class SQLManager:
    """Load and cache SQL scripts by logical name from the overseer sql tree."""

    _ALIASES = { # omit ".sql"
        # data inputs
        "initdb": "in/initdb.sql",
        "entryevent": "in/entryevent.sql",
        "entryproc": "in/entryproc.sql",
        "entryperf": "in/entryperf.sql",

        # data outputs
        "processing_getmeta": "out/getmeta_past.sql",
        "processing_getcpu": "out/getcpu_past.sql",
        "processing_geteps": "out/geteps_past.sql",
        "processing_getprocs": "out/getprocs_past.sql",
        "processing_getmaxmints": "out/getminmaxts_past.sql",
        "processing_getminmaxts": "out/getminmaxts_past.sql",

        # direct file references for both
        # TODO why?
        "in/initdb.sql": "in/initdb.sql",
        "in/entryevent.sql": "in/entryevent.sql",
        "in/entryproc.sql": "in/entryproc.sql",
        "in/entryperf.sql": "in/entryperf.sql",
        "out/getmeta_past.sql": "out/getmeta_past.sql",
        "out/getcpu_past.sql": "out/getcpu_past.sql",
        "out/geteps_past.sql": "out/geteps_past.sql",
        "out/getprocs_past.sql": "out/getprocs_past.sql",
        "out/getminmaxts_past.sql": "out/getminmaxts_past.sql",
    }

    def __init__(self, sql_dir: str | Path | None = None):
        base_dir = Path(__file__).resolve().parent
        self._sql_dir = Path(sql_dir) if sql_dir is not None else (base_dir / "sql")
        self._cache: dict[str, str] = {}

    @property
    def sql_dir(self) -> Path:
        return self._sql_dir

    def get(self, script_name: str) -> str:
        normalized = self._normalize_name(script_name)
        if normalized in self._cache:
            return self._cache[normalized]

        # TODO consider if this is very Pythonic... it might be more Pythonic
        # to just open the file and wait for it to throw a FileNotFoundError
        # on its own.

        script_path = self._sql_dir / normalized
        if not script_path.exists():
            raise SQLManagementError(f"SQL script not found: {script_path}")

        content = script_path.read_text(encoding="utf-8").strip()
        self._cache[normalized] = content
        return content

    def _normalize_name(self, script_name: str) -> str:
        name = (script_name or "").strip()
        if not name:
            raise SQLManagementError("script_name must be a non-empty string")

        if name in self._ALIASES:
            return self._ALIASES[name]

        # TODO think about this critically
        candidate = f"{name}.sql" if not name.endswith(".sql") else name
        if candidate in self._ALIASES:
            return self._ALIASES[candidate]

        # If the caller already supplied a path-like name, allow it directly.
        if "/" in name or name.endswith(".sql"):
            return name

        raise SQLManagementError(f"Unknown SQL script alias: {script_name}")
