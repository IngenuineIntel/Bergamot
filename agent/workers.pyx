# workers.pyx
# multithreadees
import queue
import sys
import time

from interface import l

def event_reader_run(event_queue, stop_event, poll_interval, proc_path,
                     wire_batch_max_bytes, size_bytes_cb, parse_line_cb, queue_put_cb):
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
            l.critical(f"{proc_path} unavalible")
            l.debug("either another process has already claimed it, or the module's not loaded", flush=True)
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
            if not sender.send_batch(outbound):
                if not sender.connect(stop_event):
                    continue
                sender.send_batch(outbound)
