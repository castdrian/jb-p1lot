#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <stdint.h>
#import <unistd.h>
#import "DisplayControl.h"
#import "InputInjector.h"

typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;
typedef IOHIDEventSystemClientRef (*ClientCreateFn)(CFAllocatorRef);
typedef IOHIDEventRef (*DigitizerCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*FingerCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double, Boolean, Boolean, uint32_t);
typedef IOHIDEventRef (*KeyboardCreateFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, Boolean, uint32_t);
typedef void (*AppendFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetIntegerFn)(IOHIDEventRef, uint32_t, int64_t);
typedef void (*SetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef void (*DispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*ReleaseFn)(CFTypeRef);

typedef struct {
    ClientCreateFn createClient;
    DigitizerCreateFn createDigitizerEvent;
    FingerCreateFn createFingerEvent;
    KeyboardCreateFn createKeyboardEvent;
    AppendFn appendEvent;
    SetIntegerFn setIntegerValue;
    SetSenderIDFn setSenderID;
    DispatchFn dispatchEvent;
    ReleaseFn releaseValue;
    IOHIDEventSystemClientRef client;
} JBP1lotHIDFunctions;

static const uint32_t JBP1lotKeyboardUsagePage = 0x07u;
static const uint32_t JBP1lotConsumerUsagePage = 0x0Cu;
static const uint32_t JBP1lotConsumerPowerUsage = 0x30u;
static const uint32_t JBP1lotConsumerMenuUsage = 0x40u;
static const uint32_t JBP1lotConsumerMuteUsage = 0xE2u;
static const uint32_t JBP1lotConsumerVolumeUpUsage = 0xE9u;
static const uint32_t JBP1lotConsumerVolumeDownUsage = 0xEAu;
static const uint64_t JBP1lotHIDSenderID = 0x8000000817319375ULL;

static JBP1lotHIDFunctions JBP1lotHIDLoadFunctions(void) {
    static JBP1lotHIDFunctions functions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
        functions.createClient = (ClientCreateFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
        functions.createDigitizerEvent = (DigitizerCreateFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerEvent");
        functions.createFingerEvent = (FingerCreateFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        functions.createKeyboardEvent = (KeyboardCreateFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventCreateKeyboardEvent");
        functions.appendEvent = (AppendFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventAppendEvent");
        functions.setIntegerValue = (SetIntegerFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventSetIntegerValue");
        functions.setSenderID = (SetSenderIDFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventSetSenderID");
        functions.dispatchEvent = (DispatchFn)dlsym(handle ?: RTLD_DEFAULT, "IOHIDEventSystemClientDispatchEvent");
        functions.releaseValue = (ReleaseFn)dlsym(RTLD_DEFAULT, "CFRelease");
        if (functions.createClient) {
            functions.client = functions.createClient(kCFAllocatorDefault);
        }
    });
    return functions;
}

static BOOL JBP1lotKeyboardUsage(unichar character, uint32_t *usage, BOOL *shift) {
    *shift = NO;
    if (character >= 'a' && character <= 'z') {
        *usage = 0x04u + (uint32_t)(character - 'a');
        return YES;
    }
    if (character >= 'A' && character <= 'Z') {
        *usage = 0x04u + (uint32_t)(character - 'A');
        *shift = YES;
        return YES;
    }
    if (character >= '1' && character <= '9') {
        *usage = 0x1Eu + (uint32_t)(character - '1');
        return YES;
    }
    if (character == '0') {
        *usage = 0x27u;
        return YES;
    }
    switch (character) {
        case ' ': *usage = 0x2Cu; return YES;
        case '\t': *usage = 0x2Bu; return YES;
        case '\n':
        case '\r': *usage = 0x28u; return YES;
        case '\b': *usage = 0x2Au; return YES;
        case '-': *usage = 0x2Du; return YES;
        case '=': *usage = 0x2Eu; return YES;
        case '[': *usage = 0x2Fu; return YES;
        case ']': *usage = 0x30u; return YES;
        case '\\': *usage = 0x31u; return YES;
        case ';': *usage = 0x33u; return YES;
        case '\'': *usage = 0x34u; return YES;
        case '`': *usage = 0x35u; return YES;
        case ',': *usage = 0x36u; return YES;
        case '.': *usage = 0x37u; return YES;
        case '/': *usage = 0x38u; return YES;
        case '!': *usage = 0x1Eu; *shift = YES; return YES;
        case '@': *usage = 0x1Fu; *shift = YES; return YES;
        case '#': *usage = 0x20u; *shift = YES; return YES;
        case '$': *usage = 0x21u; *shift = YES; return YES;
        case '%': *usage = 0x22u; *shift = YES; return YES;
        case '^': *usage = 0x23u; *shift = YES; return YES;
        case '&': *usage = 0x24u; *shift = YES; return YES;
        case '*': *usage = 0x25u; *shift = YES; return YES;
        case '(': *usage = 0x26u; *shift = YES; return YES;
        case ')': *usage = 0x27u; *shift = YES; return YES;
        case '_': *usage = 0x2Du; *shift = YES; return YES;
        case '+': *usage = 0x2Eu; *shift = YES; return YES;
        case '{': *usage = 0x2Fu; *shift = YES; return YES;
        case '}': *usage = 0x30u; *shift = YES; return YES;
        case '|': *usage = 0x31u; *shift = YES; return YES;
        case ':': *usage = 0x33u; *shift = YES; return YES;
        case '"': *usage = 0x34u; *shift = YES; return YES;
        case '~': *usage = 0x35u; *shift = YES; return YES;
        case '<': *usage = 0x36u; *shift = YES; return YES;
        case '>': *usage = 0x37u; *shift = YES; return YES;
        case '?': *usage = 0x38u; *shift = YES; return YES;
    }
    return NO;
}

static BOOL JBP1lotHIDKeyEvent(uint32_t usagePage, uint32_t usage, BOOL down) {
    JBP1lotHIDFunctions functions = JBP1lotHIDLoadFunctions();
    if (!functions.client || !functions.createKeyboardEvent || !functions.dispatchEvent)
        return NO;
    IOHIDEventRef event = functions.createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), usagePage, usage, down, 0);
    if (!event)
        return NO;
    if (functions.setSenderID)
        functions.setSenderID(event, JBP1lotHIDSenderID);
    functions.dispatchEvent(functions.client, event);
    if (functions.releaseValue)
        functions.releaseValue(event);
    return YES;
}

static BOOL JBP1lotHIDKeyboardEvent(uint32_t usage, BOOL down) {
    return JBP1lotHIDKeyEvent(JBP1lotKeyboardUsagePage, usage, down);
}

static BOOL JBP1lotInsertTextWithKeyboardEvents(NSString *text) {
    for (NSUInteger index = 0; index < text.length; index++) {
        uint32_t usage = 0;
        BOOL shift = NO;
        if (!JBP1lotKeyboardUsage([text characterAtIndex:index], &usage, &shift))
            return NO;
        if (shift && !JBP1lotHIDKeyboardEvent(0xE1u, YES))
            return NO;
        if (!JBP1lotHIDKeyboardEvent(usage, YES) || !JBP1lotHIDKeyboardEvent(usage, NO)) {
            if (shift)
                JBP1lotHIDKeyboardEvent(0xE1u, NO);
            return NO;
        }
        if (shift && !JBP1lotHIDKeyboardEvent(0xE1u, NO))
            return NO;
        usleep(4000);
    }
    return YES;
}

static BOOL JBP1lotPasteText(NSString *text) {
    __block UIPasteboard *pasteboard = nil;
    __block NSArray *previousItems = nil;
    __block BOOL available = NO;
    void (^preparePasteboard)(void) = ^{
        @try {
            pasteboard = UIPasteboard.generalPasteboard;
            previousItems = [pasteboard.items copy];
            pasteboard.string = text;
            available = pasteboard.string.length == text.length && [pasteboard.string isEqualToString:text];
        } @catch (__unused NSException *exception) {
            available = NO;
        }
    };
    if ([NSThread isMainThread])
        preparePasteboard();
    else
        dispatch_sync(dispatch_get_main_queue(), preparePasteboard);
    if (!available)
        return NO;

    BOOL performed = JBP1lotHIDKeyboardEvent(0xE3u, YES);
    usleep(12000);
    performed = JBP1lotHIDKeyboardEvent(0x19u, YES) && performed;
    performed = JBP1lotHIDKeyboardEvent(0x19u, NO) && performed;
    usleep(12000);
    performed = JBP1lotHIDKeyboardEvent(0xE3u, NO) && performed;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            if ([pasteboard.string isEqualToString:text])
                [pasteboard setItems:previousItems ?: @[]];
        } @catch (__unused NSException *exception) {
        }
    });
    return performed;
}

static BOOL JBP1lotHIDPoint(CGFloat x, CGFloat y, BOOL down);

static BOOL JBP1lotKeyboardKeyPoint(unichar character, CGSize size, CGPoint *point, BOOL *shift) {
    CGFloat top = size.height - 216.0;
    *shift = NO;
    if (character >= 'A' && character <= 'Z') {
        character = (unichar)(character - 'A' + 'a');
        *shift = YES;
    }
    NSString *topKeys = @"qwertyuiop";
    NSRange topRange = [topKeys rangeOfString:[NSString stringWithCharacters:&character length:1]];
    if (topRange.location != NSNotFound) {
        static const CGFloat positions[] = { 19, 57, 94, 132, 170, 207, 245, 282, 320, 357 };
        *point = CGPointMake(positions[topRange.location], top + 29);
        return YES;
    }
    NSString *middleKeys = @"asdfghjkl";
    NSRange middleRange = [middleKeys rangeOfString:[NSString stringWithCharacters:&character length:1]];
    if (middleRange.location != NSNotFound) {
        static const CGFloat positions[] = { 38, 76, 113, 151, 188, 226, 263, 301, 338 };
        *point = CGPointMake(positions[middleRange.location], top + 84);
        return YES;
    }
    NSString *bottomKeys = @"zxcvbnm";
    NSRange bottomRange = [bottomKeys rangeOfString:[NSString stringWithCharacters:&character length:1]];
    if (bottomRange.location != NSNotFound) {
        static const CGFloat positions[] = { 75, 113, 150, 188, 225, 263, 300 };
        *point = CGPointMake(positions[bottomRange.location], top + 139);
        return YES;
    }
    switch (character) {
        case ' ': *point = CGPointMake(size.width * 0.55, top + 193); return YES;
        case '\n':
        case '\r': *point = CGPointMake(size.width * 0.87, top + 193); return YES;
        case ',': *point = CGPointMake(size.width * 0.45, top + 139); return YES;
        case '.': *point = CGPointMake(size.width * 0.64, top + 139); return YES;
        case '-': *point = CGPointMake(size.width * 0.83, top + 29); return YES;
        case '/': *point = CGPointMake(size.width * 0.83, top + 139); return YES;
        case '\b': *point = CGPointMake(size.width * 0.93, top + 139); return YES;
        default: return NO;
    }
}

static BOOL JBP1lotInsertTextWithKeyboardTaps(NSString *text) {
    CGSize size = UIScreen.mainScreen.bounds.size;
    if (size.width < 300 || size.height < 500)
        return NO;
    for (NSUInteger index = 0; index < text.length; index++) {
        CGPoint point = CGPointZero;
        BOOL shift = NO;
        if (!JBP1lotKeyboardKeyPoint([text characterAtIndex:index], size, &point, &shift))
            return NO;
        if (shift) {
            CGPoint shiftPoint = CGPointMake(25, size.height - 51);
            if (!JBP1lotHIDPoint(shiftPoint.x, shiftPoint.y, YES) || !JBP1lotHIDPoint(shiftPoint.x, shiftPoint.y, NO))
                return NO;
        }
        if (!JBP1lotHIDPoint(point.x, point.y, YES) || !JBP1lotHIDPoint(point.x, point.y, NO))
            return NO;
        usleep(25000);
    }
    return YES;
}

static BOOL JBP1lotPointFromValue(id value, CGFloat *x, CGFloat *y) {
    if ([value isKindOfClass:[NSDictionary class]]) {
        id xValue = value[@"x"];
        id yValue = value[@"y"];
        if ([xValue respondsToSelector:@selector(doubleValue)] && [yValue respondsToSelector:@selector(doubleValue)]) {
            *x = [xValue doubleValue];
            *y = [yValue doubleValue];
            return YES;
        }
    }
    if ([value isKindOfClass:[NSArray class]] && [value count] >= 2) {
        id xValue = value[0];
        id yValue = value[1];
        if ([xValue respondsToSelector:@selector(doubleValue)] && [yValue respondsToSelector:@selector(doubleValue)]) {
            *x = [xValue doubleValue];
            *y = [yValue doubleValue];
            return YES;
        }
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"(),; \\t\\n"];
        NSMutableArray<NSString *> *components = [NSMutableArray array];
        for (NSString *component in [value componentsSeparatedByCharactersInSet:separators]) {
            if (component.length > 0) {
                [components addObject:component];
            }
        }
        if (components.count >= 2) {
            *x = components[0].doubleValue;
            *y = components[1].doubleValue;
            return YES;
        }
    }
    return NO;
}

