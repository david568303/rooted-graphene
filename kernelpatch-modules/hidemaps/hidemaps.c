/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * hidemaps - KernelPatch module that hides root-tooling lines from
 * /proc/<pid>/maps, which is what "Detected Abnormal Maps" style checks read.
 *
 * It hooks the per-VMA maps renderer and, after the kernel has written a
 * line into the seq_file, erases that line if it matches a rule. Working on
 * the already-rendered text means no fragile vm_area_struct offsets are
 * needed; only the seq_file buffer/count are touched, and every access is
 * bounds-checked so a wrong offset makes the module inert instead of unsafe.
 *
 * Rules:
 *   1. the line contains one of the denylist tokens (default on). The default
 *      tokens only ever appear in a rooted process's maps, so legitimate
 *      mappings (ART/JIT included) are never touched.
 *   2. the line is an anonymous executable mapping (opt-in, default off):
 *      executable permission and no '/' path and not a '[named]' region.
 *
 * Control (apd/APatch "kpm control", or kpm control from root shell):
 *   status            print current state
 *   enable | disable  install / remove the hook
 *   anonexec on|off   toggle rule 2
 *   add <token>       add a denylist token
 *   clear             clear the denylist
 */

#include <compiler.h>
#include <kpmodule.h>
#include <hook.h>
#include <kallsyms.h>
#include <kputils.h>
#include <linux/printk.h>
#include <ktypes.h>

/* The lib_* string helpers are not exported to KPMs, so use self-contained
 * implementations and depend only on symbols KernelPatch exports to modules
 * (hook_wrap, unhook, kallsyms_lookup_name, compat_copy_to_user, printk). */
static size_t h_strlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

static int h_strncmp(const char *a, const char *b, size_t n)
{
    while (n--) {
        unsigned char ca = (unsigned char)*a++, cb = (unsigned char)*b++;
        if (ca != cb) return (int)ca - (int)cb;
        if (!ca) break;
    }
    return 0;
}

static void *h_memchr(const void *s, int c, size_t n)
{
    const unsigned char *p = s;
    while (n--) {
        if (*p == (unsigned char)c) return (void *)p;
        p++;
    }
    return 0;
}

static int h_memeq(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;
    while (n--)
        if (*x++ != *y++) return 0;
    return 1;
}

/* substring search over a byte range (haystack is not NUL-terminated) */
static int h_contains(const char *hay, size_t n, const char *needle)
{
    size_t m = h_strlen(needle);
    size_t i;
    if (m == 0 || m > n) return 0;
    for (i = 0; i + m <= n; i++)
        if (hay[i] == needle[0] && h_memeq(hay + i, needle, m)) return 1;
    return 0;
}

/* bounded copy returning bytes written (excluding NUL) */
static size_t h_strlcpy(char *dst, const char *src, size_t size)
{
    size_t i = 0;
    if (!size) return 0;
    for (; i + 1 < size && src[i]; i++) dst[i] = src[i];
    dst[i] = '\0';
    return i;
}

KPM_NAME("hidemaps");
KPM_VERSION("1.0.0");
KPM_LICENSE("GPL v2");
KPM_AUTHOR("rooted-graphene");
KPM_DESCRIPTION("Hide root-tooling lines from /proc/<pid>/maps");

/*
 * seq_file layout on arm64 has been stable for many years:
 *   char *buf; size_t size; size_t from; size_t count; loff_t index; ...
 * so buf@0, size@8, count@24. Reads are validated (buf!=NULL, count<=size,
 * size within a sane bound) before anything is erased, so a layout mismatch
 * only disables hiding; it never corrupts the buffer.
 */
#define SEQ_BUF_OFF 0
#define SEQ_SIZE_OFF 8
#define SEQ_COUNT_OFF 24
#define SEQ_SIZE_SANE_MAX (16u << 20)

#define MAX_TOKENS 24
#define TOKEN_LEN 64

static const char *const candidate_syms[] = { "show_map_vma", "show_map", 0 };

static void *hooked_fn;
static int enabled;
static int hide_anon_exec;
static char tokens[MAX_TOKENS][TOKEN_LEN];
static int token_num;

static const char *const default_tokens[] = {
    "KernelPatch", "kernelpatch", "APatch", "apatch", "/data/adb",
    "zygisk", "rezygisk", "magisk", "Magisk", "KernelSU", "kernelsu", 0
};

static inline char *seq_buf(void *m) { return *(char **)((char *)m + SEQ_BUF_OFF); }
static inline size_t seq_size(void *m) { return *(size_t *)((char *)m + SEQ_SIZE_OFF); }
static inline size_t seq_count(void *m) { return *(size_t *)((char *)m + SEQ_COUNT_OFF); }
static inline void seq_set_count(void *m, size_t c) { *(size_t *)((char *)m + SEQ_COUNT_OFF) = c; }

static void add_token(const char *t)
{
    if (token_num >= MAX_TOKENS) return;
    if (!t || !t[0]) return;
    h_strlcpy(tokens[token_num], t, TOKEN_LEN);
    token_num++;
}

