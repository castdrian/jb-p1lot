#import "Logs.h"
#import "BridgeProtocol.h"
#import <dlfcn.h>
#import <objc/message.h>

@protocol JBP1lotLogEvent <NSObject>
- (NSString *)process;
- (int)processIdentifier;
- (NSString *)subsystem;
- (NSString *)category;
- (NSString *)composedMessage;
- (NSString *)sender;
- (NSDate *)date;
- (unsigned char)logType;
@end

@protocol JBP1lotLogStream <NSObject>
- (instancetype)initWithSource:(id)source;
- (instancetype)initWithLiveSource:(id)source;
- (void)setEventHandler:(void (^)(id<JBP1lotLogEvent>))handler;
- (void)setInvalidationHandler:(void (^)(void))handler;
- (void)activate;
- (void)activateStreamFromDate:(NSDate *)date;
- (void)invalidate;
- (void)prepareWithCompletionHandler:(void (^)(id, NSError *))handler;
@end

static NSUInteger const JBP1lotLogMaxLines = 20000;

static NSString *JBP1lotLogTypeName(unsigned char type) {
    switch (type) {
        case 0x01: return @"Info";
        case 0x02: return @"Debug";
        case 0x10: return @"Error";
        case 0x11: return @"Fault";
        default: return @"Default";
    }
}

static NSDate *JBP1lotLogSince(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return [NSDate dateWithTimeIntervalSince1970:[value doubleValue] / 1000.0];
    NSString *text = [value isKindOfClass:[NSString class]] ? [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
    if (text.length == 0) return [NSDate dateWithTimeIntervalSinceNow:-600];
    NSDictionary *units = @{ @"s": @1, @"m": @60, @"h": @3600, @"d": @86400 };
    NSNumber *unit = units[[text substringFromIndex:text.length - 1].lowercaseString];
    if (unit) return [NSDate dateWithTimeIntervalSinceNow:-[[text substringToIndex:text.length - 1] doubleValue] * unit.doubleValue];
    NSDate *parsed = [[NSISO8601DateFormatter new] dateFromString:text];
    return parsed ?: [NSDate dateWithTimeIntervalSinceNow:-[text doubleValue]];
}

static NSPredicate *JBP1lotLogPredicate(NSDictionary *params, NSString **error) {
    NSMutableArray *predicates = [NSMutableArray array];
    NSString *format = [params[@"predicate"] isKindOfClass:[NSString class]] ? params[@"predicate"] : @"";
    if (format.length) {
        @try {
            [predicates addObject:[NSPredicate predicateWithFormat:format]];
        } @catch (NSException *exception) {
            if (error) *error = [NSString stringWithFormat:@"invalid predicate: %@", exception.reason];
            return nil;
        }
    }
    NSString *process = [params[@"process"] isKindOfClass:[NSString class]] ? params[@"process"] : @"";
    if (process.length) [predicates addObject:[NSPredicate predicateWithFormat:@"process ==[c] %@ OR processIdentifier == %d", process, process.intValue]];
    return predicates.count ? [NSCompoundPredicate andPredicateWithSubpredicates:predicates] : nil;
}

static NSDictionary *JBP1lotLogRecord(id<JBP1lotLogEvent> event) {
    return @{
        @"process": event.process ?: @"",
        @"processIdentifier": @(event.processIdentifier),
        @"subsystem": event.subsystem ?: @"",
        @"category": event.category ?: @"",
        @"sender": event.sender.lastPathComponent ?: @"",
        @"messageType": JBP1lotLogTypeName(event.logType),
        @"eventMessage": event.composedMessage.description ?: @"",
    };
}

static NSString *JBP1lotLogLine(NSDictionary *record, NSDate *date, NSDateFormatter *formatter) {
    NSString *scope = [record[@"subsystem"] length] ? [NSString stringWithFormat:@" [%@:%@]", record[@"subsystem"], record[@"category"]] : @"";
    return [NSString stringWithFormat:@"%@ %@ %@[%@]%@ %@", [formatter stringFromDate:date ?: NSDate.date], record[@"messageType"], record[@"process"], record[@"processIdentifier"], scope, record[@"eventMessage"]];
}

NSDictionary *JBP1lotLogQuery(NSDictionary *params) {
    if (!dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW))
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"LoggingSupport is unavailable") };
    NSString *predicateError = nil;
    NSPredicate *predicate = JBP1lotLogPredicate(params, &predicateError);
    if (predicateError) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", predicateError) };
    BOOL follow = [params[@"follow"] boolValue];
    NSUInteger limit = MIN(MAX([params[@"limit"] unsignedIntegerValue] ?: 2000, 1), JBP1lotLogMaxLines);
    NSTimeInterval duration = MIN(MAX([params[@"durationMs"] doubleValue] ?: 5000, 250), 120000) / 1000.0;
    NSDate *since = JBP1lotLogSince(params[@"since"]);
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    __block NSUInteger matched = 0;
    __block NSUInteger scanned = 0;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block id<JBP1lotLogStream> stream = nil;
    __block NSString *failure = nil;
    NSObject *lock = [NSObject new];
    void (^handler)(id<JBP1lotLogEvent>) = ^(id<JBP1lotLogEvent> event) {
        @autoreleasepool {
            @synchronized (lock) {
                scanned += 1;
                NSDictionary *record = JBP1lotLogRecord(event);
                if (predicate && ![predicate evaluateWithObject:record]) return;
                matched += 1;
                [lines addObject:JBP1lotLogLine(record, event.date, formatter)];
                if (lines.count > limit) [lines removeObjectAtIndex:0];
                if (follow && matched >= limit) [stream invalidate];
            }
        }
    };
    Class storeClass = NSClassFromString(follow ? @"OSLogEventLiveStore" : @"OSLogEventStore");
    id<JBP1lotLogStream> store = ((id (*)(id, SEL))objc_msgSend)(storeClass, follow ? NSSelectorFromString(@"liveLocalStore") : NSSelectorFromString(@"localStore"));
    [store prepareWithCompletionHandler:^(id source, NSError *error) {
        if (!source) {
            failure = error.localizedDescription ?: @"log store is unavailable";
            dispatch_semaphore_signal(finished);
            return;
        }
        Class streamClass = NSClassFromString(follow ? @"OSLogEventLiveStream" : @"OSLogEventStream");
        stream = follow ? [[streamClass alloc] initWithLiveSource:source] : [[streamClass alloc] initWithSource:source];
        [stream setEventHandler:handler];
        [stream setInvalidationHandler:^{
            dispatch_semaphore_signal(finished);
        }];
        if (follow) {
            [stream activate];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [stream invalidate];
            });
        } else {
            [stream activateStreamFromDate:since];
        }
    }];
    long timedOut = dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((follow ? duration + 10 : 110) * NSEC_PER_SEC)));
    if (timedOut) [stream invalidate];
    if (failure) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", failure) };
    NSArray *snapshot;
    @synchronized (lock) {
        snapshot = [lines copy];
    }
    return @{ @"status": @"ok", @"payload": @{
        @"exitCode": @0,
        @"output": [[snapshot componentsJoinedByString:@"\n"] stringByAppendingString:snapshot.count ? @"\n" : @""],
        @"lines": @(snapshot.count),
        @"matched": @(matched),
        @"scanned": @(scanned),
        @"truncated": @((BOOL)(matched > snapshot.count)),
        @"mode": follow ? @"live" : @"history",
        @"timedOut": @((BOOL)(timedOut != 0)),
    } };
}