static CGPoint JBP1lotScreenPoint(CGFloat x, CGFloat y) {
    UIScreen *screen = UIScreen.mainScreen;
    CGSize bounds = screen.bounds.size;
    CGFloat width = bounds.width > 1 ? bounds.width : 320;
    CGFloat height = bounds.height > 1 ? bounds.height : 480;
    CGFloat scale = screen.scale > 1 ? screen.scale : 1;
    if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
        return CGPointMake(x * width, y * height);
    }
    if (x > width + 1) {
        x /= scale;
    }
    if (y > height + 1) {
        y /= scale;
    }
    return CGPointMake(MIN(MAX(x, 0), width), MIN(MAX(y, 0), height));
}

static BOOL JBP1lotHIDPoint(CGFloat x, CGFloat y, BOOL down) {
    JBP1lotHIDFunctions functions = JBP1lotHIDLoadFunctions();
    if (!functions.client || !functions.createDigitizerEvent || !functions.createFingerEvent || !functions.appendEvent || !functions.dispatchEvent) {
        return NO;
    }
    CGPoint point = JBP1lotScreenPoint(x, y);
    CGSize bounds = UIScreen.mainScreen.bounds.size;
    CGFloat width = bounds.width > 1 ? bounds.width : 320;
    CGFloat height = bounds.height > 1 ? bounds.height : 480;
    double normalizedX = MIN(MAX(point.x / width, 0), 1);
    double normalizedY = MIN(MAX(point.y / height, 0), 1);
    uint32_t parentMask = 1 | 2 | 32;
    if (!down) {
        parentMask |= 4;
    }
    IOHIDEventRef parent = functions.createDigitizerEvent(kCFAllocatorDefault, mach_absolute_time(), 3, 1u << 22, 1, parentMask, 0, normalizedX, normalizedY, 0, down ? 1 : 0, 0, true, down, 0);
    IOHIDEventRef child = functions.createFingerEvent(kCFAllocatorDefault, mach_absolute_time(), 3, 2, 1 | 2, normalizedX, normalizedY, 0, down ? 1 : 0, 0, true, down, 0);
    if (!parent || !child) {
        if (functions.releaseValue) {
            if (parent) functions.releaseValue(parent);
            if (child) functions.releaseValue(child);
        }
        return NO;
    }
    if (functions.setIntegerValue) {
        functions.setIntegerValue(parent, 4, 1);
        functions.setIntegerValue(parent, (11u << 16) + 25, 1);
    }
    if (functions.setSenderID) {
        functions.setSenderID(parent, JBP1lotHIDSenderID);
    }
    functions.appendEvent(parent, child, 0);
    functions.dispatchEvent(functions.client, parent);
    if (functions.releaseValue) {
        functions.releaseValue(child);
        functions.releaseValue(parent);
    }
    return YES;
}

