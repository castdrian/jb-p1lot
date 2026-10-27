#import "Health.h"
#import "BridgeProtocol.h"
#import "Display.h"
#import "IOKitBridge.h"
#import <sys/mount.h>
#import <sys/sysctl.h>
#import <os/log.h>

static NSString * const JBP1lotHealthConfigPath = @"/var/mobile/Library/Preferences/dev.adrian.jb-p1lot.health.json";
static NSString * const JBP1lotHealthStatePath = @"/var/mobile/Library/Logs/jb-p1lot-health.json";
static NSString * const JBP1lotCrashReporterPath = @"/var/mobile/Library/Logs/CrashReporter";
static NSUInteger const JBP1lotHistoryLimit = 1440;
static NSUInteger const JBP1lotAlertLimit = 200;
static NSTimeInterval const JBP1lotPolicyInterval = 30;
static NSTimeInterval const JBP1lotSampleInterval = 60;

static dispatch_queue_t JBP1lotHealthQueue;
static dispatch_source_t JBP1lotHealthTimer;
static NSMutableDictionary *JBP1lotConfig;
static NSMutableArray *JBP1lotHistory;
static NSMutableArray *JBP1lotAlerts;
static NSMutableDictionary *JBP1lotPolicy;
static NSDate *JBP1lotLastSample;
static NSDate *JBP1lotLastPersist;
static NSDate *JBP1lotLastCrashScan;

static NSDictionary *JBP1lotDefaultConfig(void) {
    return @{
        @"chargeLimit": @{ @"enabled": @YES, @"low": @50, @"high": @80 },
        @"chargeMode": @"auto",
        @"thermal": @{ @"enabled": @YES, @"pauseChargingC": @40, @"throttleC": @43, @"dimC": @45, @"resumeC": @37 },
        @"alerts": @{ @"freeStorageMB": @2048, @"availableMemoryPercent": @8, @"temperatureC": @42 },
    };
}

static id JBP1lotReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
}

static void JBP1lotWriteJSON(NSString *path, id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:path atomically:YES];
}

static NSMutableDictionary *JBP1lotMergedSection(NSDictionary *defaults, id overrides) {
    NSMutableDictionary *merged = [defaults mutableCopy];
    if ([overrides isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in overrides) {
            if ([defaults[key] isKindOfClass:[NSDictionary class]]) merged[key] = JBP1lotMergedSection(defaults[key], overrides[key]);
            else if (overrides[key] != [NSNull null]) merged[key] = overrides[key];
        }
    }
    return merged;
}

