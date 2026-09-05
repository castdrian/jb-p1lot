#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <objc/message.h>
#import <stdint.h>
#import <unistd.h>
#import "DisplayControl.h"

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

static BOOL JBP1lotHIDKeyboardEvent(uint32_t usage, BOOL down) {
    JBP1lotHIDFunctions functions = JBP1lotHIDLoadFunctions();
    if (!functions.client || !functions.createKeyboardEvent || !functions.dispatchEvent)
        return NO;
    IOHIDEventRef event = functions.createKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), 0x07u, usage, down, 0);
    if (!event)
        return NO;
    if (functions.setSenderID)
        functions.setSenderID(event, 0x8000000817319375ULL);
    functions.dispatchEvent(functions.client, event);
    if (functions.releaseValue)
        functions.releaseValue(event);
    return YES;
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
        functions.setSenderID(parent, 0x8000000817319375ULL);
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

static BOOL JBP1lotUnlockDevice(void) {
    __block BOOL performed = NO;
    void (^unlockBlock)(void) = ^{
        JBP1lotWakeDisplay();

        Class awayControllerClass = NSClassFromString(@"SBAwayController");
        id awayController = awayControllerClass && [awayControllerClass respondsToSelector:@selector(sharedAwayController)]
                                ? ((id (*)(id, SEL))objc_msgSend)((id)awayControllerClass, @selector(sharedAwayController))
                                : nil;
        if ([awayController respondsToSelector:@selector(isLocked)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(awayController, @selector(isLocked))) {
            if ([awayController respondsToSelector:@selector(attemptUnlock)]) {
                ((void (*)(id, SEL))objc_msgSend)(awayController, @selector(attemptUnlock));
                performed = YES;
            }
            if ([awayController respondsToSelector:@selector(unlockWithSound:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(awayController, @selector(unlockWithSound:), NO);
                performed = YES;
            }
        }

        Class lockManagerClass = NSClassFromString(@"SBLockScreenManager");
        SEL sharedSelector = @selector(sharedInstance);
        id lockManager = lockManagerClass && [lockManagerClass respondsToSelector:sharedSelector]
                          ? ((id (*)(id, SEL))objc_msgSend)((id)lockManagerClass, sharedSelector)
                          : nil;
        SEL unlockSelector = @selector(unlockUIFromSource:withOptions:);
        if ([lockManager respondsToSelector:unlockSelector]) {
            NSDictionary *options = @{
                @"SBUIUnlockOptionsStartFadeInAnimation": @YES,
                @"SBUIUnlockOptionsTurnOnScreenFirstKey": @YES
            };
            ((void (*)(id, SEL, NSUInteger, NSDictionary *))objc_msgSend)(lockManager, unlockSelector, 0, options);
            performed = YES;
        }
        JBP1lotDismissCoverSheet();
    };
    if ([NSThread isMainThread])
        unlockBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), unlockBlock);
    return performed;
}

static BOOL JBP1lotPressHardwareButton(NSString *button) {
    NSString *normalizedButton = [button.lowercaseString stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if ([normalizedButton isEqualToString:@"unlock"] || [normalizedButton isEqualToString:@"wake"])
        return JBP1lotUnlockDevice();
    __block BOOL performed = NO;
    void (^pressBlock)(void) = ^{
        UIApplication *application = UIApplication.sharedApplication;
        if (JBP1lotDisplayIsEnabled())
            JBP1lotWakeDisplay();

        Class lockManagerClass = NSClassFromString(@"SBLockScreenManager");
        id lockManager = lockManagerClass && [lockManagerClass respondsToSelector:@selector(sharedInstance)]
                             ? ((id (*)(id, SEL))objc_msgSend)((id)lockManagerClass, @selector(sharedInstance))
                             : nil;
        if ([normalizedButton isEqualToString:@"home"] && [lockManager respondsToSelector:@selector(isUILocked)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(lockManager, @selector(isUILocked)))
            performed = JBP1lotUnlockDevice();

        Class controllerClass = NSClassFromString(@"SBUIController");
        SEL sharedSelector = @selector(sharedInstance);
        id controller = controllerClass && [controllerClass respondsToSelector:sharedSelector]
                            ? ((id (*)(id, SEL))objc_msgSend)((id)controllerClass, sharedSelector)
                            : nil;
        BOOL stillLocked = [lockManager respondsToSelector:@selector(isUILocked)] &&
                           ((BOOL (*)(id, SEL))objc_msgSend)(lockManager, @selector(isUILocked));
        SEL homeSelector = @selector(handleHomeButtonSinglePressUp);
        if ([normalizedButton isEqualToString:@"home"] && !stillLocked && [controller respondsToSelector:homeSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(controller, homeSelector);
            performed = YES;
        } else if ([normalizedButton isEqualToString:@"home"] && [application respondsToSelector:@selector(_simulateHomeButtonPress)]) {
            ((void (*)(id, SEL))objc_msgSend)(application, @selector(_simulateHomeButtonPress));
            performed = YES;
        }

        if ([normalizedButton isEqualToString:@"home"])
            JBP1lotRegisterHomeButtonPress();

        if (!performed && [normalizedButton isEqualToString:@"home"])
            performed = JBP1lotUnlockDevice();
    };

    if ([NSThread isMainThread]) {
        pressBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), pressBlock);
    }
    return performed;
}

BOOL JBP1lotInjectAction(NSDictionary *params) {
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
        BOOL performed = YES;
        for (NSUInteger index = 0; index < repeat; index++) {
            performed = JBP1lotPressHardwareButton(button) && performed;
            if (index + 1 < repeat)
                usleep((useconds_t)interval * 1000);
        }
        if ([button.lowercaseString isEqualToString:@"home"] && repeat >= 3)
            usleep(450000);
        return performed;
    }
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

        NSUInteger totalSteps = 0;
        for (NSUInteger index = 1; index < points.count; index++) {
            CGPoint from = points[index - 1].CGPointValue;
            CGPoint to = points[index].CGPointValue;
            CGFloat distance = hypot(to.x - from.x, to.y - from.y);
            totalSteps += MAX(1, (NSUInteger)ceil(distance / 12.0));
        }
        NSUInteger durationMs = MAX(40, MIN([params[@"durationMs"] unsignedIntegerValue] ?: 200, 2000));
        if (!JBP1lotHIDPoint(startPoint.x, startPoint.y, YES))
            return NO;

        NSUInteger completedSteps = 0;
        for (NSUInteger index = 1; index < points.count; index++) {
            CGPoint from = points[index - 1].CGPointValue;
            CGPoint to = points[index].CGPointValue;
            CGFloat distance = hypot(to.x - from.x, to.y - from.y);
            NSUInteger segmentSteps = MAX(1, (NSUInteger)ceil(distance / 12.0));
            for (NSUInteger step = 1; step <= segmentSteps; step++) {
                CGFloat fraction = (CGFloat)step / (CGFloat)segmentSteps;
                CGPoint point = CGPointMake(from.x + ((to.x - from.x) * fraction),
                                            from.y + ((to.y - from.y) * fraction));
                if (!JBP1lotHIDPoint(point.x, point.y, YES)) {
                    JBP1lotHIDPoint(point.x, point.y, NO);
                    return NO;
                }
                completedSteps += 1;
                NSUInteger remainingSteps = totalSteps - completedSteps;
                NSUInteger remainingMilliseconds = durationMs * remainingSteps / totalSteps;
                NSUInteger nextMilliseconds = durationMs * completedSteps / totalSteps;
                if (remainingMilliseconds > 0 && nextMilliseconds > 0)
                    usleep((useconds_t)(nextMilliseconds - (durationMs * (completedSteps - 1) / totalSteps)) * 1000);
            }
        }
        CGPoint lastPoint = points.lastObject.CGPointValue;
        if (!JBP1lotHIDPoint(lastPoint.x, lastPoint.y, NO)) {
            JBP1lotHIDPoint(lastPoint.x, lastPoint.y, NO);
            return NO;
        }
        return YES;
    }
    if ([action isEqualToString:@"text"]) {
        NSString *text = [params[@"text"] isKindOfClass:[NSString class]] ? params[@"text"] : @"";
        return JBP1lotInsertText(text);
    }
    return NO;
}
