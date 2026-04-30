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

MODULE_LICENSE("GPL");
MODULE_AUTHOR("IgenuineIntel");
MODULE_DESCRIPTION("Bergamot: System Behavior Monitor: Allseer");
MODULE_VERSION("0.1");

/* ── kfifo ring buffer ───────────────────────────────────────────────── */
/* Holds up to 4096 events before older ones are overwritten.            */
#define AS_FIFO_SIZE 4096

static DEFINE_KFIFO(as_fifo, struct as_event, AS_FIFO_SIZE);
static DEFINE_SPINLOCK(as_fifo_lock);

/*
 * Shared guard flags referenced by hooks.c as extern symbols:
 *   - as_ready: set only after init completes and probes are registered
 *   - as_collecting: reserved for future runtime gating; enabled by default
 */
atomic_t as_ready = ATOMIC_INIT(0);
atomic_t as_collecting = ATOMIC_INIT(1);

/* ── Owner lease state ───────────────────────────────────────────────── */
/*
 * The first successful opener of /proc/all_seer claims a lease keyed by its
 * parent process identity. Any later process with the same PPID and parent
 * start time is treated as part of the same owner scope.
 *
 * The lease is sticky until the module is unloaded or reloaded. All other
 * callers see -ENOENT ("file disappears" semantics).
 */
static DEFINE_MUTEX(as_owner_lock);
static pid_t as_owner_ppid;
static u64 as_owner_parent_start_time;

static void as_clear_owner_lease(void) {
  mutex_lock(&as_owner_lock);
  as_owner_ppid = 0;
  as_owner_parent_start_time = 0;
  mutex_unlock(&as_owner_lock);
}

static bool as_current_parent_identity(pid_t *ppid, u64 *parent_start_time) {
  struct task_struct *parent;

  rcu_read_lock();
  parent = rcu_dereference(current->real_parent);
  if (!parent) {
    rcu_read_unlock();
    *ppid = 0;
    *parent_start_time = 0;
    return false;
  }

  *ppid = task_tgid_nr(parent);
  *parent_start_time = (u64)parent->group_leader->start_time;
  rcu_read_unlock();

  return *ppid > 0 && *parent_start_time != 0;
}

static bool as_current_is_owner(void) {
  pid_t my_ppid;
  u64 my_parent_start_time;
  bool authorized;

  if (!as_current_parent_identity(&my_ppid, &my_parent_start_time))
    return false;

  mutex_lock(&as_owner_lock);
  authorized = as_owner_ppid != 0 && as_owner_ppid == my_ppid &&
               as_owner_parent_start_time == my_parent_start_time;
  mutex_unlock(&as_owner_lock);

  return authorized;
}

static bool as_claim_owner_if_unset(void) {
  pid_t my_ppid;
  u64 my_parent_start_time;
  bool claimed = false;
  bool authorized;

  if (!as_current_parent_identity(&my_ppid, &my_parent_start_time))
    return false;

  mutex_lock(&as_owner_lock);
  if (as_owner_ppid == 0) {
    as_owner_ppid = my_ppid;
    as_owner_parent_start_time = my_parent_start_time;
    claimed = true;
  }

  authorized = as_owner_ppid == my_ppid &&
               as_owner_parent_start_time == my_parent_start_time;
  mutex_unlock(&as_owner_lock);

  if (claimed) {
    pr_info("all_seer: owner lease claimed ppid=%d parent_start=%llu comm=%s\n",
            my_ppid, (unsigned long long)my_parent_start_time, current->comm);
  }

  return authorized;
}

