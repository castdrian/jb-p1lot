#import "Accessibility.h"
#import "BridgeProtocol.h"
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>

@protocol JBP1lotAXElement <NSObject>
+ (id)uiApplicationWithPid:(int)pid;
- (id)objectWithAXAttribute:(long)attribute;
- (NSArray *)uiElementsWithAttribute:(long)attribute;
@end

typedef NS_ENUM(long, JBP1lotAXAttribute) {
    JBP1lotAXLabel = 2001,
    JBP1lotAXHint = 2002,
    JBP1lotAXFrame = 2003,
    JBP1lotAXTraits = 2004,
    JBP1lotAXValue = 2006,
    JBP1lotAXActivationPoint = 2007,
    JBP1lotAXVisibleElements = 2095,
};

typedef BOOL (*JBP1lotAXValueGetFn)(CFTypeRef, int, void *);

static NSUInteger const JBP1lotMaxNodes = 2000;
static NSString *JBP1lotCurrentFrame = nil;
static NSArray<NSDictionary *> *JBP1lotCurrentNodes = nil;
static NSObject *JBP1lotSnapshotLock;

static Class JBP1lotAXElementClass(void) {
    static Class elementClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime", RTLD_NOW);
        void *library = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW);
        void (*setAutomation)(int) = dlsym(library, "_AXSSetAutomationEnabled");
        void (*setApplicationAccessibility)(int) = dlsym(library, "_AXSApplicationAccessibilitySetEnabled");
        if (setAutomation) setAutomation(1);
        if (setApplicationAccessibility) setApplicationAccessibility(1);
        elementClass = NSClassFromString(@"AXUIElement");
        JBP1lotSnapshotLock = [NSObject new];
    });
    return elementClass;
}

static BOOL JBP1lotReadAXValue(id value, int type, void *output) {
    static JBP1lotAXValueGetFn getValue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getValue = (JBP1lotAXValueGetFn)dlsym(RTLD_DEFAULT, "AXValueGetValue");
    });
    return value && getValue && CFGetTypeID((__bridge CFTypeRef)value) != CFStringGetTypeID() && getValue((__bridge CFTypeRef)value, type, output);
}

static NSArray<NSString *> *JBP1lotTraitNames(uint64_t traits) {
    NSArray *names = @[@"button", @"link", @"image", @"selected", @"playsSound", @"keyboardKey", @"staticText", @"summaryElement", @"notEnabled", @"updatesFrequently", @"searchField", @"startsMediaSession", @"adjustable", @"allowsDirectInteraction", @"causesPageTurn", @"", @"header"];
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger bit = 0; bit < names.count; bit++)
        if ((traits & (1ULL << bit)) && [names[bit] length]) [result addObject:names[bit]];
    return result;
}

static NSString *JBP1lotStringAttribute(id element, long attribute) {
    id value = [element objectWithAXAttribute:attribute];
    return [value isKindOfClass:[NSString class]] ? value : [value isKindOfClass:[NSAttributedString class]] ? [value string] : nil;
}

static NSDictionary *JBP1lotNodeFromElement(id element, NSUInteger index, NSString *source) {
    CGRect frame = CGRectZero;
    CGPoint activation = CGPointZero;
    if (!JBP1lotReadAXValue([element objectWithAXAttribute:JBP1lotAXFrame], 3, &frame)) return nil;
    BOOL hasActivation = JBP1lotReadAXValue([element objectWithAXAttribute:JBP1lotAXActivationPoint], 1, &activation) && activation.x < 100000;
    if (!hasActivation) activation = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    id traitsValue = [element objectWithAXAttribute:JBP1lotAXTraits];
    uint64_t traits = [traitsValue respondsToSelector:@selector(unsignedLongLongValue)] ? [traitsValue unsignedLongLongValue] : 0;
    NSMutableDictionary *node = [@{
        @"id": [NSString stringWithFormat:@"n%lu", (unsigned long)index],
        @"source": source,
        @"frame": @{ @"x": @(frame.origin.x), @"y": @(frame.origin.y), @"width": @(frame.size.width), @"height": @(frame.size.height) },
        @"activationPoint": @{ @"x": @(activation.x), @"y": @(activation.y) },
        @"traits": JBP1lotTraitNames(traits),
        @"enabled": @((BOOL)!(traits & (1ULL << 8))),
    } mutableCopy];
    NSString *label = JBP1lotStringAttribute(element, JBP1lotAXLabel);
    NSString *value = JBP1lotStringAttribute(element, JBP1lotAXValue);
    NSString *hint = JBP1lotStringAttribute(element, JBP1lotAXHint);
    if (label.length) node[@"label"] = label;
    if (value.length) node[@"value"] = value;
    if (hint.length) node[@"hint"] = hint;
    return node;
}

