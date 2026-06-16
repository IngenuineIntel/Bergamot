# workers.pyx

"""
Agent
Thread
Workers

A primer:

0. Main:
Interacts with the user, waits for a connection to be received, and starts
threads 1-5 and becomes thread 6

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
packets with the data, and loads a packet deque with them at a specified
frequency

5. Proc & Perf Loading Thread:
Takes the information from the proc and perf deques and creates individual
networks packets with the data, and loads a packet deque, alternating between
the two deques at a specified frequency

6. Sending Thread:
Sends all packets in the packet deque at a specified frequency
"""

import contextlib
import os
import subprocess
import sys
import time

from interface import l
from protocol import (
    SystemInfo, Event, Proc, ProcSnapshot, Perf,
    gen_system_info, gen_event, gen_proc_snapshot, gen_perf
)

###############################################################################
# ── THREAD 1 ─────────────────────────────────────────────────────────────── #
###############################################################################

def thread_1(object event_queue, object kill_switch, int freq,
                   object overview_fn, str proc_path):
    """
    The Event Thread

    event_queue : the `collections.deque` object to add events to
    kill_switch : the `threading.Event` object to listen for
    freq        : the frequency to operate at
    overview_fn : the function for getting all overview data
    proc_path   : the path of the Engine procfile entry
    """

    cdef double start_ts
    cdef double end_ts

    cdef object event

    cdef int events_per_iter
    cdef int failed_events_per_iter

    cdef bool annouced
    cdef bool tried_engine_load

    cdef double sleep_dur

    announced         = False
    tried_engine_load = False


    def parse_line(str line):
        """
        Parses one procfile line into <Event>, or None if the line was invalid

        Format:
        TODO fix the engine to minimize redundancy
        the engine doesn't actually work like this atm, but I'm working on it

        <ts_ns>\t<pid>\t<type>\t<subtype>\t<arg1>\t<arg2>\t<retval>
        """
        cdef int expected_fields
        cdef int expected_delims
        
        # expected fields when parsing can be directly edited here
        expected_fields=8


        cdef object ret
        cdef list parts

        cdef int ts_ns
        cdef int ts_s
        cdef int ts_ms

        expected_delims = expected_fields -1

        line = line.strip()
        if not line or "\t" not in line:
            return None
        parts = line.split("\t", expected_delims)
        if len(parts) < expected_fields:
            return None

        try:
            # turning `ts_ns` into `ts_s` and `ts_ms`
            ts_ns = int(parts[0])
            ts_s  = ts_ns // 1_000_000_000
            ts_ms = ts_ns % 1_000_000_000 // 1_000_000

            ret = Event(
                ts_s   =ts_s,
                ts_ms  =ts_ms,
                pid    =int(parts[2]),
                type   =parts[3],
                subtype=parts[4],
                arg1   =parts[5],
                arg2   =parts[6],
                retval =int(parts[7])
            )

            # when subtype is blank, the placeholder is "none"
            if ret.subtype == "none":
                ret.subtype = ""

        except:
            return None
        return ret


    def reload_engine():
        """
        Reloads engine if need be
        """
        cdef str rm_cmd
        cdef str ins_cmd

        cdef object rm
        cdef object ins

        rm_cmd  = "rmmod bergamot_engine"
        ins_cmd = "modprobe bergamot_engine"
        
        rm = subprocess.run(
            rm_cmd.split(" "),
            capture_output=True,
            text=True,
            check=False
        )

        l.internal(f"`{rm_cmd}` returned with code {rm.returncode}")

        ins = subprocess.run(
            rm_cmd.split(" "),
            capture_output=True,
            text=True,
            check=False
        )

        l.internal(f"`{ins_cmd} returned with code {ins.returncode}")

        if rm.returncode != 0:
            l.warning(f"`{ins_cmd}` failed with code {ins.returncode}: {ins.stderr}")

    l.internal("thread 1: started")

    # adding the overview to the queue
    event_queue.append(overview_fn)
    l.internal("thread 1: added overview information to queue")

    start_ts = time.monotonic()

    while not kill_switch.is_set():

        events_per_iter = 0
        failed_events_per_iter = 0

        try:
            with open(proc_path, "r") as fd:
                if not annouced:
                    l.info(f"procfile {proc_path} access claimed")
                    annouced = True
                for ln in fd:
                    event = parse_line(ln)
                    
                    # TODO make loop break upon hitting BATCH_MAX

                    if not event:
                        failed_events_per_iter += 1
                    
                        # malformed line warning
                        if failed_events_per_iter == 5:
                            l.internal("thread 1: 5 malformed event lines in a single read")
                            l.internal("thread 1: the malformed line in question:")
                            l.internal("thread 1:" + ln)
                        elif failed_events_per_iter == 10:
                            l.warning("10 malformed event lines have been encountered in a single procfile read, considered failure at 30")
                            l.internal("thread 1: the malformed line in question:")
                            l.internal("thread 1:" + ln)
                        elif failed_events_per_iter == 30:
                            l.critical("30 malformed event lines have been encountered in a single procfile read, considered failure, exiting...")
                            l.internal("thread 1: the malformed line in question:")
                            l.internal("thread 1:" + ln)
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
            return
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

        sleep_dur = 1 / freq + start_ts - end_ts

        # detecting when the thread is falling behind
        if sleep_dur < 0:
            l.internal(f"thread 1: falling behind, no time to sleep")
            start_ts = time.monotonic()
            continue

        time.sleep(sleep_dur)
        start_ts = time.monotonic()

        l.internal(f"thread 1: slept for {sleep_dur} seconds")

    l.internal("thread 1: exited")


