// allseer.h
// (c) 2026 IngenuineIntel <roan.rothrock@proton.me>

/*
 * Interface contract across components:
 *   hooks.c produces struct as_event via as_emit_event().
 *   allseer.c drains struct as_event to procfs line format:
 *     <ts_ns> <pid> <ppid> <uid> <type> <subtype> <comm> <arg>
 *   underseer.py parses that line into JSON keys:
 *     ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg
 *
 * Field mapping:
 *   timestamp_ns -> ts_s + ts_ms
 *   pid          -> pid
 *   ppid         -> ppid
 *   uid          -> uid
 *   type         -> type (stringified in allseer.c)
 *   subtype      -> subtype (future syscall minutia)
 *   comm         -> comm
 *   arg          -> arg
 */

#ifndef ALLSEER_H
#define ALLSEER_H

#include <linux/sched.h>
#include <linux/types.h>

enum as_event_type {
  AS_TYPE_OPEN = 0,
  AS_TYPE_FORK,
  AS_TYPE_CONNECT,
  AS_TYPE_EXECVE,
};

/* ── Event struct ────────────────────────────────────────────────────── */
/* One instance is pushed into the kfifo for every intercepted event.    */
struct as_event {
  u64 timestamp_ns;         /* ktime_get_ns() at probe fire time   */
  pid_t pid;                /* PID of the triggering task          */
  pid_t ppid;               /* PID of the parent task              */
  uid_t uid;                /* UID of the triggering task          */
  u8 type;                  /* AS_TYPE_* constant                  */
  char subtype[32];         /* syscall subtype (currently "none") */
  char comm[TASK_COMM_LEN]; /* process name (≤15 chars + NUL)      */
  char arg[256];            /* filename / argv[0] / "IP:port"      */
};

/* ── Shared function declared in allseer.c, called from hooks.c ──────── */
void as_emit_event(enum as_event_type type, const char *subtype,
                   const char *arg);

#endif /* ALLSEER_H */
