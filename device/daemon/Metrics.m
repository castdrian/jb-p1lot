#import "Metrics.h"
#import "BridgeProtocol.h"
#import "Health.h"
#import "IOKitBridge.h"
#import <ifaddrs.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <net/if.h>
#import <sys/resource.h>

extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

typedef struct {
    uint64_t user, system, idle, nice;
} JBP1lotCPUTicks;

static NSArray<NSValue *> *JBP1lotCoreTicks(void) {
    natural_t count = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) != KERN_SUCCESS) return @[];
    NSMutableArray *cores = [NSMutableArray arrayWithCapacity:count];
    for (natural_t core = 0; core < count; core++) {
        integer_t *ticks = &info[core * CPU_STATE_MAX];
        JBP1lotCPUTicks value = { (uint64_t)ticks[CPU_STATE_USER], (uint64_t)ticks[CPU_STATE_SYSTEM], (uint64_t)ticks[CPU_STATE_IDLE], (uint64_t)ticks[CPU_STATE_NICE] };
        [cores addObject:[NSValue valueWithBytes:&value objCType:@encode(JBP1lotCPUTicks)]];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(integer_t));
    return cores;
}

static double JBP1lotRound(double value) {
    return round(value * 10) / 10;
}

static NSDictionary *JBP1lotCPUDelta(NSArray<NSValue *> *before, NSArray<NSValue *> *after) {
    uint64_t user = 0, system = 0, idle = 0;
    NSMutableArray *cores = [NSMutableArray array];
    for (NSUInteger index = 0; index < MIN(before.count, after.count); index++) {
        JBP1lotCPUTicks start, end;
        [before[index] getValue:&start];
        [after[index] getValue:&end];
        uint64_t coreUser = end.user - start.user + end.nice - start.nice, coreSystem = end.system - start.system, coreIdle = end.idle - start.idle;
        uint64_t total = coreUser + coreSystem + coreIdle;
        [cores addObject:@(total ? JBP1lotRound(100.0 * (coreUser + coreSystem) / total) : 0)];
        user += coreUser;
        system += coreSystem;
        idle += coreIdle;
    }
    uint64_t total = user + system + idle;
    return @{
        @"userPercent": @(total ? JBP1lotRound(100.0 * user / total) : 0),
        @"systemPercent": @(total ? JBP1lotRound(100.0 * system / total) : 0),
        @"totalPercent": @(total ? JBP1lotRound(100.0 * (user + system) / total) : 0),
        @"cores": cores,
    };
}

static NSDictionary<NSString *, NSArray<NSNumber *> *> *JBP1lotInterfaceBytes(void) {
    struct ifaddrs *addresses = NULL;
    if (getifaddrs(&addresses) != 0) return @{};
    NSMutableDictionary *interfaces = [NSMutableDictionary dictionary];
    for (struct ifaddrs *entry = addresses; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_LINK || !entry->ifa_data || !(entry->ifa_flags & IFF_UP)) continue;
        struct if_data *data = (struct if_data *)entry->ifa_data;
        if (data->ifi_ibytes == 0 && data->ifi_obytes == 0) continue;
        interfaces[@(entry->ifa_name)] = @[@(data->ifi_ibytes), @(data->ifi_obytes)];
    }
    freeifaddrs(addresses);
    return interfaces;
}

static NSDictionary *JBP1lotNetworkDelta(NSDictionary<NSString *, NSArray<NSNumber *> *> *before, NSDictionary<NSString *, NSArray<NSNumber *> *> *after, double seconds) {
    NSMutableDictionary *rates = [NSMutableDictionary dictionary];
    for (NSString *name in after) {
        NSArray *start = before[name];
        if (!start) continue;
        uint32_t received = (uint32_t)([after[name][0] unsignedIntValue] - [start[0] unsignedIntValue]);
        uint32_t sent = (uint32_t)([after[name][1] unsignedIntValue] - [start[1] unsignedIntValue]);
        rates[name] = @{ @"rxBytesPerSecond": @(llround(received / seconds)), @"txBytesPerSecond": @(llround(sent / seconds)) };
    }
    return rates;
}