static id JBP1lotObjectValue(id object, NSString *key) {
    if (!object || key.length == 0)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id JBP1lotKeyboardInstance(Class keyboardClass) {
    if (!keyboardClass)
        return nil;

    for (NSString *selectorName in @[
        @"activeInstance", @"sharedInstance", @"sharedInstanceForKeyboard", @"sharedInstanceForCurrentKeyboard",
        @"sharedKeyboard", @"_sharedInstance"
    ]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([keyboardClass respondsToSelector:selector]) {
            id keyboard = ((id (*)(id, SEL))objc_msgSend)((id)keyboardClass, selector);
            if (keyboard)
                return keyboard;
        }
    }
    return nil;
}

static BOOL JBP1lotSendTextToObject(id object, NSString *text) {
    if (!object)
        return NO;

    for (NSString *selectorName in @[@"addInputString:", @"insertText:", @"_insertText:", @"handleStringInput:"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([object respondsToSelector:selector]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(object, selector, text);
            return YES;
        }
    }

    SEL flagsSelector = NSSelectorFromString(@"addInputString:withFlags:");
    if ([object respondsToSelector:flagsSelector]) {
        ((void (*)(id, SEL, NSString *, NSUInteger))objc_msgSend)(object, flagsSelector, text, 0);
        return YES;
    }

    SEL handleFlagsSelector = NSSelectorFromString(@"handleStringInput:withFlags:");
    if ([object respondsToSelector:handleFlagsSelector]) {
        ((void (*)(id, SEL, NSString *, NSUInteger))objc_msgSend)(object, handleFlagsSelector, text, 0);
        return YES;
    }
    return NO;
}

static BOOL JBP1lotSendTextThroughKeyboardQueue(id keyboard, NSString *text) {
    if (!keyboard)
        return NO;
    id taskQueue = JBP1lotObjectValue(keyboard, @"taskQueue");
    SEL addTaskSelector = NSSelectorFromString(@"addTask:");
    SEL addInputSelector = NSSelectorFromString(@"addInputString:withFlags:executionContext:");
    if (![taskQueue respondsToSelector:addTaskSelector] || ![keyboard respondsToSelector:addInputSelector])
        return NO;

    typedef void (^KeyboardTaskBlock)(id, int);
    KeyboardTaskBlock task = ^(id context, __unused int argument) {
        ((void (*)(id, SEL, NSString *, unsigned int, id))objc_msgSend)(keyboard, addInputSelector, text, 0, context);
    };
    ((void (*)(id, SEL, KeyboardTaskBlock))objc_msgSend)(taskQueue, addTaskSelector, task);
    return YES;
}

static BOOL JBP1lotTryPrivateText(NSString *text) {
    __block BOOL performed = NO;
    void (^sendBlock)(void) = ^{
        for (NSString *className in @[@"UIKeyboardImpl", @"_UIKeyboardImpl", @"UIKeyboardInputManager"]) {
            id keyboard = JBP1lotKeyboardInstance(NSClassFromString(className));
            if (JBP1lotSendTextThroughKeyboardQueue(keyboard, text)) {
                performed = YES;
                return;
            }
            if (JBP1lotSendTextToObject(keyboard, text)) {
                performed = YES;
                return;
            }

            for (NSString *key in @[@"delegate", @"_delegate", @"textInput", @"_textInput"]) {
                if (JBP1lotSendTextToObject(JBP1lotObjectValue(keyboard, key), text)) {
                    performed = YES;
                    return;
                }
            }
        }
    };
    if ([NSThread isMainThread])
        sendBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), sendBlock);
    return performed;
}

