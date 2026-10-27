#import "IOKitBridge.h"
#import <dlfcn.h>

typedef struct {
    unsigned char major, minor, build;
    unsigned short release;
} JBP1lotSMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuLimit, gpuLimit, memoryLimit;
} JBP1lotSMCLimits;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} JBP1lotSMCKeyInfo;

typedef struct {
    uint32_t key;
    struct {
        JBP1lotSMCVersion version;
        JBP1lotSMCLimits limits;
        JBP1lotSMCKeyInfo keyInfo;
        uint8_t result, status, command;
        uint32_t data32;
        unsigned char bytes[120];
    } param;
} JBP1lotSMCParam;

enum {
    JBP1lotSMCHandleEvent = 2,
    JBP1lotSMCReadKey = 5,
    JBP1lotSMCWriteKey = 6,
    JBP1lotSMCGetKeyInfo = 9,
};

typedef struct {
    CFMutableDictionaryRef (*matching)(const char *);
    JBP1lotIOObject (*matchingService)(mach_port_t, CFDictionaryRef);
    kern_return_t (*copyProperties)(JBP1lotIOObject, CFMutableDictionaryRef *, CFAllocatorRef, uint32_t);
    kern_return_t (*open)(JBP1lotIOObject, task_port_t, uint32_t, mach_port_t *);
    kern_return_t (*callStruct)(mach_port_t, uint32_t, const void *, size_t, void *, size_t *);
    kern_return_t (*release)(JBP1lotIOObject);
} JBP1lotIOKitFunctions;

static JBP1lotIOKitFunctions *JBP1lotIOKit(void) {
    static JBP1lotIOKitFunctions functions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        functions.matching = dlsym(handle, "IOServiceMatching");
        functions.matchingService = dlsym(handle, "IOServiceGetMatchingService");
        functions.copyProperties = dlsym(handle, "IORegistryEntryCreateCFProperties");
        functions.open = dlsym(handle, "IOServiceOpen");
        functions.callStruct = dlsym(handle, "IOConnectCallStructMethod");
        functions.release = dlsym(handle, "IOObjectRelease");
    });
    return functions.matching && functions.matchingService ? &functions : NULL;
}

NSDictionary *JBP1lotIORegistryProperties(const char *serviceClass) {
    JBP1lotIOKitFunctions *iokit = JBP1lotIOKit();
    if (!iokit || !iokit->copyProperties) return nil;
    JBP1lotIOObject service = iokit->matchingService(0, iokit->matching(serviceClass));
    if (!service) return nil;
    CFMutableDictionaryRef properties = NULL;
    kern_return_t result = iokit->copyProperties(service, &properties, kCFAllocatorDefault, 0);
    iokit->release(service);
    return result == KERN_SUCCESS ? (__bridge_transfer NSDictionary *)properties : nil;
}

static uint32_t JBP1lotFourCC(const char *key) {
    return (uint32_t)key[0] << 24 | (uint32_t)key[1] << 16 | (uint32_t)key[2] << 8 | (uint32_t)key[3];
}

static mach_port_t JBP1lotSMCConnection(void) {
    static mach_port_t connection = MACH_PORT_NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        JBP1lotIOKitFunctions *iokit = JBP1lotIOKit();
        if (!iokit || !iokit->open || !iokit->callStruct) return;
        JBP1lotIOObject service = iokit->matchingService(0, iokit->matching("AppleSMC"));
        if (!service) return;
        if (iokit->open(service, mach_task_self(), 0, &connection) != KERN_SUCCESS) connection = MACH_PORT_NULL;
        iokit->release(service);
    });
    return connection;
}

static BOOL JBP1lotSMCCall(JBP1lotSMCParam *input, JBP1lotSMCParam *output) {
    mach_port_t connection = JBP1lotSMCConnection();
    if (connection == MACH_PORT_NULL) return NO;
    size_t outputSize = sizeof(*output);
    return JBP1lotIOKit()->callStruct(connection, JBP1lotSMCHandleEvent, input, sizeof(*input), output, &outputSize) == KERN_SUCCESS && output->param.result == 0;
}

static BOOL JBP1lotSMCKeyInfoFor(uint32_t key, JBP1lotSMCKeyInfo *info) {
    JBP1lotSMCParam input = {0}, output = {0};
    input.key = key;
    input.param.command = JBP1lotSMCGetKeyInfo;
    if (!JBP1lotSMCCall(&input, &output) || output.param.keyInfo.dataSize == 0) return NO;
    *info = output.param.keyInfo;
    return YES;
}

BOOL JBP1lotSMCRead(const char *key, void *bytes, uint32_t size) {
    JBP1lotSMCParam input = {0}, output = {0};
    input.key = JBP1lotFourCC(key);
    if (!JBP1lotSMCKeyInfoFor(input.key, &input.param.keyInfo)) return NO;
    input.param.command = JBP1lotSMCReadKey;
    if (!JBP1lotSMCCall(&input, &output)) return NO;
    memcpy(bytes, output.param.bytes, MIN(size, input.param.keyInfo.dataSize));
    return YES;
}

BOOL JBP1lotSMCWrite(const char *key, const void *bytes, uint32_t size) {
    JBP1lotSMCParam input = {0}, output = {0};
    input.key = JBP1lotFourCC(key);
    if (!JBP1lotSMCKeyInfoFor(input.key, &input.param.keyInfo) || input.param.keyInfo.dataSize > sizeof(input.param.bytes)) return NO;
    memcpy(input.param.bytes, bytes, MIN(size, input.param.keyInfo.dataSize));
    input.param.command = JBP1lotSMCWriteKey;
    return JBP1lotSMCCall(&input, &output);
}
