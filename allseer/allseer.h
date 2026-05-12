// allseer.h
// (c) 2026 IngenuineIntel <roan.rothrock@proton.me>

/*
 * Interface contract across components:
 *   hooks.c produces struct as_event via as_emit_event().
 *   engine (allseer.c) drains struct as_event to procfs line format:
 *     <ts_ns>\t<pid>\t<ppid>\t<uid>\t<type>\t<subtype>\t<comm>\t<arg1>\t<arg2>
 *   agent (underseer.py) parses that line into JSON keys:
 *     ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg, arg1, arg2
 *
 * Field mapping:
 *   timestamp_ns -> ts_s + ts_ms
 *   pid          -> pid
 *   ppid         -> ppid
 *   uid          -> uid
 *   type         -> type (stringified by engine in allseer.c)
 *   subtype      -> subtype (future syscall minutia)
 *   comm         -> comm
 *   arg          -> arg / arg1
 *   arg2         -> arg2
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
  AS_TYPE_ACCEPT,
  AS_TYPE_UNLINK,
  AS_TYPE_RENAME,
  AS_TYPE_SETUID,
  AS_TYPE_SETGID,
  AS_TYPE_SETREUID,
  AS_TYPE_CAPSET,
  AS_TYPE_KEYCTL,
  AS_TYPE_PTRACE,
  AS_TYPE_GETID,
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
  char arg2[256];           /* optional secondary syscall argument  */
};

/* ── Shared function declared in allseer.c, called from hooks.c ──────── */
void as_emit_event(enum as_event_type type, const char *subtype,
                   const char *arg);
void as_emit_event2(enum as_event_type type, const char *subtype,
                    const char *arg, const char *arg2);

#endif /* ALLSEER_H */
