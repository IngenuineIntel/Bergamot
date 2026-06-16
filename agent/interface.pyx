# interface.pyx
"""
I have written similar code to this like a dozen times,
so I decided to put it in a gist in order to save my
future self time.
"""
from datetime import datetime
import os
import sys
from typing import NamedTuple

cdef class Logger:

    """
    Universal logging

    [21:01:01:355314][INTERNAL]: This is an extremely verbose log, like a thread sleeping
    [21:01:01][DEBUG]    : This is a simple debug, like the most likely reason for a problem
    [21:01:01][INFO]     : Something happened successfully
    [21:01:01][WARNING]  : Minor mishap, non-fatal
    [21:01:01][CRITICAL] : Major mishap, likely fatal
    [21:01:01][ERROR]    : The error that indicates the mishap

    out_stream: the stream to print to, defaults to stdout (if not stdout, all colors are omitted)
    """

    cdef object stream

    cdef str _blue
    cdef str _cyan
    cdef str _green
    cdef str _red
    cdef str _yellow
    cdef str _reset

    cdef int __verbosity_lvl

    def __init__(self, out_stream=sys.stdout):

        self.stream = out_stream

        # colors!
        if out_stream is sys.stdout:
            self._blue   = "\033[34m"
            self._cyan   = "\033[36m"
            self._green  = "\033[32m"
            self._red    = "\033[31m"
            self._yellow = "\033[33m"
            self._reset  = "\033[39m"

        # pre-configured verbosity level (max verbosity) before it's configured
        # via `<Logger>.verbosity()`
        self.__verbosity_lvl = 2

    def __get_time(self) -> str:
        now = datetime.now()
        return now.strftime("%H:%M:%S")

    def __get_time_field(self) -> str:
        return "[%s%s%s]" % (self._blue, self.__get_time(), self._reset)

    def __get_internal_time(self) -> str:
        now = datetime.now()
        return now.strftime("%H:%M:%S:%f")

    def verbosity(self, level):
        """
        level=0 - minimum verbosity (no DEBUGs or INTERNALs)
        level=1 - medium verbosity (no INTERNALs)
        level=2 - maximum verbosity (DEBUGs and INTERNALs)
        """
        self.__verbosity_lvl = level

    def internal(self, msg):
        """
        [21:01:01:355314][INTERNAL]: `msg`
        """
        if self.__verbosity_lvl >= 2:
            print("%s[%s][INTERNAL]: %s%s" % (
                self._green, self.__get_internal_time(), msg, self._reset
            ), file=self.stream)

    def debug(self, msg, flush=False):
        """
        [21:01:01][DEBUG]    : `msg`

        flush=True - flushes buffer
        """
        if self.__verbosity_lvl >= 1:
            print("%s[%sDEBUG%s]    : %s" % (
                self.__get_time_field(), self._cyan, self._reset, msg
            ), file=self.stream, flush=flush)

    def info(self, msg, flush=False):
        """
        [21:01:01][INFO]     : `msg`

        flush=True - flushes buffer
        """
        print("%s[%sINFO%s]     : %s" % (
            self.__get_time_field(), self._green, self._reset, msg
        ), file=self.stream, flush=flush)

    def warning(self, msg, flush=False):
        """
        [21:01:01][WARNING]  : `msg`

        flush=True - flushes buffer
        """
        print("%s[%sWARNING%s]  : %s" % (
            self.__get_time_field(), self._yellow, self._reset, msg
        ), file=self.stream, flush=flush)
    
    def critical(self, msg, flush=False, *, exitcode=None):
        """
        [21:01:01][CRITICAL] : `msg`

        flush=<bool> - True flushes buffer, default is False
        exitcode=<int>|<None> - exits with value if not None, default is None
        """
        print("%s[%sCRITICAL%s] : %s" % (
            self.__get_time_field(), self._red, self._reset, msg
        ), file=self.stream, flush=flush)
        if exitcode != None:
            sys.exit(exitcode)

    def error(self, msg, flush=False):
        """
        [21:01:01][ERROR]    : `msg`

        flush=True - flushes buffer
        """
        print("%s[%sERROR%s]    : %s" % (
            self.__get_time_field(), self._red, self._reset, msg
        ), file=self.stream, flush=flush)

l = Logger()


class InterfaceArgs:
    """
    Convenient way to transport arguments
    """

    def __init__(self, **kwargs):
        self.__args = kwargs
    
    def __getattr__(self, attr):
        return self.__args[attr]


class ArgSpec(NamedTuple):
    flag: str
    field: str
    env_var: str
    default: object
    value_type: type
    description: str