static BOOL JBP1lotInsertText(NSString *text) {
    if (text.length == 0)
        return YES;

    if (JBP1lotInsertTextWithKeyboardTaps(text))
        return YES;

    if (JBP1lotTryPrivateText(text))
        return YES;

    if (JBP1lotPasteText(text))
        return YES;

    return JBP1lotInsertTextWithKeyboardEvents(text);
}

static BOOL JBP1lotPasscodeLocked(void) {
    Class aggregatorClass = NSClassFromString(@"SBLockStateAggregator");
    id aggregator = aggregatorClass && [aggregatorClass respondsToSelector:@selector(sharedInstance)]
                         ? ((id (*)(id, SEL))objc_msgSend)((id)aggregatorClass, @selector(sharedInstance))
                         : nil;
    if (![aggregator respondsToSelector:@selector(lockState)])
        return YES;
    NSUInteger lockState = ((NSUInteger (*)(id, SEL))objc_msgSend)(aggregator, @selector(lockState));
    return (lockState & 2u) != 0;
}

static void JBP1lotDismissCoverSheet(void) {
    if (JBP1lotPasscodeLocked())
        return;

    Class presentationClass = NSClassFromString(@"SBCoverSheetPresentationManager");
    id presentation = presentationClass && [presentationClass respondsToSelector:@selector(sharedInstance)]
                          ? ((id (*)(id, SEL))objc_msgSend)((id)presentationClass, @selector(sharedInstance))
                          : nil;
    SEL dismissSelector = @selector(setCoverSheetPresented:animated:withCompletion:);
    if ([presentation respondsToSelector:dismissSelector])
        ((void (*)(id, SEL, BOOL, BOOL, id))objc_msgSend)(presentation, dismissSelector, NO, NO, nil);
}

typedef NS_ENUM(NSInteger, JBP1lotHardwareButton) {
    JBP1lotHardwareButtonUnsupported,
    JBP1lotHardwareButtonHome,
    JBP1lotHardwareButtonLock,
    JBP1lotHardwareButtonUnlock,
    JBP1lotHardwareButtonVolumeUp,
    JBP1lotHardwareButtonVolumeDown,
    JBP1lotHardwareButtonMute,
};

static atomic_int JBP1lotSyntheticButtonPressDepth = 0;

BOOL JBP1lotSyntheticButtonPressActive(void) {
    return atomic_load(&JBP1lotSyntheticButtonPressDepth) > 0;
}

static void JBP1lotRunOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread])
        block();
    else
        dispatch_sync(dispatch_get_main_queue(), block);
}

static id JBP1lotSharedInstance(NSString *className) {
    Class instanceClass = NSClassFromString(className);
    return instanceClass && [instanceClass respondsToSelector:@selector(sharedInstance)]
               ? ((id (*)(id, SEL))objc_msgSend)((id)instanceClass, @selector(sharedInstance))
               : nil;
}

