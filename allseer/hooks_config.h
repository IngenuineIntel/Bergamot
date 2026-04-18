/* hooks_config.h — compile-time switches for All-Seer kprobe hooks
 *
 * Set any value to 0 before building to exclude that hook entirely.
 * The kprobe registration array in allseer.c is #if-gated on these
 * values, so excluded hooks produce zero object code.
 *
 * Usage examples:
 *   Default (all on):  leave as-is and run make
 *   Disable fork hook: change AS_HOOK_FORK to 0, then make clean && make
 *   One-off override:  make CFLAGS_EXTRA="-DAS_HOOK_CONNECT=0"
 */

#ifndef HOOKS_CONFIG_H
#define HOOKS_CONFIG_H

#define AS_HOOK_OPEN     1   /* do_sys_openat2  — file open/create events */
#define AS_HOOK_FORK     1   /* kernel_clone    — fork/clone events        */
#define AS_HOOK_EXEC     1   /* do_execveat_common — execve events         */
#define AS_HOOK_CONNECT  1   /* tcp_connect     — outbound TCP connections */

/*
 * Debug-only comm-name suppression (process name in current->comm).
 *
 * WARNING: comm filtering is spoofable and unstable by design; use only for
 * local debugging. When running Python apps, current->comm is often "python3"
 * unless explicitly changed by the process.
 */
#define AS_DEBUG_IGNORE_COMM          1
#define AS_DEBUG_IGNORE_COMM_NAME     "overseer"

#endif /* HOOKS_CONFIG_H */
