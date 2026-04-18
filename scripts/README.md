# Scripts Quick Guide

This folder has helper scripts for building, loading, unloading, and testing All-Seer.

Run all commands from the project root:

```bash
cd /home/roan/Documents/active/Bergamot
```

## 1) Build the kernel module

```bash
./scripts/build_module.sh
```

Build with a hook disabled (example: disable fork hook):

```bash
CFLAGS_EXTRA="-DAS_HOOK_FORK=0" ./scripts/build_module.sh
```

## 2) Load the module

```bash
./scripts/load_module.sh
```

This uses `sudo insmod` and shows recent `dmesg` lines.

## 3) Unload the module

```bash
./scripts/unload_module.sh
```

This uses `sudo rmmod all_seer_kmod`.

## 4) Run the smoke test

```bash
./scripts/smoke_test.sh
```

What it checks, in simple terms:
- module can load
- `/proc/all_seer` and `/proc/all_seer_ctl` exist
- events are produced
- buffer drains correctly
- non-owner reads return empty
- ctl commands (`stop`, `start`, `reset`) work
- module still loads if one hook is compiled out

## 5) Run without the kernel module (mock mode)

Use `mock_proc.py` to generate fake `/proc/all_seer`-style events:

Terminal 1:

```bash
python3 scripts/mock_proc.py
```

Terminal 2 (Under-Seer reading the mock pipe):

```bash
PROC_PATH=/tmp/all_seer_mock OVERSEER_HOST=127.0.0.1 python3 underseer/underseer.py
```

Terminal 3 (Over-Seer dashboard):

```bash
python3 overseer/app.py
```

Optional mock settings:

```bash
MOCK_PROC_PATH=/tmp/all_seer_mock MOCK_RATE_HZ=10 python3 scripts/mock_proc.py
```

## Typical order (real kernel mode)

1. `./scripts/build_module.sh`
2. `./scripts/load_module.sh`
3. Start Under-Seer / Over-Seer
4. `./scripts/smoke_test.sh` (optional verification)
5. `./scripts/unload_module.sh`
