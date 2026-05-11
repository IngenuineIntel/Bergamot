# logging.pyx
"""
I have written similar code to this like a dozen times,
so I decided to put it in a gist in order to save my
future self time.
"""
from datetime import datetime
import sys

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
        print("%s[%sDEBUG%s]: %s" % (
            self.__get_time_field(), self.cyan, self.reset, msg
        ), file=self.stream, flush=flush)

    def info(self, msg, flush=False):
        print("%s[%sINFO%s]: %s" % (
            self.__get_time_field(), self.green, self.reset, msg
        ), file=self.stream, flush=flush)

    def warning(self, msg, flush=False):
        print("%s[%sWARNING%s]: %s" % (
            self.__get_time_field(), self.yellow, self.reset, msg
        ), file=self.stream, flush=flush)
    
    def critical(self, msg, flush=False):
        print("%s[%sCRITICAL%s]: %s" % (
            self.__get_time_field(), self.red, self.reset, msg
        ), file=self.stream, flush=flush)

    def error(self, msg, flush=False):
        print("%s[%sERROR%s]: %s" % (
            self.__get_time_field(), self.red, self.reset, msg
        ), file=self.stream, flush=flush)

l = Logger()

def args_from_argv(argv: list=sys.argv):
    cdef int argc
    cdef list ret
    argc = len(argv)
    ret = [""]
    if "python" in argv[0]:
        ret[0] = argv[0] + argv[1]
    try:
        for i in range(len(argv)):
            if argv[i].startswith("-") and not argv[i+1].startwith("-"):
                ret.append(argv[i] + " " + argv[i+1])
                i += 1
    except IndexError:
        pass
    return ret

argv = args_from_argv(sys.argv)

help_msg = """\
USAGE: %s [FLAGS/VALS]

Flags:
    -h <VAL>       Host to connect to (default BERGAMOT_HOST or localhost)
    -p <VAL>       Port to connect on (default BERGAMOT_WIRE_PORT or 12046)
    -fe <VAL>      Frequency of event packets (default BERGAMOT_WIRE_HZ or 4hz)
    -fs <VAL>      Frequency of process snapshot packets (default BERGAMOT_SNAPSHOT_HZ or 1)
    -fp <VAL>      Frequency of performance snapshot packets (default BERGAMOT_PERF_HZ or 2)
    -b <VAL>       Maximum events in single wire packet in MB (default BERGAMOT_BATCH_MAX or 1MB)
""" % (argv[0])

if __name__ == "__main__":
    l.critical("Sir...")
    l.error("Just import the code")