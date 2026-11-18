/*
 * bc-limit.c — Battery Commander limit enforcer (independent, clean-room).
 *
 * Enforces a charge limit (upper/lower %) by toggling the charge-control key
 * the machine actually has. On this Mac (MacBook Pro 9,1, Catalina) that key
 * is BCLM: 10 = charging disabled (hold), 100 = charging enabled. The limit
 * % itself is NEVER written to the SMC; it lives in limit.conf.
 *
 * Phase C (2026-11-11): final enforcer. Adds the gauge-jump deferral
 * (see read_last_pct/write_last_pct): a >= 5-point % move in one 60 s
 * interval defers the write by one cycle. --test-write is kept as-is
 * (Phase B, already verified). Consolidation M6 (2026-11-13, v1.1):
 * honor .apg_paused next to the --config file — suppress only the
 * resume write. No design section 2.3/2.4 fallback
 * (dormant on this Mac).
 *
 * Discharge D2 (2026-11-13, v1.2): honor a valid .discharge_session
 * next to the --config file (discharge-design.md section 4.2) —
 * suppress the resume write while a session is valid, and hold
 * while pct > TARGET. bc-limit never creates, edits, or deletes
 * the session file; an invalid one is logged once and ignored.
 *
 * Calibrate (2026-11-14, v1.3): the ONLY delta from v1.2 — a session
 * with MODE=calibrate is honored only when it also carries RUN=<id>
 * matching a live .calibration_run file (same directory) whose
 * HEARTBEAT is <= 600 s old (CALIBRATION_RUN_STALE_MIN=10) and whose
 * ABS_FLOOR (strict integer, hard-clamped to [8, 20]) is <= TARGET.
 * A calibrate session failing any check is invalid like any other
 * bad session (ignored; normal rules apply). Routine user/corrective
 * sessions are byte-for-byte the v1.2 contract. (calibrate-design.md
 * section 5.2.)
 *
 * APG gate (2026-11-16, v1.4-apggate): the ONLY delta from v1.3 —
 * the M6 resume suppression now reads the pause REASON from
 * .apg_pause_reason (maintained by the watchdog's apg_classify next
 * to .apg_paused): exactly "thermal" (temp >= 38 C or temp
 * unreadable) suppresses as before; exactly "load" (a CPU-load-only
 * pause with a cool battery) does NOT suppress — the resume
 * proceeds and is logged. A load-only pause froze a user-pressed
 * Charge-to-100% on 2026-11-16 00:09 (load 10.79, temp 30.66 C):
 * a heuristic load pause must not block a user-initiated charge
 * (owner's rule, 2026-11-15). Missing/unreadable/empty/garbage
 * reason = unknown = suppress, exactly as v1.3 did for every
 * pause (fail safe). The discharge-session suppression above is a
 * separate branch and is unchanged.
 *
 * Gauge confirmation (2026-11-16, v1.5-gauge): the Phase C
 * one-cycle deferral becomes a true confirm-before-write, per the
 * 2026-11-12 audit design. The gauge state file (.bc-limit-last-pct,
 * format v2: confirmed pct / candidate pct / last CurrentCapacity,
 * one per line; v1 single-line files still parse) now tracks a
 * CANDIDATE: a >= 5-point move against the confirmed baseline
 * records the new level as an unconfirmed candidate and defers any
 * write; the level is confirmed only when a later invocation reads
 * within 2 points of the candidate (or falls back within 5 of the
 * baseline — the jump relaxed away). A level still moving >= 5
 * points per tick never confirms, so no BCLM write is ever based
 * on a % seen only once. Second, a HOLD write whose premise is
 * an overshoot (pct > upper+2) gains the audit's second-signal
 * gate: it requires IsCharging, Amperage > 0, or CurrentCapacity
 * rising across two ticks; without one it is deferred and logged
 * (with zero current the write has no physical effect anyway, and
 * real energy flow always produces the evidence). The resume
 * suppression (the safe direction) is NOT gated and is
 * byte-identical, as are the session contract and the APG reason
 * gate.
 *
 * Phase A (2026-11-08): DRY-RUN ONLY. The write functions exist per the
 * design (one per backend, restricted to its key/values) but are NEVER called
 * in dry-run mode, which is the default. No SMC write is performed by any
 * Phase A test. Phase B (one controlled write) needs its own separate
 * approval, and the write command / functions must be reviewed before it.
 *
 * Read path: proven V6 pattern (correct 80-byte SMCKeyData_t, commands
 * READ_KEYINFO 9 + READ_BYTES 5, no sudo). Write path: standard public SMC
 * write command (WRITE_BYTES 6) from public SMC documentation
 * (smcFanControl smc.c), written from scratch — NOT copied from battopt.
 * The write command number (6) must be confirmed in the Phase B review
 * before any real write test.
 *
 * Design: battopt-project/bc-build/limit-writer-design.md v2.
 * Audit: battopt-project/bc-build/audit-report.md.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <libgen.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_KEYINFO 9

#define BC_VERSION "1.5-gauge"

/* ------------------------------------------------------------------ */
/* SMC structs (proven V6 layout; sizeof must be 80)                   */
/* ------------------------------------------------------------------ */

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyData_keyInfo_t;

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    char bytes[32];
} SMCKeyData_t;

static UInt32 str_to_key(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16)
         | ((UInt32)(unsigned char)s[2] << 8)  | (UInt32)(unsigned char)s[3];
}

/* ------------------------------------------------------------------ */
/* Logging (limit.log in the executable's directory + stdout)           */
/* ------------------------------------------------------------------ */

static FILE *g_log = NULL;

static void log_open(const char *path) {
    if (path) {
        g_log = fopen(path, "a");
    }
}

static void log_close(void) {
    if (g_log) {
        fclose(g_log);
        g_log = NULL;
    }
}

static void log_msg(const char *fmt, ...) {
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    printf("[%s] %s\n", ts, buf);
    fflush(stdout);
    if (g_log) {
        fprintf(g_log, "[%s] %s\n", ts, buf);
        fflush(g_log);
    }
}

/* Directory containing this executable (for limit.conf / limit.log). */
static void exe_dir(char *out, size_t outsz) {
    char path[1024];
    uint32_t sz = (uint32_t)sizeof(path);
    if (_NSGetExecutablePath(path, &sz) != 0) {
        snprintf(out, outsz, ".");
        return;
    }
    char *d = dirname(path);
    snprintf(out, outsz, "%s", d ? d : ".");
}

