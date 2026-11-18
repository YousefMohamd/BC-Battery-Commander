/* status_prototype.c — READ-ONLY status for the independent BattOpt binary.
 *
 * Scope, from workspace/battopt-reader/status_prototype_design.md:
 *  - SMC commands 9 (READ_KEYINFO) and 5 (READ_BYTES) only.
 *  - No SMC modification function, no limit, no discharge, no charge,
 *    no calibrate, no trial line, no Zone/WiFi, no config modification.
 *  - Upper/lower are NOT derived from SMC: BCLM=10, ACLM=4480, BWLM=0,
 *    CHGC=98 on this Mac are NOT 86/85, so they are deliberately not read
 *    here as limits. Upper/lower live in the wrapper config file.
 *  - A missing or failed field prints "unknown" / "unavailable", never 0
 *    as if it were a real value.
 *  - macOS only: IOKit headers are not available on Linux, so this file
 *    cannot be compiled in this workspace; it is compiled and run on the
 *    Mac, daytime, read-only, with a baseline captured before and after.
 *  - Proven V6 path: SMCKeyData_t must be 80 bytes, SMCOpen via iterator
 *    + IOServiceOpen type 0, selector 2. Reads work without sudo (V6).
 *  - W2.1 extension (Battery Commander): also reads BCLM (ui8) and emits
 *    it as "BCLM: <value>" plus "Backend: bclm" when BCLM reads.
 *    BCLM is the HOLD-STATE indicator (10 = holding, 100 = charging
 *    allowed) — it is NOT the limit % (the limit lives in config).
 *    The full multi-backend probe lives in bc-limit; bc-status reports
 *    the BCLM backend on Intel. A missing BCLM prints "unknown".
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9

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
} SMCKeyData_t; /* must be 80 bytes, checked in main() */

static UInt32 str_to_key(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16)
         | ((UInt32)(unsigned char)s[2] << 8)  | (UInt32)(unsigned char)s[3];
}

/* Returns 0 on success, -1 on keyinfo/read failure or result != 0.
   Caller prints "unavailable" on -1, never 0 as a value. */
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

static UInt16 be16(const unsigned char *b) {
    return (UInt16)(((unsigned)b[0] << 8) | (unsigned)b[1]);
}

/* ioreg AppleSmartBattery properties. Each field has a *_ok flag; a missing
   property leaves its flag at 0 and the caller prints "unknown" for it. */
typedef struct {
    CFMutableDictionaryRef props; /* owned, released by caller */
    long voltage_mv; int voltage_ok;
    long current_mah; int current_ok;
    long max_mah; int max_ok;
    long design_mah; int design_ok;
    long temp_centi; int temp_ok;
    long cycle; int cycle_ok;
    int is_charging; int is_charging_ok;
    int external_connected; int external_ok;
} BatteryProps;

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

static int ioreg_battery(BatteryProps *bp) {
    memset(bp, 0, sizeof(*bp));
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
    bp->props = props;
    bp->voltage_ok = dict_long(props, "Voltage", &bp->voltage_mv);
    bp->current_ok = dict_long(props, "CurrentCapacity", &bp->current_mah);
    bp->max_ok = dict_long(props, "MaxCapacity", &bp->max_mah);
    bp->design_ok = dict_long(props, "DesignCapacity", &bp->design_mah);
    bp->temp_ok = dict_long(props, "Temperature", &bp->temp_centi);
    bp->cycle_ok = dict_long(props, "CycleCount", &bp->cycle);
    bp->is_charging_ok = dict_bool(props, "IsCharging", &bp->is_charging);
    bp->external_ok = dict_bool(props, "ExternalConnected", &bp->external_connected);
    return 0;
}