static double JBP1lotNumber(NSDictionary *dictionary, NSString *key, double fallback) {
    id value = dictionary[key];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static double JBP1lotConfigValue(NSString *section, NSString *key) {
    return JBP1lotNumber(JBP1lotConfig[section], key, JBP1lotNumber(JBP1lotDefaultConfig()[section], key, 0));
}

static BOOL JBP1lotConfigFlag(NSString *section) {
    return [JBP1lotConfig[section][@"enabled"] boolValue];
}

static NSNumber *JBP1lotNow(void) {
    return @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
}

static void JBP1lotRecordAlert(NSString *kind, NSString *severity, NSString *message, NSDictionary *details) {
    NSMutableDictionary *alert = [@{ @"time": JBP1lotNow(), @"kind": kind, @"severity": severity, @"message": message } mutableCopy];
    if (details.count) alert[@"details"] = details;
    [JBP1lotAlerts addObject:alert];
    if (JBP1lotAlerts.count > JBP1lotAlertLimit) [JBP1lotAlerts removeObjectsInRange:NSMakeRange(0, JBP1lotAlerts.count - JBP1lotAlertLimit)];
    os_log_with_type(OS_LOG_DEFAULT, [severity isEqualToString:@"critical"] ? OS_LOG_TYPE_FAULT : OS_LOG_TYPE_ERROR, "jb-p1lot health %{public}@: %{public}@", kind, message);
}

NSDictionary *JBP1lotBatterySnapshot(void) {
    NSDictionary *battery = JBP1lotIORegistryProperties("AppleSmartBattery") ?: JBP1lotIORegistryProperties("IOPMPowerSource");
    if (!battery) return @{ @"available": @NO };
    NSDictionary *adapter = [battery[@"AdapterDetails"] isKindOfClass:[NSDictionary class]] ? battery[@"AdapterDetails"] : @{};
    NSDictionary *charger = [battery[@"ChargerData"] isKindOfClass:[NSDictionary class]] ? battery[@"ChargerData"] : @{};
    double design = JBP1lotNumber(battery, @"DesignCapacity", 0);
    double nominal = JBP1lotNumber(battery, @"NominalChargeCapacity", JBP1lotNumber(battery, @"AppleRawMaxCapacity", 0));
    double adapterVoltage = JBP1lotNumber(adapter, @"AdapterVoltage", 0);
    double adapterCurrent = JBP1lotNumber(adapter, @"Current", 0);
    double voltage = JBP1lotNumber(battery, @"Voltage", 0);
    double amperage = JBP1lotNumber(battery, @"InstantAmperage", JBP1lotNumber(battery, @"Amperage", 0));
    uint32_t chargeInhibit = 0;
    uint8_t inflowInhibit = 0;
    BOOL chargeInhibitReadable = JBP1lotSMCRead("CHTE", &chargeInhibit, sizeof(chargeInhibit));
    BOOL inflowInhibitReadable = JBP1lotSMCRead("CHIE", &inflowInhibit, sizeof(inflowInhibit));
    NSMutableDictionary *snapshot = [@{
        @"available": @YES,
        @"percent": battery[@"CurrentCapacity"] ?: @0,
        @"currentCapacityMah": battery[@"AppleRawCurrentCapacity"] ?: @0,
        @"fullChargeCapacityMah": battery[@"AppleRawMaxCapacity"] ?: @0,
        @"designCapacityMah": @(design),
        @"healthPercent": design > 0 ? @(round(nominal / design * 1000) / 10) : @0,
        @"cycleCount": battery[@"CycleCount"] ?: @0,
        @"temperatureC": @(JBP1lotNumber(battery, @"Temperature", 0) / 100.0),
        @"voltageMv": @(voltage),
        @"amperageMa": @(amperage),
        @"powerW": @(round(voltage * amperage / 1000.0) / 1000.0),
        @"isCharging": @([battery[@"IsCharging"] boolValue]),
        @"externalConnected": @([battery[@"ExternalConnected"] boolValue]),
        @"fullyCharged": @([battery[@"FullyCharged"] boolValue]),
        @"notChargingReason": charger[@"NotChargingReason"] ?: @0,
        @"chargingVoltageMv": charger[@"ChargingVoltage"] ?: @0,
        @"chargingCurrentMa": charger[@"ChargingCurrent"] ?: @0,
        @"adapter": @{
            @"description": adapter[@"Description"] ?: @"",
            @"voltageMv": @(adapterVoltage),
            @"currentMa": @(adapterCurrent),
            @"watts": @(round(adapterVoltage * adapterCurrent / 100000.0) / 10.0),
            @"wireless": @([adapter[@"IsWireless"] boolValue]),
        },
    } mutableCopy];
    if (chargeInhibitReadable) snapshot[@"chargeInhibited"] = @((BOOL)(chargeInhibit != 0));
    if (inflowInhibitReadable) snapshot[@"inflowInhibited"] = @((BOOL)(inflowInhibit != 0));
    return snapshot;
}

static NSString *JBP1lotThermalStateName(void) {
    switch (NSProcessInfo.processInfo.thermalState) {
        case NSProcessInfoThermalStateNominal: return @"nominal";
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
    }
    return @"unknown";
}

static NSString *JBP1lotThermalSimulationMode(void) {
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("thermalSimulationMode"), CFSTR("com.apple.cltm")));
    return [value isKindOfClass:[NSString class]] ? value : @"off";
}

