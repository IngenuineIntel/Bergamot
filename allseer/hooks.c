// hooks.c
// kprobe pre-handler implementations for All-Seer
// (c) 2026 IngenuineIntel <roan.rothrock@proton.me>

/*
 * Boundary flow:
 *   1) Kernel syscall path triggers a kprobe handler in this file.
 *   2) Handler checks shared guards (as_ready, as_collecting).
 *   3) Handler calls as_emit_event(type, subtype, arg).
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

#include <linux/fs.h>
#include <linux/binfmts.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/inet.h>
#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/net.h>
#include <linux/sched.h>
#include <linux/uaccess.h>
#include <net/sock.h>

#include "allseer.h"
#include "switches.h"

/*
 * Guards declared in allseer.c.  Each handler checks them before doing
 * any work so that probe firings during module init/exit are no-ops.
 */
extern atomic_t as_ready;
extern atomic_t as_collecting;

#define AS_HOOK_GUARD()                                                        \
  do {                                                                         \
    if (!atomic_read(&as_ready) || !atomic_read(&as_collecting))               \
      return 0;                                                                \
  } while (0)

#if AS_HOOK_OPEN
int as_probe_openat2(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_FORK
int as_probe_clone(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_CONNECT
int as_probe_connect(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_EXECVE
int as_probe_execveat_common(struct kprobe *p, struct pt_regs *regs);
int as_probe_execve(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_execve(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_execveat(struct kprobe *p, struct pt_regs *regs);
#endif

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: open (do_sys_openat2)
 * Captures every file-open/file-create syscall.
 *
 * Argument layout:
 *   rdi = int dfd
 *   rsi = const char __user *filename
 *   rdx = struct open_how *how
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_OPEN
int as_probe_openat2(struct kprobe *p, struct pt_regs *regs) {
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

  as_emit_event(AS_TYPE_OPEN, "none", path);
  return 0;
}
#endif /* AS_HOOK_OPEN */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: fork (kernel_clone)
 * Captures fork/clone/vfork
 *
 * Argument layout:
 *   rdi = struct kernel_clone_args *args
 *
 * Note: The hook is fired on entry so we record the parent's identity; the
 * child PID is not yet allocated at this point. We emit the parent PID in the
 * event; ppid is the parent's own ppid.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_FORK
int as_probe_clone(struct kprobe *p, struct pt_regs *regs) {
  char comm[TASK_COMM_LEN];

  AS_HOOK_GUARD();

  get_task_comm(comm, current);
  as_emit_event(AS_TYPE_FORK, "none", comm);
  return 0;
}
#endif /* AS_HOOK_FORK */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: connect  (tcp_connect)
 * Captures outbound TCP connections (tcp_connect).
 * Argument layout:
 *   rdi = struct sock *sk, rsi = struct sk_buff *skb (ignored here)
 *
 * Note: tcp_connect is called after the socket has been bound; the destination
 * address is in sk->__sk_common.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_CONNECT
int as_probe_connect(struct kprobe *p, struct pt_regs *regs) {
  struct sock *sk = (struct sock *)(regs->di);
  char arg[64];
  u16 dport;
  u16 family;

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
    a = (daddr) & 0xff;
    b = (daddr >> 8) & 0xff;
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
    return 0; /* not a TCP/IP socket we care about */
  }

  as_emit_event(AS_TYPE_CONNECT, "none", arg);
  return 0;
}
#endif /* AS_HOOK_CONNECT */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: execve / execveat
 * Captures executable path + argv payload (bounded/truncated).
 *
 * do_execveat_common argument layout:
 *   rdi = int fd
 *   rsi = struct filename *filename
 *   rdx = struct user_arg_ptr argv
 *
 * do_execve argument layout:
 *   rdi = struct filename *filename
 *   rsi = struct user_arg_ptr argv
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_EXECVE
static void as_format_execve_arg(char *dst, size_t dst_sz,
                                 const char *filename,
                                 const char __user *const __user *argv) {
  int i;
  size_t off = 0;

  if (!dst || dst_sz == 0)
    return;

  off += scnprintf(dst + off, dst_sz - off, "%s", filename ? filename : "");
  if (!argv || off >= dst_sz - 1)
    return;

  off += scnprintf(dst + off, dst_sz - off, " | argv:");
  for (i = 0; i < 32 && off < dst_sz - 1; i++) {
    const char __user *uarg = NULL;
    char arg[80];
    long copied;

    if (get_user(uarg, &argv[i]))
      break;
    if (!uarg)
      break;

    copied = strncpy_from_user(arg, uarg, sizeof(arg) - 1);
    if (copied <= 0)
      break;
    arg[copied] = '\0';

    off += scnprintf(dst + off, dst_sz - off, " %s", arg);

    if (copied >= (long)(sizeof(arg) - 1)) {
      off += scnprintf(dst + off, dst_sz - off, "...");
      break;
    }
  }

  if (off >= dst_sz - 1)
    dst[dst_sz - 2] = '.';
}

int as_probe_execveat_common(struct kprobe *p, struct pt_regs *regs) {
  struct filename *fn = (struct filename *)regs->si;
  const char __user *const __user *argv =
      (const char __user *const __user *)regs->dx;
  char arg[256];

  AS_HOOK_GUARD();

  if (!fn || !fn->name)
    return 0;

  as_format_execve_arg(arg, sizeof(arg), fn->name, argv);
  as_emit_event(AS_TYPE_EXECVE, "none", arg);
  return 0;
}

int as_probe_execve(struct kprobe *p, struct pt_regs *regs) {
  struct filename *fn = (struct filename *)regs->di;
  const char __user *const __user *argv =
      (const char __user *const __user *)regs->si;
  char arg[256];

  AS_HOOK_GUARD();

  if (!fn || !fn->name)
    return 0;

  as_format_execve_arg(arg, sizeof(arg), fn->name, argv);
  as_emit_event(AS_TYPE_EXECVE, "none", arg);
  return 0;
}

int as_probe_x64_sys_execve(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  const char __user *filename;
  const char __user *const __user *argv;
  char path[128];
  char arg[256];
  long ret;

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  filename = (const char __user *)sys_regs->di;
  argv = (const char __user *const __user *)sys_regs->si;

  if (!filename)
    return 0;

  ret = strncpy_from_user(path, filename, sizeof(path) - 1);
  if (ret <= 0)
    return 0;
  path[ret] = '\0';

  as_format_execve_arg(arg, sizeof(arg), path, argv);
  as_emit_event(AS_TYPE_EXECVE, "none", arg);
  return 0;
}

int as_probe_x64_sys_execveat(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  const char __user *filename;
  const char __user *const __user *argv;
  char path[128];
  char arg[256];
  long ret;

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  filename = (const char __user *)sys_regs->si;
  argv = (const char __user *const __user *)sys_regs->dx;

  if (!filename)
    return 0;

  ret = strncpy_from_user(path, filename, sizeof(path) - 1);
  if (ret <= 0)
    return 0;
  path[ret] = '\0';

  as_format_execve_arg(arg, sizeof(arg), path, argv);
  as_emit_event(AS_TYPE_EXECVE, "none", arg);
  return 0;
}
#endif /* AS_HOOK_EXECVE */
