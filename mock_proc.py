#!/usr/bin/env python3
"""
mock_proc.py — Fake /proc/all_seer for development without the kernel module.

Creates a named pipe (FIFO) at the path Under-Seer expects and pumps
synthetic event lines into it at a configurable rate.

Usage:
    # Terminal 1 — start the mock proc file:
    python3 scripts/mock_proc.py

    # Terminal 2 — point Under-Seer at the pipe:
    PROC_PATH=/tmp/all_seer_mock OVERSEER_HOST=127.0.0.1 python3 underseer/underseer.py

    # Terminal 3 — start Over-Seer:
    python3 overseer/app.py

Environment variables:
    MOCK_PROC_PATH      Path to create the named pipe  (default: /tmp/all_seer_mock)
    MOCK_RATE_HZ        Events emitted per second       (default: 5)
"""

import os
import random
import signal
import stat
import sys
import time

PIPE_PATH = os.environ.get("MOCK_PROC_PATH", "/tmp/all_seer_mock")
RATE_HZ   = float(os.environ.get("MOCK_RATE_HZ", "5"))
INTERVAL  = 1.0 / RATE_HZ

COMMS  = ["bash", "python3", "sshd", "nginx", "postgres", "curl", "ls", "cat",
          "systemd", "cron", "vim", "grep", "find", "rsync"]
PATHS  = ["/etc/passwd", "/etc/hosts", "/var/log/syslog", "/tmp/test.txt",
          "/usr/lib/libc.so.6", "/proc/self/status", "/dev/urandom",
          "/home/user/.bashrc", "/var/run/dbus/system_bus_socket"]
DESTS  = ["93.184.216.34:443", "1.1.1.1:53", "192.168.1.1:22",
          "10.0.0.5:8080", "[2606:4700:4700::1111]:53"]
TYPES  = ["open", "fork", "exec", "connect"]
WEIGHTS = [0.55, 0.15, 0.15, 0.15]   # open events are most common

_pid_counter = 1000


def next_pid() -> int:
    global _pid_counter
    _pid_counter = (_pid_counter % 65535) + 1
    return _pid_counter


def make_event() -> str:
    ev_type = random.choices(TYPES, weights=WEIGHTS, k=1)[0]
    ts      = time.time_ns()
    pid     = next_pid()
    ppid    = max(1, pid - random.randint(1, 50))
    uid     = random.choice([0, 1000, 1001])
    comm    = random.choice(COMMS)

    if ev_type == "open":
        arg = random.choice(PATHS)
    elif ev_type == "fork":
        arg = comm
    elif ev_type == "exec":
        arg = "/usr/bin/" + comm
    else:  # connect
        arg = random.choice(DESTS)

    return f"{ts} {pid} {ppid} {uid} {ev_type} {comm} {arg}\n"


def cleanup(signum, frame):
    print(f"\n[mock] Removing pipe {PIPE_PATH}", flush=True)
    try:
        os.unlink(PIPE_PATH)
    except FileNotFoundError:
        pass
    sys.exit(0)


def main():
    # Remove stale pipe if it exists but is not a FIFO
    if os.path.exists(PIPE_PATH):
        if not stat.S_ISFIFO(os.stat(PIPE_PATH).st_mode):
            os.unlink(PIPE_PATH)
        else:
            pass  # reuse existing FIFO
    else:
        os.mkfifo(PIPE_PATH, mode=0o666)

    signal.signal(signal.SIGINT,  cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    print(f"[mock] FIFO ready at {PIPE_PATH} ({RATE_HZ:.1f} events/s)", flush=True)
    print(f"[mock] Set PROC_PATH={PIPE_PATH} in Under-Seer", flush=True)

    while True:
        # open() on a write-only FIFO blocks until a reader opens the read end.
        print("[mock] Waiting for a reader...", flush=True)
        try:
            with open(PIPE_PATH, "w") as fh:
                print("[mock] Reader connected — emitting events", flush=True)
                while True:
                    fh.write(make_event())
                    fh.flush()
                    time.sleep(INTERVAL)
        except BrokenPipeError:
            print("[mock] Reader disconnected, waiting for next reader...",
                  flush=True)
        except OSError as exc:
            print(f"[mock] Error: {exc}", flush=True)
            time.sleep(1)


if __name__ == "__main__":
    main()
else: raise ImportError("Don't import me!!!")