/* ------------------------------------------------------------------ */
/* SMC connection + read (proven V6 pattern, commands 9 + 5 only)       */
/* ------------------------------------------------------------------ */

static int smc_open(io_connect_t *out_conn) {
    mach_port_t masterPort = MACH_PORT_NULL;
    kern_return_t kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
    if (kr != KERN_SUCCESS) return -1;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (!matching) return -1;
    io_iterator_t iterator = 0;
    kr = IOServiceGetMatchingServices(masterPort, matching, &iterator);
    if (kr != KERN_SUCCESS) return -1;
    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!service) return -1;
    io_connect_t conn = 0;
    kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return -1;
    *out_conn = conn;
    return 0;
}

/* Returns 0 on success, -1 on transport error or result != 0. */
static int smc_read(io_connect_t conn, const char *name,
                    UInt32 *out_size, unsigned char out_bytes[32]) {
    SMCKeyData_t in, out;
    size_t out_sz;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_to_key(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    out_sz = sizeof(out);
    if (IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &out_sz) != KERN_SUCCESS)
        return -1;
    if (out.result != 0)
        return -1;
    UInt32 size = out.keyInfo.dataSize;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_to_key(name);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    out_sz = sizeof(out);
    if (IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &out_sz) != KERN_SUCCESS)
        return -1;
    if (out.result != 0)
        return -1;
    if (size > 32)
        size = 32;
    *out_size = size;
    memcpy(out_bytes, out.bytes, size);
    return 0;
}

/* Returns 1 if the key is readable (KeyInfo result == 0), 0 if not
   present / not readable, -1 on transport error. Read-only probe. */
static int smc_key_exists(io_connect_t conn, const char *name) {
    SMCKeyData_t in, out;
    size_t out_sz;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_to_key(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    out_sz = sizeof(out);
    if (IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &out_sz) != KERN_SUCCESS)
        return -1;
    return (out.result == 0) ? 1 : 0;
}

/* Read a key as an unsigned long (big-endian for multi-byte values). */
static int smc_read_ulong(io_connect_t conn, const char *name, unsigned long *out) {
    UInt32 size = 0;
    unsigned char bytes[32];
    if (smc_read(conn, name, &size, bytes) != 0)
        return -1;
    unsigned long v = 0;
    for (UInt32 i = 0; i < size; i++)
        v = (v << 8) | (unsigned long)bytes[i];
    *out = v;
    return 0;
}

/* ------------------------------------------------------------------ */
/* SMC write (per design section 5).                                    */
/*                                                                      */
/* PHASE A NOTE: these functions exist per the design but are NEVER     */
/* called in dry-run mode (the default). Phase B review must confirm    */
/* the write command (WRITE_BYTES = 6, public SMC documentation) and    */
/* each function before any real write test. No Phase A test passes     */
/* --write, so no write path is exercised here.                         */
/* ------------------------------------------------------------------ */

/* Generic write: KeyInfo first (checks the key exists and its size),
   then WRITE_BYTES with the bytes, then the caller verifies by read-back.
   Returns 0 on success, -1 on any failure. */
static int smc_write_key(io_connect_t conn, const char *name,
                         const unsigned char *bytes, UInt32 size) {
    SMCKeyData_t in, out;
    size_t out_sz;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_to_key(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    out_sz = sizeof(out);
    if (IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &out_sz) != KERN_SUCCESS)
        return -1;
    if (out.result != 0)
        return -1;
    if (out.keyInfo.dataSize != size)
        return -1;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = str_to_key(name);
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(in.bytes, bytes, size);
    out_sz = sizeof(out);
    if (IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &out, &out_sz) != KERN_SUCCESS)
        return -1;
    if (out.result != 0)
        return -1;
    return 0;
}

/* Intel BCLM: only 10 (hold) or 100 (resume). Key 0x42434c4d. */
static int smc_write_bclm(io_connect_t conn, unsigned int value) {
    if (value != 10 && value != 100)
        return -1;
    unsigned char b[1];
    b[0] = (unsigned char)value;
    if (smc_write_key(conn, "BCLM", b, 1) != 0)
        return -1;
    unsigned long back = 0;
    if (smc_read_ulong(conn, "BCLM", &back) != 0)
        return -1;
    return (back == value) ? 0 : -1;
}

/* Apple Silicon legacy CH0B+CH0C: only 00 (allow) or 02 (inhibit).
   Writes both keys (redundancy, per design). */
static int smc_write_ch0b_ch0c(io_connect_t conn, unsigned int value) {
    if (value != 0 && value != 2)
        return -1;
    unsigned char b[1];
    b[0] = (unsigned char)value;
    if (smc_write_key(conn, "CH0B", b, 1) != 0)
        return -1;
    if (smc_write_key(conn, "CH0C", b, 1) != 0)
        return -1;
    unsigned long back = 0;
    if (smc_read_ulong(conn, "CH0B", &back) != 0)
        return -1;
    return (back == value) ? 0 : -1;
}

/* Apple Silicon CHTE: only 0x00000000 (allow) or 0x01000000 (inhibit). */
static int smc_write_chte(io_connect_t conn, unsigned long value) {
    if (value != 0x00000000UL && value != 0x01000000UL)
        return -1;
    unsigned char b[4];
    b[0] = (unsigned char)((value >> 24) & 0xff);
    b[1] = (unsigned char)((value >> 16) & 0xff);
    b[2] = (unsigned char)((value >> 8) & 0xff);
    b[3] = (unsigned char)(value & 0xff);
    if (smc_write_key(conn, "CHTE", b, 4) != 0)
        return -1;
    unsigned long back = 0;
    if (smc_read_ulong(conn, "CHTE", &back) != 0)
        return -1;
    return (back == value) ? 0 : -1;
}

/* Apple Silicon CHWA flag: limit must be 80 or 100 only.
   Flag set (1) = 80% ceiling, cleared (0) = 100%.
   NOTE: CHWA write semantics need hardware verification (design section 9);
   v1 does not drive this backend. */
static int smc_write_chwa(io_connect_t conn, unsigned int limit_pct) {
    if (limit_pct != 80 && limit_pct != 100)
        return -1;
    unsigned char b[1];
    b[0] = (limit_pct == 80) ? 1 : 0;
    if (smc_write_key(conn, "CHWA", b, 1) != 0)
        return -1;
    unsigned long back = 0;
    if (smc_read_ulong(conn, "CHWA", &back) != 0)
        return -1;
    return (back == (unsigned long)b[0]) ? 0 : -1;
}

