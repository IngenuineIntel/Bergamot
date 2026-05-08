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
#include <linux/capability.h>
#include <linux/in.h>
#include <linux/in6.h>
#include <linux/inet.h>
#include <linux/keyctl.h>
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

#if AS_HOOK_ACCEPT
int as_probe_x64_sys_accept4(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_UNLINK
int as_probe_x64_sys_unlinkat(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_RENAME
int as_probe_x64_sys_renameat2(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_SETUID
int as_probe_x64_sys_setuid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_setresuid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_SETGID
int as_probe_x64_sys_setgid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_setresgid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_setegid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_SETREUID
int as_probe_x64_sys_setreuid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_seteuid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_CAPSET
int as_probe_x64_sys_capset(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_KEYCTL
int as_probe_x64_sys_keyctl(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_GETUID_FAMILY
int as_probe_x64_sys_getuid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_geteuid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getgid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getegid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getresuid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getresgid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_GETPID_FAMILY
int as_probe_x64_sys_getpid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getppid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_gettid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getpgid(struct kprobe *p, struct pt_regs *regs);
int as_probe_x64_sys_getsid(struct kprobe *p, struct pt_regs *regs);
#endif

#if AS_HOOK_OPEN || AS_HOOK_UNLINK || AS_HOOK_RENAME
static int as_copy_user_str(const char __user *uptr, char *dst, size_t dst_sz) {
  long ret;

  if (!uptr || !dst || dst_sz < 2)
    return -EINVAL;

  ret = strncpy_from_user(dst, uptr, dst_sz - 1);
  if (ret <= 0)
    return -EFAULT;

  dst[ret] = '\0';
  return 0;
}
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
  int dfd = (int)regs->di;
  char path[256];
  char arg[256];

  AS_HOOK_GUARD();

  if (as_copy_user_str(upath, path, sizeof(path)) < 0)
    return 0;

  snprintf(arg, sizeof(arg), "dfd=%d path=%s", dfd, path);

  as_emit_event(AS_TYPE_OPEN, "do_sys_openat2", arg);
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
  char arg[64];

  AS_HOOK_GUARD();

  get_task_comm(comm, current);
  snprintf(arg, sizeof(arg), "parent_comm=%s parent_pid=%d", comm,
           task_tgid_nr(current));
  as_emit_event(AS_TYPE_FORK, "kernel_clone", arg);
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
    snprintf(arg, sizeof(arg), "family=ipv4 dst=%u.%u.%u.%u:%u", a, b, c, d,
         dport);

  } else if (family == AF_INET6) {
    struct in6_addr daddr6;
    char ip6str[INET6_ADDRSTRLEN];

    if (get_kernel_nofault(daddr6, &sk->__sk_common.skc_v6_daddr))
      return 0;
    if (get_kernel_nofault(dport, &sk->__sk_common.skc_dport))
      return 0;

    dport = ntohs(dport);
    snprintf(ip6str, sizeof(ip6str), "%pI6c", &daddr6);
    snprintf(arg, sizeof(arg), "family=ipv6 dst=[%s]:%u", ip6str, dport);

  } else {
    return 0; /* not a TCP/IP socket we care about */
  }

  as_emit_event(AS_TYPE_CONNECT, "tcp_connect", arg);
  return 0;
}
#endif /* AS_HOOK_CONNECT */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: accept4 (__x64_sys_accept4)
 * Captures userspace accept4() invocations.
 *
 * __x64_sys_accept4 argument layout:
 *   rdi = struct pt_regs *sys_regs
 *   sys_regs->di = int fd
 *   sys_regs->r10 = int flags
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_ACCEPT
int as_probe_x64_sys_accept4(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  int fd;
  int flags;
  char arg[64];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  fd = (int)sys_regs->di;
  flags = (int)sys_regs->r10;

  snprintf(arg, sizeof(arg), "fd=%d flags=0x%x", fd, flags);
  as_emit_event(AS_TYPE_ACCEPT, "__x64_sys_accept4", arg);
  return 0;
}
#endif /* AS_HOOK_ACCEPT */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: unlinkat (__x64_sys_unlinkat)
 * Captures pathname deletes.
 *
 * __x64_sys_unlinkat argument layout:
 *   rdi = struct pt_regs *sys_regs
 *   sys_regs->di = int dfd
 *   sys_regs->si = const char __user *pathname
 *   sys_regs->dx = int flag
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_UNLINK
int as_probe_x64_sys_unlinkat(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  const char __user *upath;
  int dfd;
  int flag;
  char path[192];
  char arg[256];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  dfd = (int)sys_regs->di;
  upath = (const char __user *)sys_regs->si;
  flag = (int)sys_regs->dx;

  if (as_copy_user_str(upath, path, sizeof(path)) < 0)
    return 0;

  snprintf(arg, sizeof(arg), "dfd=%d path=%s flags=0x%x", dfd, path, flag);
  as_emit_event(AS_TYPE_UNLINK, "__x64_sys_unlinkat", arg);
  return 0;
}
#endif /* AS_HOOK_UNLINK */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: renameat2 (__x64_sys_renameat2)
 * Captures file rename/move operations.
 *
 * __x64_sys_renameat2 argument layout:
 *   rdi = struct pt_regs *sys_regs
 *   sys_regs->di = int olddfd
 *   sys_regs->si = const char __user *oldname
 *   sys_regs->dx = int newdfd
 *   sys_regs->r10 = const char __user *newname
 *   sys_regs->r8 = unsigned int flags
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_RENAME
int as_probe_x64_sys_renameat2(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  const char __user *uold;
  const char __user *unew;
  int olddfd;
  int newdfd;
  unsigned int flags;
  char old_path[96];
  char new_path[96];
  char arg[256];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  olddfd = (int)sys_regs->di;
  uold = (const char __user *)sys_regs->si;
  newdfd = (int)sys_regs->dx;
  unew = (const char __user *)sys_regs->r10;
  flags = (unsigned int)sys_regs->r8;

  if (as_copy_user_str(uold, old_path, sizeof(old_path)) < 0)
    return 0;
  if (as_copy_user_str(unew, new_path, sizeof(new_path)) < 0)
    return 0;

  snprintf(arg, sizeof(arg), "olddfd=%d old=%s newdfd=%d new=%s flags=0x%x",
           olddfd, old_path, newdfd, new_path, flags);
  as_emit_event(AS_TYPE_RENAME, "__x64_sys_renameat2", arg);
  return 0;
}
#endif /* AS_HOOK_RENAME */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: setuid / setresuid (__x64_sys_setuid, __x64_sys_setresuid)
 * Captures UID transitions from userspace entrypoints.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_SETUID
int as_probe_x64_sys_setuid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int uid;
  char arg[64];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  uid = (unsigned int)sys_regs->di;
  snprintf(arg, sizeof(arg), "uid=%u", uid);
  as_emit_event(AS_TYPE_SETUID, "__x64_sys_setuid", arg);
  return 0;
}

int as_probe_x64_sys_setresuid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int ruid;
  unsigned int euid;
  unsigned int suid;
  char arg[80];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  ruid = (unsigned int)sys_regs->di;
  euid = (unsigned int)sys_regs->si;
  suid = (unsigned int)sys_regs->dx;

  snprintf(arg, sizeof(arg), "ruid=%u euid=%u suid=%u", ruid, euid, suid);
  as_emit_event(AS_TYPE_SETUID, "__x64_sys_setresuid", arg);
  return 0;
}
#endif /* AS_HOOK_SETUID */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: setgid / setresgid / setegid
 * Captures GID transitions from userspace entrypoints.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_SETGID
int as_probe_x64_sys_setgid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int gid;
  char arg[64];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  gid = (unsigned int)sys_regs->di;
  snprintf(arg, sizeof(arg), "gid=%u", gid);
  as_emit_event(AS_TYPE_SETGID, "__x64_sys_setgid", arg);
  return 0;
}

