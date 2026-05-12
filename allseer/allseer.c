// allseer.c
// All-Seer kernel module core
// (c) 2026 IngenuineIntel <roan.rothrock@proton.me>

/*
 * Component boundary: kernel -> userspace handoff.
 *   - hooks.c emits normalized events into kfifo via as_emit_event().
 *   - /proc/all_seer exposes drained kfifo events as one text line each.
 *   - underseer.py consumes those lines, maps fields to JSON, and forwards
 *     them over TCP to Over-Seer.
 *
 * Responsibilities:
 *   - kfifo ring buffer + as_emit_event() called from hooks.c
 *   - as_ready flag: hooks are no-ops until module is fully initialised
 *   - Exclusive reader lock on /proc/all_seer
 *   - procfs interface (drains kfifo for the owner only)
 *   - kprobe registration / deregistration (entries #if-gated by
 * hooks_config.h)
 */

#include <linux/atomic.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/kfifo.h>
#include <linux/kprobes.h>
#include <linux/ktime.h>
#include <linux/module.h>
#include <linux/pid.h>
#include <linux/proc_fs.h>
#include <linux/rcupdate.h>
#include <linux/sched.h>
#include <linux/seq_file.h>
#include <linux/spinlock.h>

#include "allseer.h"
#include "switches.h"

/*
 * Per-kernel symbol availability flags.
 * Override at build time (for example via EXTRA_CFLAGS -DAS_SYM_...=0)
 * without editing switches.h.
 */
#ifndef AS_SYM_X64_SYS_ACCEPT4
#define AS_SYM_X64_SYS_ACCEPT4 1
#endif
#ifndef AS_SYM_X64_SYS_UNLINKAT
#define AS_SYM_X64_SYS_UNLINKAT 1
#endif
#ifndef AS_SYM_X64_SYS_RENAMEAT2
#define AS_SYM_X64_SYS_RENAMEAT2 1
#endif
#ifndef AS_SYM_X64_SYS_SETUID
#define AS_SYM_X64_SYS_SETUID 1
#endif
#ifndef AS_SYM_X64_SYS_SETRESUID
#define AS_SYM_X64_SYS_SETRESUID 1
#endif
#ifndef AS_SYM_X64_SYS_SETGID
#define AS_SYM_X64_SYS_SETGID 1
#endif
#ifndef AS_SYM_X64_SYS_SETRESGID
#define AS_SYM_X64_SYS_SETRESGID 1
#endif
#ifndef AS_SYM_X64_SYS_SETEGID
#define AS_SYM_X64_SYS_SETEGID 0
#endif
#ifndef AS_SYM_X64_SYS_SETREUID
#define AS_SYM_X64_SYS_SETREUID 1
#endif
#ifndef AS_SYM_X64_SYS_SETEUID
#define AS_SYM_X64_SYS_SETEUID 0
#endif
#ifndef AS_SYM_X64_SYS_CAPSET
#define AS_SYM_X64_SYS_CAPSET 1
#endif
#ifndef AS_SYM_X64_SYS_KEYCTL
#define AS_SYM_X64_SYS_KEYCTL 1
#endif
#ifndef AS_SYM_X64_SYS_PTRACE
#define AS_SYM_X64_SYS_PTRACE 1
#endif
#ifndef AS_SYM_X64_SYS_GETUID
#define AS_SYM_X64_SYS_GETUID 1
#endif
#ifndef AS_SYM_X64_SYS_GETEUID
#define AS_SYM_X64_SYS_GETEUID 1
#endif
#ifndef AS_SYM_X64_SYS_GETGID
#define AS_SYM_X64_SYS_GETGID 1
#endif
#ifndef AS_SYM_X64_SYS_GETEGID
#define AS_SYM_X64_SYS_GETEGID 1
#endif
#ifndef AS_SYM_X64_SYS_GETRESUID
#define AS_SYM_X64_SYS_GETRESUID 1
#endif
#ifndef AS_SYM_X64_SYS_GETRESGID
#define AS_SYM_X64_SYS_GETRESGID 1
#endif
#ifndef AS_SYM_X64_SYS_GETPID
#define AS_SYM_X64_SYS_GETPID 1
#endif
#ifndef AS_SYM_X64_SYS_GETPPID
#define AS_SYM_X64_SYS_GETPPID 1
#endif
#ifndef AS_SYM_X64_SYS_GETTID
#define AS_SYM_X64_SYS_GETTID 1
#endif
#ifndef AS_SYM_X64_SYS_GETPGID
#define AS_SYM_X64_SYS_GETPGID 1
#endif
#ifndef AS_SYM_X64_SYS_GETSID
#define AS_SYM_X64_SYS_GETSID 1
#endif