/* Apple Silicon CHLS: write 0x100 | end% (end% 10-100). u16 big-endian.
   NOTE: needs hardware verification (design section 9); v1 does not
   drive this backend. */
static int smc_write_chls(io_connect_t conn, unsigned int end_pct) {
    if (end_pct < 10 || end_pct > 100)
        return -1;
    unsigned int v = 0x100 | end_pct;
    unsigned char b[2];
    b[0] = (unsigned char)((v >> 8) & 0xff);
    b[1] = (unsigned char)(v & 0xff);
    if (smc_write_key(conn, "CHLS", b, 2) != 0)
        return -1;
    unsigned long back = 0;
    if (smc_read_ulong(conn, "CHLS", &back) != 0)
        return -1;
    return (back == (unsigned long)v) ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* Backends (design section 2). v1 drives only the on/off toggle       */
/* backends (BCLM, CH0B/CH0C, CHTE). CHWA/CHLS have different          */
/* semantics and are monitor-only in v1; native/adapter are not in     */
/* the v1 build scope (design section 9).                               */
/* ------------------------------------------------------------------ */

typedef enum {
    BE_BCLM = 0,
    BE_CHLS,
    BE_CHWA,
    BE_CHTE,
    BE_CH0B_CH0C,
    BE_MONITOR
} Backend;

typedef struct {
    Backend id;
    const char *name;      /* probe name */
    const char *key;       /* primary SMC key (NULL for monitor) */
    const char *key2;      /* second key, CH0B/CH0C only */
    unsigned long hold;    /* hold (inhibit) value */
    unsigned long resume;  /* resume (allow) value */
    int value_bytes;       /* 1 or 4 */
    int toggle;            /* 1 = v1 drives this backend as a toggle */
} BackendDesc;

static const BackendDesc kBackends[] = {
    { BE_BCLM,      "bclm",     "BCLM", NULL, 10,         100,        1, 1 },
    { BE_CHLS,      "chls",     "CHLS", NULL, 0,          0,          2, 0 },
    { BE_CHWA,      "chwa",     "CHWA", NULL, 0,          0,          1, 0 },
    { BE_CHTE,      "chte",     "CHTE", NULL, 0x01000000, 0x00000000, 4, 1 },
    { BE_CH0B_CH0C, "ch0b_ch0c", "CH0B", "CH0C", 2,        0,          1, 1 },
    { BE_MONITOR,   "monitor",  NULL,   NULL, 0,          0,          0, 0 },
};

static const BackendDesc *backend_by_id(Backend id) {
    size_t n = sizeof(kBackends) / sizeof(kBackends[0]);
    for (size_t i = 0; i < n; i++)
        if (kBackends[i].id == id)
            return &kBackends[i];
    return &kBackends[n - 1];
}

/* Probe in the design order (section 2.1). Read-only. Returns the
   selected backend and logs every probe step. */
static Backend probe_backend(io_connect_t conn) {
    int r;
    r = smc_key_exists(conn, "BCLM");
    log_msg("probe: BCLM %s", r == 1 ? "present -> backend=bclm (Intel)" : (r == 0 ? "absent" : "transport error"));
    if (r == 1) return BE_BCLM;
    r = smc_key_exists(conn, "CHLS");
    log_msg("probe: CHLS %s", r == 1 ? "present -> backend=chls (firmware limit)" : (r == 0 ? "absent" : "transport error"));
    if (r == 1) return BE_CHLS;
    r = smc_key_exists(conn, "CHWA");
    log_msg("probe: CHWA %s", r == 1 ? "present -> backend=chwa (fixed 80)" : (r == 0 ? "absent" : "transport error"));
    if (r == 1) return BE_CHWA;
    r = smc_key_exists(conn, "CHTE");
    log_msg("probe: CHTE %s", r == 1 ? "present -> backend=chte (legacy toggle)" : (r == 0 ? "absent" : "transport error"));
    if (r == 1) return BE_CHTE;
    int b = smc_key_exists(conn, "CH0B");
    int c = smc_key_exists(conn, "CH0C");
    log_msg("probe: CH0B %s, CH0C %s", b == 1 ? "present" : (b == 0 ? "absent" : "transport error"),
            c == 1 ? "present" : (c == 0 ? "absent" : "transport error"));
    if (b == 1 && c == 1) return BE_CH0B_CH0C;
    log_msg("probe: no SMC charge key found -> monitor-only (native/adapter backends not in v1 scope)");
    return BE_MONITOR;
}

/* Read the backend's control value. Returns 0 on success. */
static int backend_read_value(io_connect_t conn, const BackendDesc *be, unsigned long *out) {
    if (!be->key)
        return -1;
    return smc_read_ulong(conn, be->key, out);
}

/* Write the backend's control value (dispatches to the per-backend
   write function). Returns 0 on success. NEVER called in dry-run mode. */
static int backend_write_value(io_connect_t conn, const BackendDesc *be, unsigned long value) {
    switch (be->id) {
        case BE_BCLM:
            return smc_write_bclm(conn, (unsigned int)value);
        case BE_CH0B_CH0C:
            return smc_write_ch0b_ch0c(conn, (unsigned int)value);
        case BE_CHTE:
            return smc_write_chte(conn, value);
        case BE_CHWA:
            return smc_write_chwa(conn, (unsigned int)value);
        case BE_CHLS:
            return smc_write_chls(conn, (unsigned int)value);
        default:
            return -1;
    }
}


/* ------------------------------------------------------------------ */
/* Gauge-jump confirmation (Phase C; confirm-before-write v1.5).       */
/*                                                                      */
/* The battery % is a gas-gauge estimate (bq20z451 + macOS smoothing)  */
/* and can jump +7..+12% in under a minute with zero current (proven  */
/* 2026-10-30 and 2026-11-11: 86% -> 93% in <=60 s, Amperage=0). A    */
/* single ioreg read per invocation cannot tell a re-estimate from     */
/* real energy. Phase C deferred a write one cycle on a >= 5-point     */
/* move and then accepted the new value as baseline. v1.5 keeps a      */
/* candidate instead: the jumped level must be CONFIRMED by a later    */
/* read within 2 points of it (or relax back within 5 of the           */
/* baseline) before any write may be based on it; a level still        */
/* moving >= 5 points per invocation never confirms. The state file    */
/* lives next to the log (exe dir). If it cannot be read or written,   */
/* enforcement proceeds (fail open) and a warning is logged.           */
/* ------------------------------------------------------------------ */

/* Gauge state, format v2 (v1.5-gauge): three lines — confirmed
   baseline pct, candidate pct (-1 = none pending), last
   CurrentCapacity in mAh (-1 = unknown). A v1 single-line file
   (baseline only) still parses, with candidate/capacity unknown.
   Returns 0 on success (baseline valid), -1 otherwise. */
static int read_gauge_state(const char *path, int *last_pct,
                            int *cand_pct, long *last_cap) {
    *cand_pct = -1;
    *last_cap = -1;
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    int v = -1;
    if (fscanf(f, "%d", &v) != 1) {
        fclose(f);
        return -1;
    }
    if (v < 0 || v > 100) {
        fclose(f);
        return -1;
    }
    *last_pct = v;
    int c = -1;
    if (fscanf(f, "%d", &c) == 1 && c >= 0 && c <= 100)
        *cand_pct = c;
    long cap = -1;
    if (fscanf(f, "%ld", &cap) == 1 && cap >= 0)
        *last_cap = cap;
    fclose(f);
    return 0;
}

static int write_gauge_state(const char *path, int last_pct,
                             int cand_pct, long last_cap) {
    char tmp[1200];
    snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    FILE *f = fopen(tmp, "w");
    if (!f)
        return -1;
    fprintf(f, "%d\n%d\n%ld\n", last_pct, cand_pct, last_cap);
    if (fclose(f) != 0) {
        remove(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        remove(tmp);
        return -1;
    }
    return 0;
}

/* Second-signal evidence for an overshoot premise (2026-11-12
   audit rule): charging right now, charge current flowing in, or
   the mAh estimate rising across two ticks. Any one suffices;
   a % reading alone never does. */
static int second_signal(int is_charging, long amperage,
                         long cap, long prev_cap) {
    if (is_charging)
        return 1;
    if (amperage > 0)
        return 1;
    if (prev_cap >= 0 && cap > prev_cap)
        return 1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* APG pause reason (v1.4-apggate): the watchdog's apg_classify      */
/* maintains .apg_pause_reason next to .apg_paused (and so next to   */
/* the --config file): exactly "thermal" or "load". thermal means    */
/* battery temp >= 38 C at classification time or temp unreadable;   */
/* load means a CPU-load-only pause with a cool battery. Anything    */
/* else — file missing, unreadable, empty, unexpected content — is   */
/* UNKNOWN and the caller fails safe (suppress, as v1.3 did for      */
/* every pause).                                                     */
/* ------------------------------------------------------------------ */

#define APG_REASON_UNKNOWN 0
#define APG_REASON_LOAD    1
#define APG_REASON_THERMAL 2

static int apg_pause_reason(const char *config_path) {
    char path[1200];
    const char *slash = strrchr(config_path, '/');
    if (slash) {
        size_t dlen = (size_t)(slash - config_path);
        snprintf(path, sizeof(path), "%.*s/.apg_pause_reason", (int)dlen, config_path);
    } else {
        snprintf(path, sizeof(path), ".apg_pause_reason");
    }
    FILE *f = fopen(path, "r");
    if (!f)
        return APG_REASON_UNKNOWN;
    char buf[32];
    size_t n = fread(buf, 1, sizeof(buf) - 1, f);
    fclose(f);
    buf[n] = '\0';
    /* The writer emits exactly "load\n" or "thermal\n"; trim
       trailing whitespace/newlines, then require an exact match —
       anything else is unknown. */
    while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' ||
                     buf[n - 1] == ' ' || buf[n - 1] == '\t'))
        buf[--n] = '\0';
    if (strcmp(buf, "load") == 0)
        return APG_REASON_LOAD;
    if (strcmp(buf, "thermal") == 0)
        return APG_REASON_THERMAL;
    return APG_REASON_UNKNOWN;
}

/* ------------------------------------------------------------------ */
/* Config (limit.conf: LAST_UPPER= / LAST_LOWER=)                      */
/* ------------------------------------------------------------------ */

static int read_config(const char *path, int *upper, int *lower) {
    FILE *f = fopen(path, "r");
    if (!f)
        return -1;
    char line[256];
    int u = -1, l = -1;
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "LAST_UPPER=%d", &u) == 1)
            continue;
        if (sscanf(line, "LAST_LOWER=%d", &l) == 1)
            continue;
    }
    fclose(f);
    if (u < 15 || u > 100 || l < 15 || l > 100 || u <= l)
        return -1;
    *upper = u;
    *lower = l;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Discharge session (discharge-design.md section 4.2).                */
