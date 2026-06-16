"""
Bergamot
Agent

(c) 2026
Ingenuineintel
(Roan Rothrock)
<roan.rothrock@proton.me>
"""

# ── CYTHON CDEFS ─────────────────────────────────────────────────────────── #
cdef str BERGAMOT_VER
cdef object ARGS
cdef str PROC_PATH
cdef object EVENT_QUEUE
cdef object PROC_QUEUE
cdef object PERF_QUEUE
cdef object SEND_QUEUE
cdef int THREAD1_HZ
cdef int THREAD2_HZ
cdef int THREAD3_HZ
cdef int THREAD4_HZ
cdef int THREAD5_HZ
cdef int THREAD6_HZ
cdef object KILL_SWITCH
# ── END CYTHON CDEFS ───────────────────────────────────────────── #


BERGAMOT_VER = "1.0"

PROC_PATH = "/proc/bergamot-pipe" # Engine pipe entry

# ── IMPORTS ──────────────────────────────────────────────────────────────── #
from collections import deque
import contextlib
from dataclasses import dataclass
import os
import subprocess
import sys
import threading
import time

from interface import *
from net import Sender
from procurement import collect_system_info
import protocol
from workers import (
    thread_1, thread_2, thread_3,
    thread_4, thread_5, thread_6
)
# ── END IMPORTS ────────────────────────────────────────────────── #


# ── ARGS ─────────────────────────────────────────────────────────────────── #
ARGS = parse_interface_args()

# Megabytes to Bytes
ARGS.batch_max       *= 1024 * 1024
ARGS.packet_max      *= 1024 * 1024

# boundaries
if ARGS.event_hz <= 0:
    l.warning(f"Event frequency being raised to 1 from {ARGS.event_hz} to prevent breakage.")
    ARGS.event_hz = 1
if ARGS.proc_hz <= 0:
    l.warning(f"Proc frequnecy being raised to 1 from {ARGS.proc_hz} to prevent breakage.")
    ARGS.proc_hz = 1
if ARGS.perf_hz <= 0:
    l.warning(f"Perf frequency being raised to 1 from {ARGS.perf_hz} to prevent breakage.")
    ARGS.perf_hz = 1

# TODO queue size boundaries

# logging verbosity
l.verbosity(ARGS.verbose_logs)

# ── END ARGS ───────────────────────────────────────────────────── #


# ── QUEUES ───────────────────────────────────────────────────────────────── #
EVENT_QUEUE   = deque(maxlen=ARGS.event_queue_max)
PROC_QUEUE    = deque(maxlen=ARGS.proc_queue_max)
PERF_QUEUE    = deque(maxlen=ARGS.perf_queue_max)
PACKET_QUEUE  = deque(maxlen=ARGS.packet_max)


# ── END QUEUES ─────────────────────────────────────────────────── #


# ── FREQUENCY OVERRIDES ──────────────────────────────────────────────────── #
# these will have to be tuned to prevent certain threads falling behind, and
# I'm not enough of an expert to know if these will have to be tuned depending
# on the machine's CPU. Ideally, threads 2 and 3 can be as high as 5hz, and
# thread 1 can be as high as 10hz, but I don't know what threads 4, 5, & 6 can
# process, and whether or not its dependent on CPU capacity

THREAD1_HZ = 4
#THREAD1_HZ = ARGS.event_hz
THREAD2_HZ = 2
#THREAD2_HZ = ARGS.proc_hz
THREAD3_HZ = 2
#THREAD3_HZ = ARGS.perf_hz
THREAD4_HZ = 4
#THREAD4_HZ = ARGS.event_packet_hz # doesn't exist
THREAD5_HZ = 4
#THREAD5_HZ = ARGS.proc_perf_packet_hz # doesn't exist
THREAD6_HZ = 2
#THREAD6_HZ = ARGS.sender_hz # doesn't exist
# ── END FREQUENCY OVERRIDES ────────────────────────────────────── #



# ── STOP ─────────────────────────────────────────────────────────────────── #
KILL_SWITCH = threading.Event()

# ── END STOP ───────────────────────────────────────────────────── #


# ── MAIN ─────────────────────────────────────────────────────────────────── #

def _main():
    cdef object sender
    cdef object t1
    cdef object t2
    cdef object t3
    cdef object t4
    cdef object t5

    # must be run as sudo
    if os.geteuid() != 0:
        l.critical("try it with sudo", exitcode=1)

    sender = Sender(
        ARGS.host, ARGS.port,
        reconnect_max=ARGS.reconnect_timeout,
        max_frame_sz=ARGS.packet_max
    )

    # await connection
    sender.connect()

    l.internal(f"thread 1 frequency: {THREAD1_HZ} ({1/THREAD1_HZ}s)")
    l.internal(f"thread 2 frequency: {THREAD2_HZ} ({1/THREAD2_HZ}s)")
    l.internal(f"thread 3 frequency: {THREAD3_HZ} ({1/THREAD3_HZ}s)")
    l.internal(f"thread 4 frequency: {THREAD4_HZ} ({1/THREAD4_HZ}s)")
    l.internal(f"thread 5 frequency: {THREAD5_HZ} ({1/THREAD5_HZ}s)")
    l.internal(f"thread 6 frequency: {THREAD6_HZ} ({1/THREAD6_HZ}s)")

    l.debug(f"Wire protocol version: {protocol.WIRE_VERSION_STR}")

    t1 = threading.Thread(
        target=thread_1,
        args=(
            EVENT_QUEUE,
            KILL_SWITCH,
            THREAD1_HZ,
            collect_system_info,
            PROC_PATH
        ),
        daemon=True,
        name="bergamot-event-thread"
    )

    t2 = threading.Thread(
        target=thread_2,
        args=(
            PROC_QUEUE,
            KILL_SWITCH,
            THREAD2_HZ
        ),
        daemon=True,
        name="bergamot-proc-thread"
    )

    t3 = threading.Thread(
        target=thread_3,
        args=(
            PERF_QUEUE,
            KILL_SWITCH,
            THREAD3_HZ
        ),
        daemon=True,
        name="bergamot-perf-thread"
    )

    t4 = threading.Thread(
        target=thread_4,
        args=(
            EVENT_QUEUE,
            PACKET_QUEUE,
            KILL_SWITCH,
            THREAD4_HZ
        ),
        daemon=True,
        name="bergamot-event-loading-thread"
    )

    t5 = threading.Thread(
        target=thread_5,
        args=(
            PROC_QUEUE,
            PERF_QUEUE,
            PACKET_QUEUE,
            KILL_SWITCH,
            THREAD5_HZ
        )
    )

    l.debug("starting threads")
    t1.start()
    t2.start()
    t3.start()
    t4.start()
    t5.start()
    
    l.internal("Adam thread becoming thread 6")
    t6(
        PACKET_QUEUE,
        KILL_SWITCH,
        sender,
        THREAD6_HZ
    )


def main():
    try:
        _main()
    except KeyboardInterrupt:
        l.error("CTRL-C")
        KILL_SWITCH.set()
        sys.exit(1)

# ── END MAIN ───────────────────────────────────────────────────── #

if __name__ == "__main__":
    main()