MODULE_LICENSE("GPL");
MODULE_AUTHOR("IgenuineIntel");
MODULE_DESCRIPTION("System Event Analytics");
MODULE_VERSION("0.1");

/* ── KFIFO RING BUFFER ──────────────────────────────────────────────────── */
#define AS_FIFO_SIZE 8192

static DEFINE_KFIFO(as_fifo, struct as_event, AS_FIFO_SIZE);
static DEFINE_SPINLOCK(as_fifo_lock);

/*
 * Shared guard flags referenced by hooks.c as extern symbols:
 *   - as_ready: set only after init completes and probes are registered
 *   - as_collecting: reserved for future runtime gating; enabled by default
 */
atomic_t as_ready = ATOMIC_INIT(0);
atomic_t as_collecting = ATOMIC_INIT(1);

static bool as_type_has_multiple_subtypes(enum as_event_type type) {
  switch (type) {
  case AS_TYPE_EXECVE:
  case AS_TYPE_SETUID:
  case AS_TYPE_SETGID:
  case AS_TYPE_SETREUID:
  case AS_TYPE_GETID:
    return true;
  default:
    return false;
  }
}

/* as_emit_event — called from hooks.c */
void as_emit_event2(enum as_event_type type, const char *subtype,
                    const char *arg, const char *arg2) {
  struct as_event ev;
  unsigned long flags;
  const char *effective_subtype;

  /* Drop events until module init completes and collection is active. */
  if (!atomic_read(&as_ready) || !atomic_read(&as_collecting))
    return;

  ev.timestamp_ns = ktime_get_ns();
  ev.pid = current->pid;
  ev.ppid = task_ppid_nr(current);
  ev.uid = from_kuid_munged(&init_user_ns, current_uid());
  ev.type = type;

    /*
     * Only multi-subtype event types carry subtype labels.
     * All other types intentionally emit with no subtype.
     */
    effective_subtype = as_type_has_multiple_subtypes(type) ? subtype : NULL;
    strncpy(ev.subtype, effective_subtype ? effective_subtype : "none",
      sizeof(ev.subtype) - 1);
  ev.subtype[sizeof(ev.subtype) - 1] = '\0';
  get_task_comm(ev.comm, current);
  strncpy(ev.arg, arg ? arg : "", sizeof(ev.arg) - 1);
  ev.arg[sizeof(ev.arg) - 1] = '\0';
  strncpy(ev.arg2, arg2 ? arg2 : "", sizeof(ev.arg2) - 1);
  ev.arg2[sizeof(ev.arg2) - 1] = '\0';

  spin_lock_irqsave(&as_fifo_lock, flags);
  /* If the fifo is full, drop the oldest entry to make room. */
  if (kfifo_is_full(&as_fifo)) {
    struct as_event discard;
    bool dropped = kfifo_get(&as_fifo, &discard);
    (void)dropped;
  }
  kfifo_put(&as_fifo, ev);
  spin_unlock_irqrestore(&as_fifo_lock, flags);
}
EXPORT_SYMBOL(as_emit_event2);

void as_emit_event(enum as_event_type type, const char *subtype,
                   const char *arg) {
  as_emit_event2(type, subtype, arg, "");
}
EXPORT_SYMBOL(as_emit_event);

/* ── END KFIFO RING BUFFER ──────────────────────────────────────────────── */

/* ── PROCFS INTERFACE ───────────────────────────────────────────────────── */

/* Owner lease state
 * The first successful opener of /proc/all_seer claims a lease. If the
 * opener's PPID is 1 (it called setsid, making init its parent), only that
 * exact PID holds the lease. Otherwise any process sharing the same PPID is
 * treated as part of the same owner scope.
 *
 * The lease is sticky until the module is unloaded or reloaded. All other
 * callers see -ENOENT ("file disappears" semantics).
 */
static DEFINE_MUTEX(lease_owner_lock);

struct lease_owner_ident {
  /* managing identifying attributes of a claiming process */
  pid_t pid;
  pid_t ppid;
  // if setsid == 1, only the PID gets the lease, else all children of the PPID
  // get it. `setsid` should only be made true if PPID == 1
  bool  setsid;
};
static struct lease_owner_ident lease_ident;

