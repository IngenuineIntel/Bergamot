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
HAVE_LOADED_ENGINE_LOCALLY = False
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

cdef object parse_line(str line):
    """
        Parse one procfs event line.

        Preferred format (tab-separated):
            <ts_ns>\t<pid>\t<ppid>\t<uid>\t<type>\t<subtype>\t<comm>\t<arg1>\t<arg2>\t<retval>

        Legacy format (space-separated):
            <ts_ns> <pid> <ppid> <uid> <type> <subtype> <comm> <arg>

        Legacy parsing keeps backward compatibility for old module builds.
    """

    cdef list parts
    cdef str ts_raw
    cdef str pid_raw
    cdef str ppid_raw
    cdef str uid_raw
    cdef str type_raw
    cdef str subtype_raw
    cdef str comm
    cdef str arg1
    cdef str arg2
    cdef str retval_raw
    cdef object arg2_value
    cdef object retval_value
    cdef str arg_legacy
    cdef long long ts_ns
    cdef long long ts_s
    cdef long long rem_ns
    cdef int arg2_pos

    line = line.strip()
    if not line:
        return None

    if "\t" in line:
        parts = line.split("\t", 9)
        if len(parts) < 9:
            return None

        ts_raw = parts[0]
        pid_raw = parts[1]
        ppid_raw = parts[2]
        uid_raw = parts[3]
        type_raw = parts[4]
        subtype_raw = parts[5]
        if subtype_raw == "none":
            subtype_raw = ""
        comm = parts[6]
        arg1 = parts[7]
        arg2 = parts[8]
        retval_raw = parts[9] if len(parts) > 9 else "0"
    else:
        parts = line.split(None, 7)
        if len(parts) < 8:
            return None

        ts_raw = parts[0]
        pid_raw = parts[1]
        ppid_raw = parts[2]
        uid_raw = parts[3]
        type_raw = parts[4]
        subtype_raw = parts[5]
        if subtype_raw == "none":
            subtype_raw = ""
        comm = parts[6]

        arg_legacy = parts[7]
        arg1 = arg_legacy
        arg2 = ""
        retval_raw = "0"

        # Transitional parsing: if arg was encoded as "arg1=<x> arg2=<y>", split it.
        if arg_legacy.startswith("arg1="):
            arg2_pos = arg_legacy.find(" arg2=")
            if arg2_pos != -1:
                arg1 = arg_legacy[5:arg2_pos].strip()
                arg2 = arg_legacy[arg2_pos + 6:].strip()

    try:
        ts_ns = int(ts_raw)
        ts_s = ts_ns // 1_000_000_000
        rem_ns = ts_ns % 1_000_000_000

        arg2_value = arg2
        if type_raw == "ptrace" and arg2:
            try:
                arg2_value = int(arg2)
            except ValueError:
                arg2_value = arg2

        retval_value = int(retval_raw)

        return protocol.Event(
            int(ts_s),
            int(rem_ns // 1_000_000),
            int(pid_raw),
            type_raw,
            subtype_raw,
            arg1,
            str(arg2_value),
            retval_value,
        )
    except ValueError:
        return None

cdef object collect_process_snapshot():
    now = time.time()
    ts_s = int(now)
    ts_ms = int((now - ts_s) * 1000)
    processes = []
    cdef int found
    cdef bint got_name
    cdef bint got_ppid
    cdef bint got_uid
    cdef bint got_threads
    cdef bint got_vmrss

    for entry in os.scandir("/proc"):
        if not entry.name.isdigit() or not entry.is_dir(follow_symlinks=False):
            continue

        pid = int(entry.name)
        status_path = f"/proc/{entry.name}/status"
        stat_path = f"/proc/{entry.name}/stat"
        try:
            ppid = 0
            uid = 0
            comm = ""
            threads = 0
            vm_rss_kb = 0
            cpu_ticks = 0
            found = 0
            got_name = False
            got_ppid = False
            got_uid = False
            got_threads = False
            got_vmrss = False
            with open(status_path, "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    if (not got_name) and line.startswith("Name:\t"):
                        comm = line.split("\t", 1)[1].strip()
                        got_name = True
                        found += 1
                    elif (not got_ppid) and line.startswith("PPid:\t"):
                        ppid = int(line.split("\t", 1)[1].strip() or 0)
                        got_ppid = True
                        found += 1
                    elif (not got_uid) and line.startswith("Uid:\t"):
                        uid = int(line.split("\t", 1)[1].split()[0])
                        got_uid = True
                        found += 1
                    elif (not got_threads) and line.startswith("Threads:\t"):
                        threads = int(line.split("\t", 1)[1].strip() or 0)
                        got_threads = True
                        found += 1
                    elif (not got_vmrss) and line.startswith("VmRSS:\t"):
                        vm_rss_kb = int(line.split("\t", 1)[1].split()[0])
                        got_vmrss = True
                        found += 1

                    if found >= 5:
                        break

            # /proc/<pid>/stat: field 14 = utime, field 15 = stime (1-indexed)
            try:
                with open(stat_path, "r", encoding="utf-8", errors="replace") as sf:
                    stat_line = sf.readline()
                # find the closing ')' of the comm field, then split the rest
                rp = stat_line.rfind(")")
                if rp != -1:
                    stat_fields = stat_line[rp + 2:].split()
                    # fields after ')' are 0-indexed; utime=11, stime=12 in that slice
                    if len(stat_fields) > 12:
                        cpu_ticks = int(stat_fields[11]) + int(stat_fields[12])
            except (FileNotFoundError, ProcessLookupError, PermissionError,
                    OSError, ValueError, IndexError):
                cpu_ticks = 0

            processes.append(
                protocol.Proc(
                    pid,
                    ppid,
                    uid,
                    threads,
                    cpu_ticks,
                    vm_rss_kb,
                    comm,
                )
            )
        except (FileNotFoundError, ProcessLookupError, PermissionError, OSError, ValueError):
            # Process exited (or became unreadable) while being sampled.
            continue

    return protocol.ProcSnapshot(ts_s, ts_ms, processes)


def collect_system_perf() -> object:
    """Collect system-wide CPU, RAM, and load-average data from /proc."""
    now = time.time()
    ts_s = int(now)
    ts_ms = int((now - ts_s) * 1000)

    # Per-core CPU ticks from /proc/stat
    cores = []
    try:
        with open("/proc/stat", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line.startswith("cpu"):
                    continue
                # skip the aggregate "cpu " line (no digit after "cpu")
                parts = line.split()
                if len(parts) < 8 or not parts[0][3:].isdigit():
                    continue
                # user, nice, system, idle, iowait, irq, softirq
                cores.append([int(parts[i]) for i in range(1, 8)])
    except OSError:
        pass

    # RAM from /proc/meminfo
    mem_fields = {"MemTotal": 0, "MemFree": 0, "MemAvailable": 0, "Cached": 0}
    found_mem = 0
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                key = line.split(":")[0]
                if key in mem_fields:
                    mem_fields[key] = int(line.split()[1])
                    found_mem += 1
                    if found_mem >= 4:
                        break
    except OSError:
        pass
    mem = [
        mem_fields["MemTotal"],
        mem_fields["MemFree"],
        mem_fields["MemAvailable"],
        mem_fields["Cached"],
    ]

    # Load average from /proc/loadavg
    load = [0.0, 0.0, 0.0]
    try:
        with open("/proc/loadavg", "r", encoding="utf-8") as fh:
            parts = fh.read().split()
            if len(parts) >= 3:
                load = [float(parts[0]), float(parts[1]), float(parts[2])]
    except OSError:
        pass

    return protocol.Perf(
        ts_s,
        ts_ms,
        len(cores),
        0.0,
        mem[0],
        mem[1],
        mem[2],
        mem[3],
        load[0],
        load[1],
        load[2],
        str(cores),
    )


def collect_all_snapshots() -> list:
    """Return both rich_proc_snapshot and system_perf as a list for the snapshot worker."""
    return [collect_process_snapshot(), collect_system_perf()]


def _reload_engine_module():

    if HAVE_LOADED_ENGINE_LOCALLY:
        l.critical("reload has already been attempted, calling it quits", flush=True, exitcode=1)

    l.warning("reloading bergamot_engine module in an attempt to access it...", flush=True)

    rm = subprocess.run(
        ["rmmod", "bergamot_engine"],
        capture_output=True,
        text=True,
        check=False,
    )
    if rm.returncode != 0:
        stderr = (rm.stderr or "").strip()
        # Treat 'not currently loaded' as non-fatal before modprobe.
        if "not currently loaded" not in stderr:
            l.warning(f"rmmod bergamot_engine failed: {stderr or rm.returncode}", flush=True)

    mp = subprocess.run(
        ["modprobe", "bergamot_engine"],
        capture_output=True,
        text=True,
        check=False,
    )
    if mp.returncode != 0:
        l.critical(
            f"modprobe bergamot_engine failed: {(mp.stderr or '').strip() or mp.returncode}",
            flush=True,
        )
        return

    l.info("module reload complete: bergamot_engine", flush=True)

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
