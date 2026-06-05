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
    cdef readonly object stream
    cdef readonly str blue
    cdef readonly str cyan
    cdef readonly str green
    cdef readonly str red
    cdef readonly str yellow
    cdef readonly str reset

    def __init__(self, out_stream=sys.stdout):
        self.stream = out_stream

        self.blue   = "\033[34m"
        self.cyan   = "\033[36m"
        self.green  = "\033[32m"
        self.red    = "\033[31m"
        self.yellow = "\033[33m"
        self.reset  = "\033[39m"

    def __get_time(self) -> str:
        now = datetime.now()
        return now.strftime("%H:%M:%S")

    def __get_time_field(self) -> str:
        return "[%s%s%s]" % (self.blue, self.__get_time(), self.reset)

    def debug(self, msg, flush=False):
        print("%s[%sDEBUG%s]    : %s" % (
            self.__get_time_field(), self.cyan, self.reset, msg
        ), file=self.stream, flush=flush)

    def info(self, msg, flush=False):
        print("%s[%sINFO%s]     : %s" % (
            self.__get_time_field(), self.green, self.reset, msg
        ), file=self.stream, flush=flush)

    def warning(self, msg, flush=False):
        print("%s[%sWARNING%s]  : %s" % (
            self.__get_time_field(), self.yellow, self.reset, msg
        ), file=self.stream, flush=flush)
    
    def critical(self, msg, flush=False, *, exitcode=None):
        print("%s[%sCRITICAL%s] : %s" % (
            self.__get_time_field(), self.red, self.reset, msg
        ), file=self.stream, flush=flush)
        if exitcode != None:
            sys.exit(exitcode)

    def error(self, msg, flush=False):
        print("%s[%sERROR%s]    : %s" % (
            self.__get_time_field(), self.red, self.reset, msg
        ), file=self.stream, flush=flush)

l = Logger()


class InterfaceArgs(NamedTuple):
    host: str
    port: int
    event_hz: int
    proc_hz: int
    perf_hz: int
    reconnect_timeout: int
    batch_max: int
    event_queue_max: int
    proc_queue_max: int
    perf_queue_max: int


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
    
    ## Below additions don't have cmdline flags ##
    
    BATCH_MAX_MB = ArgSpec(
        flag=None,
        field="batch_max",
        env_var="BERGAMOT_BATCH_MAX",
        default=2,
        value_type=int,
        description="Maximum size of read batch from the Engine",
    )
    EVENT_QUEUE_MAX_MB = ArgSpec(
        flag=None,
        field="event_queue_max",
        env_var="BERGAMOT_EVENT_QUEUE_MAX",
        default=64,
        value_type=int,
        description="Maximum size of event capture packets",
    )
    PROC_QUEUE_MAX_MB = ArgSpec(
        flag=None,
        field="proc_queue_max",
        env_var="BERGAMOT_SNAPSHOT_QUEUE_MAX",
        default=8,
        value_type=int,
        description="Maximum size of process snapshot packets",
    )
    PERF_QUEUE_MAX_MB = ArgSpec(
        flag=None,
        field="perf_queue_max",
        env_var="BERGAMOT_PERF_QUEUE_MAX",
        default=6,
        value_type=int,
        description="Maximum size of performance monitor packets",
    )

    ALL_OPTIONS = (
        HOST,
        PORT,
        EVENT_HZ,
        SNAPSHOT_HZ,
        PERF_HZ,
        RECONNECT_TIMEOUT,
        BATCH_MAX_MB,
        EVENT_QUEUE_MAX_MB,
        PROC_QUEUE_MAX_MB,
        PERF_QUEUE_MAX_MB,
    )

    OPTIONS = tuple(spec for spec in ALL_OPTIONS if spec.flag)

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
        "Flags:",
    ]

    for spec in InterfaceArgTable.OPTIONS:
        lines.append(
            "    %-12s %s (default %s or %s)" % (
                "%s <VAL>" % spec.flag,
                spec.description,
                spec.env_var,
                spec.default,
            )
        )

    lines.append("    -h             Prints this message")
    return "\n".join(lines)



help_msg = _build_help_msg(sys.argv[0])

if __name__ == "__main__":
    l.critical("Sir...")
    l.error("Just import the code")