static void as_clear_owner_lease(void) {
  /* Clears lease */
  mutex_lock(&lease_owner_lock);
  lease_ident.pid = 0;
  lease_ident.ppid = 0;
  lease_ident.setsid = false;
  mutex_unlock(&lease_owner_lock);
}

static struct lease_owner_ident as_current_parent_identity(void) {
  /* Gathers information from the process that has last interacted */
  struct lease_owner_ident ident = {0};
  struct task_struct *parent;

  ident.pid = task_tgid_nr(current);

  rcu_read_lock();
  parent = rcu_dereference(current->real_parent);
  if (!parent) {
    rcu_read_unlock();
    return ident;
  }

  ident.ppid = task_tgid_nr(parent);
  rcu_read_unlock();

  ident.setsid = (ident.ppid == 1);

  return ident;

}

static bool as_current_is_owner(void) {
  /* Checks the interacting process against the authorized one */
  struct lease_owner_ident loc_ident = as_current_parent_identity();
  bool authorized;

  if (loc_ident.ppid <= 0)
    return false;

  mutex_lock(&lease_owner_lock);
  if (lease_ident.ppid == 0)
    authorized = false;
  else if (lease_ident.setsid)
    authorized = loc_ident.pid == lease_ident.pid;
  else
    authorized = loc_ident.ppid == lease_ident.ppid;
  mutex_unlock(&lease_owner_lock);

  return authorized;
}

static bool as_claim_owner_if_unset(void) {
  /* Authorizes the interacting process if another one hasn't been authorized
   * yet.
   */
  struct lease_owner_ident my_ident = as_current_parent_identity();
  bool claimed = false;
  bool authorized;

  if (my_ident.ppid <= 0)
    return false;

  mutex_lock(&lease_owner_lock);
  if (lease_ident.ppid == 0) {
    lease_ident = my_ident;
    claimed = true;
  }

  if (lease_ident.setsid)
    authorized = my_ident.pid == lease_ident.pid;
  else
    authorized = my_ident.ppid == lease_ident.ppid;
  mutex_unlock(&lease_owner_lock);

  if (claimed) {
    pr_info("all_seer: owner lease claimed pid=%d ppid=%d setsid=%d comm=%s\n",
            my_ident.pid, my_ident.ppid, (int)my_ident.setsid, current->comm);
  }

  return authorized;
}

static const char *const as_type_str[] = {
    [AS_TYPE_OPEN] = "open",
    [AS_TYPE_FORK] = "fork",
    [AS_TYPE_CONNECT] = "connect",
    [AS_TYPE_EXECVE] = "execve",
    [AS_TYPE_ACCEPT] = "accept",
    [AS_TYPE_UNLINK] = "unlink",
    [AS_TYPE_RENAME] = "rename",
    [AS_TYPE_SETUID] = "setuid",
    [AS_TYPE_SETGID] = "setgid",
    [AS_TYPE_SETREUID] = "setreuid",
    [AS_TYPE_CAPSET] = "capset",
    [AS_TYPE_KEYCTL] = "keyctl",
    [AS_TYPE_PTRACE] = "ptrace",
    [AS_TYPE_GETID] = "getid",
};

/*
 * seq_show is called once per iteration.  We drain the entire fifo in
 * one start/show/stop cycle by using a simple iterator approach:
 * start returns a non-NULL cookie on the first call, show drains one
 * event and returns 0, next advances, stop cleans up.
 *
 * For simplicity we drain all events synchronously in a single read(2)
 * call: start() locks out unauthorized readers; next() keeps returning
 * non-NULL until the fifo is empty.
 */

static int as_proc_open(struct inode *inode, struct file *file) {
  /* Logic for when procfile is opened */
  /*
   * Strict owner lease mode:
   *   - first opener claims ownership for its parent-process scope
   *   - only processes in that scope may open/read afterwards
   *   - everyone else sees ENOENT
   */
  if (!as_claim_owner_if_unset())
    return -ENOENT;

  return 0;
}

