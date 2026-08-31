#import "BridgeProtocol.h"

NSString * const JBP1lotAgentSocketPath = @"/var/mobile/Library/Caches/jb-p1lot-agent.sock";
NSString * const JBP1lotBonjourType = @"_jb-p1lot._tcp";
uint16_t const JBP1lotPort = 5912;
NSString * const JBP1lotVersionString = @"0.1.2";

NSData *JBP1lotFrameForDictionary(NSDictionary *dictionary) {
    NSError *error = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
    if (error || body.length > (16u << 20)) {
        return nil;
    }
    uint32_t length = CFSwapInt32HostToBig((uint32_t)body.length);
    NSMutableData *frame = [NSMutableData dataWithBytes:&length length:sizeof(length)];
    [frame appendData:body];
    return frame;
}

NSDictionary *JBP1lotDictionaryFromFrame(NSData *frame) {
    if (frame.length < sizeof(uint32_t)) {
        return nil;
    }
    uint32_t length = 0;
    [frame getBytes:&length length:sizeof(length)];
    length = CFSwapInt32BigToHost(length);
    if (length == 0 || length > (16u << 20) || frame.length < sizeof(uint32_t) + length) {
        return nil;
    }
    NSData *body = [frame subdataWithRange:NSMakeRange(sizeof(uint32_t), length)];
    id object = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

NSDictionary *JBP1lotErrorPayload(NSString *code, NSString *message) {
    return @{ @"code": code ?: @"backend_error", @"message": message ?: @"device bridge error" };
}
