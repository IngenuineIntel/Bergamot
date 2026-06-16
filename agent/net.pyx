# net.pyx

import contextlib
import socket
import time
from threading import RLock

from interface import l
from protocol import (
    SystemInfo, gen_system_info,
    Event, gen_event,
    ProcSnapshot, gen_proc_snapshot,
    Perf, gen_perf
)

# inter-method retval management is done via True/False|0/1
# extra-method retval management is done via arg/None, allowing for code like:

#if obj is sender_object.method(obj):
#   # success
#else:
##not success 

# or, alternatively, when the above is not applicable, True/False, allowing:

#if not sender_object.method(obj):
#   # lack of succes
#else:
#   # lack of lack of success

# because of the lack of explicit communication about functionality that
# occures with this method, logs go directly to stdout via `l`.

cdef class Sender:
    cdef str __host
    cdef int __port
    cdef object __sock
    cdef object __l
    cdef int __reconnect_max_seconds
    cdef int __max_frame_sz
    cdef int __socket_timeout

    """
    Manages all network communication done by this program.
    Thread safe via RLocks.
    """

    def __init__(self, str host, int port, int reconnect_max=30,
                 int max_frame_sz=12, int socket_timeout=5):
        # Quick!
        self.__l = RLock() # the door!

        self.__host = host
        self.__port = port
        
        self.__reconnect_max_seconds = reconnect_max
        self.__max_frame_sz = max_frame_sz * 1024 * 1024 # MB conversion
        self.__socket_timeout = max(1, socket_timeout)

        self.__sock = None

        # how backoffs (the time between retries in the event of a failed connection)
        # are are calculated. It is called iteratively.

    # getters & setters because we can't keep the front door unlocked

    # max_frame_sz
    @property
    def max_frame_sz(self):
        with self.__l:
            return self.__max_frame_sz

    @max_frame_sz.setter
    def max_frame_sz(self, value):
        with self.__l:
            self.__max_frame_sz = value

    # socket_timeout
    @property
    def socket_timeout(self):
        with self.__l:
            return self.__socket_timeout
    
    @socket_timeout.setter
    def socket_timeout(self, value):
        with self.__l:
            self.__socket_timeout = value


    # internal functions for connecting/disconnecting/sending
    cdef bool __connect(self):
        """Attempts connection, True/False on Success/Failure"""
        try:
            self.__sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)

            self.__sock.settimeout(self.__socket_timeout)
            self.__sock.connect((self.__host, self.__port))
            self.__sock.settimeout(None)

        except OSError as e:
            return False
        return True

    def __close(self):
        """Attempts disconnection, can't fail."""
        with contextlib.suppress(OSError):
            self.__sock.close()

    def __send(self, bytes data) -> bool:
        
        if len(data) > self.__max_frame_sz:
            l.warning("packet cannot be sent as it is oversized, skipping")
            l.debug(
                f"max packet size is configured at {self.__max_frame_sz} bytes, but the packet is {len(data)} bytes"
            )
            return False

        try:
            self.__sock.sendall(data)
            return True
        except OSError as e:
            l.error(f"send error: {e}", flush=True)
            return False

    # wrapprs
    def connect(self) -> bool:
        """Attempts connection in saecula saeculorum"""
        cdef int backoff = 1
        cdef int inter_backoff

        backoff_calc = lambda x, y: min(x*2, y) if x < y else y

        with self.__l:
            while True:
                if self.__connect():
                    return True
                l.critical(f"connection failed, retrying in {backoff}s...")
                time.sleep(backoff)
                backoff = backoff_calc(backoff, self.__reconnect_max_seconds)
        l.info("connection successful")

    def close(self) -> None:
        """Attempts disconnection, deletes `self`, can't fail."""
        if self.__sock:
            with self.__l:
                self.__close()
        del self

    def send(self, bytes data) -> bool:
        """Creates frame from `data` and sends it, True/False on success."""
        if not self.__sock:
            return False
        with self.__l:
            return self.__send(data)
