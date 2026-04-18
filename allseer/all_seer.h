/* all_seer.h — shared definitions for the All-Seer kernel module
 *
 * Included by both allseer.c (core) and hooks.c (kprobe handlers).
 *
 * Interface contract across components:
 *   hooks.c produces struct as_event via as_emit_event().
 *   allseer.c drains struct as_event to procfs line format:
 *     <ts_ns> <pid> <ppid> <uid> <type> <comm> <arg>
 *   underseer.py parses that line into JSON keys:
 *     ts, pid, ppid, uid, type, comm, arg
 *
 * Field mapping:
 *   timestamp_ns -> ts
 *   pid          -> pid
 *   ppid         -> ppid
 *   uid          -> uid
 *   type         -> type (stringified in allseer.c)
 *   comm         -> comm
 *   arg          -> arg
 */

#ifndef ALL_SEER_H
#define ALL_SEER_H

#include <linux/types.h>
#include <linux/sched.h>

/* ── Event type constants ────────────────────────────────────────────── */
#define AS_TYPE_OPEN     0
#define AS_TYPE_FORK     1
#define AS_TYPE_EXEC     2
#define AS_TYPE_CONNECT  3

/* ── Event struct ────────────────────────────────────────────────────── */
/* One instance is pushed into the kfifo for every intercepted event.    */
struct as_event {
    u64   timestamp_ns;           /* ktime_get_ns() at probe fire time   */
    pid_t pid;                    /* PID of the triggering task          */
    pid_t ppid;                   /* PID of the parent task              */
    uid_t uid;                    /* UID of the triggering task          */
    u8    type;                   /* AS_TYPE_* constant                  */
    char  comm[TASK_COMM_LEN];    /* process name (≤15 chars + NUL)      */
    char  arg[256];               /* filename / argv[0] / "IP:port"      */
};

/* ── Shared function declared in allseer.c, called from hooks.c ──────── */
void as_emit_event(u8 type, const char *arg);

#endif /* ALL_SEER_H */
