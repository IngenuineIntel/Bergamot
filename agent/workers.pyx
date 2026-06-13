# workers.pyx
# multithreadees
import queue
import sys
import time

from interface import l
from protocol import SystemInfo, Event, ProcSnapshot, Perf

def event_reader_run(event_queue, stop_event, poll_interval, proc_path,
                     wire_batch_max_bytes, size_bytes_cb, parse_line_cb,
                     queue_put_cb, reload_module_cb=None):
    lease_announced = False
    next_poll_at = time.monotonic()
    error_backoff_seconds = 0.2

    while not stop_event.is_set():
        batch = []
        batch_bytes = 0
        try:
            with open(proc_path, "r") as fh:
                if not lease_announced:
                    l.info(f"{proc_path} access claimed", flush=True)
                    lease_announced = True
                for raw_line in fh:
                    ev = parse_line_cb(raw_line)
                    if ev:
                        ev_size = size_bytes_cb(ev)
                        if ev_size <= 0:
                            continue

                        if ev_size > wire_batch_max_bytes:
                            l.warning(
                                f"dropping event larger than batch limit ({ev_size} > {wire_batch_max_bytes})",
                                flush=True,
                            )
                            continue

                        if batch and (batch_bytes + ev_size) > wire_batch_max_bytes:
                            break

                        batch.append(ev)
                        batch_bytes += ev_size
        except PermissionError:
            l.critical(
                f"permission denied reading {proc_path}; process must be run with sudo",
                flush=True,
                exitcode=1,
            )
        except FileNotFoundError:
            l.critical(f"{proc_path} unavailable")
            l.debug("either another process has already claimed it, or the module's not loaded", flush=True)
            if reload_module_cb is not None:
                try:
                    reload_module_cb()
                except Exception as exc:
                    l.warning(f"module reload attempt failed: {exc}", flush=True)
            time.sleep(5)
            continue
        except OSError as exc:
            l.warning(
                f"read failed ({exc}); backing off for {error_backoff_seconds:.1f}s",
                flush=True,
            )
            stop_event.wait(error_backoff_seconds)
            continue

        if batch:
            queue_put_cb(event_queue, batch, batch_bytes)

        next_poll_at += poll_interval
        now_mono = time.monotonic()
        sleep_for = next_poll_at - now_mono
        if sleep_for > 0:
            stop_event.wait(sleep_for)
        else:
            next_poll_at = now_mono


def snapshot_worker_run(snapshot_queue, stop_event, snapshot_interval,
                        collect_snapshot_cb, size_bytes_cb, queue_put_cb):
    next_snapshot_at = time.monotonic()

    while not stop_event.is_set():
        now_mono = time.monotonic()
        if now_mono >= next_snapshot_at:
            snap = collect_snapshot_cb()
            if isinstance(snap, list):
                for item in snap:
                    item_bytes = size_bytes_cb(item)
                    if item_bytes > 0:
                        queue_put_cb(snapshot_queue, item, item_bytes)
            else:
                item_bytes = size_bytes_cb(snap)
                if item_bytes > 0:
                    queue_put_cb(snapshot_queue, snap, item_bytes)

            while next_snapshot_at <= now_mono:
                next_snapshot_at += snapshot_interval

        sleep_for = next_snapshot_at - time.monotonic()
        if sleep_for > 0:
            stop_event.wait(sleep_for)


def sender_run(sender, event_queue, snapshot_queue, stop_event):
    allowed_types = (SystemInfo, Event, ProcSnapshot, Perf)

    def _sender_send_all(obj, items):
        for item in items:
            if not isinstance(item, allowed_types):
                l.warning(f"dropping outbound item with unsupported type: {type(item).__name__}", flush=True)
                continue
            if not obj.send(item):
                return False
        return True

    while not stop_event.is_set():
        outbound = []

        try:
            batch_item = event_queue.get(timeout=0.25)
            if isinstance(batch_item, tuple) and len(batch_item) == 2:
                batch = batch_item[0]
            else:
                batch = batch_item
            if isinstance(batch, list) and batch:
                outbound.extend(batch)
        except queue.Empty:
            pass

        snapshots = []
        while True:
            try:
                snap_item = snapshot_queue.get_nowait()
                if isinstance(snap_item, tuple) and len(snap_item) == 2:
                    snap = snap_item[0]
                else:
                    snap = snap_item
                snapshots.append(snap)
            except queue.Empty:
                break

        if snapshots:
            outbound.extend(snapshots)

        if outbound:
            if not _sender_send_all(sender, outbound):
                if not sender.connect():
                    continue
                _sender_send_all(sender, outbound)

# NEW

