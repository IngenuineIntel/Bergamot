# Underseer Wire Protocol

This document defines the wire protocol between Underseer and Overseer.

It has two sections:
- V1: current production protocol (NDJSON over TCP)
- V2: planned binary framed protocol (migration target)

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

## V2 (Planned): Binary framed protocol

Status: planned migration target. Not production default yet.

### Goals
- Remove newline-delimited JSON transport overhead.
- Support strict frame boundaries independent of TCP packetization.
- Decode into the same event dictionary shape inside Overseer.
- Keep browser/API JSON outputs unchanged.

### Frame structure (proposed)
Each frame:
- magic (fixed bytes)
- protocol version
- message kind
- flags
- payload length
- payload bytes

Optional for hardening:
- checksum field in header or trailer

### Message kinds (proposed)
- system_info
- event
- proc_snapshot

### Compatibility strategy (planned)
- Deploy Overseer dual-mode first.
- Roll out Underseer binary sender incrementally.
- Keep compatibility period before retiring NDJSON.

## Canonical in-memory target shape
Regardless of wire encoding, Overseer should convert inbound messages to the same dictionary structures currently consumed by state ingestion:
- event fields: `ts_s`, `ts_ms`, `pid`, `ppid`, `uid`, `type`, `subtype`, `comm`, `arg`, `arg1`, `arg2`
- snapshot fields: `kind=proc_snapshot`, `ts_s`, `ts_ms`, `processes[]`

## Source of truth in code
Current behavior is implemented in:
- underseer/underseer.pyx
- overseer/server.py
- overseer/state.py
