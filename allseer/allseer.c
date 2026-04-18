/* allseer.c — All-Seer kernel module core
 *
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
 *   - /proc/all_seer_ctl write interface (start / stop / reset)
 *   - kprobe registration / deregistration (entries #if-gated by hooks_config.h)
 *
 * /proc/all_seer_ctl commands (write a newline-terminated string):
 *   stop   — suspend event collection (hooks still installed, emit is no-op)
 *   start  — resume event collection
 *   reset  — drain the kfifo and release the current reader lock
 *   status — (read) returns "running\n" or "stopped\n"
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/kfifo.h>
#include <linux/kprobes.h>
#include <linux/spinlock.h>
#include <linux/sched.h>
#include <linux/atomic.h>
#include <linux/ktime.h>
#include <linux/pid.h>
#include <linux/rcupdate.h>
#include <linux/fs.h>

#include "all_seer.h"
#include "hooks_config.h"

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Bergamot");
MODULE_DESCRIPTION("All-Seer: syscall event stream via /proc/all_seer");
MODULE_VERSION("1.0");

/* ── kfifo ring buffer ───────────────────────────────────────────────── */
/* Holds up to 4096 events before older ones are overwritten.            */
#define AS_FIFO_SIZE  4096

static DEFINE_KFIFO(as_fifo, struct as_event, AS_FIFO_SIZE);
static DEFINE_SPINLOCK(as_fifo_lock);

/*
 * Shared guard flags referenced by hooks.c as extern symbols:
 *   - as_ready: set only after init completes and probes are registered
 *   - as_collecting: toggled by /proc/all_seer_ctl start/stop commands
 */
atomic_t as_ready      = ATOMIC_INIT(0);
atomic_t as_collecting = ATOMIC_INIT(1);

/* ── Exclusive reader state ──────────────────────────────────────────── */
/* Only the first process to open /proc/all_seer becomes the owner.      */
/* We store both PID and task start_time to guard against PID reuse.     */

static atomic_t  as_owner_pid        = ATOMIC_INIT(0);
static atomic64_t as_owner_start_time = ATOMIC64_INIT(0);

/* Returns true if 'current' is the established owner. */
static inline bool as_is_owner(void)
{
    return (atomic_read(&as_owner_pid) == (int)current->pid) &&
           (atomic64_read(&as_owner_start_time) == (s64)current->start_time);
}

/* Try to claim ownership atomically.  Returns true if we won the race. */
static bool as_try_claim(void)
{
    int zero = 0;
    if (!atomic_cmpxchg(&as_owner_pid, 0, (int)current->pid)) {
        atomic64_set(&as_owner_start_time, (s64)current->start_time);
        pr_info("all_seer: owner claimed by pid=%d comm=%s\n",
                current->pid, current->comm);
        return true;
    }
    return false;
}

/* Release ownership (called from .release when owner closes the file). */
static void as_release_owner(void)
{
    pr_info("all_seer: owner released by pid=%d\n", current->pid);
    atomic64_set(&as_owner_start_time, 0);
    atomic_set(&as_owner_pid, 0);
}

/* ── as_emit_event — called from hooks.c ────────────────────────────── */
void as_emit_event(u8 type, const char *arg)
{
    struct as_event ev;
    unsigned long flags;

    /* Drop events until module init completes and collection is active. */
    if (!atomic_read(&as_ready) || !atomic_read(&as_collecting))
        return;

    ev.timestamp_ns = ktime_get_ns();
    ev.pid          = current->pid;
    ev.ppid         = task_ppid_nr(current);
    ev.uid          = from_kuid_munged(&init_user_ns,
                                        current_uid());
    ev.type         = type;
    get_task_comm(ev.comm, current);
    strncpy(ev.arg, arg ? arg : "", sizeof(ev.arg) - 1);
    ev.arg[sizeof(ev.arg) - 1] = '\0';

    spin_lock_irqsave(&as_fifo_lock, flags);
    /* If the fifo is full, drop the oldest entry to make room. */
    if (kfifo_is_full(&as_fifo)) {
        struct as_event discard;
        kfifo_get(&as_fifo, &discard);
    }
    kfifo_put(&as_fifo, ev);
    spin_unlock_irqrestore(&as_fifo_lock, flags);
}
EXPORT_SYMBOL(as_emit_event);