static ssize_t as_proc_read(struct file *file, char __user *ubuf,
                                size_t count, loff_t *ppos) {
  /* Event handler for when `/proc/all_seer` is read.
   *
   * Custom read implementation: for the authorized owner we drain and
   * format the kfifo directly into the user buffer. Non-owners get 0
   * bytes, identical to an empty file.
   *
  * Procfs line contract emitted to Under-Seer:
  *   <ts_ns>\t<pid>\t<ppid>\t<uid>\t<type>\t<subtype>\t<comm>\t<arg1>\t<arg2>\n
   *
   * Under-Seer maps these fields into JSON keys:
  *   ts_s, ts_ms, pid, ppid, uid, type, subtype, comm, arg, arg1, arg2
   */

  struct as_event ev;
  char line[768];
  ssize_t total = 0;
  unsigned long flags;

  if (!as_current_is_owner())
    return -ENOENT;

  while (count > 0) {
    int len;

    spin_lock_irqsave(&as_fifo_lock, flags);
    if (!kfifo_get(&as_fifo, &ev)) {
      spin_unlock_irqrestore(&as_fifo_lock, flags);
      break;
    }
    spin_unlock_irqrestore(&as_fifo_lock, flags);

    len = snprintf(line, sizeof(line), "%llu\t%d\t%d\t%u\t%s\t%s\t%s\t%s\t%s\n",
                   (unsigned long long)ev.timestamp_ns, ev.pid, ev.ppid, ev.uid,
                   (ev.type < ARRAY_SIZE(as_type_str) && as_type_str[ev.type])
                       ? as_type_str[ev.type]
                       : "unknown",
             ev.subtype, ev.comm, ev.arg, ev.arg2);

    if (len <= 0)
      continue;

    if ((size_t)len > count)
      break; /* not enough space in caller's buffer — stop for now */

    if (copy_to_user(ubuf + total, line, len)) {
      if (total == 0)
        return -EFAULT;
      break;
    }

    total += len;
    count -= len;
  }

  return total;
}

static const struct proc_ops as_all_seer_ops = {
    .proc_open = as_proc_open,
    .proc_read = as_proc_read,
    .proc_lseek = noop_llseek,
};
static struct proc_dir_entry *as_all_seer_entry;

/* ── END PROCFS INTERFACE ───────────────────────────────────────────────── */

/* ── KPROBE DECLARATIONS ────────────────────────────────────────────────── */

