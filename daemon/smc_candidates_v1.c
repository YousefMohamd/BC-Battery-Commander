#include <stdio.h>
#include <string.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_KEYINFO 9
typedef struct { char major; char minor; char build; char reserved[1]; UInt16 release; } SMCKeyData_vers_t;
typedef struct { UInt16 version; UInt16 length; UInt32 cpuPLimit; UInt32 gpuPLimit; UInt32 memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct { UInt32 key; SMCKeyData_vers_t vers; SMCKeyData_pLimitData_t pLimitData; SMCKeyData_keyInfo_t keyInfo; char result; char status; char data8; UInt32 data32; char bytes[32]; } SMCKeyData_t;
static UInt32 str_to_key(const char *s) { return ((UInt32)(unsigned char)s[0] << 24) | ((UInt32)(unsigned char)s[1] << 16) | ((UInt32)(unsigned char)s[2] << 8) | (UInt32)(unsigned char)s[3]; }
static void print_type(UInt32 t) { char c[5]; c[0]=(char)((t>>24)&0xff); c[1]=(char)((t>>16)&0xff); c[2]=(char)((t>>8)&0xff); c[3]=(char)(t&0xff); c[4]='\0'; printf("%s", c); }
int main(void) {
    printf("sizeof SMCKeyData_t=%zu (expect 80)\n", sizeof(SMCKeyData_t));
    if (sizeof(SMCKeyData_t) != 80) return 1;
    mach_port_t masterPort = MACH_PORT_NULL;
    kern_return_t kr = IOMasterPort(MACH_PORT_NULL, &masterPort);
    if (kr != KERN_SUCCESS) return 1;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    io_iterator_t iterator = 0;
    kr = IOServiceGetMatchingServices(masterPort, matching, &iterator);
    if (kr != KERN_SUCCESS) return 1;
    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);
    if (!service) return 1;
    io_connect_t conn = 0;
    kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) return 1;
    const char *keys[] = {"TC0P", "F0Ac", "BCLM", "ACLM", "BWLM", "DPLM", "B0FC", "B0RM", "B0St", "B0CT", "BATP", "BCHG", "CHGC", "CHLC", "BNum"};
    for (int i = 0; i < 15; i++) {
        const char *name = keys[i];
        SMCKeyData_t input; SMCKeyData_t output; size_t outputSize;
        memset(&input, 0, sizeof(input)); memset(&output, 0, sizeof(output));
        input.key = str_to_key(name); input.data8 = SMC_CMD_READ_KEYINFO; outputSize = sizeof(output);
        kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &input, sizeof(input), &output, &outputSize);
        if (kr != KERN_SUCCESS) { printf("%s: ERROR read keyinfo %d\n", name, (int)kr); continue; }
        if (output.result != 0) { printf("%s: KeyNotFound or error result=%d\n", name, (int)output.result); continue; }
        UInt32 size = output.keyInfo.dataSize; UInt32 type = output.keyInfo.dataType;
        memset(&input, 0, sizeof(input)); memset(&output, 0, sizeof(output));
        input.key = str_to_key(name); input.keyInfo.dataSize = size; input.data8 = SMC_CMD_READ_BYTES; outputSize = sizeof(output);
        kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &input, sizeof(input), &output, &outputSize);
        if (kr != KERN_SUCCESS) { printf("%s: ERROR read bytes %d\n", name, (int)kr); continue; }
        if (output.result != 0) { printf("%s: read error result=%d\n", name, (int)output.result); continue; }
        printf("%s: size=%u type=", name, (unsigned)size); print_type(type); printf(" bytes=");
        for (UInt32 j = 0; j < size && j < 32; j++) printf("%02x ", (unsigned char)output.bytes[j]);
        printf(" value=");
        if (size == 1) printf("%u\n", (unsigned char)output.bytes[0]);
        else if (size == 2) printf("%u\n", ((unsigned char)output.bytes[0] << 8) | (unsigned char)output.bytes[1]);
        else if (size == 4) printf("%u\n", ((unsigned char)output.bytes[0] << 24) | ((unsigned char)output.bytes[1] << 16) | ((unsigned char)output.bytes[2] << 8) | (unsigned char)output.bytes[3]);
        else printf("(raw above)\n");
    }
    IOServiceClose(conn);
    printf("READ-ONLY DONE: no SMC write was performed\n");
    return 0;
}