/*                                                                      */
/* The session file (.discharge_session, in the directory of the      */
/* --config file, like .apg_paused) is the whole contract between     */
/* the session owner (dispatch/watchdog) and bc-limit. bc-limit only  */
/* reads it — it never creates, edits, or deletes it. A file that     */
/* exists but is invalid is ignored (normal rules apply), so a dead   */
/* session owner can never suppress charging for longer than          */
/* DISCHARGE_MAX_MINUTES.                                             */
/* ------------------------------------------------------------------ */

/* Strict integer parse: the whole string must be one integer. */
static int parse_strict_long(const char *s, long *out) {
    if (!s || !*s)
        return -1;
    errno = 0;
    char *end = NULL;
    long v = strtol(s, &end, 10);
    if (errno != 0 || end == s || !end || *end != '\0')
        return -1;
    *out = v;
    return 0;
}

/* Staleness bound for a session, in seconds: DISCHARGE_MAX_MINUTES
   from the config file (minutes; default 240 if absent or
   unparseable; clamped to [30, 1440]). */
static long discharge_max_age_s(const char *config_path) {
    long minutes = 240;
    FILE *f = fopen(config_path, "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "DISCHARGE_MAX_MINUTES=", 22) == 0) {
                char val[64];
                snprintf(val, sizeof(val), "%s", line + 22);
                size_t vl = strlen(val);
                while (vl > 0 && (val[vl - 1] == '\n' || val[vl - 1] == '\r'))
                    val[--vl] = '\0';
                long v = 0;
                minutes = (parse_strict_long(val, &v) == 0) ? v : 240;
            }
        }
        fclose(f);
    }
    if (minutes < 30) minutes = 30;
    if (minutes > 1440) minutes = 1440;
    return minutes * 60;
}

