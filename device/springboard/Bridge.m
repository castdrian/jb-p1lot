#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#import "BridgeProtocol.h"
#import "DisplayControl.h"
#import "InputInjector.h"

extern NSData *JBP1lotCapturePNG(void);

static int JBP1lotSocket = -1;

static id JBP1lotMessage(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static NSDictionary *JBP1lotScreenState(void) {
    __block NSDictionary *state = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id backlight = JBP1lotMessage(NSClassFromString(@"SBBacklightController"), @"sharedInstance");
        SEL screenIsOn = NSSelectorFromString(@"screenIsOn");
        BOOL on = [backlight respondsToSelector:screenIsOn] ? ((BOOL (*)(id, SEL))objc_msgSend)(backlight, screenIsOn) : YES;
        id lockManager = JBP1lotMessage(NSClassFromString(@"SBLockScreenManager"), @"sharedInstance");
        SEL isUILocked = NSSelectorFromString(@"isUILocked");
        BOOL locked = [lockManager respondsToSelector:isUILocked] && ((BOOL (*)(id, SEL))objc_msgSend)(lockManager, isUILocked);
        state = @{ @"screenOn": @(on), @"locked": @(locked) };
    });
    return state;
}

static NSDictionary *JBP1lotApplicationProcess(id bundleIdentifier) {
    __block NSDictionary *result = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        id application = nil;
        if ([bundleIdentifier isKindOfClass:[NSString class]] && [bundleIdentifier length] > 0 && ![bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            id controller = JBP1lotMessage(NSClassFromString(@"SBApplicationController"), @"sharedInstance");
            SEL lookup = NSSelectorFromString(@"applicationWithBundleIdentifier:");
            application = [controller respondsToSelector:lookup] ? ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, bundleIdentifier) : nil;
        } else {
            application = JBP1lotMessage(UIApplication.sharedApplication, @"_accessibilityFrontMostApplication");
        }
        id processState = JBP1lotMessage(application, @"processState");
        SEL pidSelector = NSSelectorFromString(@"pid");
        int pid = [processState respondsToSelector:pidSelector] ? ((int (*)(id, SEL))objc_msgSend)(processState, pidSelector) : 0;
        NSString *identifier = JBP1lotMessage(application, @"bundleIdentifier");
        BOOL requested = [bundleIdentifier isKindOfClass:[NSString class]] && [bundleIdentifier length] > 0 && ![bundleIdentifier isEqualToString:@"com.apple.springboard"];
        if (pid > 0)
            result = @{ @"bundleId": identifier ?: @"", @"pid": @(pid), @"springboard": @NO, @"running": @YES };
        else if (requested)
            result = @{ @"bundleId": bundleIdentifier, @"pid": @0, @"springboard": @NO, @"running": @NO };
        else
            result = @{ @"bundleId": @"com.apple.springboard", @"pid": @(getpid()), @"springboard": @YES, @"running": @YES };
    });
    return result;
}

static NSDictionary *JBP1lotAgentResponse(NSDictionary *request) {
    NSString *method = [request[@"method"] isKindOfClass:[NSString class]] ? request[@"method"] : @"";
    NSDictionary *params = [request[@"payload"] isKindOfClass:[NSDictionary class]] ? request[@"payload"] : @{};
    if ([method isEqualToString:@"screen.capture"]) {
        NSData *png = JBP1lotCapturePNG();
        if (!png) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"screen capture unavailable") };
        }
        UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject;
        UIInterfaceOrientation orientation = scene ? scene.interfaceOrientation : UIInterfaceOrientationPortrait;
        return @{ @"status": @"ok", @"payload": @{ @"data": [png base64EncodedStringWithOptions:0], @"mimeType": @"image/png", @"orientation": orientation == UIInterfaceOrientationPortrait ? @"portrait" : @"landscape" } };
    }
    if ([method isEqualToString:@"screen.stream.start"]) {
        NSString *session = [NSString stringWithFormat:@"screen-%@", NSUUID.UUID.UUIDString];
        return @{ @"status": @"ok", @"payload": @{ @"sessionId": session, @"url": [NSString stringWithFormat:@"jb-p1lot://screen/%@", session], @"codec": @"h264", @"fps": @([params[@"fps"] integerValue] ?: 30) } };
    }
    if ([method isEqualToString:@"display.state"]) {
        return @{ @"status": @"ok", @"payload": JBP1lotScreenState() };
    }
    if ([method isEqualToString:@"ui.application"]) {
        return @{ @"status": @"ok", @"payload": JBP1lotApplicationProcess(params[@"bundleId"]) };
    }
    if ([method isEqualToString:@"ui_action"]) {
        CFTimeInterval actionStart = CFAbsoluteTimeGetCurrent();
        NSString *failureReason = nil;
        BOOL performed = JBP1lotInjectAction(params, &failureReason);
        NSNumber *actionDuration = @((CFAbsoluteTimeGetCurrent() - actionStart) * 1000.0);
        if (!performed) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", failureReason ?: @"UI action unavailable") };
        }
        return @{ @"status": @"ok", @"payload": @{ @"performed": @YES, @"displayEnabled": @(JBP1lotDisplayIsEnabled()), @"actionDurationMs": actionDuration } };
    }
    return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"unsupported agent method") };
}