int as_probe_x64_sys_setresgid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int rgid;
  unsigned int egid;
  unsigned int sgid;
  char arg[80];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  rgid = (unsigned int)sys_regs->di;
  egid = (unsigned int)sys_regs->si;
  sgid = (unsigned int)sys_regs->dx;

  snprintf(arg, sizeof(arg), "rgid=%u egid=%u sgid=%u", rgid, egid, sgid);
  as_emit_event(AS_TYPE_SETGID, "__x64_sys_setresgid", arg);
  return 0;
}

int as_probe_x64_sys_setegid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int egid;
  char arg[64];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  egid = (unsigned int)sys_regs->di;
  snprintf(arg, sizeof(arg), "egid=%u", egid);
  as_emit_event(AS_TYPE_SETGID, "__x64_sys_setegid", arg);
  return 0;
}
#endif /* AS_HOOK_SETGID */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: setreuid / seteuid
 * Captures effective/real UID changes outside setuid/setresuid paths.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_SETREUID
int as_probe_x64_sys_setreuid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int ruid;
  unsigned int euid;
  char arg[80];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  ruid = (unsigned int)sys_regs->di;
  euid = (unsigned int)sys_regs->si;
  snprintf(arg, sizeof(arg), "ruid=%u euid=%u", ruid, euid);
  as_emit_event(AS_TYPE_SETREUID, "__x64_sys_setreuid", arg);
  return 0;
}

int as_probe_x64_sys_seteuid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  unsigned int euid;
  char arg[64];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  euid = (unsigned int)sys_regs->di;
  snprintf(arg, sizeof(arg), "euid=%u", euid);
  as_emit_event(AS_TYPE_SETREUID, "__x64_sys_seteuid", arg);
  return 0;
}
#endif /* AS_HOOK_SETREUID */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: capset
 * Captures capability updates requested by userspace.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_CAPSET