/* Calibration run cross-check (v1.3, calibrate-design.md section
   5.2): a MODE=calibrate session is valid only while a live run
   authorizes it. Reads .calibration_run next to the --config file.
   Returns 1 only if ALL of: the session's RUN=<id> equals the run
   file's RUN_ID; the run HEARTBEAT is a strict integer no more than
   CAL_RUN_STALE_S old (and not > 60 s in the future); ABS_FLOOR is a
   strict integer in the hard clamp [8, 20] (so a forged run file can
   never authorize a drain below the design emergency bound); and
   target >= ABS_FLOOR. Any failure returns 0 — the session is then
   invalid exactly like any other bad session. */
#define CAL_RUN_STALE_S 600
static int calibration_run_ok(const char *config_path, const char *run_id,
                              long target) {
    char path[1200];
    const char *slash = strrchr(config_path, '/');
    if (slash) {
        size_t dlen = (size_t)(slash - config_path);
        snprintf(path, sizeof(path), "%.*s/.calibration_run", (int)dlen, config_path);
    } else {
        snprintf(path, sizeof(path), ".calibration_run");
    }
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    char id_s[64] = "";
    char hb_s[64] = "";
    char floor_s[64] = "";
    int have_id = 0, have_hb = 0, have_floor = 0;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        if (!eq)
            continue;
        *eq = '\0';
        char *val = eq + 1;
        size_t vl = strlen(val);
        while (vl > 0 && (val[vl - 1] == '\n' || val[vl - 1] == '\r'))
            val[--vl] = '\0';
        if (strcmp(line, "RUN_ID") == 0) {
            snprintf(id_s, sizeof(id_s), "%s", val);
            have_id = 1;
        } else if (strcmp(line, "HEARTBEAT") == 0) {
            snprintf(hb_s, sizeof(hb_s), "%s", val);
            have_hb = 1;
        } else if (strcmp(line, "ABS_FLOOR") == 0) {
            snprintf(floor_s, sizeof(floor_s), "%s", val);
            have_floor = 1;
        }
    }
    fclose(f);
    if (!have_id || !have_hb || !have_floor)
        return 0;
    if (run_id[0] == '\0' || strcmp(id_s, run_id) != 0)
        return 0;
    long hb = 0, fl = 0;
    if (parse_strict_long(hb_s, &hb) != 0)
        return 0;
    if (parse_strict_long(floor_s, &fl) != 0 || fl < 8 || fl > 20)
        return 0;
    long now = (long)time(NULL);
    if (hb > now + 60)
        return 0;
    if (now - hb > CAL_RUN_STALE_S)
        return 0;
    if (target < fl || target > 99)
        return 0;
    return 1;
}

/* Check the session file next to the config file. Returns 0 = no
   session file, 1 = valid session (*out_target set), 2 = the file
   exists but is invalid. Valid means: MODE is exactly "user" or
   "corrective", TARGET is a strict integer in [20, 99], and STARTED
   is a strict integer > 0, not in the future, and no older than the
   DISCHARGE_MAX_MINUTES bound. v1.3 adds MODE "calibrate": TARGET
   may go below 20 (preliminary range [8, 99]) but the session is
   valid only with the calibration run cross-check above. */
static int discharge_session(const char *config_path, int *out_target) {
    char path[1200];
    const char *slash = strrchr(config_path, '/');
    if (slash) {
        size_t dlen = (size_t)(slash - config_path);
        snprintf(path, sizeof(path), "%.*s/.discharge_session", (int)dlen, config_path);
    } else {
        snprintf(path, sizeof(path), ".discharge_session");
    }
    if (access(path, F_OK) != 0)
        return 0;
    FILE *f = fopen(path, "r");
    if (!f)
        return 2;
    char mode[64] = "";
    char target_s[64] = "";
    char started_s[64] = "";
    char run_s[64] = "";
    int have_mode = 0, have_target = 0, have_started = 0, have_run = 0;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        char *eq = strchr(line, '=');
        if (!eq)
            continue;
        *eq = '\0';
        char *val = eq + 1;
        size_t vl = strlen(val);
        while (vl > 0 && (val[vl - 1] == '\n' || val[vl - 1] == '\r'))
            val[--vl] = '\0';
        if (strcmp(line, "MODE") == 0) {
            snprintf(mode, sizeof(mode), "%s", val);
            have_mode = 1;
        } else if (strcmp(line, "TARGET") == 0) {
            snprintf(target_s, sizeof(target_s), "%s", val);
            have_target = 1;
        } else if (strcmp(line, "STARTED") == 0) {
            snprintf(started_s, sizeof(started_s), "%s", val);
            have_started = 1;
        } else if (strcmp(line, "RUN") == 0) {
            snprintf(run_s, sizeof(run_s), "%s", val);
            have_run = 1;
        }
    }
    fclose(f);
    if (!have_mode || !have_target || !have_started)
        return 2;
    int is_cal = (strcmp(mode, "calibrate") == 0);
    if (!is_cal && strcmp(mode, "user") != 0 && strcmp(mode, "corrective") != 0)
        return 2;
    long target = 0, started = 0;
    if (is_cal) {
        /* v1.3: preliminary range only — the run cross-check below
           enforces TARGET >= the run's ABS_FLOOR. */
        if (parse_strict_long(target_s, &target) != 0 || target < 8 || target > 99)
            return 2;
    } else {
        if (parse_strict_long(target_s, &target) != 0 || target < 20 || target > 99)
            return 2;
    }
    if (parse_strict_long(started_s, &started) != 0 || started <= 0)
        return 2;
    long now = (long)time(NULL);
    if (started > now)
        return 2;
    if (now - started > discharge_max_age_s(config_path))
        return 2;
    if (is_cal) {
        if (!have_run)
            return 2;
        if (!calibration_run_ok(config_path, run_s, target))
            return 2;
    }
    *out_target = (int)target;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Battery % from ioreg (AppleSmartBattery). Same pattern as the        */
/* proven status prototype (bc-status).                                 */
/* ------------------------------------------------------------------ */

static int dict_long(CFDictionaryRef d, const char *key, long *out) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!k)
        return 0;
    CFNumberRef v = (CFNumberRef)CFDictionaryGetValue(d, k);
    CFRelease(k);
    if (!v || CFGetTypeID(v) != CFNumberGetTypeID())
        return 0;
    long val = 0;
    if (!CFNumberGetValue(v, kCFNumberLongType, &val))
        return 0;
    *out = val;
    return 1;
}

