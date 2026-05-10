# underseer_workers.pyx
# multithreadees
import queue
import sys
import time

from logging import l

def event_reader_run(event_queue, stop_event, poll_interval, proc_path,
                     wire_batch_max, parse_line_cb, queue_put_cb):
    lease_announced = False
    next_poll_at = time.monotonic()

    while not stop_event.is_set():
        batch = []
        try:
            with open(proc_path, "r") as fh:
                if not lease_announced:
                    l.info(f"{proc_path} access claimed", flush=True)
                    lease_announced = True
                for raw_line in fh:
                    ev = parse_line_cb(raw_line)
                    if ev:
                        batch.append(ev)
                    if len(batch) >= wire_batch_max:
                        break
        except PermissionError:
            continue
        except FileNotFoundError:
            l.critical(f"{proc_path} unavalible")
            l.debug("either another process has already claimed it, or the module's not loaded", flush=True)
            time.sleep(5)
            continue
        except OSError as exc:
            l.error(f"read failed: {exc}", flush=True)
            continue

        if batch:
            queue_put_cb(event_queue, batch)

        next_poll_at += poll_interval
        now_mono = time.monotonic()
        sleep_for = next_poll_at - now_mono
        if sleep_for > 0:
            stop_event.wait(sleep_for)
        else:
            next_poll_at = now_mono


def snapshot_worker_run(snapshot_queue, stop_event, snapshot_interval,
                        collect_snapshot_cb, queue_put_cb):
    next_snapshot_at = time.monotonic()

    while not stop_event.is_set():
        now_mono = time.monotonic()
        if now_mono >= next_snapshot_at:
            snap = collect_snapshot_cb()
            if isinstance(snap, list):
                for item in snap:
                    queue_put_cb(snapshot_queue, item)
            else:
                queue_put_cb(snapshot_queue, snap)

            while next_snapshot_at <= now_mono:
                next_snapshot_at += snapshot_interval

        sleep_for = next_snapshot_at - time.monotonic()
        if sleep_for > 0:
            stop_event.wait(sleep_for)


def sender_run(sender, event_queue, snapshot_queue, stop_event):
    while not stop_event.is_set():
        outbound = []

        try:
            batch = event_queue.get(timeout=0.25)
            if isinstance(batch, list) and batch:
                outbound.extend(batch)
        except queue.Empty:
            pass

        snapshots = []
        while True:
            try:
                snap = snapshot_queue.get_nowait()
                snapshots.append(snap)
            except queue.Empty:
                break

        if snapshots:
            outbound.extend(snapshots)

        if outbound:
            if not sender.send_batch(outbound):
                sender.connect()
                sender.send_batch(outbound)