static void JBP1lotSetThermalSimulationMode(NSString *mode) {
    CFPreferencesSetAppValue(CFSTR("thermalSimulationMode"), (__bridge CFStringRef)mode, CFSTR("com.apple.cltm"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.cltm"));
}

static int64_t JBP1lotSysctlInteger(const char *name) {
    int64_t value = 0;
    size_t size = sizeof(value);
    if (sysctlbyname(name, &value, &size, NULL, 0) != 0) return -1;
    if (size == sizeof(int32_t)) return *(int32_t *)&value;
    return value;
}

static NSDictionary *JBP1lotMemorySnapshot(void) {
    vm_statistics64_data_t stats = {0};
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t pageSize = 0;
    host_page_size(mach_host_self(), &pageSize);
    host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&stats, &count);
    double megabyte = 1024.0 * 1024.0;
    int64_t pressure = JBP1lotSysctlInteger("kern.memorystatus_vm_pressure_level");
    NSString *pressureName = pressure >= 4 ? @"critical" : pressure >= 2 ? @"warning" : @"normal";
    return @{
        @"totalMB": @(round(JBP1lotSysctlInteger("hw.memsize") / megabyte)),
        @"freeMB": @(round((stats.free_count + stats.speculative_count) * pageSize / megabyte)),
        @"activeMB": @(round(stats.active_count * pageSize / megabyte)),
        @"inactiveMB": @(round(stats.inactive_count * pageSize / megabyte)),
        @"wiredMB": @(round(stats.wire_count * pageSize / megabyte)),
        @"compressedMB": @(round(stats.compressor_page_count * pageSize / megabyte)),
        @"pressure": pressureName,
        @"availableLevel": @(JBP1lotSysctlInteger("kern.memorystatus_level")),
    };
}

static NSDictionary *JBP1lotStorageSnapshot(void) {
    struct statfs data = {0};
    if (statfs("/private/var", &data) != 0) return @{};
    double megabyte = 1024.0 * 1024.0;
    return @{
        @"freeMB": @(round((double)data.f_bavail * data.f_bsize / megabyte)),
        @"totalMB": @(round((double)data.f_blocks * data.f_bsize / megabyte)),
    };
}

static NSNumber *JBP1lotBootTime(void) {
    struct timeval boot = {0};
    size_t size = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) != 0) return @0;
    return @((long long)boot.tv_sec * 1000);
}