/* ── as_emit_event — called from hooks.c ────────────────────────────── */
void as_emit_event(enum as_event_type type, const char *arg) {
  struct as_event ev;
  unsigned long flags;

  /* Drop events until module init completes and collection is active. */
  if (!atomic_read(&as_ready) || !atomic_read(&as_collecting))
    return;

#if AS_DEBUG_IGNORE_COMM
  /* Debug-only name filter from hooks_config.h. */
  if (strcmp(current->comm, AS_DEBUG_IGNORE_COMM_NAME) == 0)
    return;
#endif

  ev.timestamp_ns = ktime_get_ns();
  ev.pid = current->pid;
  ev.ppid = task_ppid_nr(current);
  ev.uid = from_kuid_munged(&init_user_ns, current_uid());
  ev.type = type;
  get_task_comm(ev.comm, current);
  strncpy(ev.arg, arg ? arg : "", sizeof(ev.arg) - 1);
  ev.arg[sizeof(ev.arg) - 1] = '\0';

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
EXPORT_SYMBOL(as_emit_event);

/* ── PROCFS INTERFACE ───────────────────────────────────────────────────── */

static const char *const as_type_str[] = {
    [AS_TYPE_OPEN] = "open",
    [AS_TYPE_FORK] = "fork",
    [AS_TYPE_EXEC] = "exec",
    [AS_TYPE_CONNECT] = "connect",
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

/* ─── /proc/all_seer ─── */

static ssize_t as_all_seer_read(struct file *file, char __user *ubuf,
                                size_t count, loff_t *ppos) {
  /* Event handler for when `/proc/all_seer` is read.
   *
   * Custom read implementation: for the authorized owner we drain and
   * format the kfifo directly into the user buffer. Non-owners get 0
   * bytes, identical to an empty file.
   *
   * Procfs line contract emitted to Under-Seer:
   *   <ts_ns> <pid> <ppid> <uid> <type> <comm> <arg>\n
   *
   * Under-Seer maps these fields into JSON keys:
  *   ts_s, ts_ms, pid, ppid, uid, type, comm, arg
   */

  struct as_event ev;
  char line[384];
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

    len = snprintf(line, sizeof(line), "%llu %d %d %u %s %s %s\n",
                   (unsigned long long)ev.timestamp_ns, ev.pid, ev.ppid, ev.uid,
                   (ev.type < ARRAY_SIZE(as_type_str) && as_type_str[ev.type])
                       ? as_type_str[ev.type]
                       : "unknown",
                   ev.comm, ev.arg);

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
    .proc_read = as_all_seer_read,
    .proc_lseek = noop_llseek,
};
static struct proc_dir_entry *as_all_seer_entry;

/* ── KPROBE DECLARATIONS ────────────────────────────────────────────────── */

#if AS_HOOK_OPEN
extern int as_probe_openat2(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_FORK
extern int as_probe_clone(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_EXEC
extern int as_probe_execve(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_CONNECT
extern int as_probe_connect(struct kprobe *p, struct pt_regs *regs);
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
#if AS_HOOK_EXEC
    {
        .symbol_name = "__x64_sys_execveat",
        .pre_handler = as_probe_execve,
    },
#endif
#if AS_HOOK_CONNECT
    {
        .symbol_name = "tcp_connect",
        .pre_handler = as_probe_connect,
    },
#endif
};

static int as_num_probes = ARRAY_SIZE(as_kprobes);

/* ── INIT/EXIT ──────────────────────────────────────────────────────────── */

static int __init allseer_init(void) {
  int ret, i;

  // registering /proc/all_seer
  as_all_seer_entry = proc_create("all_seer", 0400, NULL, &as_all_seer_ops);
  if (!as_all_seer_entry) {
    pr_err("all_seer: failed to create /proc/all_seer\n");
    proc_remove(as_all_seer_entry);

    return -ENOMEM;
  }

  // registering all kprobe hooks
  for (i = 0; i < as_num_probes; i++) {
    ret = register_kprobe(&as_kprobes[i]);
    if (ret < 0) {
      pr_err("all_seer: register_kprobe failed for %s (%d)\n",
             as_kprobes[i].symbol_name, ret);

      /* Unwind already-registered probes */
      while (--i >= 0)
        unregister_kprobe(&as_kprobes[i]);

      proc_remove(as_all_seer_entry);
      return ret;
    }
  }

  // mark module as ready
  as_clear_owner_lease();

  atomic_set(&as_ready, 1);

  pr_info("all_seer: loaded (%d hook(s) active)\n", as_num_probes);

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

  // unregistering procfs entries
  proc_remove(as_all_seer_entry);

  pr_info("all_seer: unloaded\n");
}

module_init(allseer_init);
module_exit(allseer_exit);
