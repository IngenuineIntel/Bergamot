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

/* ── Owner lease state ───────────────────────────────────────────────── */
/*
 * Ownership is explicitly claimed through /proc/all_seer_ctl with:
 *   claim_owner_tgid <tgid>
 *
 * Once claimed, only that TGID may open/read /proc/all_seer.  All other
 * callers see -ENOENT ("file disappears" semantics).
 */
static atomic_t   as_owner_tgid        = ATOMIC_INIT(0);
static atomic64_t as_owner_start_time  = ATOMIC64_INIT(0);

static void as_clear_owner_lease(void)
{
    atomic64_set(&as_owner_start_time, 0);
    atomic_set(&as_owner_tgid, 0);
}

static bool as_current_is_owner(void)
{
    pid_t owner_tgid = atomic_read(&as_owner_tgid);
    u64 owner_start = (u64)atomic64_read(&as_owner_start_time);
    u64 my_start = (u64)current->group_leader->start_time;

    return owner_tgid != 0 &&
           owner_tgid == current->tgid &&
           owner_start == my_start;
}

/* ── TGID filter state ───────────────────────────────────────────────── */
#define AS_TGID_FILTER_MAX 64

struct as_tgid_filter {
    pid_t tgid;
    u64 leader_start_time;
};

static struct as_tgid_filter as_tgid_filters[AS_TGID_FILTER_MAX];
static int as_tgid_filter_count;
static DEFINE_SPINLOCK(as_tgid_filter_lock);
static atomic64_t as_dropped_by_filter = ATOMIC64_INIT(0);

static bool as_tgid_is_filtered(void)
{
    int i;
    bool matched = false;
    u64 cur_start = (u64)current->group_leader->start_time;

    spin_lock(&as_tgid_filter_lock);
    for (i = 0; i < as_tgid_filter_count; i++) {
        if (as_tgid_filters[i].tgid == current->tgid &&
            as_tgid_filters[i].leader_start_time == cur_start) {
            matched = true;
            break;
        }
    }
    spin_unlock(&as_tgid_filter_lock);

    return matched;
}

static int as_filter_add_tgid(pid_t tgid)
{
    int i;

    /* Keep filter registration self-scoped for debug/agent use. */
    if (tgid != current->tgid)
        return -EPERM;

    spin_lock(&as_tgid_filter_lock);
    for (i = 0; i < as_tgid_filter_count; i++) {
        if (as_tgid_filters[i].tgid == tgid &&
            as_tgid_filters[i].leader_start_time ==
                (u64)current->group_leader->start_time) {
            spin_unlock(&as_tgid_filter_lock);
            return 0;
        }
    }

    if (as_tgid_filter_count >= AS_TGID_FILTER_MAX) {
        spin_unlock(&as_tgid_filter_lock);
        return -ENOSPC;
    }

    as_tgid_filters[as_tgid_filter_count].tgid = tgid;
    as_tgid_filters[as_tgid_filter_count].leader_start_time =
        (u64)current->group_leader->start_time;
    as_tgid_filter_count++;
    spin_unlock(&as_tgid_filter_lock);

    return 0;
}

static int as_filter_del_tgid(pid_t tgid)
{
    int i, j;
    int removed = 0;

    spin_lock(&as_tgid_filter_lock);
    for (i = 0; i < as_tgid_filter_count; ) {
        if (as_tgid_filters[i].tgid == tgid) {
            for (j = i; j < as_tgid_filter_count - 1; j++)
                as_tgid_filters[j] = as_tgid_filters[j + 1];
            as_tgid_filter_count--;
            removed++;
            continue;
        }
        i++;
    }
    spin_unlock(&as_tgid_filter_lock);

    return removed > 0 ? 0 : -ENOENT;
}

static void as_filter_clear(void)
{
    spin_lock(&as_tgid_filter_lock);
    as_tgid_filter_count = 0;
    spin_unlock(&as_tgid_filter_lock);
}

/* ── as_emit_event — called from hooks.c ────────────────────────────── */
void as_emit_event(u8 type, const char *arg)
{
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

    /* Suppress events from explicitly ignored task groups. */
    if (as_tgid_is_filtered()) {
        atomic64_inc(&as_dropped_by_filter);
        return;
    }

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
        bool dropped = kfifo_get(&as_fifo, &discard);
        (void)dropped;
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
     * Strict owner lease mode:
     *   - only claimed owner TGID can open/read
     *   - everyone else sees ENOENT
     */
    if (as_current_is_owner()) {
        priv->authorized = true;
    } else {
        kfree(priv);
        return -ENOENT;
    }

    file->private_data = priv;
    return 0;
}