static NSArray<NSDictionary *> *JBP1lotCrashReportsSince(NSDate *since, NSString *prefix) {
    NSMutableArray *reports = [NSMutableArray array];
    NSFileManager *manager = [NSFileManager defaultManager];
    for (NSString *name in [manager contentsOfDirectoryAtPath:JBP1lotCrashReporterPath error:nil] ?: @[]) {
        if (![name hasPrefix:prefix]) continue;
        NSString *path = [JBP1lotCrashReporterPath stringByAppendingPathComponent:name];
        NSDate *modified = [manager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
        if (modified && (!since || [modified compare:since] == NSOrderedDescending)) [reports addObject:@{ @"path": path, @"time": @((long long)(modified.timeIntervalSince1970 * 1000)) }];
    }
    return reports;
}

static void JBP1lotSetChargeInhibited(BOOL inhibited, NSString *reason) {
    uint32_t current = 0;
    BOOL readable = JBP1lotSMCRead("CHTE", &current, sizeof(current));
    if (readable && (current != 0) == inhibited) {
        JBP1lotPolicy[@"chargeInhibitReason"] = inhibited ? reason : [NSNull null];
        return;
    }
    uint32_t value = inhibited ? 1 : 0;
    BOOL written = JBP1lotSMCWrite("CHTE", &value, sizeof(value));
    JBP1lotPolicy[@"chargeControl"] = written ? @"smc" : @"unavailable";
    JBP1lotPolicy[@"chargeInhibitReason"] = inhibited && written ? reason : [NSNull null];
    if (!written && inhibited) JBP1lotRecordAlert(@"charge_control", @"warning", @"charge inhibit is unavailable on this device", @{ @"reason": reason });
}

static void JBP1lotEvaluatePolicy(NSDictionary *battery) {
    double percent = JBP1lotNumber(battery, @"percent", 0);
    double temperature = JBP1lotNumber(battery, @"temperatureC", 0);
    BOOL thermalEnabled = JBP1lotConfigFlag(@"thermal");
    BOOL hot = [JBP1lotPolicy[@"thermalPaused"] boolValue] ? temperature > JBP1lotConfigValue(@"thermal", @"resumeC") : temperature >= JBP1lotConfigValue(@"thermal", @"pauseChargingC");
    hot = thermalEnabled && hot;
    if (hot != [JBP1lotPolicy[@"thermalPaused"] boolValue]) {
        JBP1lotRecordAlert(@"thermal", hot ? @"warning" : @"info", hot ? @"battery is hot; charging paused" : @"battery cooled; charging resumed", @{ @"temperatureC": @(temperature) });
        JBP1lotPolicy[@"thermalPaused"] = @(hot);
    }
    BOOL limitEnabled = JBP1lotConfigFlag(@"chargeLimit");
    BOOL limitHolding = [JBP1lotPolicy[@"limitHolding"] boolValue] ? percent > JBP1lotConfigValue(@"chargeLimit", @"low") : percent >= JBP1lotConfigValue(@"chargeLimit", @"high");
    limitHolding = limitEnabled && limitHolding;
    JBP1lotPolicy[@"limitHolding"] = @(limitHolding);
    NSString *mode = [JBP1lotConfig[@"chargeMode"] isKindOfClass:[NSString class]] ? JBP1lotConfig[@"chargeMode"] : @"auto";
    if ([mode isEqualToString:@"inhibit"]) JBP1lotSetChargeInhibited(YES, @"manual");
    else if ([mode isEqualToString:@"allow"]) JBP1lotSetChargeInhibited(hot, @"thermal");
    else JBP1lotSetChargeInhibited(hot || limitHolding, hot ? @"thermal" : @"limit");

    BOOL throttle = thermalEnabled && ([JBP1lotPolicy[@"throttling"] boolValue] ? temperature > JBP1lotConfigValue(@"thermal", @"resumeC") : temperature >= JBP1lotConfigValue(@"thermal", @"throttleC"));
    if (throttle != [JBP1lotPolicy[@"throttling"] boolValue]) {
        JBP1lotSetThermalSimulationMode(throttle ? @"moderate" : @"off");
        JBP1lotPolicy[@"throttling"] = @(throttle);
        JBP1lotRecordAlert(@"thermal_throttle", throttle ? @"critical" : @"info", throttle ? @"battery is very hot; performance throttled" : @"performance throttle released", @{ @"temperatureC": @(temperature) });
    }
    BOOL dim = thermalEnabled && temperature >= JBP1lotConfigValue(@"thermal", @"dimC");
    if (dim && ![JBP1lotPolicy[@"dimmed"] boolValue]) {
        if (!JBP1lotBlackoutEnabled()) JBP1lotSetBlackout(YES, @"thermal");
        JBP1lotRecordAlert(@"thermal_dim", @"critical", @"battery is critically hot; display blacked out", @{ @"temperatureC": @(temperature) });
    }
    JBP1lotPolicy[@"dimmed"] = @(dim);
}

static void JBP1lotCheckAlerts(NSDictionary *battery, NSDictionary *memory, NSDictionary *storage) {
    NSString *pressure = memory[@"pressure"];
    if (![pressure isEqualToString:JBP1lotPolicy[@"memoryPressure"] ?: @"normal"] && ![pressure isEqualToString:@"normal"])
        JBP1lotRecordAlert(@"memory_pressure", [pressure isEqualToString:@"critical"] ? @"critical" : @"warning", [NSString stringWithFormat:@"memory pressure is %@", pressure], memory);
    JBP1lotPolicy[@"memoryPressure"] = pressure;
    double availableLevel = JBP1lotNumber(memory, @"availableLevel", -1);
    BOOL lowMemory = availableLevel >= 0 && availableLevel < JBP1lotConfigValue(@"alerts", @"availableMemoryPercent");
    if (lowMemory && ![JBP1lotPolicy[@"lowMemory"] boolValue]) JBP1lotRecordAlert(@"low_memory", @"warning", @"available memory is low", memory);
    JBP1lotPolicy[@"lowMemory"] = @(lowMemory);
    BOOL lowStorage = storage.count && JBP1lotNumber(storage, @"freeMB", 0) < JBP1lotConfigValue(@"alerts", @"freeStorageMB");
    if (lowStorage && ![JBP1lotPolicy[@"lowStorage"] boolValue]) JBP1lotRecordAlert(@"low_storage", @"warning", @"free storage is low", storage);
    JBP1lotPolicy[@"lowStorage"] = @(lowStorage);
    BOOL hot = JBP1lotNumber(battery, @"temperatureC", 0) >= JBP1lotConfigValue(@"alerts", @"temperatureC");
    if (hot && ![JBP1lotPolicy[@"hot"] boolValue]) JBP1lotRecordAlert(@"temperature", @"warning", @"battery temperature is high", @{ @"temperatureC": battery[@"temperatureC"] ?: @0 });
    JBP1lotPolicy[@"hot"] = @(hot);
    NSDate *scanStart = JBP1lotLastCrashScan;
    JBP1lotLastCrashScan = NSDate.date;
    if (!scanStart) return;
    for (NSDictionary *report in JBP1lotCrashReportsSince(scanStart, @"JetsamEvent"))
        JBP1lotRecordAlert(@"jetsam", @"warning", @"a jetsam event was recorded", report);
    for (NSDictionary *report in JBP1lotCrashReportsSince(scanStart, @"panic"))
        JBP1lotRecordAlert(@"panic", @"critical", @"a kernel panic was recorded", report);
}

static void JBP1lotPersistState(void) {
    JBP1lotWriteJSON(JBP1lotHealthStatePath, @{ @"bootTime": JBP1lotBootTime(), @"history": JBP1lotHistory, @"alerts": JBP1lotAlerts });
    JBP1lotLastPersist = NSDate.date;
}

static void JBP1lotHealthTick(void) {
    @autoreleasepool {
        NSDictionary *battery = JBP1lotBatterySnapshot();
        NSDictionary *memory = JBP1lotMemorySnapshot();
        NSDictionary *storage = JBP1lotStorageSnapshot();
        if ([battery[@"available"] boolValue]) JBP1lotEvaluatePolicy(battery);
        JBP1lotCheckAlerts(battery, memory, storage);
        if (!JBP1lotLastSample || -JBP1lotLastSample.timeIntervalSinceNow >= JBP1lotSampleInterval - 1) {
            JBP1lotLastSample = NSDate.date;
            [JBP1lotHistory addObject:@{
                @"time": JBP1lotNow(),
                @"percent": battery[@"percent"] ?: @0,
                @"temperatureC": battery[@"temperatureC"] ?: @0,
                @"voltageMv": battery[@"voltageMv"] ?: @0,
                @"amperageMa": battery[@"amperageMa"] ?: @0,
                @"charging": battery[@"isCharging"] ?: @NO,
                @"chargeInhibited": battery[@"chargeInhibited"] ?: @NO,
                @"thermalState": JBP1lotThermalStateName(),
                @"freeMemoryMB": memory[@"freeMB"] ?: @0,
                @"memoryPressure": memory[@"pressure"] ?: @"normal",
                @"freeStorageMB": storage[@"freeMB"] ?: @0,
            }];
            if (JBP1lotHistory.count > JBP1lotHistoryLimit) [JBP1lotHistory removeObjectsInRange:NSMakeRange(0, JBP1lotHistory.count - JBP1lotHistoryLimit)];
        }
        if (!JBP1lotLastPersist || -JBP1lotLastPersist.timeIntervalSinceNow >= 600) JBP1lotPersistState();
    }
}

static void JBP1lotLoadState(void) {
    JBP1lotConfig = JBP1lotMergedSection(JBP1lotDefaultConfig(), JBP1lotReadJSON(JBP1lotHealthConfigPath));
    NSDictionary *state = JBP1lotReadJSON(JBP1lotHealthStatePath);
    JBP1lotHistory = [state[@"history"] isKindOfClass:[NSArray class]] ? [state[@"history"] mutableCopy] : [NSMutableArray array];
    JBP1lotAlerts = [state[@"alerts"] isKindOfClass:[NSArray class]] ? [state[@"alerts"] mutableCopy] : [NSMutableArray array];
    JBP1lotPolicy = [NSMutableDictionary dictionary];
    NSNumber *previousBoot = state[@"bootTime"];
    NSNumber *currentBoot = JBP1lotBootTime();
    if (previousBoot && ![previousBoot isEqual:currentBoot]) {
        NSMutableDictionary *details = [@{ @"previousBootTime": previousBoot, @"bootTime": currentBoot } mutableCopy];
        NSArray *panics = JBP1lotCrashReportsSince([NSDate dateWithTimeIntervalSince1970:previousBoot.doubleValue / 1000.0], @"panic");
        if (panics.count) details[@"panics"] = panics;
        JBP1lotRecordAlert(@"reboot", panics.count ? @"critical" : @"info", panics.count ? @"device rebooted after a kernel panic" : @"device rebooted", details);
    }
}

void JBP1lotHealthStart(void) {
    JBP1lotHealthQueue = dispatch_queue_create("dev.adrian.jb-p1lot.health", DISPATCH_QUEUE_SERIAL);
    dispatch_async(JBP1lotHealthQueue, ^{
        JBP1lotLoadState();
        JBP1lotHealthTick();
    });
    JBP1lotHealthTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, JBP1lotHealthQueue);
    dispatch_source_set_timer(JBP1lotHealthTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(JBP1lotPolicyInterval * NSEC_PER_SEC)), (uint64_t)(JBP1lotPolicyInterval * NSEC_PER_SEC), NSEC_PER_SEC);
    dispatch_source_set_event_handler(JBP1lotHealthTimer, ^{
        JBP1lotHealthTick();
    });
    dispatch_resume(JBP1lotHealthTimer);
}

