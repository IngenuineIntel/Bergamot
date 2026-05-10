# Underseer Wire Protocol

This document defines the wire protocol between Underseer and Overseer.

It has two sections:
- V1: current production protocol (NDJSON over TCP)
- V2: binary framed protocol (implemented and selectable)

## V1 (Current): NDJSON over TCP

### Transport
- Protocol: TCP
- Default destination: BERGAMOT_HOST:BERGAMOT_WIRE_PORT
- Default port: 12046
- Encoding: UTF-8

### Message framing
- Each message is one JSON object followed by a newline (`\n`).
- Underseer may send many JSON lines in one socket write.
- A single JSON line may be split across multiple TCP packets.
- Overseer reassembles bytes and splits by newline.

### Connection sequence
1. Underseer connects to Overseer TCP listener.
2. First message must be a `system_info` object.
3. Overseer validates handshake and initializes session DB.
4. Remaining messages are event messages and process snapshots.

### Handshake message (first message)
Human-readable JSON equivalent:

```json
{
  "kind": "system_info",
  "hostname": "host-a",
  "kernelver": "6.11.0 x86_64",
  "distro": "Fedora Linux 42",
  "ipaddr": "192.168.1.20",
  "macaddr": "aa:bb:cc:dd:ee:ff",
  "processor": "Intel(R) Core(TM) i7-12700H",
  "processor_vend": "GenuineIntel",
  "ram_gbs": 32
}
```

### Event message
Human-readable JSON equivalent:

```json
{
  "ts_s": 1778387001,
  "ts_ms": 123,
  "pid": 2134,
  "ppid": 1,
  "uid": 1000,
  "type": "execve",
  "subtype": "__x64_sys_execve",
  "comm": "bash",
  "arg": "/usr/bin/ls",
  "arg1": "/usr/bin/ls",
  "arg2": ""
}
```

Notes:
- `arg` is maintained for compatibility and mirrors `arg1`.
- `subtype` may be empty for event families without subtypes.
- `ptrace` events may carry numeric `arg2`.

### Process snapshot message
Human-readable JSON equivalent:

```json
{
  "kind": "proc_snapshot",
  "ts_s": 1778387002,
  "ts_ms": 500,
  "processes": [
    {
      "pid": 1,
      "ppid": 0,
      "uid": 0,
      "comm": "systemd",
      "threads": 1
    },
    {
      "pid": 2134,
      "ppid": 1,
      "uid": 1000,
      "comm": "bash",
      "threads": 1
    }
  ]
}
```

### V1 receiver behavior
- If first decoded message is not `{"kind": "system_info", ...}`, connection is rejected.
- Malformed JSON lines are skipped.
- Valid decoded dictionaries are sent into state ingestion.

### Packet sniffing view for V1
- Traffic appears as plaintext JSON in TCP stream reassembly.
- Packet boundaries do not equal message boundaries.
- Message boundaries are newline delimiters in the byte stream.

## V2 (Implemented): Binary framed protocol

Status: implemented and selectable with `BERGAMOT_WIRE_PROTOCOL=binary`.

Default remains `json` for compatibility.

### Goals
- Remove newline-delimited JSON transport overhead.
- Support strict frame boundaries independent of TCP packetization.
- Decode into the same event dictionary shape inside Overseer.
- Keep browser/API JSON outputs unchanged.

### Frame structure (on wire)
Each frame is network byte order (big-endian):

- `magic`: 4 bytes (`BGW2`)
- `version`: 1 byte (`2`)
- `kind`: 1 byte
- `flags`: 1 byte
- `reserved`: 1 byte
- `payload_len`: 4 bytes
- `checksum`: 4 bytes (CRC32 of payload)
- `payload`: `payload_len` bytes

Header pack format used in code: `!4sBBBBII`.

Current hardening rules:
- checksum flag is required (`flags & 0x01`)
- unknown flag bits are rejected
- oversized frames are rejected (max controlled by `BERGAMOT_WIRE_MAX_FRAME_BYTES`, default 1048576)
- checksum mismatch is rejected

### Message kinds
- system_info
- event
- proc_snapshot

### Compatibility strategy
- Overseer supports dual mode (JSON NDJSON and binary framed).
- Receiver mode is auto-detected by first bytes (`BGW2` means binary).
- Underseer chooses send mode via `BERGAMOT_WIRE_PROTOCOL`.
- Recommended rollout: deploy Overseer dual-mode first, then migrate Underseer agents.

### Human-readable JSON equivalents (V2 payload semantics)
V2 payloads decode back into the same in-memory dictionaries as V1. Equivalent examples:

`system_info` equivalent:

```json
{
  "kind": "system_info",
  "hostname": "host-a",
  "kernelver": "6.11.0 x86_64",
  "distro": "Fedora Linux 42",
  "ipaddr": "192.168.1.20",
  "macaddr": "aa:bb:cc:dd:ee:ff",
  "processor": "Intel(R) Core(TM) i7-12700H",
  "processor_vend": "GenuineIntel",
  "ram_gbs": 32
}
```

`event` equivalent:

```json
{
  "ts_s": 1778387001,
  "ts_ms": 123,
  "pid": 2134,
  "ppid": 1,
  "uid": 1000,
  "type": "execve",
  "subtype": "__x64_sys_execve",
  "comm": "bash",
  "arg": "/usr/bin/ls",
  "arg1": "/usr/bin/ls",
  "arg2": ""
}
```

`proc_snapshot` equivalent:

```json
{
  "kind": "proc_snapshot",
  "ts_s": 1778387002,
  "ts_ms": 500,
  "processes": [
    {
      "pid": 1,
      "ppid": 0,
      "uid": 0,
      "comm": "systemd",
      "threads": 1
    }
  ]
}
```

## Canonical in-memory target shape
Regardless of wire encoding, Overseer should convert inbound messages to the same dictionary structures currently consumed by state ingestion:
- event fields: `ts_s`, `ts_ms`, `pid`, `ppid`, `uid`, `type`, `subtype`, `comm`, `arg`, `arg1`, `arg2`
- snapshot fields: `kind=proc_snapshot`, `ts_s`, `ts_ms`, `processes[]`

## Source of truth in code
Current behavior is implemented in:
- underseer/underseer.pyx
- overseer/server.py
- overseer/state.py