static NSDictionary *JBP1lotApplicationProcess(NSString *bundleIdentifier) {
    NSDictionary *request = @{ @"id": @0, @"method": @"ui.application", @"payload": bundleIdentifier.length ? @{ @"bundleId": bundleIdentifier } : @{} };
    NSDictionary *response = nil;
    if (!JBP1lotForwardToAgent(request, &response) || ![response[@"payload"] isKindOfClass:[NSDictionary class]]) return nil;
    return response[@"payload"];
}

static NSArray<NSDictionary *> *JBP1lotNodesForPid(int pid, NSString *source, NSUInteger startIndex) {
    id application = [JBP1lotAXElementClass() uiApplicationWithPid:pid];
    NSMutableArray *nodes = [NSMutableArray array];
    for (id element in [application uiElementsWithAttribute:JBP1lotAXVisibleElements] ?: @[]) {
        if (nodes.count >= JBP1lotMaxNodes) break;
        @autoreleasepool {
            NSDictionary *node = JBP1lotNodeFromElement(element, startIndex + nodes.count, source);
            if (node) [nodes addObject:node];
        }
    }
    return nodes;
}

static NSDictionary *JBP1lotCaptureSnapshot(NSDictionary *params, NSDictionary **error) {
    if (!JBP1lotAXElementClass()) {
        if (error) *error = JBP1lotErrorPayload(@"backend_error", @"AXRuntime is unavailable");
        return nil;
    }
    NSString *requested = [params[@"application"] isKindOfClass:[NSString class]] ? params[@"application"] : @"";
    if ([requested isEqualToString:@"frontmost"]) requested = @"";
    NSDictionary *process = JBP1lotApplicationProcess(requested);
    if (!process) {
        if (error) *error = JBP1lotErrorPayload(@"unavailable", @"SpringBoard agent is unavailable");
        return nil;
    }
    if (![process[@"running"] boolValue]) {
        if (error) *error = JBP1lotErrorPayload(@"not_found", [NSString stringWithFormat:@"%@ is not running", requested]);
        return nil;
    }
    int pid = [process[@"pid"] intValue];
    BOOL springboard = [process[@"springboard"] boolValue];
    NSMutableArray *nodes = [NSMutableArray arrayWithArray:JBP1lotNodesForPid(pid, springboard ? @"springboard" : @"application", 0)];
    if (!springboard && [params[@"includeSpringBoard"] boolValue]) {
        int boardPid = [JBP1lotApplicationProcess(@"com.apple.springboard")[@"pid"] intValue];
        if (boardPid > 0) [nodes addObjectsFromArray:JBP1lotNodesForPid(boardPid, @"springboard", nodes.count)];
    }
    NSString *frameId = NSUUID.UUID.UUIDString;
    @synchronized (JBP1lotSnapshotLock) {
        JBP1lotCurrentFrame = frameId;
        JBP1lotCurrentNodes = nodes;
    }
    return @{ @"frameId": frameId, @"application": process[@"bundleId"] ?: @"", @"pid": process[@"pid"] ?: @0, @"nodes": nodes, @"count": @(nodes.count), @"visualFallback": @(nodes.count == 0) };
}

NSDictionary *JBP1lotUISnapshot(NSDictionary *params) {
    NSDictionary *error = nil;
    NSDictionary *snapshot = JBP1lotCaptureSnapshot(params, &error);
    return snapshot ? @{ @"status": @"ok", @"payload": snapshot } : @{ @"status": @"error", @"error": error };
}