static id JBP1lotObjectForSelector(id object, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static BOOL JBP1lotBoolForSelector(id object, NSString *selectorName, BOOL fallback) {
    SEL selector = NSSelectorFromString(selectorName);
    return [object respondsToSelector:selector] ? ((BOOL (*)(id, SEL))objc_msgSend)(object, selector) : fallback;
}

@interface JBP1lotSpringBoardState : NSObject
@property (nonatomic) BOOL uiLocked;
@property (nonatomic) BOOL screenOn;
@property (nonatomic) BOOL showingHomeScreen;
@property (nonatomic, copy) NSString *frontmostApplication;
- (BOOL)isUnlockedAtHomeScreen;
- (BOOL)isUnlockedAndAwake;
- (BOOL)differsFrom:(JBP1lotSpringBoardState *)other;
@end

@implementation JBP1lotSpringBoardState

- (BOOL)isUnlockedAtHomeScreen {
    return !self.uiLocked && self.showingHomeScreen && self.frontmostApplication == nil;
}

- (BOOL)isUnlockedAndAwake {
    return !self.uiLocked && self.screenOn;
}

- (BOOL)differsFrom:(JBP1lotSpringBoardState *)other {
    BOOL sameFrontmost = self.frontmostApplication == other.frontmostApplication ||
                         [self.frontmostApplication isEqualToString:other.frontmostApplication];
    return self.uiLocked != other.uiLocked || self.screenOn != other.screenOn ||
           self.showingHomeScreen != other.showingHomeScreen || !sameFrontmost;
}

@end

static JBP1lotSpringBoardState *JBP1lotReadSpringBoardState(void) {
    JBP1lotSpringBoardState *state = [JBP1lotSpringBoardState new];
    JBP1lotRunOnMain(^{
        @try {
            UIApplication *application = UIApplication.sharedApplication;
            state.uiLocked = JBP1lotBoolForSelector(JBP1lotSharedInstance(@"SBLockScreenManager"), @"isUILocked", NO);
            state.screenOn = JBP1lotBoolForSelector(JBP1lotSharedInstance(@"SBBacklightController"), @"screenIsOn", YES);
            state.showingHomeScreen = JBP1lotBoolForSelector(application, @"isShowingHomescreen", NO);
            id frontmost = JBP1lotObjectForSelector(application, @"_accessibilityFrontMostApplication");
            id bundleIdentifier = JBP1lotObjectForSelector(frontmost, @"bundleIdentifier");
            state.frontmostApplication = [bundleIdentifier isKindOfClass:[NSString class]] ? bundleIdentifier : nil;
        } @catch (__unused NSException *exception) {
        }
    });
    return state;
}

static JBP1lotSpringBoardState *JBP1lotAwaitSpringBoardState(NSTimeInterval timeout, BOOL (^condition)(JBP1lotSpringBoardState *state)) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout;
    JBP1lotSpringBoardState *state = JBP1lotReadSpringBoardState();
    while (!condition(state) && CFAbsoluteTimeGetCurrent() < deadline) {
        usleep(50000);
        state = JBP1lotReadSpringBoardState();
    }
    return state;
}

static BOOL JBP1lotHardwareButtonIsDown(JBP1lotHardwareButton button) {
    __block BOOL down = NO;
    NSString *accessor = button == JBP1lotHardwareButtonLock ? @"lockHardwareButton" : @"homeHardwareButton";
    JBP1lotRunOnMain(^{
        @try {
            id hardwareButton = JBP1lotObjectForSelector(UIApplication.sharedApplication, accessor);
            down = JBP1lotBoolForSelector(hardwareButton, @"isButtonDown", NO);
        } @catch (__unused NSException *exception) {
            down = NO;
        }
    });
    return down;
}

static BOOL JBP1lotHIDButtonPress(JBP1lotHardwareButton button, BOOL *observedBySpringBoard) {
    uint32_t usage = button == JBP1lotHardwareButtonLock ? JBP1lotConsumerPowerUsage : JBP1lotConsumerMenuUsage;
    *observedBySpringBoard = NO;
    if (!JBP1lotHIDKeyEvent(JBP1lotConsumerUsagePage, usage, YES))
        return NO;
    CFAbsoluteTime pressStart = CFAbsoluteTimeGetCurrent();
    while (!*observedBySpringBoard && CFAbsoluteTimeGetCurrent() - pressStart < 0.15) {
        usleep(10000);
        *observedBySpringBoard = JBP1lotHardwareButtonIsDown(button);
    }
    NSTimeInterval held = CFAbsoluteTimeGetCurrent() - pressStart;
    if (held < 0.06)
        usleep((useconds_t)((0.06 - held) * 1000000.0));
    return JBP1lotHIDKeyEvent(JBP1lotConsumerUsagePage, usage, NO);
}

static void JBP1lotRequestUIUnlock(void) {
    JBP1lotRunOnMain(^{
        @try {
            JBP1lotWakeDisplay();
            id lockManager = JBP1lotSharedInstance(@"SBLockScreenManager");
            SEL unlockSelector = @selector(unlockUIFromSource:withOptions:);
            if ([lockManager respondsToSelector:unlockSelector]) {
                NSDictionary *options = @{
                    @"SBUIUnlockOptionsStartFadeInAnimation": @YES,
                    @"SBUIUnlockOptionsTurnOnScreenFirstKey": @YES
                };
                ((void (*)(id, SEL, NSUInteger, NSDictionary *))objc_msgSend)(lockManager, unlockSelector, 0, options);
            }
            JBP1lotDismissCoverSheet();
        } @catch (__unused NSException *exception) {
        }
    });
}