static int as_proc_release(struct inode *inode, struct file *file)
{
    struct as_file_priv *priv = file->private_data;

    if (priv) {
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
        return -ENOENT;

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
    .proc_lseek   = noop_llseek,
};

/* ── /proc/all_seer_ctl — control interface ──────────────────────────── */

static ssize_t as_ctl_write(struct file *file, const char __user *ubuf,
                             size_t count, loff_t *ppos)
{
    char cmd[32];
    size_t len = min(count, sizeof(cmd) - 1);
    unsigned long flags;
    int tgid;

    if (copy_from_user(cmd, ubuf, len))
        return -EFAULT;
    cmd[len] = '\0';

    /* Strip trailing newline / whitespace */
    while (len > 0 && (cmd[len-1] == '\n' || cmd[len-1] == '\r' ||
                       cmd[len-1] == ' '))
        cmd[--len] = '\0';

    if (sscanf(cmd, "claim_owner_tgid %d", &tgid) == 1) {
        u64 start_time = 0;
        pid_t old_owner;

        if (tgid <= 0)
            return -EINVAL;

        /* Only self-claims are accepted. */
        if (tgid != current->tgid)
            return -EPERM;

        old_owner = atomic_read(&as_owner_tgid);
        if (old_owner != 0 && old_owner != tgid)
            pr_info("all_seer: owner lease takeover old_tgid=%d new_tgid=%d\n",
                    old_owner, tgid);

        start_time = (u64)current->group_leader->start_time;

        atomic_set(&as_owner_tgid, tgid);
        atomic64_set(&as_owner_start_time, (s64)start_time);
        pr_info("all_seer: owner lease claimed tgid=%d comm=%s\n",
                tgid, current->comm);

    } else if (sscanf(cmd, "filter_add_tgid %d", &tgid) == 1) {
        int ret;

        if (tgid <= 0)
            return -EINVAL;

        ret = as_filter_add_tgid((pid_t)tgid);
        if (ret)
            return ret;

        pr_info("all_seer: filter added tgid=%d\n", tgid);

    } else if (sscanf(cmd, "filter_del_tgid %d", &tgid) == 1) {
        int ret;

        if (tgid <= 0)
            return -EINVAL;

        ret = as_filter_del_tgid((pid_t)tgid);
        if (ret)
            return ret;

        pr_info("all_seer: filter removed tgid=%d\n", tgid);

    } else if (strcmp(cmd, "filter_clear") == 0) {
        as_filter_clear();
        pr_info("all_seer: all filters cleared\n");

    } else if (strcmp(cmd, "stop") == 0) {
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
        /* Release owner lease so a new Under-Seer can claim after reset. */
        as_clear_owner_lease();
        pr_info("all_seer: buffer reset and owner lease cleared via ctl\n");

    } else {
        pr_warn("all_seer: unknown ctl command: %s\n", cmd);
        return -EINVAL;
    }

    return (ssize_t)count;
}

static ssize_t as_ctl_read(struct file *file, char __user *ubuf,
                            size_t count, loff_t *ppos)
{
    char status[1024];
    size_t len;
    int i;
    ssize_t written;
    pid_t owner_tgid;
    u64 owner_start;

    owner_tgid = atomic_read(&as_owner_tgid);
    owner_start = (u64)atomic64_read(&as_owner_start_time);

    written = scnprintf(status, sizeof(status),
                        "%s\nowner_tgid=%d owner_start=%llu\n"
                        "filters=%d dropped_by_filter=%llu\n",
                        atomic_read(&as_collecting) ? "running" : "stopped",
                        owner_tgid,
                        (unsigned long long)owner_start,
                        as_tgid_filter_count,
                        (unsigned long long)atomic64_read(&as_dropped_by_filter));

    spin_lock(&as_tgid_filter_lock);
    for (i = 0; i < as_tgid_filter_count && written < sizeof(status); i++) {
        written += scnprintf(status + written, sizeof(status) - written,
                             "filter[%d]=tgid:%d start:%llu\n",
                             i,
                             as_tgid_filters[i].tgid,
                             (unsigned long long)as_tgid_filters[i].leader_start_time);
    }
    spin_unlock(&as_tgid_filter_lock);

    len = min_t(size_t, (size_t)written, sizeof(status));

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
    .proc_lseek   = noop_llseek,
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
    as_filter_clear();
    as_clear_owner_lease();
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
