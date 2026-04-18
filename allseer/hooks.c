/* hooks.c — kprobe pre-handler implementations for All-Seer
 *
 * Boundary flow:
 *   1) Kernel syscall path triggers a kprobe handler in this file.
 *   2) Handler checks shared guards (as_ready, as_collecting).
 *   3) Handler calls as_emit_event(type, arg).
 *   4) allseer.c pushes event to kfifo.
 *   5) Under-Seer drains kfifo entries by reading /proc/all_seer.
 *
 * This file owns syscall-argument extraction only.
 * Buffering, ownership checks, procfs formatting, and control commands
 * live in allseer.c.
 *
 * Adding a new hook:
 *   1. Write a new as_probe_<name>() pre-handler here.
 *   2. Add a matching #define AS_HOOK_<NAME> flag in hooks_config.h.
 *   3. Add a kprobe entry in the allseer.c kprobes[] array, guarded by
 *      #if AS_HOOK_<NAME>.
 *
 * Guards at the top of each section mirror the flags in hooks_config.h
 * so that the compiler sees no dead code when a hook is disabled.
 */

#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/sched.h>
#include <linux/fs.h>
#include <linux/net.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/inet.h>
#include <linux/uaccess.h>
#include <net/sock.h>

#include "all_seer.h"
#include "hooks_config.h"

/*
 * Guards declared in allseer.c.  Each handler checks them before doing
 * any work so that probe firings during module init/exit are no-ops.
 */
extern atomic_t as_ready;
extern atomic_t as_collecting;

#define AS_HOOK_GUARD() \
    do { if (!atomic_read(&as_ready) || !atomic_read(&as_collecting)) return 0; } while (0)

/* ═══════════════════════════════════════════════════════════════════════
 * HOOK: open  (do_sys_openat2)
 * Captures every file-open / file-create syscall.
 * Argument layout (x86-64 calling convention via pt_regs):
 *   rdi = int dfd, rsi = const char __user *filename,
 *   rdx = struct open_how *how
 * ═══════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_OPEN
int as_probe_openat2(struct kprobe *p, struct pt_regs *regs)
{
    const char __user *upath = (const char __user *)regs->si;
    char path[256];
    long ret;

    AS_HOOK_GUARD();

    if (!upath)
        return 0;

    ret = strncpy_from_user(path, upath, sizeof(path) - 1);
    if (ret < 0)
        return 0;
    path[ret] = '\0';

    as_emit_event(AS_TYPE_OPEN, path);
    return 0;
}
#endif /* AS_HOOK_OPEN */


/* ═══════════════════════════════════════════════════════════════════════
 * HOOK: fork  (kernel_clone)
 * Captures fork()/clone()/vfork() — fired on entry so we record the
 * parent's identity; the child PID is not yet allocated at this point.
 * We emit the parent PID in the event; ppid is the parent's own ppid.
 * Argument layout:
 *   rdi = struct kernel_clone_args *args
 * ═══════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_FORK
int as_probe_clone(struct kprobe *p, struct pt_regs *regs)
{
    char comm[TASK_COMM_LEN];

    AS_HOOK_GUARD();

    get_task_comm(comm, current);
    as_emit_event(AS_TYPE_FORK, comm);
    return 0;
}
#endif /* AS_HOOK_FORK */


/* ═══════════════════════════════════════════════════════════════════════
 * HOOK: exec  (do_execveat_common)
 * Captures execve / execveat.  We extract argv[0] from the filename
 * argument which holds the path of the image being loaded.
 * Argument layout:
 *   rdi = int fd, rsi = struct filename *filename,
 *   rdx = struct user_arg_ptr argv, rcx = struct user_arg_ptr envp,
 *   r8  = int flags
 * ═══════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_EXEC
int as_probe_execve(struct kprobe *p, struct pt_regs *regs)
{
    /*
     * regs->si holds a 'struct filename *'.  The first field of that
     * struct is 'const char *name', pointing to the resolved path.
     * We dereference it safely with get_kernel_nofault.
     */
    struct filename *fn = (struct filename *)(regs->si);
    const char *kpath = NULL;

    AS_HOOK_GUARD();

    if (!fn)
        return 0;

    if (get_kernel_nofault(kpath, &fn->name) || !kpath)
        return 0;

    as_emit_event(AS_TYPE_EXEC, kpath);
    return 0;
}
#endif /* AS_HOOK_EXEC */


/* ═══════════════════════════════════════════════════════════════════════
 * HOOK: connect  (tcp_connect)
 * Captures outbound TCP connections.  tcp_connect is called after the
 * socket has been bound; the destination address is in sk->__sk_common.
 * Argument layout:
 *   rdi = struct sock *sk, rsi = struct sk_buff *skb (ignored here)
 * ═══════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_CONNECT
int as_probe_connect(struct kprobe *p, struct pt_regs *regs)
{
    struct sock *sk = (struct sock *)(regs->di);
    char arg[64];
    u16  dport;
    u16  family;

    AS_HOOK_GUARD();

    if (!sk)
        return 0;

    if (get_kernel_nofault(family, &sk->__sk_common.skc_family))
        return 0;

    if (family == AF_INET) {
        __be32 daddr;
        u8 a, b, c, d;

        if (get_kernel_nofault(daddr, &sk->__sk_common.skc_daddr))
            return 0;
        if (get_kernel_nofault(dport, &sk->__sk_common.skc_dport))
            return 0;

        dport = ntohs(dport);
        a = (daddr)       & 0xff;
        b = (daddr >> 8)  & 0xff;
        c = (daddr >> 16) & 0xff;
        d = (daddr >> 24) & 0xff;
        snprintf(arg, sizeof(arg), "%u.%u.%u.%u:%u", a, b, c, d, dport);

    } else if (family == AF_INET6) {
        struct in6_addr daddr6;
        char ip6str[INET6_ADDRSTRLEN];

        if (get_kernel_nofault(daddr6, &sk->__sk_common.skc_v6_daddr))
            return 0;
        if (get_kernel_nofault(dport, &sk->__sk_common.skc_dport))
            return 0;

        dport = ntohs(dport);
        snprintf(ip6str, sizeof(ip6str), "%pI6c", &daddr6);
        snprintf(arg, sizeof(arg), "[%s]:%u", ip6str, dport);

    } else {
        return 0;  /* not a TCP/IP socket we care about */
    }

    as_emit_event(AS_TYPE_CONNECT, arg);
    return 0;
}
#endif /* AS_HOOK_CONNECT */