static NSDictionary *JBP1lotGPUSnapshot(void) {
    NSDictionary *accelerator = JBP1lotIORegistryProperties("IOGPU") ?: JBP1lotIORegistryProperties("IOAccelerator");
    NSDictionary *statistics = [accelerator[@"PerformanceStatistics"] isKindOfClass:[NSDictionary class]] ? accelerator[@"PerformanceStatistics"] : nil;
    if (!statistics) return @{ @"available": @NO };
    return @{
        @"available": @YES,
        @"devicePercent": statistics[@"Device Utilization %"] ?: @0,
        @"rendererPercent": statistics[@"Renderer Utilization %"] ?: @0,
        @"tilerPercent": statistics[@"Tiler Utilization %"] ?: @0,
        @"memoryMB": @(llround([statistics[@"In use system memory"] doubleValue] / 1048576.0)),
    };
}

static pid_t JBP1lotResolveProcess(id selector, NSString **resolvedName) {
    NSString *query = [selector isKindOfClass:[NSString class]] ? selector : [selector description];
    if (query.length == 0) return 0;
    pid_t numeric = (pid_t)query.intValue;
    int capacity = proc_listallpids(NULL, 0) + 64;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    int count = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    pid_t match = 0;
    for (int index = 0; index < count && !match; index++) {
        char name[256] = {0};
        proc_name(pids[index], name, sizeof(name));
        NSString *processName = @(name);
        BOOL matches = numeric > 0 ? pids[index] == numeric : [processName caseInsensitiveCompare:query] == NSOrderedSame || [processName.lowercaseString containsString:query.lowercaseString];
        if (matches) {
            match = pids[index];
            if (resolvedName) *resolvedName = processName;
        }
    }
    free(pids);
    return match;
}

static BOOL JBP1lotProcessUsage(pid_t pid, struct rusage_info_v4 *usage) {
    return pid > 0 && proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)usage) == 0;
}

static NSDictionary *JBP1lotProcessDelta(pid_t pid, NSString *name, struct rusage_info_v4 *before, struct rusage_info_v4 *after, double seconds) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) mach_timebase_info(&timebase);
    double cpuNanoseconds = (double)(after->ri_user_time + after->ri_system_time - before->ri_user_time - before->ri_system_time) * timebase.numer / timebase.denom;
    double megabyte = 1048576.0;
    return @{
        @"pid": @(pid),
        @"name": name ?: @"",
        @"cpuPercent": @(JBP1lotRound(cpuNanoseconds / (seconds * 1e9) * 100)),
        @"footprintMB": @(JBP1lotRound(after->ri_phys_footprint / megabyte)),
        @"residentMB": @(JBP1lotRound(after->ri_resident_size / megabyte)),
        @"energyMilliwatts": @(JBP1lotRound((after->ri_billed_energy - before->ri_billed_energy) / 1e6 / seconds)),
        @"diskReadBytesPerSecond": @(llround((after->ri_diskio_bytesread - before->ri_diskio_bytesread) / seconds)),
        @"diskWriteBytesPerSecond": @(llround((after->ri_diskio_byteswritten - before->ri_diskio_byteswritten) / seconds)),
    };
}

