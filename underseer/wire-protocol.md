# Underseer Wire Protocol

This document defines the active wire protocol between Underseer and Overseer.

## Current Protocol (Version 1.0)

- Transport: TCP
- Framing: binary, length-prefixed
- Byte order: big-endian (network order)
- Magic: `BGW1`
- Version: `1` (byte value; protocol version 1.0)
- Header format: `!4sBBBBII`

Header fields:
- `magic` (4 bytes)
- `version` (1 byte)
- `kind` (1 byte)
- `flags` (1 byte)
- `reserved` (1 byte)
- `payload_len` (4 bytes)
- `checksum` (4 bytes, CRC32 of payload)

Validation rules:
- checksum flag bit (`0x01`) is required
- unknown flag bits are rejected
- oversized frames are rejected (limit from `BERGAMOT_WIRE_MAX_FRAME_BYTES`, default `1048576`)
- checksum mismatch is rejected

## Message Kinds

- `1` = `system_info`
- `2` = `event`
- `4` = `rich_proc_snapshot`
- `5` = `system_perf`

## Payload Semantics

### `system_info`
Host metadata used to initialize a session database.

### `event`
Per-syscall event payload normalized to:
- `ts_s`, `ts_ms`, `pid`, `ppid`, `uid`
- `type`, `subtype`, `comm`
- `arg`, `arg1`, `arg2`

### `rich_proc_snapshot`
Periodic process table payload:
- `ts_s`, `ts_ms`
- `processes[]`: `pid`, `ppid`, `uid`, `comm`, `threads`, `cpu_ticks`, `vm_rss_kb`

### `system_perf`
Periodic system performance payload:
- `ts_s`, `ts_ms`
- `cores[]`: per-core raw tick counters (`user`, `nice`, `system`, `idle`, `iowait`, `irq`, `softirq`)
- `mem`: `total_kb`, `free_kb`, `available_kb`, `cached_kb`
- `load`: `l1`, `l5`, `l15`

## Source of Truth

Current behavior is implemented in:
- `underseer/underseer.pyx`
- `underseer/underseer_workers.pyx`
- `overseer/server.py`
- `overseer/state.py`