static void JBP1lotReleasePowerControls(void) {
    uint32_t chargeInhibit = 0;
    uint8_t inflowInhibit = 0;
    JBP1lotSMCWrite("CHTE", &chargeInhibit, sizeof(chargeInhibit));
    JBP1lotSMCWrite("CHIE", &inflowInhibit, sizeof(inflowInhibit));
    if (![JBP1lotThermalSimulationMode() isEqualToString:@"off"]) JBP1lotSetThermalSimulationMode(@"off");
    if (JBP1lotHistory) JBP1lotPersistState();
}

void JBP1lotHealthReleasePower(void) {
    if (JBP1lotHealthQueue) dispatch_sync(JBP1lotHealthQueue, ^{
        JBP1lotReleasePowerControls();
    });
    else JBP1lotReleasePowerControls();
}

static NSDictionary *JBP1lotPolicySnapshot(void) {
    return @{
        @"chargeMode": JBP1lotConfig[@"chargeMode"] ?: @"auto",
        @"chargeControl": JBP1lotPolicy[@"chargeControl"] ?: @"smc",
        @"chargeInhibitReason": JBP1lotPolicy[@"chargeInhibitReason"] ?: [NSNull null],
        @"limitHolding": JBP1lotPolicy[@"limitHolding"] ?: @NO,
        @"thermalPaused": JBP1lotPolicy[@"thermalPaused"] ?: @NO,
        @"throttling": JBP1lotPolicy[@"throttling"] ?: @NO,
        @"dimmed": JBP1lotPolicy[@"dimmed"] ?: @NO,
    };
}