/* ── seq_file / procfs interface ─────────────────────────────────────── */

static const char * const as_type_str[] = {
    [AS_TYPE_OPEN]    = "open",
    [AS_TYPE_FORK]    = "fork",
    [AS_TYPE_EXEC]    = "exec",
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

/* Private data attached to each open file handle. */
struct as_file_priv {
    bool authorized;
};

static int as_proc_open(struct inode *inode, struct file *file)
{
    struct as_file_priv *priv;

    priv = kzalloc(sizeof(*priv), GFP_KERNEL);
    if (!priv)
        return -ENOMEM;

    /*
     * If no owner is set, try to claim ownership.
     * If an owner is already set but it's us, we're allowed (re-open).
     * Anyone else gets an unauthorized handle — their reads return empty.
     */
    if (atomic_read(&as_owner_pid) == 0) {
        as_try_claim();
        priv->authorized = true;
    } else if (as_is_owner()) {
        priv->authorized = true;
    } else {
        priv->authorized = false;
        /* Do NOT return an error — caller must not know an owner exists. */
    }

    file->private_data = priv;
    return 0;
}

static int as_proc_release(struct inode *inode, struct file *file)
{
    struct as_file_priv *priv = file->private_data;

    if (priv) {
        if (priv->authorized && as_is_owner())
            as_release_owner();
        kfree(priv);
        file->private_data = NULL;
    }
    return 0;
}

/*
 * Custom read implementation: for the authorized owner we drain and
 * format the kfifo directly into the user buffer. Non-owners get 0
 * bytes, identical to an empty file.
 *
 * Procfs line contract emitted to Under-Seer:
 *   <ts_ns> <pid> <ppid> <uid> <type> <comm> <arg>\n
 *
 * Under-Seer maps these fields into JSON keys:
 *   ts, pid, ppid, uid, type, comm, arg
 */
static ssize_t as_proc_read(struct file *file, char __user *ubuf,
                             size_t count, loff_t *ppos)
{
    struct as_file_priv *priv = file->private_data;
    struct as_event ev;
    char line[384];
    ssize_t total = 0;
    unsigned long flags;

    if (!priv || !priv->authorized)
        return 0;

    while (count > 0) {
        int len;

        spin_lock_irqsave(&as_fifo_lock, flags);
        if (!kfifo_get(&as_fifo, &ev)) {
            spin_unlock_irqrestore(&as_fifo_lock, flags);
            break;
        }
        spin_unlock_irqrestore(&as_fifo_lock, flags);

        len = snprintf(line, sizeof(line),
                       "%llu %d %d %u %s %s %s\n",
                       (unsigned long long)ev.timestamp_ns,
                       ev.pid, ev.ppid, ev.uid,
                       (ev.type < ARRAY_SIZE(as_type_str) &&
                        as_type_str[ev.type]) ? as_type_str[ev.type] : "unknown",
                       ev.comm, ev.arg);

        if (len <= 0)
            continue;

        if ((size_t)len > count)
            break;   /* not enough space in caller's buffer — stop for now */

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

static const struct proc_ops as_proc_ops = {
    .proc_open    = as_proc_open,
    .proc_read    = as_proc_read,
    .proc_release = as_proc_release,
    .proc_lseek   = no_llseek,
};

/* ── /proc/all_seer_ctl — control interface ──────────────────────────── */

static ssize_t as_ctl_write(struct file *file, const char __user *ubuf,
                             size_t count, loff_t *ppos)
{
    char cmd[32];
    size_t len = min(count, sizeof(cmd) - 1);
    unsigned long flags;

    if (copy_from_user(cmd, ubuf, len))
        return -EFAULT;
    cmd[len] = '\0';

    /* Strip trailing newline / whitespace */
    while (len > 0 && (cmd[len-1] == '\n' || cmd[len-1] == '\r' ||
                       cmd[len-1] == ' '))
        cmd[--len] = '\0';

    if (strcmp(cmd, "stop") == 0) {
        atomic_set(&as_collecting, 0);
        pr_info("all_seer: collection stopped via ctl\n");

    } else if (strcmp(cmd, "start") == 0) {
        atomic_set(&as_collecting, 1);
        pr_info("all_seer: collection started via ctl\n");

    } else if (strcmp(cmd, "reset") == 0) {
        /* Drain the fifo */
        spin_lock_irqsave(&as_fifo_lock, flags);
        kfifo_reset(&as_fifo);
        spin_unlock_irqrestore(&as_fifo_lock, flags);
        /* Release reader lock so Under-Seer can re-claim after restart */
        atomic64_set(&as_owner_start_time, 0);
        atomic_set(&as_owner_pid, 0);
        pr_info("all_seer: buffer reset and reader lock cleared via ctl\n");

    } else {
        pr_warn("all_seer: unknown ctl command: %s\n", cmd);
        return -EINVAL;
    }

    return (ssize_t)count;
}

static ssize_t as_ctl_read(struct file *file, char __user *ubuf,
                            size_t count, loff_t *ppos)
{
    const char *status = atomic_read(&as_collecting) ? "running\n" : "stopped\n";
    size_t len = strlen(status);

    if (*ppos >= (loff_t)len)
        return 0;

    len -= *ppos;
    if (len > count)
        len = count;

    if (copy_to_user(ubuf, status + *ppos, len))
        return -EFAULT;

    *ppos += len;
    return (ssize_t)len;
}

static const struct proc_ops as_ctl_ops = {
    .proc_read    = as_ctl_read,
    .proc_write   = as_ctl_write,
    .proc_lseek   = no_llseek,
};

static struct proc_dir_entry *as_ctl_entry;

/* ── kprobe declarations (handlers defined in hooks.c) ──────────────── */

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
        .symbol_name = "do_execveat_common",
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
static struct proc_dir_entry *as_proc_entry;

/* ── Module init / exit ──────────────────────────────────────────────── */

static int __init allseer_init(void)
{
    int ret, i;

    as_proc_entry = proc_create("all_seer", 0400, NULL, &as_proc_ops);
    if (!as_proc_entry) {
        pr_err("all_seer: failed to create /proc/all_seer\n");
        return -ENOMEM;
    }

    as_ctl_entry = proc_create("all_seer_ctl", 0600, NULL, &as_ctl_ops);
    if (!as_ctl_entry) {
        pr_err("all_seer: failed to create /proc/all_seer_ctl\n");
        proc_remove(as_proc_entry);
        return -ENOMEM;
    }

    for (i = 0; i < as_num_probes; i++) {
        ret = register_kprobe(&as_kprobes[i]);
        if (ret < 0) {
            pr_err("all_seer: register_kprobe failed for %s (%d)\n",
                   as_kprobes[i].symbol_name, ret);
            /* Unwind already-registered probes */
            while (--i >= 0)
                unregister_kprobe(&as_kprobes[i]);
            proc_remove(as_ctl_entry);
            proc_remove(as_proc_entry);
            return ret;
        }
    }

    /*
     * Mark the module as ready AFTER all kprobes are registered.
     * Hooks will silently drop events until this flag is set.
     */
    atomic_set(&as_ready, 1);

    pr_info("all_seer: loaded (%d hook(s) active)\n", as_num_probes);
    return 0;
}

static void __exit allseer_exit(void)
{
    int i;

    /*
     * Clear as_ready BEFORE unregistering kprobes so that any hook
     * firing during the unregister window is a guaranteed no-op.
     */
    atomic_set(&as_ready, 0);

    for (i = 0; i < as_num_probes; i++)
        unregister_kprobe(&as_kprobes[i]);

    proc_remove(as_ctl_entry);
    proc_remove(as_proc_entry);
    pr_info("all_seer: unloaded\n");
}

module_init(allseer_init);
module_exit(allseer_exit);