###############################################################################
# ── THREAD 2 ─────────────────────────────────────────────────────────────── #
###############################################################################

def thread_2(object proc_queue, object kill_switch, int freq):
    """
    The Proc Thread

    proc_queue  : the queue to add process snapshots to
    kill_switch : the `threading.Event` object to listen to
    freq        : the frequency to operate at
    """

    cdef double start_ts
    cdef double end_ts

    cdef double now
    cdef int ts_s
    cdef int ts_ms

    cdef object snapshot

    cdef int pid
    cdef str comm

    cdef str status_path
    cdef str stat_path

    cdef int ppid
    cdef int uid
    cdef int threads
    cdef int vm_rss_kb
    cdef int cpu_ticks
    cdef int found

    cdef bool got_name
    cdef bool got_ppid
    cdef bool got_uid
    cdef bool got_threads
    cdef bool got_vmrss

    cdef double sleep_dur


    l.internal("thread 2: started")

    start_ts = time.monotonic()

    while not kill_switch.is_set():

        now = time.time()
        ts_s = int(now)
        ts_ms = int((now - ts_s) * 1000)

        snapshot = ProcSnapshot(
            ts_s=ts_s,
            ts_ms=ts_ms,
            processes=[]
        )

        for entry in os.scandir("/proc"):
            if not entry.name.isdigit() or not entry.is_dir(follow_symlinks=False):
                continue

            pid = int(entry.name)
            status_path = f"/proc/{entry.name}/status"
            stat_path   = f"/proc/{entry.name}/stat"

            try:
                with open(status_path, "r", encoding="utf-8", errors="replace") as fd:
                    for line in fd:

                        # comm
                        if (not got_name) and line.startswith("Name:\t"):
                            comm = line.split("\t", 1)[1].strip()
                            got_name = True
                            found += 1

                        # ppid
                        elif (not got_ppid) and line.startswith("PPid:\t"):
                            ppid = int(line.split("\t", 1)[1].strip() or 0)
                            got_ppid = True
                            found += 1
                        
                        # uid
                        elif (not got_uid) and line.startswith("Uid:\t"):
                            uid = int(line.split("\t", 1)[1].split()[0])
                            got_uid = True
                            found += 1
                        
                        # threads
                        elif (not got_threads) and line.startswith("Threads:\t"):
                            threads = int(line.split("\t", 1)[1].strip() or 0)
                            got_threads = True
                            found += 1
                        
                        # vmrss
                        elif (not got_vmrss) and line.startswith("VmRSS:\t"):
                            vm_rss_kb = int(line.split("\t", 1)[1].split()[0])
                            got_vmrss = True
                            found += 1

                        if found >= 5: # we have all we need
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

                snapshot.processes.append(
                    Proc(
                        pid=pid,
                        ppid=ppid,
                        uid=uid,
                        threads=threads,
                        cpu_ticks=cpu_ticks,
                        vm_rss_kb=vm_rss_kb,
                        comm=comm
                    )
                )

            except (FileNotFoundError, ProcessLookupError, PermissionError, OSError, ValueError):
                l.internal(f"process {pid} exited or otherwise became unreadable while being sampled, ignoring")
                continue

        proc_queue.append(snapshot)

        end_ts = time.monotonic()

        sleep_dur = 1 / freq + start_ts - end_ts

        # detecting when the thread is falling behind
        if sleep_dur < 0:
            l.internal(f"thread 2: falling behind, no time to sleep")
            start_ts = time.monotonic()
            continue

        time.sleep(sleep_dur)
        start_ts = time.monotonic()

        l.internal(f"thread 2: slept for {sleep_dur} seconds")

    l.internal("thread 2: exited")


