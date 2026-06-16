"""The Bergamot Agent"""
# ── CYTHON CDEFS ─────────────────────────────────────────────────────────── #
cdef str BERGAMOT_VERSION
cdef str TARGET_HOST
cdef int TARGET_PORT
cdef int EVENT_HZ
cdef int PROC_HZ
cdef int PERF_HZ
cdef int BATCH_MAX_BYTES
cdef int EVENT_QUEUE_MAX_BYTES
cdef int PROC_QUEUE_MAX_BYTES
cdef int PERF_QUEUE_MAX_BYTES
cdef int MAX_FRAME_BYTES
cdef int RECONNECT_MAX_SECONDS
cdef int SOCKET_TIMEOUT_SECONDS
cdef str PROC_PATH
cdef bool HAVE_LOADED_ENGINE_LOCALLY
# ── END CYTHON CDEFS ─────────────────────────────────────────────────────── #

BERGAMOT_VERSION = "1.0"

import contextlib
from dataclasses import dataclass
import os
import queue
import subprocess
import sys
import threading
import time

from interface import l, parse_interface_args
from net import Sender
from procurement import *
import protocol
import workers

# ── SWITCHES ─────────────────────────────────────────────────────────────── #
_cmdline = parse_interface_args()
TARGET_HOST = _cmdline.host
TARGET_PORT = _cmdline.port
EVENT_HZ    = _cmdline.event_hz
PROC_HZ     = _cmdline.proc_hz
PERF_HZ     = _cmdline.perf_hz

BATCH_MAX_BYTES       = _cmdline.batch_max       * 1024 * 1024
EVENT_QUEUE_MAX_BYTES = _cmdline.event_queue_max * 1024 * 1024
PROC_QUEUE_MAX_BYTES  = _cmdline.proc_queue_max  * 1024 * 1024
PERF_QUEUE_MAX_BYTES  = _cmdline.perf_queue_max  * 1024 * 1024

MAX_FRAME_BYTES        = 1024 * 1024
RECONNECT_MAX_SECONDS  = _cmdline.reconnect_timeout
SOCKET_TIMEOUT_SECONDS = 5

# ── GLOBALS ──────────────────────────────────────────────────────────────── #

# In the event the Agent tries to load the Engine, this marks whether it has
# tried previously. It will not allow itself to try more than once, because it
# loads based on the assumption the module file is installed in the kernel,
# which is not always true.
PROC_PATH = "/proc/bergamot-pipe"

# minimum values to prevent breakage
if EVENT_HZ <= 0:
    EVENT_HZ = 1
if PROC_HZ <= 0:
    PROC_HZ = 1
if PERF_HZ <= 0:
    PERF_HZ = 1
if MAX_FRAME_BYTES < 256:
    MAX_FRAME_BYTES = 256


@dataclass
class _QueueBytesState:
    max_bytes: int
    used_bytes: int = 0
    dropped_items: int = 0
    lock: object = None


def _queue_put_drop_oldest(q: object, state: _QueueBytesState, item: object, item_bytes: int):
    if item_bytes <= 0:
        return

    if item_bytes > state.max_bytes:
        l.warning(f"dropping item larger than queue byte limit ({item_bytes} > {state.max_bytes})", flush=True)
        return

    with state.lock:
        while state.used_bytes + item_bytes > state.max_bytes:
            try:
                dropped_item, dropped_bytes = q.get_nowait()
                state.used_bytes = max(0, state.used_bytes - int(dropped_bytes))
                state.dropped_items += 1
            except queue.Empty:
                break

        q.put_nowait((item, item_bytes))
        state.used_bytes += item_bytes


def collect_all_snapshots() -> list:
    """Return both rich_proc_snapshot and system_perf as a list for the snapshot worker."""
    return [collect_process_snapshot(), collect_system_perf()]


# ── Main poll loop ────────────────────────────────────────────────────────────

