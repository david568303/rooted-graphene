/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * execspawn - KernelPatch module that detects GrapheneOS "secure app spawning"
 * (exec-spawn) app launches, in-kernel and deterministically.
 *
 * Background
 * ----------
 * On GrapheneOS, the primary zygote launches apps with Zygote.nativeForkExec():
 * the child _Fork()s and immediately re-execs /system/bin/app_process
 * (execveat on arm64, execve as a fallback), replaying the recorded zygote
 * command. Because the child execs, it loses any injected Zygisk loader, so
 * Zygisk/NeoZygisk modules never reach exec-spawned apps.
 *
 * The replayed command always carries ExecSpawning.COMMAND_FD_ARG
 * ("--command-fd="). That argument uniquely identifies an exec-spawn launch: it
 * never appears for system_server (nativeForkSystemServer) or regular apps
 * (nativeForkAndSpecialize), neither of which execs. Matching on it in the
 * execve/execveat syscall is therefore exec-spawn-only by construction -- it
 * cannot perturb system_server the way fork-following would.
 *
 * Why in-kernel
 * -------------
 * A userspace watcher only learns of the exec after it happened (racing the
 * app's specialization, which applies DENY_PROCESS_PTRACE), and a Zygisk module
 * never runs in the zygote daemon so cannot hook the exec at its source. The
 * exec syscall hook runs synchronously in the exec-spawn child, before the new
 * image runs a single instruction -- the one place the launch can be caught
 * deterministically without following every zygote fork.
 *
 * This stage is detection only: it logs each exec-spawn launch so the signal and
 * timing can be validated on hardware. The injection hand-off (pausing the task
 * in this window and letting a userspace injector attach before specialization)
 * builds on this exact hook point.
 *
 * Conventions (match hidemaps): depend only on symbols KernelPatch exports to
 * modules -- hook_wrap, unhook, kallsyms_lookup_name, printk. Everything else
 * (user-memory reads) is resolved at runtime via kallsyms_lookup_name, so the
 * module adds no undefined symbols. String helpers are self-contained.
 */

#include <compiler.h>
#include <kpmodule.h>
#include <hook.h>
#include <kallsyms.h>
#include <kputils.h>
#include <linux/printk.h>
#include <ktypes.h>
#include <asm/ptrace.h>

KPM_NAME("execspawn");
KPM_VERSION("0.1.0");
KPM_LICENSE("GPL v2");
KPM_AUTHOR("rooted-graphene");
KPM_DESCRIPTION("Detect GrapheneOS exec-spawned app_process launches");

#define COMMAND_FD_ARG "--command-fd="
#define COMMAND_FD_LEN (sizeof(COMMAND_FD_ARG) - 1)
#define MAX_ARGV_SCAN 64
#define PATH_BUF 256
#define ARG_BUF 64

/* Kernel primitives resolved at runtime (runtime pointers add no undefined
 * symbols, so the build-time export allowlist is satisfied). */
static void *(*p_memdup_user)(const void __user *src, size_t len);
static long (*p_strncpy_from_user)(char *dst, const char __user *src, long count);
static void (*p_kfree)(const void *ptr);

static void *hooked_execve;
static void *hooked_execveat;

/* --- self-contained string helpers (kf_/lib_ are not exported to KPMs) --- */

static int h_strncmp(const char *a, const char *b, unsigned long n)
{
    while (n--) {
        unsigned char ca = (unsigned char) *a++, cb = (unsigned char) *b++;
        if (ca != cb) return (int) ca - (int) cb;
        if (!ca) break;
    }
    return 0;
}

static int h_starts_with(const char *s, const char *prefix)
{
    while (*prefix) {
        if (*s++ != *prefix++) return 0;
    }
    return 1;
}

static const char *h_basename(const char *path)
{
    const char *base = path;
    for (const char *p = path; *p; p++) {
        if (*p == '/') base = p + 1;
    }
    return base;
}

/* IS_ERR without pulling in linux/err.h: the kernel's error pointers occupy the
 * top 4095 addresses. */
static int is_err_or_null(const void *p)
{
    return !p || (unsigned long) p >= (unsigned long) -4095L;
}

/* Read argv[idx] (a native 64-bit user pointer) from the user argv array. */
static const char __user *argv_entry(const void __user *argv_base, int idx)
{
    if (!argv_base || !p_memdup_user || !p_kfree) return 0;

    const void __user *slot =
        (const void __user *) ((unsigned long) argv_base + (unsigned long) idx * 8);
    void *buf = p_memdup_user(slot, 8);
    if (is_err_or_null(buf)) return 0;

    const char __user *uptr = *(const char __user **) buf;
    p_kfree(buf);
    return uptr;
}

/* True iff this exec is a GrapheneOS exec-spawn launch: the program is
 * app_process and some argv entry starts with "--command-fd=". */
static int is_exec_spawn(const char __user *filename_u, const char __user *argv_u)
{
    char path[PATH_BUF];
    long n;
    int i;

    if (!filename_u || !argv_u || !p_strncpy_from_user) return 0;

    n = p_strncpy_from_user(path, filename_u, PATH_BUF);
    if (n <= 0) return 0;
    path[PATH_BUF - 1] = '\0';

    /* Fast reject before touching argv: exec-spawn always re-execs app_process. */
    if (h_strncmp(h_basename(path), "app_process", 11) != 0) return 0;

    for (i = 0; i < MAX_ARGV_SCAN; i++) {
        const char __user *a = argv_entry((const void __user *) argv_u, i);
        char arg[ARG_BUF];
        long m;
        if (!a) break; /* NULL terminator or read failure */
        m = p_strncpy_from_user(arg, a, ARG_BUF);
        if (m <= 0) continue;
        arg[ARG_BUF - 1] = '\0';
        if (h_starts_with(arg, COMMAND_FD_ARG)) return 1;
    }
    return 0;
}

/* __arm64_sys_execve(const struct pt_regs *regs): x0=filename, x1=argv */
static void before_execve(hook_fargs1_t *fargs, void *udata)
{
    struct pt_regs *r = (struct pt_regs *) fargs->arg0;
    if (!r) return;
    if (is_exec_spawn((const char __user *) r->regs[0], (const char __user *) r->regs[1]))
        pr_info("execspawn: detected exec-spawn launch via execve\n");
}

/* __arm64_sys_execveat(const struct pt_regs *regs): x0=dfd, x1=filename, x2=argv */
static void before_execveat(hook_fargs1_t *fargs, void *udata)
{
    struct pt_regs *r = (struct pt_regs *) fargs->arg0;
    if (!r) return;
    if (is_exec_spawn((const char __user *) r->regs[1], (const char __user *) r->regs[2]))
        pr_info("execspawn: detected exec-spawn launch via execveat\n");
}

static void *resolve_first(const char *const *names)
{
    int i;
    for (i = 0; names[i]; i++) {
        unsigned long addr = kallsyms_lookup_name(names[i]);
        if (addr) return (void *) addr;
    }
    return 0;
}

static long execspawn_init(const char *args, const char *event, void *__user reserved)
{
    static const char *const execve_names[] = {
        "__arm64_sys_execve", "__se_sys_execve", "sys_execve", 0
    };
    static const char *const execveat_names[] = {
        "__arm64_sys_execveat", "__se_sys_execveat", "sys_execveat", 0
    };
    void *ve, *veat;

    p_memdup_user = (void *) kallsyms_lookup_name("memdup_user");
    p_strncpy_from_user = (void *) kallsyms_lookup_name("strncpy_from_user");
    p_kfree = (void *) kallsyms_lookup_name("kfree");
    if (!p_memdup_user || !p_strncpy_from_user || !p_kfree) {
        pr_err("execspawn: could not resolve user-memory primitives; staying inert\n");
        return 0;
    }

    ve = resolve_first(execve_names);
    if (ve && hook_wrap(ve, 1, (void *) before_execve, 0, 0) == 0) {
        hooked_execve = ve;
    } else {
        pr_err("execspawn: failed to hook execve\n");
    }

    veat = resolve_first(execveat_names);
    if (veat && hook_wrap(veat, 1, (void *) before_execveat, 0, 0) == 0) {
        hooked_execveat = veat;
    } else {
        pr_err("execspawn: failed to hook execveat\n");
    }

    pr_info("execspawn: init (execve=%d execveat=%d)\n", !!hooked_execve, !!hooked_execveat);
    return 0;
}

static long execspawn_ctl0(const char *args, char *__user out_msg, int outlen)
{
    return 0;
}

static long execspawn_exit(void *__user reserved)
{
    if (hooked_execve) unhook(hooked_execve);
    if (hooked_execveat) unhook(hooked_execveat);
    pr_info("execspawn: exit\n");
    return 0;
}

KPM_INIT(execspawn_init);
KPM_CTL0(execspawn_ctl0);
KPM_EXIT(execspawn_exit);
