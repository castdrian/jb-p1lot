#import "Applications.h"
#import "BridgeProtocol.h"
#import <dlfcn.h>
#import <objc/message.h>

static id JBP1lotSend(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSString *JBP1lotPath(id url) {
    return [url isKindOfClass:[NSURL class]] ? [url path] : nil;
}

NSDictionary *JBP1lotAppContainer(NSDictionary *params) {
    NSString *bundleIdentifier = [params[@"bundleId"] isKindOfClass:[NSString class]] ? params[@"bundleId"] : ([params[@"bundle"] isKindOfClass:[NSString class]] ? params[@"bundle"] : @"");
    if (bundleIdentifier.length == 0) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"bundleId is required") };
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices", RTLD_NOW);
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id proxy = proxyClass ? ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, NSSelectorFromString(@"applicationProxyForIdentifier:"), bundleIdentifier) : nil;
    NSString *bundlePath = JBP1lotPath(JBP1lotSend(proxy, @"bundleURL"));
    if (!proxy || bundlePath.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:bundlePath])
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"not_found", [NSString stringWithFormat:@"%@ is not installed", bundleIdentifier]) };
    NSMutableDictionary *groups = [NSMutableDictionary dictionary];
    NSDictionary *groupURLs = JBP1lotSend(proxy, @"groupContainerURLs");
    if ([groupURLs isKindOfClass:[NSDictionary class]])
        for (NSString *group in groupURLs) groups[group] = JBP1lotPath(groupURLs[group]) ?: @"";
    NSString *dataContainer = JBP1lotPath(JBP1lotSend(proxy, @"dataContainerURL"));
    NSMutableDictionary *payload = [@{
        @"bundleId": bundleIdentifier,
        @"name": JBP1lotSend(proxy, @"localizedName") ?: @"",
        @"version": JBP1lotSend(proxy, @"shortVersionString") ?: @"",
        @"build": JBP1lotSend(proxy, @"bundleVersion") ?: @"",
        @"bundlePath": bundlePath,
        @"executable": JBP1lotSend(proxy, @"bundleExecutable") ?: @"",
        @"dataContainer": dataContainer ?: [NSNull null],
        @"groupContainers": groups,
    } mutableCopy];
    NSString *subpath = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : @"";
    if (subpath.length && dataContainer.length) {
        NSString *root = dataContainer.stringByStandardizingPath;
        NSString *resolved = [[root stringByAppendingPathComponent:subpath] stringByStandardizingPath];
        if (![resolved isEqualToString:root] && ![resolved hasPrefix:[root stringByAppendingString:@"/"]])
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"path escapes the data container") };
        payload[@"resolvedPath"] = resolved;
        payload[@"resolvedExists"] = @([[NSFileManager defaultManager] fileExistsAtPath:resolved]);
    }
    return @{ @"status": @"ok", @"payload": payload };
}