###############################################################################
# ── THREAD 3 ─────────────────────────────────────────────────────────────── #
###############################################################################

def thread_3(object perf_queue, object kill_switch, int freq):
    """
    The Perf Thread
    
    perf_queue  : the queue to feed performance information into
    kill_switch : process-wide kill switch
    freq        : the frequency to operate at
    """

    cdef double start_ts
    cdef double end_ts
    cdef double sleep_dur

    cdef double now
    cdef int ts_s

    cdef list cores
    cdef list parts

    cdef dict mem_fields
    cdef int found_mem
    cdef str key
    mem_fields = {"MemTotal": 0, "MemFree": 0, "MemAvailable": 0, "Cached": 0}

    l.internal("thread 3: started")

    start_ts = time.monotonic()

    while not kill_switch.is_set():

        now = time.time()
        ts_s = int(now)

        # CPU
        cores = []
        try:
            with open("/proc/stat", "r") as fd:
                for ln in fd:

                    if not ln.startswith("cpu"):
                        continue 
                    
                    parts = ln.split()
                    if len(parts) < 8 or not parts[0][3:].isdigit():
                        continue

                    # user, nice, system, idle, iowait, irq, softirq
                    cores.append([int(parts[i]) for i in range(1, 8)])
        except OSError:
            pass

        # RAM
        found_mem = 0
        try:
            with open("/proc/meminfo", "r") as fd:
                for ln in fd:
                    key = ln.split(":")[0]
                    if key in mem_fields:
                        mem_fields[key] = int(ln.split()[1])
                        found_mem += 1
                        if found_mem >= 4:
                            break

        except OSError:
            pass

        ret = Perf(
            ts_s=ts_s,
            ts_ms=int((now - ts_s) * 1000),
            cores=len(cores),
            avg_cpu_pct=0.0,
            mem_total_kb=mem_fields["MemTotal"],
            mem_free_kb=mem_fields["MemFree"],
            mem_available_kb=mem_fields["MemAvailable"],
            mem_cached_kb=mem_fields["Cached"],
            load_1m=0.0,
            load_5m=0.0,
            load_15m=0.0,
            cores_json=""
        )

        # lastly, load
        try:
            with open("/porc/loadavg", "r") as fd:
                parts = fd.read().split()
                if len(parts) >= 3:
                    ret.load_1m, ret.load_5m, ret.load_15m = float(parts[0]), float(parts[1]), float(parts[2])
        except OSError:
            pass


        perf_queue.append(ret)

        end_ts = time.monotonic()

        sleep_dur = 1 / freq + start_ts - end_ts

        # detecting when the thread is falling behind
        if sleep_dur < 0:
            l.internal(f"thread 3: falling behind, no time to sleep")
            start_ts = time.monotonic()
            continue

        time.sleep(sleep_dur)
        start_ts = time.monotonic()

        l.internal(f"thread 3: slept for {sleep_dur} seconds")

    l.internal("thread 3: exited")


###############################################################################
# ── THREAD 4 ─────────────────────────────────────────────────────────────── #
###############################################################################