static NSDictionary *JBP1lotSummary(NSArray<NSDictionary *> *samples) {
    double cpuTotal = 0, cpuPeak = 0, gpuPeak = 0, processCPUPeak = 0, footprintPeak = 0, powerTotal = 0;
    for (NSDictionary *sample in samples) {
        double cpu = [sample[@"cpu"][@"totalPercent"] doubleValue];
        cpuTotal += cpu;
        cpuPeak = MAX(cpuPeak, cpu);
        gpuPeak = MAX(gpuPeak, [sample[@"gpu"][@"devicePercent"] doubleValue]);
        processCPUPeak = MAX(processCPUPeak, [sample[@"process"][@"cpuPercent"] doubleValue]);
        footprintPeak = MAX(footprintPeak, [sample[@"process"][@"footprintMB"] doubleValue]);
        powerTotal += [sample[@"energy"][@"batteryPowerW"] doubleValue];
    }
    NSUInteger count = MAX(samples.count, 1u);
    return @{
        @"samples": @(samples.count),
        @"cpuAveragePercent": @(JBP1lotRound(cpuTotal / count)),
        @"cpuPeakPercent": @(cpuPeak),
        @"gpuPeakPercent": @(gpuPeak),
        @"processCpuPeakPercent": @(processCPUPeak),
        @"processFootprintPeakMB": @(footprintPeak),
        @"batteryPowerAverageW": @(round(powerTotal / count * 1000) / 1000),
    };
}

NSDictionary *JBP1lotMetricsSample(NSDictionary *params) {
    double interval = MIN(MAX([params[@"intervalMs"] doubleValue] ?: 1000, 250), 10000) / 1000.0;
    double duration = MIN(MAX([params[@"durationMs"] doubleValue] ?: 5000, interval * 1000), 120000) / 1000.0;
    NSString *processName = nil;
    pid_t pid = JBP1lotResolveProcess(params[@"process"] ?: params[@"pid"], &processName);
    if ((params[@"process"] || params[@"pid"]) && pid == 0)
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"not_found", @"no running process matches the selector") };
    NSMutableArray *samples = [NSMutableArray array];
    NSArray *cpuBefore = JBP1lotCoreTicks();
    NSDictionary *networkBefore = JBP1lotInterfaceBytes();
    struct rusage_info_v4 usageBefore = {0}, usageAfter = {0};
    BOOL hasProcess = JBP1lotProcessUsage(pid, &usageBefore);
    NSDate *startDate = NSDate.date;
    NSUInteger total = (NSUInteger)MAX(1, floor(duration / interval));
    for (NSUInteger index = 0; index < total; index++) {
        @autoreleasepool {
            NSDate *tickStart = NSDate.date;
            usleep((useconds_t)(interval * 1e6));
            double seconds = -tickStart.timeIntervalSinceNow;
            NSArray *cpuAfter = JBP1lotCoreTicks();
            NSDictionary *networkAfter = JBP1lotInterfaceBytes();
            NSDictionary *battery = JBP1lotBatterySnapshot();
            NSMutableDictionary *sample = [@{
                @"offsetMs": @(llround(-startDate.timeIntervalSinceNow * 1000)),
                @"cpu": JBP1lotCPUDelta(cpuBefore, cpuAfter),
                @"memory": JBP1lotMemorySnapshot(),
                @"gpu": JBP1lotGPUSnapshot(),
                @"network": JBP1lotNetworkDelta(networkBefore, networkAfter, seconds),
                @"energy": @{ @"batteryPowerW": battery[@"powerW"] ?: @0, @"amperageMa": battery[@"amperageMa"] ?: @0, @"temperatureC": battery[@"temperatureC"] ?: @0 },
            } mutableCopy];
            if (hasProcess && JBP1lotProcessUsage(pid, &usageAfter)) {
                sample[@"process"] = JBP1lotProcessDelta(pid, processName, &usageBefore, &usageAfter, seconds);
                usageBefore = usageAfter;
            } else if (hasProcess) {
                sample[@"process"] = @{ @"pid": @(pid), @"name": processName ?: @"", @"exited": @YES };
                hasProcess = NO;
            }
            [samples addObject:sample];
            cpuBefore = cpuAfter;
            networkBefore = networkAfter;
        }
    }
    return @{ @"status": @"ok", @"payload": @{ @"intervalMs": @(interval * 1000), @"durationMs": @(llround(-startDate.timeIntervalSinceNow * 1000)), @"summary": JBP1lotSummary(samples), @"samples": samples } };
}