static int dict_bool(CFDictionaryRef d, const char *key, int *out) {
    CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
    if (!k)
        return 0;
    CFTypeRef v = CFDictionaryGetValue(d, k);
    CFRelease(k);
    if (!v || CFGetTypeID(v) != CFBooleanGetTypeID())
        return 0;
    *out = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    return 1;
}

/* Returns 0 on success. pct is 0-100 (rounded down). The capacity
   (mAh) and amperage (mA, signed: > 0 = current flowing into the
   battery) outputs are optional (either may be NULL); amperage
   reads 0 when the property is absent. */
static int ioreg_battery(int *pct, int *is_charging, int *external_connected,
                         long *out_cap, long *out_amp) {
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSmartBattery");
    if (!matching)
        return -1;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault, matching, &it) != KERN_SUCCESS)
        return -1;
    io_service_t svc = IOIteratorNext(it);
    IOObjectRelease(it);
    if (!svc)
        return -1;
    CFMutableDictionaryRef props = NULL;
    if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS) {
        IOObjectRelease(svc);
        return -1;
    }
    IOObjectRelease(svc);
    if (!props)
        return -1;
    long cur = 0, max = 0;
    int ok_cur = dict_long(props, "CurrentCapacity", &cur);
    int ok_max = dict_long(props, "MaxCapacity", &max);
    long amp = 0;
    (void)dict_long(props, "Amperage", &amp);
    int chg = 0, ext = 0;
    dict_bool(props, "IsCharging", &chg);
    dict_bool(props, "ExternalConnected", &ext);
    CFRelease(props);
    if (!ok_cur || !ok_max || max <= 0 || cur < 0)
        return -1;
    if (out_cap)
        *out_cap = cur;
    if (out_amp)
        *out_amp = amp;
    *pct = (int)((100L * cur) / max);
    if (*pct < 0) *pct = 0;
    if (*pct > 100) *pct = 100;
    *is_charging = chg;
    *external_connected = ext;
    return 0;
}

/* ------------------------------------------------------------------ */
/* main                                                                 */
/* ------------------------------------------------------------------ */

static void usage(const char *prog) {
    printf("bc-limit %s — Battery Commander limit enforcer (dry-run default)\n", BC_VERSION);
    printf("usage: %s [--probe] [--dry-run] [--write] [--config PATH] [--log PATH]\n", prog);
    printf("             [--upper N] [--lower N] [--backend NAME]\n");
    printf("  --probe    probe SMC keys and print the selected backend (read-only)\n");
    printf("  --dry-run  log what WOULD be written, write nothing (default)\n");
    printf("  --write    actually write (Phase B only — separate approval required)\n");
    printf("  --test-write  Phase B test: write BCLM=10 once when already 10 (BCLM only)\n");
    printf("  --backend  force a backend for testing (must have been probed present)\n");
}