static BOOL JBP1lotNodeMatches(NSDictionary *node, NSString *selector) {
    NSString *query = selector;
    NSArray<NSString *> *fields = @[@"label", @"value", @"hint"];
    BOOL exact = NO;
    NSRange separator = [selector rangeOfString:@"="];
    if (separator.location != NSNotFound && separator.location > 0) {
        NSString *field = [selector substringToIndex:separator.location].lowercaseString;
        if ([@[@"label", @"value", @"hint", @"id", @"trait"] containsObject:field]) {
            fields = @[field];
            query = [selector substringFromIndex:separator.location + 1];
            exact = YES;
        }
    }
    for (NSString *field in fields) {
        if ([field isEqualToString:@"trait"]) {
            if ([node[@"traits"] containsObject:query]) return YES;
            continue;
        }
        NSString *value = node[field];
        if (![value isKindOfClass:[NSString class]]) continue;
        if (exact ? [value caseInsensitiveCompare:query] == NSOrderedSame : [value rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static NSDictionary *JBP1lotFirstMatch(NSArray<NSDictionary *> *nodes, NSString *selector) {
    for (NSDictionary *node in nodes)
        if (JBP1lotNodeMatches(node, selector)) return node;
    return nil;
}

NSDictionary *JBP1lotUIWait(NSDictionary *params) {
    NSString *selector = [params[@"selector"] isKindOfClass:[NSString class]] ? params[@"selector"] : @"";
    if (selector.length == 0) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"selector is required") };
    NSTimeInterval timeout = MIN(MAX([params[@"timeoutMs"] doubleValue] ?: 10000, 100), 120000) / 1000.0;
    useconds_t poll = (useconds_t)MIN(MAX([params[@"pollMs"] doubleValue] ?: 500, 100), 5000) * 1000;
    BOOL absent = [params[@"absent"] boolValue];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSUInteger attempts = 0;
    while (YES) {
        attempts += 1;
        NSDictionary *error = nil;
        NSDictionary *snapshot = JBP1lotCaptureSnapshot(params, &error);
        NSDictionary *match = snapshot ? JBP1lotFirstMatch(snapshot[@"nodes"], selector) : nil;
        if (snapshot && (absent ? match == nil : match != nil))
            return @{ @"status": @"ok", @"payload": @{ @"matched": @YES, @"node": match ?: [NSNull null], @"frameId": snapshot[@"frameId"], @"attempts": @(attempts) } };
        if ([deadline timeIntervalSinceNow] <= 0)
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"timeout", [NSString stringWithFormat:@"selector \"%@\" was %@ after %lu snapshots", selector, absent ? @"still present" : @"not found", (unsigned long)attempts]) };
        usleep(poll);
    }
}

NSDictionary *JBP1lotResolveUITarget(NSDictionary *params, NSDictionary **error) {
    NSString *nodeId = [params[@"nodeId"] isKindOfClass:[NSString class]] ? params[@"nodeId"] : @"";
    NSString *selector = [params[@"selector"] isKindOfClass:[NSString class]] ? params[@"selector"] : @"";
    if (nodeId.length == 0 && selector.length == 0) return params;
    JBP1lotAXElementClass();
    NSDictionary *node = nil;
    if (nodeId.length) {
        NSString *frame = [params[@"frameId"] isKindOfClass:[NSString class]] ? params[@"frameId"] : @"";
        @synchronized (JBP1lotSnapshotLock) {
            if (frame.length && ![frame isEqualToString:JBP1lotCurrentFrame]) {
                if (error) *error = JBP1lotErrorPayload(@"invalid_frame", @"accessibility node frame expired; take a new ui_snapshot");
                return nil;
            }
            for (NSDictionary *candidate in JBP1lotCurrentNodes)
                if ([candidate[@"id"] isEqualToString:nodeId]) node = candidate;
        }
    } else {
        NSDictionary *snapshot = JBP1lotCaptureSnapshot(params, error);
        if (!snapshot) return nil;
        node = JBP1lotFirstMatch(snapshot[@"nodes"], selector);
    }
    if (!node) {
        if (error) *error = JBP1lotErrorPayload(@"not_found", nodeId.length ? @"node is not in the current snapshot" : [NSString stringWithFormat:@"no node matches \"%@\"", selector]);
        return nil;
    }
    NSMutableDictionary *resolved = [params mutableCopy];
    [resolved removeObjectsForKeys:@[@"nodeId", @"frameId", @"selector"]];
    resolved[@"x"] = node[@"activationPoint"][@"x"];
    resolved[@"y"] = node[@"activationPoint"][@"y"];
    if (![resolved[@"action"] isKindOfClass:[NSString class]]) resolved[@"action"] = @"tap";
    resolved[@"resolvedNode"] = node;
    return resolved;
}