#if AS_HOOK_OPEN
extern int as_probe_openat2(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_FORK
extern int as_probe_clone(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_CONNECT
extern int as_probe_connect(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_ACCEPT && AS_SYM_X64_SYS_ACCEPT4
extern int as_probe_x64_sys_accept4(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_UNLINK && AS_SYM_X64_SYS_UNLINKAT
extern int as_probe_x64_sys_unlinkat(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_RENAME && AS_SYM_X64_SYS_RENAMEAT2
extern int as_probe_x64_sys_renameat2(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_SETUID && AS_SYM_X64_SYS_SETUID
extern int as_probe_x64_sys_setuid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_SETUID && AS_SYM_X64_SYS_SETRESUID
extern int as_probe_x64_sys_setresuid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_SETGID && AS_SYM_X64_SYS_SETGID
extern int as_probe_x64_sys_setgid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_SETGID && AS_SYM_X64_SYS_SETRESGID
extern int as_probe_x64_sys_setresgid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_SETGID && AS_SYM_X64_SYS_SETEGID
extern int as_probe_x64_sys_setegid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_SETREUID && AS_SYM_X64_SYS_SETREUID
extern int as_probe_x64_sys_setreuid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_SETREUID && AS_SYM_X64_SYS_SETEUID
extern int as_probe_x64_sys_seteuid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_CAPSET && AS_SYM_X64_SYS_CAPSET
extern int as_probe_x64_sys_capset(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_KEYCTL && AS_SYM_X64_SYS_KEYCTL
extern int as_probe_x64_sys_keyctl(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_PTRACE && AS_SYM_X64_SYS_PTRACE
extern int as_probe_x64_sys_ptrace(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETUID
extern int as_probe_x64_sys_getuid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETEUID
extern int as_probe_x64_sys_geteuid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETGID
extern int as_probe_x64_sys_getgid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETEGID
extern int as_probe_x64_sys_getegid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETRESUID
extern int as_probe_x64_sys_getresuid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETRESGID
extern int as_probe_x64_sys_getresgid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETPID
extern int as_probe_x64_sys_getpid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETPPID
extern int as_probe_x64_sys_getppid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETTID
extern int as_probe_x64_sys_gettid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETPGID
extern int as_probe_x64_sys_getpgid(struct kprobe *p, struct pt_regs *regs);
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETSID
extern int as_probe_x64_sys_getsid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_EXECVE
extern int as_probe_execveat_common(struct kprobe *p, struct pt_regs *regs);
extern int as_probe_execve(struct kprobe *p, struct pt_regs *regs);
extern int as_probe_x64_sys_execve(struct kprobe *p, struct pt_regs *regs);
extern int as_probe_x64_sys_execveat(struct kprobe *p, struct pt_regs *regs);

static struct kprobe as_execve_probe;
static bool as_execve_probe_registered;
static const char *as_execve_probe_symbol;
#endif

static struct kprobe as_kprobes[] = {
#if AS_HOOK_OPEN
    {
        .symbol_name = "do_sys_openat2",
        .pre_handler = as_probe_openat2,
    },
#endif
#if AS_HOOK_FORK
    {
        .symbol_name = "kernel_clone",
        .pre_handler = as_probe_clone,
    },
#endif
#if AS_HOOK_CONNECT
    {
        .symbol_name = "tcp_connect",
        .pre_handler = as_probe_connect,
    },
#endif
#if AS_HOOK_ACCEPT && AS_SYM_X64_SYS_ACCEPT4
  {
    .symbol_name = "__x64_sys_accept4",
    .pre_handler = as_probe_x64_sys_accept4,
  },
#endif
#if AS_HOOK_UNLINK && AS_SYM_X64_SYS_UNLINKAT
  {
    .symbol_name = "__x64_sys_unlinkat",
    .pre_handler = as_probe_x64_sys_unlinkat,
  },
#endif
#if AS_HOOK_RENAME && AS_SYM_X64_SYS_RENAMEAT2
  {
    .symbol_name = "__x64_sys_renameat2",
    .pre_handler = as_probe_x64_sys_renameat2,
  },
#endif
#if AS_HOOK_SETUID && AS_SYM_X64_SYS_SETUID
  {
    .symbol_name = "__x64_sys_setuid",
    .pre_handler = as_probe_x64_sys_setuid,
  },
#endif
#if AS_HOOK_SETUID && AS_SYM_X64_SYS_SETRESUID
  {
    .symbol_name = "__x64_sys_setresuid",
    .pre_handler = as_probe_x64_sys_setresuid,
  },
#endif
#if AS_HOOK_SETGID && AS_SYM_X64_SYS_SETGID
  {
    .symbol_name = "__x64_sys_setgid",
    .pre_handler = as_probe_x64_sys_setgid,
  },
#endif
#if AS_HOOK_SETGID && AS_SYM_X64_SYS_SETRESGID
  {
    .symbol_name = "__x64_sys_setresgid",
    .pre_handler = as_probe_x64_sys_setresgid,
  },
#endif
#if AS_HOOK_SETGID && AS_SYM_X64_SYS_SETEGID
  {
    .symbol_name = "__x64_sys_setegid",
    .pre_handler = as_probe_x64_sys_setegid,
  },
#endif
#if AS_HOOK_SETREUID && AS_SYM_X64_SYS_SETREUID
  {
    .symbol_name = "__x64_sys_setreuid",
    .pre_handler = as_probe_x64_sys_setreuid,
  },
#endif
#if AS_HOOK_SETREUID && AS_SYM_X64_SYS_SETEUID
  {
    .symbol_name = "__x64_sys_seteuid",
    .pre_handler = as_probe_x64_sys_seteuid,
  },
#endif
#if AS_HOOK_CAPSET && AS_SYM_X64_SYS_CAPSET
  {
    .symbol_name = "__x64_sys_capset",
    .pre_handler = as_probe_x64_sys_capset,
  },
#endif
#if AS_HOOK_KEYCTL && AS_SYM_X64_SYS_KEYCTL
  {
    .symbol_name = "__x64_sys_keyctl",
    .pre_handler = as_probe_x64_sys_keyctl,
  },
#endif
#if AS_HOOK_PTRACE && AS_SYM_X64_SYS_PTRACE
  {
    .symbol_name = "__x64_sys_ptrace",
    .pre_handler = as_probe_x64_sys_ptrace,
  },
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETUID
  {
    .symbol_name = "__x64_sys_getuid",
    .pre_handler = as_probe_x64_sys_getuid,
  },
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETEUID
  {
    .symbol_name = "__x64_sys_geteuid",
    .pre_handler = as_probe_x64_sys_geteuid,
  },
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETGID
  {
    .symbol_name = "__x64_sys_getgid",
    .pre_handler = as_probe_x64_sys_getgid,
  },
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETEGID
  {
    .symbol_name = "__x64_sys_getegid",
    .pre_handler = as_probe_x64_sys_getegid,
  },
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETRESUID
  {
    .symbol_name = "__x64_sys_getresuid",
    .pre_handler = as_probe_x64_sys_getresuid,
  },
#endif
#if AS_HOOK_GETUID_FAMILY && AS_SYM_X64_SYS_GETRESGID
  {
    .symbol_name = "__x64_sys_getresgid",
    .pre_handler = as_probe_x64_sys_getresgid,
  },
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETPID
  {
    .symbol_name = "__x64_sys_getpid",
    .pre_handler = as_probe_x64_sys_getpid,
  },
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETPPID
  {
    .symbol_name = "__x64_sys_getppid",
    .pre_handler = as_probe_x64_sys_getppid,
  },
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETTID
  {
    .symbol_name = "__x64_sys_gettid",
    .pre_handler = as_probe_x64_sys_gettid,
  },
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETPGID
  {
    .symbol_name = "__x64_sys_getpgid",
    .pre_handler = as_probe_x64_sys_getpgid,
  },
#endif
#if AS_HOOK_GETPID_FAMILY && AS_SYM_X64_SYS_GETSID
  {
    .symbol_name = "__x64_sys_getsid",
    .pre_handler = as_probe_x64_sys_getsid,
  },
#endif
};

static int as_num_probes = ARRAY_SIZE(as_kprobes);

/* ── END KPROBE DECLARATIONS ────────────────────────────────────────────── */

/* ── INIT/EXIT ──────────────────────────────────────────────────────────── */

static int __init allseer_init(void) {
  int ret, i;

  // registering /proc/all_seer
  as_all_seer_entry = proc_create("all_seer", 0400, NULL, &as_all_seer_ops);
  if (!as_all_seer_entry) {
    pr_err("engine: failed to create /proc/all_seer\n");
    proc_remove(as_all_seer_entry);

    return -ENOMEM;
  }

  // registering all kprobe hooks
  for (i = 0; i < as_num_probes; i++) {
    ret = register_kprobe(&as_kprobes[i]);
    if (ret < 0) {
      pr_err("engine: register_kprobe failed for %s (%d)\n",
             as_kprobes[i].symbol_name, ret);

      /* Unwind already-registered probes */
      while (--i >= 0)
        unregister_kprobe(&as_kprobes[i]);

      proc_remove(as_all_seer_entry);
      return ret;
    }
  }

#if AS_HOOK_EXECVE
  {
    struct {
      const char *symbol;
      kprobe_pre_handler_t handler;
    } execve_candidates[] = {
      {.symbol = "__x64_sys_execve", .handler = as_probe_x64_sys_execve},
      {.symbol = "__x64_sys_execveat", .handler = as_probe_x64_sys_execveat},
        {.symbol = "do_execveat_common", .handler = as_probe_execveat_common},
      {.symbol = "do_execveat_common.isra.0", .handler = as_probe_execveat_common},
        {.symbol = "do_execve", .handler = as_probe_execve},
    };
    int j;

    as_execve_probe_registered = false;
    as_execve_probe_symbol = NULL;

    for (j = 0; j < ARRAY_SIZE(execve_candidates); j++) {
      as_execve_probe.symbol_name = execve_candidates[j].symbol;
      as_execve_probe.pre_handler = execve_candidates[j].handler;
      as_execve_probe.post_handler = NULL;

      ret = register_kprobe(&as_execve_probe);
      if (ret == 0) {
        as_execve_probe_registered = true;
        as_execve_probe_symbol = execve_candidates[j].symbol;
        break;
      }
    }

    if (as_execve_probe_registered)
      pr_info("engine: execve hook registered on %s\n", as_execve_probe_symbol);
    else
      pr_warn("engine: execve hook unavailable; continuing without execve capture\n");
  }
#endif

  // mark module as ready
  as_clear_owner_lease();

  atomic_set(&as_ready, 1);

    pr_info("engine: loaded (%d hook(s) active)\n",
      as_num_probes + (as_execve_probe_registered ? 1 : 0));

  return 0;
}

static void __exit allseer_exit(void) {
  int i;

  /*
   * Clear as_ready BEFORE unregistering kprobes so that any hook
   * firing during the unregister window is a guaranteed no-op.
   */
  atomic_set(&as_ready, 0);

  // unregistering kprobe hooks
  for (i = 0; i < as_num_probes; i++)
    unregister_kprobe(&as_kprobes[i]);

#if AS_HOOK_EXECVE
  if (as_execve_probe_registered)
    unregister_kprobe(&as_execve_probe);
#endif

  // unregistering procfs entries
  proc_remove(as_all_seer_entry);

  pr_info("engine: unloaded\n");
}

module_init(allseer_init);
module_exit(allseer_exit);

/* ── END INIT/EXIT ──────────────────────────────────────────────────────── */