static BOOL JBP1lotRequestSpringBoardButtonSimulation(NSString *selectorName, BOOL takesCompletion) {
    __block BOOL requested = NO;
    JBP1lotRunOnMain(^{
        UIApplication *application = UIApplication.sharedApplication;
        SEL selector = NSSelectorFromString(selectorName);
        if (![application respondsToSelector:selector])
            return;
        @try {
            if (takesCompletion)
                ((void (*)(id, SEL, dispatch_block_t))objc_msgSend)(application, selector, ^{});
            else
                ((void (*)(id, SEL))objc_msgSend)(application, selector);
            requested = YES;
        } @catch (__unused NSException *exception) {
            requested = NO;
        }
    });
    return requested;
}

static void JBP1lotRecordHomeButtonPress(void) {
    JBP1lotRunOnMain(^{
        JBP1lotRegisterHomeButtonPress();
    });
}

static BOOL JBP1lotUnlockDevice(NSString **failureReason) {
    BOOL (^unlocked)(JBP1lotSpringBoardState *) = ^BOOL(JBP1lotSpringBoardState *state) {
        return [state isUnlockedAndAwake];
    };
    JBP1lotSpringBoardState *state = JBP1lotReadSpringBoardState();
    for (NSUInteger attempt = 0; attempt < 3 && !unlocked(state); attempt++) {
        BOOL observed = NO;
        if (!state.uiLocked)
            JBP1lotRunOnMain(^{
                JBP1lotWakeDisplay();
            });
        else if (attempt == 1)
            JBP1lotRequestUIUnlock();
        else if (!JBP1lotHIDButtonPress(JBP1lotHardwareButtonHome, &observed))
            JBP1lotRequestUIUnlock();
        state = JBP1lotAwaitSpringBoardState(1.2, unlocked);
    }
    if (unlocked(state))
        return YES;
    *failureReason = state.uiLocked ? @"device is still locked; a passcode may be required" : @"display did not wake";
    return NO;
}

static BOOL JBP1lotPressHome(NSString **failureReason) {
    JBP1lotSpringBoardState *before = JBP1lotReadSpringBoardState();
    if (before.uiLocked && !JBP1lotUnlockDevice(failureReason))
        return NO;
    JBP1lotSpringBoardState *current = before.uiLocked ? JBP1lotReadSpringBoardState() : before;
    if (before.uiLocked && [current isUnlockedAtHomeScreen])
        return YES;

    BOOL observed = NO;
    if (!JBP1lotHIDButtonPress(JBP1lotHardwareButtonHome, &observed)) {
        *failureReason = @"home button HID event could not be dispatched";
        return NO;
    }
    JBP1lotRecordHomeButtonPress();
    if ([current isUnlockedAtHomeScreen])
        return YES;

    BOOL (^atHomeScreen)(JBP1lotSpringBoardState *) = ^BOOL(JBP1lotSpringBoardState *state) {
        return [state isUnlockedAtHomeScreen];
    };
    if ([JBP1lotAwaitSpringBoardState(1.5, atHomeScreen) isUnlockedAtHomeScreen])
        return YES;
    if (JBP1lotRequestSpringBoardButtonSimulation(@"_simulateHomeButtonPressWithCompletion:", YES) &&
        [JBP1lotAwaitSpringBoardState(1.5, atHomeScreen) isUnlockedAtHomeScreen])
        return YES;
    *failureReason = observed ? @"home button press did not reach the home screen"
                              : @"home button press was not delivered to SpringBoard";
    return NO;
}

static BOOL JBP1lotPressLock(NSString **failureReason) {
    JBP1lotSpringBoardState *before = JBP1lotReadSpringBoardState();
    BOOL (^lockOrDisplayChanged)(JBP1lotSpringBoardState *) = ^BOOL(JBP1lotSpringBoardState *state) {
        return state.uiLocked != before.uiLocked || state.screenOn != before.screenOn;
    };
    BOOL observed = NO;
    if (!JBP1lotHIDButtonPress(JBP1lotHardwareButtonLock, &observed)) {
        *failureReason = @"lock button HID event could not be dispatched";
        return NO;
    }
    if (lockOrDisplayChanged(JBP1lotAwaitSpringBoardState(1.5, lockOrDisplayChanged)))
        return YES;
    if (JBP1lotRequestSpringBoardButtonSimulation(@"_simulateLockButtonPress", NO) &&
        lockOrDisplayChanged(JBP1lotAwaitSpringBoardState(1.5, lockOrDisplayChanged)))
        return YES;
    *failureReason = observed ? @"lock button press did not change the lock or display state"
                              : @"lock button press was not delivered to SpringBoard";
    return NO;
}

static BOOL JBP1lotPressButtonSequence(JBP1lotHardwareButton button, NSUInteger repeat, NSUInteger intervalMs, NSString **failureReason) {
    JBP1lotSpringBoardState *before = JBP1lotReadSpringBoardState();
    NSUInteger observedPresses = 0;
    for (NSUInteger index = 0; index < repeat; index++) {
        BOOL observed = NO;
        if (!JBP1lotHIDButtonPress(button, &observed)) {
            *failureReason = @"hardware button HID event could not be dispatched";
            return NO;
        }
        if (observed)
            observedPresses += 1;
        if (button == JBP1lotHardwareButtonHome)
            JBP1lotRecordHomeButtonPress();
        if (index + 1 < repeat)
            usleep((useconds_t)intervalMs * 1000);
    }
    if (observedPresses == repeat)
        return YES;
    BOOL (^changed)(JBP1lotSpringBoardState *) = ^BOOL(JBP1lotSpringBoardState *state) {
        return [state differsFrom:before];
    };
    if (changed(JBP1lotAwaitSpringBoardState(1.0, changed)))
        return YES;
    *failureReason = @"hardware button sequence had no observable effect";
    return NO;
}