int main(void) {
    if (sizeof(SMCKeyData_t) != 80) {
        fprintf(stderr, "STOP: SMCKeyData_t size != 80, do not trust results\n");
        return 1;
    }
    mach_port_t masterPort = MACH_PORT_NULL;
    kern_return_t kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "ERROR: IOMasterPort failed %d\n", (int)kr);
        return 1;
    }
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    if (!matching) {
        fprintf(stderr, "ERROR: IOServiceMatching failed\n");
        return 1;
    }
    io_iterator_t iterator = 0;
    kr = IOServiceGetMatchingServices(masterPort, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "ERROR: GetMatchingServices failed %d\n", (int)kr);
        return 1;
    }
    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!service) {
        fprintf(stderr, "ERROR: AppleSMC service not found via iterator\n");
        return 1;
    }
    io_connect_t conn = 0;
    kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "ERROR: IOServiceOpen failed %d\n", (int)kr);
        return 1;
    }

    UInt32 sz = 0;
    unsigned char buf[32];
    double tc0p_c = -1.0, fan_rpm = -1.0;
    int tc0p_ok = 0, fan_ok = 0;
    long b0fc = -1, b0rm = -1, b0ct = -1;
    int b0fc_ok = 0, b0rm_ok = 0, b0ct_ok = 0;
    long bclm = -1;
    int bclm_ok = 0;

    if (smc_read(conn, "TC0P", &sz, buf) == 0 && sz == 2) {
        tc0p_c = be16(buf) / 256.0;
        tc0p_ok = 1;
    }
    if (smc_read(conn, "F0Ac", &sz, buf) == 0 && sz == 2) {
        fan_rpm = be16(buf) / 4.0;
        fan_ok = 1;
    }
    if (smc_read(conn, "B0FC", &sz, buf) == 0 && sz == 2) {
        b0fc = be16(buf);
        b0fc_ok = 1;
    }
    if (smc_read(conn, "B0RM", &sz, buf) == 0 && sz == 2) {
        b0rm = be16(buf);
        b0rm_ok = 1;
    }
    if (smc_read(conn, "B0CT", &sz, buf) == 0 && sz == 2) {
        b0ct = be16(buf);
        b0ct_ok = 1;
    }
    /* BCLM is ui8 (size 1): 10 = hold, 100 = charging allowed. Read-only. */
    if (smc_read(conn, "BCLM", &sz, buf) == 0 && sz >= 1) {
        bclm = buf[0];
        bclm_ok = 1;
    }
    IOServiceClose(conn);

    BatteryProps bp;
    int ioreg_ok = (ioreg_battery(&bp) == 0);

    /* Capacity: SMC B0RM/B0FC, cross-checked against ioreg. */
    if (b0fc_ok && b0rm_ok && b0fc > 0 && b0rm >= 0)
        printf("Capacity: %.1f%%\n", (double)b0rm * 100.0 / (double)b0fc);
    else
        printf("Capacity: unknown\n");

    if (ioreg_ok && bp.voltage_ok)
        printf("Voltage: %.3fV\n", (double)bp.voltage_mv / 1000.0);
    else
        printf("Voltage: unknown\n");

    if (tc0p_ok)
        printf("TempCPU: %.1fC\n", tc0p_c);
    else
        printf("TempCPU: unknown\n");

    if (ioreg_ok && bp.temp_ok)
        printf("TempBatteryPack: %.2fC\n", (double)bp.temp_centi / 100.0);
    else
        printf("TempBatteryPack: unknown\n");

    /* Health: SMC B0FC / ioreg DesignCapacity. No guessed design value. */
    if (b0fc_ok && ioreg_ok && bp.design_ok && bp.design_mah > 0 && b0fc > 0)
        printf("Health: %.1f%%\n", (double)b0fc * 100.0 / (double)bp.design_mah);
    else
        printf("Health: unknown\n");

    if (b0ct_ok)
        printf("Cycle: %ld\n", b0ct);
    else
        printf("Cycle: unknown\n");

    if (b0fc_ok)
        printf("FullCharge: %ld mAh\n", b0fc);
    else
        printf("FullCharge: unknown\n");

    if (b0rm_ok)
        printf("Remaining: %ld mAh\n", b0rm);
    else
        printf("Remaining: unknown\n");

    if (ioreg_ok && bp.design_ok)
        printf("Design: %ld mAh\n", bp.design_mah);
    else
        printf("Design: unknown\n");

    if (ioreg_ok && bp.is_charging_ok)
        printf("IsCharging: %s\n", bp.is_charging ? "Yes" : "No");
    else
        printf("IsCharging: unknown\n");

    if (ioreg_ok && bp.external_ok)
        printf("ExternalConnected: %s\n", bp.external_connected ? "Yes" : "No");
    else
        printf("ExternalConnected: unknown\n");

    if (fan_ok)
        printf("Fan0: %.0f RPM\n", fan_rpm);
    else
        printf("Fan0: unknown\n");

    /* Hold-state indicator (10 = hold, 100 = not holding). Not a limit. */
    if (bclm_ok)
        printf("BCLM: %ld\n", bclm);
    else
        printf("BCLM: unknown\n");

    printf("Backend: %s\n", bclm_ok ? "bclm" : "unknown");

    printf("StatusSource: SMC+ioreg\n");

    /* Cross-check flags, printed only on a real discrepancy, never silently. */
    if (b0fc_ok && b0rm_ok && b0fc > 0 && ioreg_ok && bp.current_ok && bp.max_ok && bp.max_mah > 0) {
        double smc_pct = (double)b0rm * 100.0 / (double)b0fc;
        double ioreg_pct = (double)bp.current_mah * 100.0 / (double)bp.max_mah;
        if (fabs(smc_pct - ioreg_pct) > 1.0)
            printf("CapacityNote: SMC %.1f%% vs ioreg %.1f%% (discrepancy >1%%)\n", smc_pct, ioreg_pct);
    }
    if (b0ct_ok && ioreg_ok && bp.cycle_ok && b0ct != bp.cycle)
        printf("CycleNote: SMC %ld vs ioreg %ld\n", b0ct, bp.cycle);

    printf("READ-ONLY DONE: no SMC modification was performed\n");
    if (bp.props)
        CFRelease(bp.props);
    return 0;
}