int main(int argc, char **argv) {
    int do_probe = 0;
    int dry_run = 1; /* DEFAULT: dry-run ON (design rule 7, Phase A) */
    int want_write = 0;
    int do_test_write = 0;
    const char *config_path = NULL;
    const char *log_path = NULL;
    int arg_upper = -1, arg_lower = -1;
    const char *force_backend = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--probe") == 0) {
            do_probe = 1;
        } else if (strcmp(argv[i], "--dry-run") == 0) {
            dry_run = 1;
        } else if (strcmp(argv[i], "--write") == 0) {
            want_write = 1;
            dry_run = 0;
        } else if (strcmp(argv[i], "--test-write") == 0) {
            do_test_write = 1;
        } else if (strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
            config_path = argv[++i];
        } else if (strcmp(argv[i], "--log") == 0 && i + 1 < argc) {
            log_path = argv[++i];
        } else if (strcmp(argv[i], "--upper") == 0 && i + 1 < argc) {
            arg_upper = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--lower") == 0 && i + 1 < argc) {
            arg_lower = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--backend") == 0 && i + 1 < argc) {
            force_backend = argv[++i];
        } else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

    if (sizeof(SMCKeyData_t) != 80) {
        fprintf(stderr, "STOP: SMCKeyData_t size != 80, do not trust results\n");
        return 1;
    }

    char dir[1024];
    exe_dir(dir, sizeof(dir));
    char default_config[1200];
    char default_log[1200];
    snprintf(default_config, sizeof(default_config), "%s/limit.conf", dir);
    snprintf(default_log, sizeof(default_log), "%s/limit.log", dir);
    if (!config_path) config_path = default_config;
    if (!log_path) log_path = default_log;
    log_open(log_path);

    log_msg("bc-limit %s starting (dry_run=%d)", BC_VERSION, dry_run);

    io_connect_t conn = 0;
    if (smc_open(&conn) != 0) {
        log_msg("ERROR: cannot open SMC connection");
        log_close();
        return 1;
    }

    Backend be = probe_backend(conn);
    const BackendDesc *bd = backend_by_id(be);
    log_msg("selected backend: %s", bd->name);

    if (force_backend) {
        int found = 0;
        size_t n = sizeof(kBackends) / sizeof(kBackends[0]);
        for (size_t i = 0; i < n; i++) {
            if (strcmp(kBackends[i].name, force_backend) == 0) {
                if (kBackends[i].id != be) {
                    log_msg("ERROR: --backend %s was not probed present (selected=%s); refusing", force_backend, bd->name);
                    IOServiceClose(conn);
                    log_close();
                    return 2;
                }
                found = 1;
                break;
            }
        }
        if (!found) {
            log_msg("ERROR: unknown --backend %s", force_backend);
            IOServiceClose(conn);
            log_close();
            return 2;
        }
        log_msg("--backend %s accepted (probed present)", force_backend);
    }

    if (do_probe) {
        printf("selected backend: %s\n", bd->name);
        IOServiceClose(conn);
        log_close();
        return 0;
    }

    if (be == BE_MONITOR || !bd->toggle) {
        /* Monitor-only (design rule 9): report status, enforce nothing. */
        int pct = -1, chg = 0, ext = 0;
        if (ioreg_battery(&pct, &chg, &ext, NULL, NULL) == 0)
            log_msg("monitor-only: backend=%s pct=%d%% charging=%d external=%d (no enforcement)", bd->name, pct, chg, ext);
        else
            log_msg("monitor-only: backend=%s (battery %% read failed)", bd->name);
        printf("monitor-only: backend=%s (no enforcement)\n", bd->name);
        IOServiceClose(conn);
        log_close();
        return 0;
    }


    /* --test-write (Phase B): write BCLM=10 once, but ONLY when BCLM
       is already 10 (the already-10 guard — the test verifies the
       write path without changing state). BCLM backend only. If
       --test-write and --write are both given, test-write wins. */
    if (do_test_write) {
        if (be != BE_BCLM) {
            log_msg("ERROR: --test-write is BCLM-only (selected backend=%s); refusing", bd->name);
            IOServiceClose(conn);
            log_close();
            return 2;
        }
        unsigned long tkval = 0;
        if (backend_read_value(conn, bd, &tkval) != 0) {
            log_msg("ERROR: cannot read BCLM; not writing");
            IOServiceClose(conn);
            log_close();
            return 1;
        }
        if (tkval != 10) {
            log_msg("ERROR: --test-write requires BCLM already 10 (current=%lu); refusing (would change state)", tkval);
            IOServiceClose(conn);
            log_close();
            return 2;
        }
        log_msg("TEST-WRITE: writing BCLM=10 (already 10; write-path test)");
        if (backend_write_value(conn, bd, 10) != 0) {
            log_msg("ERROR: test-write BCLM=10 failed (write error or read-back mismatch); no retry");
            IOServiceClose(conn);
            log_close();
            return 1;
        }
        log_msg("TEST-WRITE OK: BCLM=10 verified by read-back");
        printf("TEST-WRITE OK: BCLM=10 verified by read-back\n");
        IOServiceClose(conn);
        log_close();
        return 0;
    }

    /* Toggle backend: read config, battery %, and the control key. */
    int upper = -1, lower = -1;
    if (arg_upper > 0 && arg_lower > 0) {
        upper = arg_upper;
        lower = arg_lower;
        if (upper < 15 || upper > 100 || lower < 15 || lower > 100 || upper <= lower) {
            log_msg("ERROR: invalid --upper/--lower (%d/%d)", upper, lower);
            IOServiceClose(conn);
            log_close();
            return 2;
        }
        log_msg("limits from args: upper=%d lower=%d", upper, lower);
    } else {
        if (read_config(config_path, &upper, &lower) != 0) {
            log_msg("ERROR: cannot read valid limits from %s (need LAST_UPPER=/LAST_LOWER=, 15-100, upper>lower)", config_path);
            IOServiceClose(conn);
            log_close();
            return 1;
        }
        log_msg("limits from %s: upper=%d lower=%d", config_path, upper, lower);
    }

    int pct = -1, chg = 0, ext = 0;
    long cur_cap = -1, amp_now = 0;
    if (ioreg_battery(&pct, &chg, &ext, &cur_cap, &amp_now) != 0) {
        log_msg("ERROR: cannot read battery %% (ioreg); not writing");
        IOServiceClose(conn);
        log_close();
        return 1;
    }
    if (pct < 0 || pct > 100) {
        log_msg("ERROR: battery %% out of range (%d); not writing", pct);
        IOServiceClose(conn);
        log_close();
        return 1;
    }

    unsigned long kval = 0;
    if (backend_read_value(conn, bd, &kval) != 0) {
        log_msg("ERROR: cannot read control key %s; not writing", bd->key);
        IOServiceClose(conn);
        log_close();
        return 1;
    }
    if (kval != bd->hold && kval != bd->resume) {
        log_msg("ERROR: control key %s has unexpected value %lu (expected %lu or %lu); not writing",
                bd->key, kval, bd->hold, bd->resume);
        IOServiceClose(conn);
        log_close();
        return 1;
    }

    log_msg("state: backend=%s upper=%d lower=%d pct=%d%% %s=%lu charging=%d external=%d",
            bd->name, upper, lower, pct, bd->key, kval, chg, ext);

    /* Discharge session (design section 4.2): read-only check for a
       session file next to the --config file. An existing-but-invalid
       file is logged once here and then ignored (normal rules). */
    int session_target = -1;
    int session_rc = discharge_session(config_path, &session_target);
    int session_valid = (session_rc == 1);
    if (session_rc == 2)
        log_msg("discharge session: invalid file ignored");

    /* Decision (design section 3): write only on state change. */
    int decision = 0; /* 0 = nothing, 1 = write hold, 2 = write resume */
    unsigned long target = 0;
    if (pct >= upper && kval == bd->resume) {
        decision = 1;
        target = bd->hold;
    } else if (pct <= lower && kval == bd->hold) {
        /* Rule 4: resume only if pct <= lower (implies pct < upper). */
        decision = 2;
        target = bd->resume;
    }


    /* Gauge confirmation (Phase C deferral, made a true
       confirm-before-write in v1.5-gauge): run the confirmation
       state machine on every invocation. A >= 5-point move against
       the confirmed baseline records the new level as an
       UNCONFIRMED candidate; the candidate confirms when a later
       invocation reads within 2 points of it, and is abandoned
       when the % relaxes back within 5 of the baseline. While a
       candidate is pending, no write is based on the new level.
       The capacity of the PREVIOUS invocation is kept for the
       second-signal gate below. If the state file is unusable,
       enforcement proceeds (fail open) with a warning, as Phase C
       did. */
    char last_path[1200];
    snprintf(last_path, sizeof(last_path), "%s/.bc-limit-last-pct", dir);
    int g_last = -1, g_cand = -1;
    long g_cap = -1;
    int have_last = (read_gauge_state(last_path, &g_last, &g_cand, &g_cap) == 0);
    long prev_cap = g_cap;
    int gauge_confirmed = 1;
    int gauge_logged = 0; /* a GAUGE line was already emitted this run */
    if (have_last) {
        if (g_cand >= 0) {
            int d_cand = pct - g_cand;
            if (d_cand < 0) d_cand = -d_cand;
            int d_base = pct - g_last;
            if (d_base < 0) d_base = -d_base;
            if (d_cand <= 2) {
                log_msg("GAUGE CONFIRMED: pct %d%% confirmed by a second read (candidate was %d%%); normal decisions resume", pct, g_cand);
                g_last = pct;
                g_cand = -1;
            } else if (d_base < 5) {
                log_msg("GAUGE JUMP CLEARED: pct %d%% back near baseline %d%% (candidate %d%% abandoned); normal decisions resume", pct, g_last, g_cand);
                g_last = pct;
                g_cand = -1;
            } else {
                /* Still moving: track the newest reading as the
                   candidate and keep deferring. */
                g_cand = pct;
                gauge_confirmed = 0;
            }
        } else {
            int delta = pct - g_last;
            if (delta < 0) delta = -delta;
            if (delta >= 5) {
                log_msg("GAUGE JUMP SUSPECTED: pct %d -> %d (delta %d) in one interval; awaiting a confirming read (no write performed)", g_last, pct, pct - g_last);
                printf("gauge jump suspected: pct %d -> %d (delta %d); awaiting a confirming read\n", g_last, pct, pct - g_last);
                g_cand = pct;
                gauge_confirmed = 0;
                gauge_logged = 1;
            } else {
                g_last = pct;
            }
        }
    } else {
        g_last = pct;
    }
    if (write_gauge_state(last_path, g_last, g_cand, cur_cap) != 0)
        log_msg("WARN: cannot record gauge state to %s (gauge confirmation unavailable this run)", last_path);
    if (decision != 0 && !gauge_confirmed) {
        if (!gauge_logged)
            log_msg("GAUGE JUMP UNCONFIRMED: pct %d%% not yet confirmed by a second read; deferring write this cycle (no write performed)", pct);
        printf("gauge jump unconfirmed: pct %d%%; deferring write this cycle\n", pct);
        IOServiceClose(conn);
        log_close();
        return 0;
    }

    /* Discharge session (design section 4.2), integrated after the
       gauge confirmation above and checked before the APG gate
       below: while a session is valid, the resume write is
       suppressed, and while pct > TARGET the hold value is the
       desired value. Any write still goes through the single write
       path below (read-back verify, one write per invocation,
       dry-run WOULD-WRITE semantics unchanged). */
    if (session_valid && decision == 2) {
        log_msg("discharge session: resume suppressed (target=%d)", session_target);
        printf("discharge session: resume suppressed (target=%d)\n", session_target);
        IOServiceClose(conn);
        log_close();
        return 0;
    }
    if (session_valid && decision == 0 && pct > session_target && kval == bd->resume) {
        /* This write is decided after the gauge confirmation above
           (which only gates an already-decided write); apply the
           same confirmation to it. */
        if (!gauge_confirmed) {
            if (!gauge_logged)
                log_msg("GAUGE JUMP UNCONFIRMED: pct %d%% not yet confirmed by a second read; deferring write this cycle (no write performed)", pct);
            printf("gauge jump unconfirmed: pct %d%%; deferring write this cycle\n", pct);
            IOServiceClose(conn);
            log_close();
            return 0;
        }
        decision = 1;
        target = bd->hold;
    }

    if (decision == 0) {
        log_msg("decision: nothing to do (pct=%d%%, %s=%lu already correct)", pct, bd->key, kval);
        printf("nothing to do: pct=%d%% %s=%lu\n", pct, bd->key, kval);
        IOServiceClose(conn);
        log_close();
        return 0;
    }

    /* APG pause (M6, consolidation; reason gate v1.4-apggate,
       2026-11-16): if .apg_paused exists in the directory of the
       --config file, suppress ONLY the resume write (decision == 2)
       — and only when the pause is thermal or its recorded reason
       is unknown. A load-only pause (reason file says exactly
       "load") does NOT suppress: the resume proceeds below and the
       bypass is logged. Hold writes are never suppressed. */
    if (decision == 2) {
        char paused_path[1200];
        const char *slash = strrchr(config_path, '/');
        if (slash) {
            size_t dlen = (size_t)(slash - config_path);
            snprintf(paused_path, sizeof(paused_path), "%.*s/.apg_paused", (int)dlen, config_path);
        } else {
            snprintf(paused_path, sizeof(paused_path), ".apg_paused");
        }
        if (access(paused_path, F_OK) == 0) {
            int reason = apg_pause_reason(config_path);
            if (reason == APG_REASON_LOAD) {
                log_msg("APG load-pause: resume allowed (reason=load)");
                printf("APG load-pause: resume allowed (reason=load)\n");
                /* fall through to the write path */
            } else if (reason == APG_REASON_THERMAL) {
                log_msg("APG paused: resume suppressed (reason=thermal)");
                printf("APG paused: resume suppressed (reason=thermal)\n");
                IOServiceClose(conn);
                log_close();
                return 0;
            } else {
                log_msg("APG paused: resume suppressed (reason=unknown)");
                printf("APG paused: resume suppressed (reason=unknown)\n");
                IOServiceClose(conn);
                log_close();
                return 0;
            }
        }
    }

    /* Second-signal gate (v1.5-gauge, 2026-11-12 audit rule): a
       HOLD write whose premise is an overshoot (pct > upper+2)
       requires a second signal — IsCharging, Amperage > 0, or
       CurrentCapacity rising across two ticks. With zero current
       and a flat capacity the write has no physical effect anyway
       (nothing is charging), and the moment real energy flows the
       evidence exists and the gate passes; a phantom gauge jump
       can never stampede the write. Resume writes and the
       discharge-session suppression are NOT gated. */
    if (decision == 1 && pct > upper + 2
            && !second_signal(chg, amp_now, cur_cap, prev_cap)) {
        log_msg("HOLD DEFERRED: overshoot pct=%d%% (upper=%d) without second signal (chg=%d amp=%ld cap %ld -> %ld); no write this cycle", pct, upper, chg, amp_now, prev_cap, cur_cap);
        printf("hold deferred: overshoot pct=%d%% without second signal\n", pct);
        IOServiceClose(conn);
        log_close();
        return 0;
    }

    if (dry_run) {
        log_msg("DRY-RUN: WOULD WRITE %s=%lu (pct=%d%% %s %s=%lu). No write performed.",
                bd->key, target, pct,
                decision == 1 ? ">=" : "<=",
                decision == 1 ? "upper" : "lower",
                decision == 1 ? (unsigned long)upper : (unsigned long)lower);
        printf("DRY-RUN: would write %s=%lu (no write performed)\n", bd->key, target);
        IOServiceClose(conn);
        log_close();
        return 0;
    }

    /* Real write path (Phase B only — separate approval required).
       At most one write per invocation (design rule 5). */
    (void)want_write;
    log_msg("WRITE: %s=%lu (pct=%d%%)", bd->key, target, pct);
    if (backend_write_value(conn, bd, target) != 0) {
        log_msg("ERROR: write %s=%lu failed (read-back mismatch or write error); no retry", bd->key, target);
        IOServiceClose(conn);
        log_close();
        return 1;
    }
    log_msg("WRITE OK: %s=%lu verified by read-back", bd->key, target);
    printf("wrote %s=%lu (verified)\n", bd->key, target);
    IOServiceClose(conn);
    log_close();
    return 0;
}