def main():
    cdef object sender
    cdef double poll_interval
    cdef double snapshot_interval
    cdef object event_queue
    cdef object snapshot_queue
    cdef object stop_event
    cdef object event_thread
    cdef object snapshot_thread

    # Check for sudo/root privileges
    if os.geteuid() != 0:
        l.critical("try it with sudo", flush=True, exitcode=1)

    stop_event = threading.Event()
    sender = None
    event_thread = None
    snapshot_thread = None

    try:
        sender = Sender(
            TARGET_HOST, TARGET_PORT, RECONNECT_MAX_SECONDS, MAX_FRAME_BYTES,
            SOCKET_TIMEOUT_SECONDS
        )
        if not sender.connect():
            return

        poll_interval = 1 / EVENT_HZ
        snapshot_interval = 1 / PROC_HZ


        l.info(f"polling the Engine feed at {PROC_PATH} @ {EVENT_HZ:.2f}hz")
        l.info(f"process snapshots @ {PROC_HZ:.2f}hz")
        l.info(f"perf snapshots @ {PERF_HZ:.2f}Hz (emitted alongside proc snapshots)")
        l.debug(f"wire protocol version: {protocol.WIRE_VERSION_STR}", flush=True)



        event_queue = queue.Queue()
        snapshot_queue = queue.Queue()
        event_queue_state = _QueueBytesState(
            max_bytes=EVENT_QUEUE_MAX_BYTES,
            lock=threading.Lock(),
        )
        snapshot_queue_state = _QueueBytesState(
            max_bytes=max(PROC_QUEUE_MAX_BYTES, PERF_QUEUE_MAX_BYTES),
            lock=threading.Lock(),
        )
        def _event_queue_put_cb(q_obj, item_obj, item_bytes):
            _queue_put_drop_oldest(q_obj, event_queue_state, item_obj, item_bytes)

        def _snapshot_queue_put_cb(q_obj, item_obj, item_bytes):
            _queue_put_drop_oldest(q_obj, snapshot_queue_state, item_obj, item_bytes)

        event_thread = threading.Thread(
            target=workers.event_reader_run,
            args=(
                event_queue,
                stop_event,
                poll_interval,
                PROC_PATH,
                BATCH_MAX_BYTES,
                protocol.event_frame_size_bytes,
                parse_line,
                _event_queue_put_cb,
                _reload_engine_module,
            ),
            daemon=True,
            name="bergamot-agent-event-reader",
        )
        snapshot_thread = threading.Thread(
           target=workers.snapshot_worker_run,
            args=(
               snapshot_queue,
                stop_event,
                snapshot_interval,
                collect_all_snapshots,
                protocol.object_frame_size_bytes,
               _snapshot_queue_put_cb,
            ),
            daemon=True,
            name="bergamot-agent-snapshot-worker",
        )

        event_thread.start()
        snapshot_thread.start()

        try:
            workers.sender_run(sender, event_queue, snapshot_queue,
                                         stop_event)
        finally:
            stop_event.set()
            sender.close()
            if event_thread is not None:
                event_thread.join(timeout=1.0)
            if snapshot_thread is not None:
                snapshot_thread.join(timeout=1.0)
    except KeyboardInterrupt:
        l.critical("CTRL-C", flush=True)
        stop_event.set()
        if sender is not None:
            with contextlib.suppress(Exception):
                sender.close()
        sys.exit(2)

if __name__ == "__main__":
    main()

# OTRA VEZ

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

from interface import l, parse_interface_args
from net import Sender
from procurement import *
import protocol
# ── END IMPORTS ────────────────────────────────────────────────── #


# ── ARGS ─────────────────────────────────────────────────────────────────── #
ARGS = parse_interface_args()

# Megabytes to Bytes
ARGS.batch_max       *= 1024 * 1024
ARGS.event_queue_max *= 1024 * 1024
ARGS.proc_queue_max  *= 1024 * 1024
ARGS.perf_queue_max  *= 1024 * 1024
ARGS.send_queue_max  *= 1024 * 1024

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
PACKET_QUEUE  = deque(maxlen=ARGS.send_queue_max)


# ── END QUEUES ───────────────────────────────────────────────────────────── #


# ── FREQUENCY OVERRIDES ──────────────────────────────────────────────────── #
# ── END FREQUENCY OVERRIDES ──────────────────────────────────────────────── #