/* line is "start-end perms offset dev inode  path\n"; decide anon+exec from
 * the rendered text alone: executable perm bit, and no file path ('/') and
 * not a named '[...]' region. */
static int line_is_anon_exec(const char *line, size_t len)
{
    size_t i = 0;
    while (i < len && line[i] != ' ') i++; /* skip addr range */
    if (i >= len) return 0;
    i++; /* space before perms */
    if (i + 3 >= len) return 0;
    if (line[i + 2] != 'x') return 0; /* perms[2] is the x bit */
    if (h_memchr(line, '/', len)) return 0; /* file-backed */
    if (h_memchr(line, '[', len)) return 0; /* [stack]/[vdso]/[anon:...] */
    return 1;
}

static int line_should_hide(const char *line, size_t len)
{
    int i;
    for (i = 0; i < token_num; i++) {
        if (tokens[i][0] && h_contains(line, len, tokens[i])) return 1;
    }
    if (hide_anon_exec && line_is_anon_exec(line, len)) return 1;
    return 0;
}

static void before_show(hook_fargs2_t *args, void *udata)
{
    void *m = (void *)args->arg0;
    args->local.data1 = (uint64_t)m;
    args->local.data0 = m ? seq_count(m) : 0;
}

static void after_show(hook_fargs2_t *args, void *udata)
{
    void *m = (void *)args->local.data1;
    char *buf;
    size_t size, oldc, newc;

    if (!m) return;
    buf = seq_buf(m);
    size = seq_size(m);
    oldc = args->local.data0;
    newc = seq_count(m);

    if (!buf || size == 0 || size > SEQ_SIZE_SANE_MAX) return; /* layout check */
    if (oldc > size || newc > size || newc <= oldc) return; /* nothing added / overflow */

    if (line_should_hide(buf + oldc, newc - oldc))
        seq_set_count(m, oldc); /* erase the line just written */
}

static int install_hook(void)
{
    int i;
    unsigned long addr = 0;

    if (hooked_fn) return 0;
    if (!kallsyms_lookup_name) return -1;

    for (i = 0; candidate_syms[i]; i++) {
        addr = kallsyms_lookup_name(candidate_syms[i]);
        if (addr) break;
    }
    if (!addr) {
        pr_err("hidemaps: no maps renderer symbol found\n");
        return -1;
    }

    hook_err_t err = hook_wrap((void *)addr, 2, (void *)before_show, (void *)after_show, 0);
    if (err) {
        pr_err("hidemaps: hook failed on %s: %d\n", candidate_syms[i], err);
        return -1;
    }
    hooked_fn = (void *)addr;
    enabled = 1;
    pr_info("hidemaps: hooked %s\n", candidate_syms[i]);
    return 0;
}

static void remove_hook(void)
{
    if (!hooked_fn) return;
    unhook(hooked_fn);
    hooked_fn = 0;
    enabled = 0;
    pr_info("hidemaps: unhooked\n");
}

static long hidemaps_init(const char *args, const char *event, void *__user reserved)
{
    int i;
    token_num = 0;
    for (i = 0; default_tokens[i]; i++) add_token(default_tokens[i]);
    hide_anon_exec = 0;
    if (install_hook()) return 0; /* stay loaded but inert if no symbol */
    return 0;
}

static long hidemaps_ctl0(const char *args, char *__user out_msg, int outlen)
{
    char buf[256];

    if (!args) args = "";

    if (!h_strncmp(args, "enable", 6)) {
        install_hook();
    } else if (!h_strncmp(args, "disable", 7)) {
        remove_hook();
    } else if (!h_strncmp(args, "anonexec on", 11)) {
        hide_anon_exec = 1;
    } else if (!h_strncmp(args, "anonexec off", 12)) {
        hide_anon_exec = 0;
    } else if (!h_strncmp(args, "add ", 4)) {
        add_token(args + 4);
    } else if (!h_strncmp(args, "clear", 5)) {
        token_num = 0;
    }

    if (out_msg && outlen > 0) {
        int n = 0, i;
        n += h_strlcpy(buf + n, "hidemaps ", sizeof(buf) - n);
        n += h_strlcpy(buf + n, enabled ? "enabled" : "disabled", sizeof(buf) - n);
        n += h_strlcpy(buf + n, hide_anon_exec ? " anonexec=on tokens=" : " anonexec=off tokens=",
                         sizeof(buf) - n);
        for (i = 0; i < token_num && n < (int)sizeof(buf) - 2; i++) {
            if (i) n += h_strlcpy(buf + n, ",", sizeof(buf) - n);
            n += h_strlcpy(buf + n, tokens[i], sizeof(buf) - n);
        }
        compat_copy_to_user(out_msg, buf, n + 1 < outlen ? n + 1 : outlen);
    }
    return 0;
}

static long hidemaps_exit(void *__user reserved)
{
    remove_hook();
    return 0;
}

KPM_INIT(hidemaps_init);
KPM_CTL0(hidemaps_ctl0);
KPM_EXIT(hidemaps_exit);