"""
Agent
Thread
Workers

A primer:

0. Main:
Starts threads 1-6 and becomes thread 7

1. Event Thread:
Reads the pipe from the engine and loads a deque with the data at a specified
frequency, and upon initialization loads the deque with system overview data

2. Proc Thread:
Reads the process table from `/proc` and loads a deque with the data at a
specified frequency

3. Perf Thread:
Reads performance information and loads a deque with the data at a specified
frequency

4. Event Loading Thread:
Takes the information from the event deque and creates individual network
packets with the data, and loads a deque for the triage thread at a frequency
of 2hz, accounting for its own execution time when calculating sleep durations

5. Proc & Perf Loading Thread:
Takes the information from the proc and perf deques and creates individual
networks packets with the data, and loads a deque for the triage thread at a
frequency of 4hz, alternating between the two deques

6. Triage Thread:
Combines the event packet deque with the proc and perf packet deque at a
frequency of 2hz

7. Sending Thread:
Sends all packets in triage queue, and when done, pauses for .5s (in theory it
operates at 2hz but I don't know how universal that is)
"""

import sys
import time

from interface import l
from protocol import SystemInfo, Event, ProcSnapshot, Perf

# ── THREAD 1 ─────────────────────────────────────────────────────────────── #

cdef void thread_1(event_queue, kill_switch, freq, overview_fn, proc_path):
    """
    TODO
    """

    cdef int start_ts
    cdef int end_ts

    cdef object event

    cdef int events_per_iter
    cdef int failed_events_per_iter

    cdef bool annouced
    cdef bool tried_engine_load

    cdef int sleep_dur

    announced         = False
    tried_engine_load = False


    cdef object parse_line(str line):
        """
        Parses one procfile line into <Event>, or None if the line was invalid

        Format:
        TODO fix the engine to minimize redundancy
        the engine doesn't actually work like this atm, but I'm working on it

        <ts_s>\t<ts_ms>\t<pid>\t<type>\t<subtype>\t<arg1>\t<arg2>\t<retval>
        """

        cdef object ret
        ret = Event()

        line = line.strip()
        if not line:
            return None

        parts = line.split("\t")
        pass # TODO


    cdef bool reload_engine():
        """
        Reloads engine if need be
        """
        pass # TODO


    l.internal("started thread 1")

    # adding the overview to the queue
    event_queue.append(overview_fn)
    l.internal("thread 1: added overview information to queue")

    while not kill_switch.is_set():

        start_ts = time.monotonic()

        events_per_iter = 0
        failed_events_per_iter = 0

        try:
            with open(proc_path, "r") as fd:
                if not annouced:
                    l.info(f"procfile {proc_path} access claimed")
                    annouced = True
                for ln in fd:
                    event = parse_line(ln)
                    
                    if not event:
                        failed_events_per_iter += 1
                    
                        if failed_events_per_iter == 5:
                            l.internal("thread 1: 5 malformed event lines in a single read")
                        elif failed_events_per_iter == 10:
                            l.warning("10 malformed event lines have been encountered in a single procfile read, considered failure at 30")
                        elif failed_events_per_iter == 30:
                            l.critical("30 malformed event lines have been encountered in a single procfile read, considered failure, exiting...")    
                            kill_switch.set()
                            return
                    else:
                        events_per_iter += 1
                        event_queue.append(event)
        except PermissionError as e:
            # unless the file is _somehow_ -r, this is impossible, because we've already established UID=0
            l.critical(f"accessing procfile {proc_path} failed due to a permission error")
            l.error(e)
            l.internal("this is either impossible or intentional, good luck figuring it out")
            kill_switch.set()
            break
        except FileNotFoundError:
            l.critical(f"{proc_path} unavailable")
            if not tried_engine_load:
                l.debug("either the Engine wasn't loaded, or another program accessed the procfile and spoiled the lease")
                l.info("attempting to load the Engine")
                try:
                    reload_engine()
                    tried_engine_load = True
                    continue
                except Exception as e:
                    l.critical("reloading module failed")
                    l.error(e)
                    l.internal("thread 1: activating process-wide kill switch and aborting")
                    kill_switch.set()
                    l.internal("thread 1 exited with failure")
                    return
            else:
                l.critical("unrecoverable, exiting...")
                kill_switch.set()
                return
        except OSError as e:
            l.warning(f"procfile read failed, backing off until next iteration")
            l.error(e)

        l.internal(f"thread 1: {events_per_iter} events in interation")

        end_ts = time.monotonic()

        sleep_dur = freq + start_ts - end_ts

        time.sleep(sleep_dur)

        l.internal(f"thread 1: slept for {sleep_dur} seconds")

    l.internal("thread 1 exited with success")

# TODO