int as_probe_x64_sys_capset(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  const struct __user_cap_header_struct __user *uheader;
  const struct __user_cap_data_struct __user *udata;
  struct __user_cap_header_struct header;
  struct __user_cap_data_struct data0;
  char arg[192];
  bool have_header = false;
  bool have_data0 = false;

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  uheader = (const struct __user_cap_header_struct __user *)sys_regs->di;
  udata = (const struct __user_cap_data_struct __user *)sys_regs->si;

  if (uheader && !copy_from_user(&header, uheader, sizeof(header)))
    have_header = true;
  if (udata && !copy_from_user(&data0, udata, sizeof(data0)))
    have_data0 = true;

  if (have_header && have_data0) {
    snprintf(arg, sizeof(arg),
             "ver=0x%x pid=%d eff0=0x%x perm0=0x%x inh0=0x%x",
             header.version, header.pid, data0.effective, data0.permitted,
             data0.inheritable);
  } else if (have_header) {
    snprintf(arg, sizeof(arg), "ver=0x%x pid=%d data=unreadable",
             header.version, header.pid);
  } else {
    snprintf(arg, sizeof(arg), "header=%px data=%px", uheader, udata);
  }

  as_emit_event(AS_TYPE_CAPSET, "__x64_sys_capset", arg);
  return 0;
}
#endif /* AS_HOOK_CAPSET */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: keyctl
 * Captures key management operations and argument envelope.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_KEYCTL
int as_probe_x64_sys_keyctl(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  long option;
  unsigned long arg2;
  unsigned long arg3;
  unsigned long arg4;
  unsigned long arg5;
  char arg[160];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  option = (long)sys_regs->di;
  arg2 = (unsigned long)sys_regs->si;
  arg3 = (unsigned long)sys_regs->dx;
  arg4 = (unsigned long)sys_regs->r10;
  arg5 = (unsigned long)sys_regs->r8;

  snprintf(arg, sizeof(arg),
           "option=%ld arg2=0x%lx arg3=0x%lx arg4=0x%lx arg5=0x%lx",
           option, arg2, arg3, arg4, arg5);
  as_emit_event(AS_TYPE_KEYCTL, "__x64_sys_keyctl", arg);
  return 0;
}
#endif /* AS_HOOK_KEYCTL */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: get*id (user/group identity family)
 * Captures call intent only. Subtype identifies exact syscall.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_GETUID_FAMILY
int as_probe_x64_sys_getuid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getuid", "call=none");
  return 0;
}

int as_probe_x64_sys_geteuid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_geteuid", "call=none");
  return 0;
}

int as_probe_x64_sys_getgid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getgid", "call=none");
  return 0;
}

int as_probe_x64_sys_getegid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getegid", "call=none");
  return 0;
}

int as_probe_x64_sys_getresuid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  char arg[96];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  snprintf(arg, sizeof(arg), "ruid_ptr=0x%lx euid_ptr=0x%lx suid_ptr=0x%lx",
           (unsigned long)sys_regs->di, (unsigned long)sys_regs->si,
           (unsigned long)sys_regs->dx);
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getresuid", arg);
  return 0;
}

int as_probe_x64_sys_getresgid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  char arg[96];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  snprintf(arg, sizeof(arg), "rgid_ptr=0x%lx egid_ptr=0x%lx sgid_ptr=0x%lx",
           (unsigned long)sys_regs->di, (unsigned long)sys_regs->si,
           (unsigned long)sys_regs->dx);
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getresgid", arg);
  return 0;
}
#endif /* AS_HOOK_GETUID_FAMILY */

/* ════════════════════════════════════════════════════════════════════════════
 * HOOK: get*id (process/session family)
 * Captures call intent only. Subtype identifies exact syscall.
 * ═════════════════════════════════════════════════════════════════════════ */
#if AS_HOOK_GETPID_FAMILY
int as_probe_x64_sys_getpid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getpid", "call=none");
  return 0;
}

int as_probe_x64_sys_getppid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getppid", "call=none");
  return 0;
}

int as_probe_x64_sys_gettid(struct kprobe *p, struct pt_regs *regs) {
  AS_HOOK_GUARD();
  as_emit_event(AS_TYPE_GETID, "__x64_sys_gettid", "call=none");
  return 0;
}

int as_probe_x64_sys_getpgid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  char arg[48];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  snprintf(arg, sizeof(arg), "pid=%ld", (long)sys_regs->di);
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getpgid", arg);
  return 0;
}

int as_probe_x64_sys_getsid(struct kprobe *p, struct pt_regs *regs) {
  const struct pt_regs *sys_regs = (const struct pt_regs *)regs->di;
  char arg[48];

  AS_HOOK_GUARD();

  if (!sys_regs)
    return 0;

  snprintf(arg, sizeof(arg), "pid=%ld", (long)sys_regs->di);
  as_emit_event(AS_TYPE_GETID, "__x64_sys_getsid", arg);
  return 0;
}
#endif /* AS_HOOK_GETPID_FAMILY */

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
  as_emit_event(AS_TYPE_EXECVE, "do_execveat_common", arg);
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
  as_emit_event(AS_TYPE_EXECVE, "do_execve", arg);
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
  as_emit_event(AS_TYPE_EXECVE, "__x64_sys_execve", arg);
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
  as_emit_event(AS_TYPE_EXECVE, "__x64_sys_execveat", arg);
  return 0;
}
#endif /* AS_HOOK_EXECVE */