class InterfaceArgTable:
    HELP_FLAG = "-h"

    HOST = ArgSpec(
        flag="-c",
        field="host",
        env_var="BERGAMOT_HOST",
        default="localhost",
        value_type=str,
        description="Host to connect to",
    )
    PORT = ArgSpec(
        flag="-p",
        field="port",
        env_var="BERGAMOT_WIRE_PORT",
        default=12046,
        value_type=int,
        description="Port to connect on",
    )
    EVENT_HZ = ArgSpec(
        flag="-fe",
        field="event_hz",
        env_var="BERGAMOT_EVENT_HZ",
        default=4,
        value_type=int,
        description="Frequency of event packets",
    )
    SNAPSHOT_HZ = ArgSpec(
        flag="-fs",
        field="proc_hz",
        env_var="BERGAMOT_PROC_HZ",
        default=1,
        value_type=int,
        description="Frequency of process snapshot packets",
    )
    PERF_HZ = ArgSpec(
        flag="-fp",
        field="perf_hz",
        env_var="BERGAMOT_PERF_HZ",
        default=2,
        value_type=int,
        description="Frequency of performance snapshot packets",
    )
    RECONNECT_TIMEOUT = ArgSpec(
        flag="-t",
        field="reconnect_timeout",
        env_var="BERGAMOT_REC_MAX",
        default=30,
        value_type=int,
        description="Timeout before connection is tried again",
    )

    VERBOSE_LOGS = ArgSpec(
        flag="-v",
        field="verbose_logs",
        env_var="BERGAMOT_INTERNAL_ARGS",
        default=2,
        value_type=int,
        description="Verbose output (0 is no verbose output, max is 2)"
    )

    # TODO -vf options to put internal logs in file

    ## Below additions don't have cmdline flags ##
    # Note: the MBs are converted to bytes in `agent.pyx`
    
    PACKET_MAX_MB = ArgSpec(
        flag=None,
        field="packet_max",
        env_var="BERGAMOT_PACKET_MAX",
        default=12,
        value_type=int,
        description="Maximum size of outgoing packets"
    )

    # TODO make this mean something
    BATCH_MAX_MB = ArgSpec(
        flag=None,
        field="batch_max",
        env_var="BERGAMOT_BATCH_MAX",
        default=2,
        value_type=int,
        description="Maximum size of read batch from the Engine",
    )
    EVENT_PACKET_MAX = ArgSpec(
        flag=None,
        field="event_queue_max",
        env_var="BERGAMOT_EVENT_QUEUE_MAX",
        default=64,
        value_type=int,
        description="Maximum index size of event capture packets",
    )
    PROC_PACKET_MAX = ArgSpec(
        flag=None,
        field="proc_queue_max",
        env_var="BERGAMOT_SNAPSHOT_QUEUE_MAX",
        default=8,
        value_type=int,
        description="Maximum index size of process snapshot packets",
    )
    PERF_PACKET_MAX = ArgSpec(
        flag=None,
        field="perf_queue_max",
        env_var="BERGAMOT_PERF_QUEUE_MAX",
        default=6,
        value_type=int,
        description="Maximum index size of performance monitor packets",
    )

    ALL_OPTIONS = (
        HOST,
        PORT,
        EVENT_HZ,
        SNAPSHOT_HZ,
        PERF_HZ,
        RECONNECT_TIMEOUT,
        VERBOSE_LOGS,
        PACKET_MAX_MB,
        BATCH_MAX_MB,
        EVENT_PACKET_MAX,
        PROC_PACKET_MAX,
        PERF_PACKET_MAX,
    )

    OPTIONS = tuple(spec for spec in ALL_OPTIONS if bool(spec.flag or spec.env_var))

    BY_FLAG = {spec.flag: spec for spec in OPTIONS}

def _getenv_safe(var: str, cast: type, default):
    assert isinstance(default, cast)
    ret = os.getenv(var)
    if not ret:
        return default
    try:
        return cast(ret)
    except (TypeError, ValueError) as e:
        l.warning("Failed to retrieve usable value from %s, defaulting to %s" %
            (var, default)
        )
        l.debug("The error was %s: %s" % (type(e), e))
        return default

def _coerce_value(value, spec, source_name):
    if spec.value_type == int:
        try:
            return int(value)
        except (TypeError, ValueError):
            l.critical("Invalid integer for %s: %r" % (source_name, value), flush=True, exitcode=1)
    elif spec.value_type == str:
        return value


def _load_defaults_from_env():
    values = {}
    for spec in InterfaceArgTable.ALL_OPTIONS:
        raw = _getenv_safe(spec.env_var, spec.value_type, spec.default)
        if raw is None or raw == "":
            values[spec.field] = spec.default
            continue
        values[spec.field] = _coerce_value(raw, spec, spec.env_var)
    return values


def parse_interface_args(args=None):
    if args is None:
        args = sys.argv[1:]

    values = _load_defaults_from_env()

    i = 0
    while i < len(args):
        flag = args[i]

        if flag == InterfaceArgTable.HELP_FLAG:
            print(help_msg)
            sys.exit(0)

        spec = InterfaceArgTable.BY_FLAG.get(flag)
        if spec is None:
            print(help_msg)
            l.critical("Unknown flag: %s" % flag, flush=True, exitcode=1)

        if i + 1 >= len(args):
            print(help_msg)
            l.critical("Missing value for flag: %s" % flag, flush=True, exitcode=1)

        val = args[i + 1]
        values[spec.field] = _coerce_value(val, spec, flag)

        i += 2

    return InterfaceArgs(**values)


def _build_help_msg(program_name):
    lines = [
        "USAGE: %s [FLAGS/VALS]" % program_name,
        "",
        " Flag         Environment Variable        Default Value        Description",
    ]

    for spec in InterfaceArgTable.OPTIONS:
        flag = "%s <VAL>" % spec.flag if spec.flag != None else ""
        envv = "%s" % spec.env_var if spec.env_var != None else ""
        dflt = "%s" % spec.default
        dscr = "%s" % spec.description
        lines.append(
            " %s%s%s%s" % (
                flag.ljust(13, " "),
                envv.ljust(28, " "),
                dflt.ljust(21, " "),
                dscr
            )
        )

    lines.append(" -h".ljust(63) + "Prints this message")
    return "\n".join(lines)



help_msg = _build_help_msg(sys.argv[0])

__all__ = ["parse_interface_args", "l"]

if __name__ == "__main__":
    l.critical("Sir...")
    l.error("Just import the code")