static NSArray *JBP1lotTail(NSArray *items, NSInteger limit, NSNumber *since) {
    NSArray *filtered = items;
    if (since.doubleValue > 0) filtered = [items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"time >= %@", since]];
    if (limit <= 0 || (NSUInteger)limit >= filtered.count) return filtered;
    return [filtered subarrayWithRange:NSMakeRange(filtered.count - (NSUInteger)limit, (NSUInteger)limit)];
}

static NSDictionary *JBP1lotStatusPayload(void) {
    return @{
        @"battery": JBP1lotBatterySnapshot(),
        @"policy": JBP1lotPolicySnapshot(),
        @"thermal": @{ @"state": JBP1lotThermalStateName(), @"simulationMode": JBP1lotThermalSimulationMode() },
        @"memory": JBP1lotMemorySnapshot(),
        @"storage": JBP1lotStorageSnapshot(),
        @"bootTime": JBP1lotBootTime(),
        @"uptimeSeconds": @((long long)NSProcessInfo.processInfo.systemUptime),
        @"config": JBP1lotConfig,
        @"alerts": JBP1lotTail(JBP1lotAlerts, 20, nil),
    };
}

NSDictionary *JBP1lotHealthSummary(void) {
    __block NSDictionary *summary = @{};
    if (!JBP1lotHealthQueue) return summary;
    dispatch_sync(JBP1lotHealthQueue, ^{
        NSDictionary *battery = JBP1lotBatterySnapshot();
        NSDictionary *memory = JBP1lotMemorySnapshot();
        summary = @{
            @"batteryPercent": battery[@"percent"] ?: @0,
            @"temperatureC": battery[@"temperatureC"] ?: @0,
            @"charging": battery[@"isCharging"] ?: @NO,
            @"chargeInhibited": battery[@"chargeInhibited"] ?: @NO,
            @"thermalState": JBP1lotThermalStateName(),
            @"memoryPressure": memory[@"pressure"] ?: @"normal",
            @"recentAlerts": @(JBP1lotTail(JBP1lotAlerts, 0, @([JBP1lotNow() longLongValue] - 3600 * 1000)).count),
        };
    });
    return summary;
}