static JBP1lotHardwareButton JBP1lotHardwareButtonNamed(NSString *name) {
    NSString *normalized = [name.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if ([@[@"home", @"menu"] containsObject:normalized])
        return JBP1lotHardwareButtonHome;
    if ([@[@"lock", @"power", @"sleep", @"side"] containsObject:normalized])
        return JBP1lotHardwareButtonLock;
    if ([@[@"unlock", @"wake"] containsObject:normalized])
        return JBP1lotHardwareButtonUnlock;
    if ([@[@"volume_up", @"volumeup", @"volume_increment"] containsObject:normalized])
        return JBP1lotHardwareButtonVolumeUp;
    if ([@[@"volume_down", @"volumedown", @"volume_decrement"] containsObject:normalized])
        return JBP1lotHardwareButtonVolumeDown;
    if ([@[@"mute", @"ringer", @"silent"] containsObject:normalized])
        return JBP1lotHardwareButtonMute;
    return JBP1lotHardwareButtonUnsupported;
}

static uint32_t JBP1lotConsumerUsageForButton(JBP1lotHardwareButton button) {
    switch (button) {
        case JBP1lotHardwareButtonVolumeUp: return JBP1lotConsumerVolumeUpUsage;
        case JBP1lotHardwareButtonVolumeDown: return JBP1lotConsumerVolumeDownUsage;
        case JBP1lotHardwareButtonMute: return JBP1lotConsumerMuteUsage;
        default: return 0;
    }
}

static BOOL JBP1lotPressConsumerButton(uint32_t usage, NSUInteger repeat, NSUInteger intervalMs, NSString **failureReason) {
    for (NSUInteger index = 0; index < repeat; index++) {
        if (!JBP1lotHIDKeyEvent(JBP1lotConsumerUsagePage, usage, YES) || !JBP1lotHIDKeyEvent(JBP1lotConsumerUsagePage, usage, NO)) {
            *failureReason = @"consumer button HID event could not be dispatched";
            return NO;
        }
        if (index + 1 < repeat)
            usleep((useconds_t)intervalMs * 1000);
    }
    return YES;
}

static BOOL JBP1lotPerformHardwareButton(JBP1lotHardwareButton button, NSUInteger repeat, NSUInteger intervalMs, NSString **failureReason) {
    uint32_t consumerUsage = JBP1lotConsumerUsageForButton(button);
    if (consumerUsage)
        return JBP1lotPressConsumerButton(consumerUsage, repeat, intervalMs, failureReason);
    if (button == JBP1lotHardwareButtonUnlock)
        return JBP1lotUnlockDevice(failureReason);
    if (repeat > 1)
        return JBP1lotPressButtonSequence(button, repeat, intervalMs, failureReason);
    return button == JBP1lotHardwareButtonHome ? JBP1lotPressHome(failureReason) : JBP1lotPressLock(failureReason);
}

static BOOL JBP1lotPressHardwareButton(NSString *name, NSUInteger repeat, NSUInteger intervalMs, NSString **failureReason) {
    JBP1lotHardwareButton button = JBP1lotHardwareButtonNamed(name);
    if (button == JBP1lotHardwareButtonUnsupported) {
        *failureReason = [NSString stringWithFormat:@"unsupported hardware button \"%@\"", name];
        return NO;
    }
    atomic_fetch_add(&JBP1lotSyntheticButtonPressDepth, 1);
    BOOL performed = JBP1lotPerformHardwareButton(button, repeat, intervalMs, failureReason);
    usleep(150000);
    atomic_fetch_sub(&JBP1lotSyntheticButtonPressDepth, 1);
    return performed;
}

static CGFloat JBP1lotEase(CGFloat progress, NSString *easing) {
    if ([easing isEqualToString:@"ease_in"])
        return progress * progress;
    if ([easing isEqualToString:@"ease_out"])
        return 1 - (1 - progress) * (1 - progress);
    if ([easing isEqualToString:@"ease_in_out"])
        return progress < 0.5 ? 2 * progress * progress : 1 - pow(-2 * progress + 2, 2) / 2;
    return progress;
}

static CGPoint JBP1lotPointAlongPath(NSArray<NSValue *> *points, NSArray<NSNumber *> *offsets, CGFloat distance) {
    for (NSUInteger index = 1; index < points.count; index++) {
        CGFloat segmentEnd = offsets[index].doubleValue;
        if (distance > segmentEnd && index + 1 < points.count)
            continue;
        CGFloat segmentStart = offsets[index - 1].doubleValue;
        CGFloat length = segmentEnd - segmentStart;
        CGFloat fraction = length > 0 ? MIN(MAX((distance - segmentStart) / length, 0), 1) : 1;
        CGPoint from = points[index - 1].CGPointValue;
        CGPoint to = points[index].CGPointValue;
        return CGPointMake(from.x + (to.x - from.x) * fraction, from.y + (to.y - from.y) * fraction);
    }
    return points.lastObject.CGPointValue;
}

static void JBP1lotSleepUntil(uint64_t deadline) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0)
        mach_timebase_info(&timebase);
    uint64_t now = mach_absolute_time();
    if (deadline <= now)
        return;
    uint64_t nanoseconds = (deadline - now) * timebase.numer / timebase.denom;
    usleep((useconds_t)(nanoseconds / 1000));
}