static ssize_t JBP1lotReadFull(int fd, void *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = read(fd, (uint8_t *)buffer + offset, length - offset);
        if (count <= 0) return -1;
        offset += (size_t)count;
    }
    return (ssize_t)offset;
}

static ssize_t JBP1lotWriteFull(int fd, const void *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, (const uint8_t *)buffer + offset, length - offset);
        if (count <= 0) return -1;
        offset += (size_t)count;
    }
    return (ssize_t)offset;
}

static void JBP1lotHandleAgentConnection(int fd) {
    uint32_t length = 0;
    if (JBP1lotReadFull(fd, &length, sizeof(length)) < 0) {
        close(fd);
        return;
    }
    length = CFSwapInt32BigToHost(length);
    if (length == 0 || length > (16u << 20)) {
        close(fd);
        return;
    }
    NSMutableData *body = [NSMutableData dataWithLength:length];
    if (JBP1lotReadFull(fd, body.mutableBytes, length) < 0) {
        close(fd);
        return;
    }
    uint32_t prefix = CFSwapInt32HostToBig(length);
    NSMutableData *frame = [NSMutableData dataWithBytes:&prefix length:sizeof(prefix)];
    [frame appendData:body];
    NSDictionary *request = JBP1lotDictionaryFromFrame(frame);
    if (!request) {
        close(fd);
        return;
    }
    NSMutableDictionary *response = [JBP1lotAgentResponse(request) mutableCopy];
    response[@"version"] = @1;
    response[@"kind"] = [response[@"status"] isEqualToString:@"error"] ? @"error" : @"response";
    response[@"id"] = request[@"id"] ?: @0;
    if ([response[@"kind"] isEqualToString:@"error"] && !response[@"payload"] && response[@"error"]) {
        response[@"payload"] = response[@"error"];
    }
    NSData *reply = JBP1lotFrameForDictionary(response);
    if (reply) JBP1lotWriteFull(fd, reply.bytes, reply.length);
    close(fd);
}

static void JBP1lotAcceptLoop(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        while (JBP1lotSocket >= 0) {
            int client = accept(JBP1lotSocket, NULL, NULL);
            if (client < 0) continue;
            JBP1lotHandleAgentConnection(client);
        }
    });
}

void JBP1lotAgentStart(void) {
    if (JBP1lotSocket >= 0) return;
    JBP1lotSocket = socket(AF_UNIX, SOCK_STREAM, 0);
    if (JBP1lotSocket < 0) return;
    unlink(JBP1lotAgentSocketPath.fileSystemRepresentation);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, JBP1lotAgentSocketPath.fileSystemRepresentation, sizeof(address.sun_path));
    if (bind(JBP1lotSocket, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(JBP1lotSocket, 8) != 0) {
        close(JBP1lotSocket);
        JBP1lotSocket = -1;
        return;
    }
    chmod(JBP1lotAgentSocketPath.fileSystemRepresentation, 0660);
    JBP1lotAcceptLoop();
}
