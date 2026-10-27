#import "Display.h"
#import "BridgeProtocol.h"
#import "IOKitBridge.h"
#import <dlfcn.h>
#import <notify.h>

static NSString * const JBP1lotDisplayStatePath = @"/var/mobile/Library/Preferences/dev.adrian.jb-p1lot.display.json";
static char const * const JBP1lotBlackoutToggleNotification = "dev.adrian.jb-p1lot.blackout.toggle";
static NSTimeInterval const JBP1lotDisplayReassertInterval = 3;
static NSTimeInterval const JBP1lotAgentRefreshInterval = 30;

static dispatch_queue_t JBP1lotDisplayQueue;
static dispatch_source_t JBP1lotDisplayTimer;
static BOOL JBP1lotBlackout = YES;
static NSString *JBP1lotBlackoutSource = @"default";
static NSDate *JBP1lotLastAgentRefresh;
static int JBP1lotToggleToken;

typedef int (*JBP1lotFramebufferMainFn)(void **);
typedef int (*JBP1lotFramebufferPowerFn)(void *, int);

static BOOL JBP1lotRequestPanelPower(BOOL on) {
    static JBP1lotFramebufferMainFn mainDisplay;
    static JBP1lotFramebufferPowerFn requestPower;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer", RTLD_NOW);
        mainDisplay = (JBP1lotFramebufferMainFn)dlsym(handle, "IOMobileFramebufferGetMainDisplay");
        requestPower = (JBP1lotFramebufferPowerFn)dlsym(handle, "IOMobileFramebufferRequestPowerChange");
    });
    void *framebuffer = NULL;
    if (!mainDisplay || !requestPower || mainDisplay(&framebuffer) != 0 || !framebuffer) return NO;
    return requestPower(framebuffer, on ? 1 : 0) == 0;
}

static NSNumber *JBP1lotBacklightMicroAmps(void) {
    NSDictionary *backlight = JBP1lotIORegistryProperties("AppleARMBacklight");
    id parameters = backlight[@"IODisplayParameters"];
    id current = [parameters isKindOfClass:[NSDictionary class]] ? parameters[@"BrightnessMicroAmps"] : nil;
    id value = [current isKindOfClass:[NSDictionary class]] ? current[@"value"] : nil;
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

static BOOL JBP1lotTellAgent(BOOL blackout) {
    NSDictionary *request = @{ @"id": @0, @"method": @"ui_action", @"payload": @{ @"action": blackout ? @"dark_on" : @"dark_off", @"source": @"daemon" } };
    NSDictionary *response = nil;
    BOOL delivered = JBP1lotForwardToAgent(request, &response) && ![response[@"status"] isEqual:@"error"];
    if (delivered) JBP1lotLastAgentRefresh = NSDate.date;
    return delivered;
}

static void JBP1lotPersistDisplayState(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"blackout": @(JBP1lotBlackout) } options:0 error:nil];
    [data writeToFile:JBP1lotDisplayStatePath atomically:YES];
}

static void JBP1lotReassertBlackout(void);

static BOOL JBP1lotApplyBlackout(void) {
    BOOL agent = JBP1lotTellAgent(JBP1lotBlackout);
    BOOL panel = JBP1lotRequestPanelPower(!JBP1lotBlackout);
    if (JBP1lotBlackout)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), JBP1lotDisplayQueue, ^{
            JBP1lotReassertBlackout();
        });
    return agent || panel;
}

static BOOL JBP1lotSpringBoardScreenOn(void) {
    NSDictionary *response = nil;
    if (!JBP1lotForwardToAgent(@{ @"id": @0, @"method": @"display.state", @"payload": @{} }, &response)) return YES;
    id on = [response[@"payload"] isKindOfClass:[NSDictionary class]] ? response[@"payload"][@"screenOn"] : nil;
    return on ? [on boolValue] : YES;
}

static void JBP1lotReassertBlackout(void) {
    if (!JBP1lotBlackout) return;
    if (!JBP1lotSpringBoardScreenOn()) return;
    if (!JBP1lotLastAgentRefresh || -JBP1lotLastAgentRefresh.timeIntervalSinceNow >= JBP1lotAgentRefreshInterval) JBP1lotTellAgent(YES);
    NSNumber *current = JBP1lotBacklightMicroAmps();
    if (current && current.integerValue == 0) return;
    JBP1lotRequestPanelPower(YES);
    usleep(200000);
    JBP1lotRequestPanelPower(NO);
}

void JBP1lotDisplayStart(void) {
    JBP1lotDisplayQueue = dispatch_queue_create("dev.adrian.jb-p1lot.display", DISPATCH_QUEUE_SERIAL);
    NSData *data = [NSData dataWithContentsOfFile:JBP1lotDisplayStatePath];
    NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([state isKindOfClass:[NSDictionary class]] && state[@"blackout"]) {
        JBP1lotBlackout = [state[@"blackout"] boolValue];
        JBP1lotBlackoutSource = @"persisted";
    }
    notify_register_dispatch(JBP1lotBlackoutToggleNotification, &JBP1lotToggleToken, JBP1lotDisplayQueue, ^(int token) {
        JBP1lotBlackout = !JBP1lotBlackout;
        JBP1lotBlackoutSource = @"home_triple_press";
        JBP1lotPersistDisplayState();
        JBP1lotApplyBlackout();
    });
    JBP1lotDisplayTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, JBP1lotDisplayQueue);
    dispatch_source_set_timer(JBP1lotDisplayTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(JBP1lotDisplayReassertInterval * NSEC_PER_SEC)), (uint64_t)(JBP1lotDisplayReassertInterval * NSEC_PER_SEC), NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(JBP1lotDisplayTimer, ^{
        JBP1lotReassertBlackout();
    });
    dispatch_resume(JBP1lotDisplayTimer);
    dispatch_async(JBP1lotDisplayQueue, ^{
        JBP1lotApplyBlackout();
    });
}

BOOL JBP1lotSetBlackout(BOOL enabled, NSString *source) {
    __block BOOL performed = NO;
    dispatch_sync(JBP1lotDisplayQueue, ^{
        JBP1lotBlackout = enabled;
        JBP1lotBlackoutSource = source ?: @"request";
        JBP1lotPersistDisplayState();
        performed = JBP1lotApplyBlackout();
    });
    return performed;
}

void JBP1lotRefreshBlackout(void) {
    dispatch_sync(JBP1lotDisplayQueue, ^{
        if (JBP1lotBlackout)
            JBP1lotApplyBlackout();
    });
}

BOOL JBP1lotBlackoutEnabled(void) {
    __block BOOL enabled = NO;
    dispatch_sync(JBP1lotDisplayQueue, ^{
        enabled = JBP1lotBlackout;
    });
    return enabled;
}

NSDictionary *JBP1lotDisplayStatus(void) {
    __block NSDictionary *status = nil;
    dispatch_sync(JBP1lotDisplayQueue, ^{
        NSMutableDictionary *payload = [@{ @"blackout": @(JBP1lotBlackout), @"source": JBP1lotBlackoutSource } mutableCopy];
        NSNumber *current = JBP1lotBacklightMicroAmps();
        if (current) payload[@"backlightMicroAmps"] = current;
        status = payload;
    });
    return status;
}