static NSDictionary *JBP1lotConfigure(NSDictionary *params) {
    NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"chargeLimit", @"thermal", @"alerts"])
        if ([params[key] isKindOfClass:[NSDictionary class]]) overrides[key] = params[key];
    NSString *mode = [params[@"chargeMode"] isKindOfClass:[NSString class]] ? [params[@"chargeMode"] lowercaseString] : nil;
    if (mode && ![@[@"auto", @"inhibit", @"allow"] containsObject:mode])
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"chargeMode must be auto, inhibit, or allow") };
    NSMutableDictionary *next = JBP1lotMergedSection(JBP1lotDefaultConfig(), JBP1lotConfig);
    next = JBP1lotMergedSection(next, overrides);
    if (mode) next[@"chargeMode"] = mode;
    double low = JBP1lotNumber(next[@"chargeLimit"], @"low", 50), high = JBP1lotNumber(next[@"chargeLimit"], @"high", 80);
    if (low < 5 || high > 100 || low >= high)
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"chargeLimit needs 5 <= low < high <= 100") };
    JBP1lotConfig = next;
    JBP1lotWriteJSON(JBP1lotHealthConfigPath, JBP1lotConfig);
    JBP1lotHealthTick();
    return @{ @"status": @"ok", @"payload": JBP1lotStatusPayload() };
}

NSDictionary *JBP1lotHealthRequest(NSDictionary *params) {
    NSString *action = [params[@"action"] isKindOfClass:[NSString class]] ? [params[@"action"] lowercaseString] : @"status";
    __block NSDictionary *response = nil;
    dispatch_sync(JBP1lotHealthQueue, ^{
        if (action.length == 0 || [action isEqualToString:@"status"]) {
            response = @{ @"status": @"ok", @"payload": JBP1lotStatusPayload() };
        } else if ([action isEqualToString:@"history"]) {
            response = @{ @"status": @"ok", @"payload": @{ @"samples": JBP1lotTail(JBP1lotHistory, [params[@"limit"] integerValue] ?: 120, params[@"sinceMs"]), @"intervalSeconds": @(JBP1lotSampleInterval) } };
        } else if ([action isEqualToString:@"alerts"]) {
            NSArray *alerts = JBP1lotTail(JBP1lotAlerts, [params[@"limit"] integerValue] ?: 50, params[@"sinceMs"]);
            if ([params[@"clear"] boolValue]) {
                [JBP1lotAlerts removeAllObjects];
                JBP1lotPersistState();
            }
            response = @{ @"status": @"ok", @"payload": @{ @"alerts": alerts } };
        } else if ([action isEqualToString:@"configure"]) {
            response = JBP1lotConfigure(params);
        } else {
            response = @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"device_health action must be status, history, alerts, or configure") };
        }
    });
    return response;
}