def thread_4(object event_queue, object packet_queue,
                   object kill_switch, int freq=2):
    """
    The Event Loading Thread

    event_queue        : the queue to take events from
    event_packet_queue : the queue to put packets into
    kill_switch        : process-wide kill switch
    freq               : the frequency to operate at
    """

    cdef double start_ts
    cdef double end_ts
    cdef double sleep_dur

    cdef object i
    cdef list j

    l.internal("thread 4: started")

    start_ts = time.monotonic()

    while not kill_switch.is_set():

        while not kill_switch.is_set() and len(event_queue) > 0:
            j = []
            i = event_queue.popleft()

            if isinstance(i, Event):
                j.append(i)
            elif isinstance(i, SystemInfo):
                # completely event packet, create overview packet, return to
                # making event packet

                packet_queue.append(gen_event(j))
                packet_queue.append(gen_system_info(i))
                continue

            else:
                l.internal(f"thread 4: unknown instance in the event queue: {type(i)}, ignoring")

        packet_queue.append(gen_event(j))

        end_ts = time.monotonic()

        sleep_dur = 1 / freq + start_ts - end_ts

        # detecting when the thread is falling behind
        if sleep_dur < 0:
            start_ts = time.monotonic()
            l.internal(f"thread 4: falling behind, no time to sleep")
            continue

        time.sleep(sleep_dur)
        start_ts = time.monotonic()

        l.internal(f"thread 4: slept for {sleep_dur} seconds")

    l.internal("thread 4: exited")


###############################################################################
# ── THREAD 5 ─────────────────────────────────────────────────────────────── #
###############################################################################

def thread_5(object proc_queue, object perf_queue, object combined_queue,
                   object kill_switch, int freq=1):
    """
    Proc/Perf Loading Thread

    proc_queue     : the queue to get proc data from
    perf_queue     : the queue to get perf data from
    combined_queue : the queue to combine them into
    kill_switch    : the process-wide kill switch
    freq           : the frequency to operate at
    """

    cdef double start_ts
    cdef double end_ts
    cdef double sleep_dur

    cdef object i

    start_ts = time.monotonic()

    while not kill_switch.is_set():

        while len(proc_queue) > 0 and len(perf_queue) > 0 and not kill_switch.is_set():
            i = proc_queue.popleft()
            combined_queue.append(gen_proc_snapshot(i))
            i = perf_queue.popleft()
            combined_queue.append(gen_perf(i))       
        
        # get stragglers
        while len(proc_queue) > 0 and not kill_switch.is_set():
            i = proc_queue.popleft()
            combined_queue.append(gen_proc_snapshot(i))

        while len(perf_queue) > 0 and not kill_switch.is_set():
            i = perf_queue.popleft()
            combined_queue.append(gen_perf(i))

        end_ts = time.monotonic()

        sleep_dur = 1 / freq + start_ts - end_ts

        # detecting when the thread is falling behind
        if sleep_dur < 0:
            start_ts = time.monotonic()
            l.internal(f"thread 5: falling behind, no time to sleep")
            continue

        time.sleep(sleep_dur)
        start_ts = time.monotonic()

        l.internal(f"thread 5: slept for {sleep_dur} seconds")
    
    l.internal("thread 5: exited")

###############################################################################
# ── THREAD 6 ─────────────────────────────────────────────────────────────── #
###############################################################################

def thread_6(object packet_queue, object kill_switch, object sender,
                   int freq):
    """
    The Sender Thread

    packet_queue : queue with packets to send
    kill_switch  : process-wide kill switch
    sender       : sender object
    freq         : the frequency to operate at
    """

    cdef double start_ts
    cdef double end_ts
    cdef double sleep_dur

    l.internal("thread 6: started")

    start_ts = time.monotonic()

    while not kill_switch.is_set():

        while not kill_switch.is_set() and len(packet_queue) > 0:
            sender.send(packet_queue.popleft())

        end_ts = time.monotonic()

        sleep_dur = 1 / freq + start_ts - end_ts

        # detecting when the thread is falling behind
        if sleep_dur < 0:
            start_ts = time.monotonic()
            l.internal(f"thread 6: falling behind, no time to sleep")
            continue

        time.sleep(sleep_dur)
        start_ts = time.monotonic()

        l.internal(f"thread 6: slept for {sleep_dur} seconds")
    
    l.internal("thread 6: exited")