static BOOL JBP1lotPerformPathGesture(NSArray<NSValue *> *points, NSUInteger durationMs, NSString *easing) {
    NSMutableArray<NSNumber *> *offsets = [NSMutableArray arrayWithObject:@0];
    for (NSUInteger index = 1; index < points.count; index++) {
        CGPoint from = points[index - 1].CGPointValue;
        CGPoint to = points[index].CGPointValue;
        [offsets addObject:@(offsets.lastObject.doubleValue + hypot(to.x - from.x, to.y - from.y))];
    }
    CGFloat totalDistance = offsets.lastObject.doubleValue;
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0)
        mach_timebase_info(&timebase);
    double frameMs = 8.0;
    NSUInteger frames = MAX(2, (NSUInteger)ceil(durationMs / frameMs));
    uint64_t frameTicks = (uint64_t)(durationMs * 1e6 / frames * timebase.denom / timebase.numer);
    CGPoint start = points.firstObject.CGPointValue;
    if (!JBP1lotHIDPoint(start.x, start.y, YES))
        return NO;
    uint64_t origin = mach_absolute_time();
    CGPoint current = start;
    for (NSUInteger frame = 1; frame <= frames; frame++) {
        JBP1lotSleepUntil(origin + frameTicks * frame);
        CGFloat progress = JBP1lotEase((CGFloat)frame / (CGFloat)frames, easing);
        current = JBP1lotPointAlongPath(points, offsets, totalDistance * progress);
        if (!JBP1lotHIDPoint(current.x, current.y, YES)) {
            JBP1lotHIDPoint(current.x, current.y, NO);
            return NO;
        }
    }
    return JBP1lotHIDPoint(current.x, current.y, NO);
}

BOOL JBP1lotInjectAction(NSDictionary *params, NSString **failureReason) {
    NSString *action = [params[@"action"] isKindOfClass:[NSString class]] ? [params[@"action"] lowercaseString] : @"";
    if ([action isEqualToString:@"screen_off"] || [action isEqualToString:@"display_off"] || [action isEqualToString:@"dark_on"]) {
        return JBP1lotSetDisplayEnabled(NO);
    }
    if ([action isEqualToString:@"screen_on"] || [action isEqualToString:@"display_on"] || [action isEqualToString:@"dark_off"]) {
        return JBP1lotSetDisplayEnabled(YES);
    }
    if ([action isEqualToString:@"button"] || [action isEqualToString:@"hardware_button"]) {
        NSString *button = [params[@"button"] isKindOfClass:[NSString class]] ? params[@"button"] : @"";
        NSUInteger repeat = MAX(1, MIN([params[@"repeat"] unsignedIntegerValue], 5));
        NSUInteger interval = MAX(40, MIN([params[@"intervalMs"] unsignedIntegerValue] ?: 180, 1000));
        BOOL performed = JBP1lotPressHardwareButton(button, repeat, interval, failureReason);
        if (performed && [button.lowercaseString isEqualToString:@"home"] && repeat >= 3)
            usleep(450000);
        return performed;
    }
    if ([params[@"unlock"] boolValue] && !JBP1lotUnlockDevice(failureReason))
        return NO;
    CGFloat x = 0;
    CGFloat y = 0;
    BOOL hasPoint = NO;
    if (params[@"x"] != nil && params[@"y"] != nil)
        hasPoint = JBP1lotPointFromValue(@{ @"x": params[@"x"], @"y": params[@"y"] }, &x, &y);
    if ([action isEqualToString:@"tap"] || [action isEqualToString:@"press"]) {
        return hasPoint && JBP1lotHIDPoint(x, y, YES) && JBP1lotHIDPoint(x, y, NO);
    }
    if ([action isEqualToString:@"long_press"]) {
        if (!hasPoint || !JBP1lotHIDPoint(x, y, YES)) {
            return NO;
        }
        usleep((useconds_t)MAX(100, [params[@"durationMs"] integerValue]) * 1000);
        return JBP1lotHIDPoint(x, y, NO);
    }
    if ([action isEqualToString:@"swipe"] || [action isEqualToString:@"drag"]) {
        NSArray *values = [params[@"points"] isKindOfClass:[NSArray class]] ? params[@"points"] : @[];
        NSMutableArray<NSValue *> *requestedPoints = [NSMutableArray arrayWithCapacity:values.count];
        for (id value in values) {
            CGFloat pointX = 0;
            CGFloat pointY = 0;
            if (JBP1lotPointFromValue(value, &pointX, &pointY)) {
                [requestedPoints addObject:[NSValue valueWithCGPoint:CGPointMake(pointX, pointY)]];
            }
        }
        if (!hasPoint && requestedPoints.count > 0) {
            CGPoint firstPoint = requestedPoints.firstObject.CGPointValue;
            x = firstPoint.x;
            y = firstPoint.y;
            hasPoint = YES;
        }
        if (!hasPoint || requestedPoints.count == 0) {
            return NO;
        }

        NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:requestedPoints.count + 1];
        CGPoint startPoint = CGPointMake(x, y);
        [points addObject:[NSValue valueWithCGPoint:startPoint]];
        for (NSValue *value in requestedPoints) {
            CGPoint point = value.CGPointValue;
            if (!CGPointEqualToPoint(point, points.lastObject.CGPointValue))
                [points addObject:value];
        }
        if (points.count < 2)
            return NO;

        NSUInteger durationMs = MAX(40, MIN([params[@"durationMs"] unsignedIntegerValue] ?: 200, 5000));
        NSString *easing = [params[@"easing"] isKindOfClass:[NSString class]] ? [params[@"easing"] lowercaseString] : @"linear";
        return JBP1lotPerformPathGesture(points, durationMs, easing);
    }
    if ([action isEqualToString:@"text"]) {
        NSString *text = [params[@"text"] isKindOfClass:[NSString class]] ? params[@"text"] : @"";
        return JBP1lotInsertText(text);
    }
    return NO;
}
