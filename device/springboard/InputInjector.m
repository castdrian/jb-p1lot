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
typedef void (*AppendFn)(IOHIDEventRef, IOHIDEventRef, uint32_t);
typedef void (*SetIntegerFn)(IOHIDEventRef, uint32_t, int64_t);
typedef void (*SetSenderIDFn)(IOHIDEventRef, uint64_t);
typedef void (*DispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef void (*ReleaseFn)(CFTypeRef);

typedef struct {
    ClientCreateFn createClient;
    DigitizerCreateFn createDigitizerEvent;
    FingerCreateFn createFingerEvent;
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

static BOOL JBP1lotInsertText(NSString *text) {
    Class keyboardClass = NSClassFromString(@"UIKeyboardImpl");
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    id keyboard = keyboardClass && [keyboardClass respondsToSelector:sharedSelector] ? ((id (*)(id, SEL))objc_msgSend)((id)keyboardClass, sharedSelector) : nil;
    SEL insertSelector = NSSelectorFromString(@"insertText:");
    if (!keyboard || ![keyboard respondsToSelector:insertSelector]) {
        return NO;
    }
    ((void (*)(id, SEL, NSString *))objc_msgSend)(keyboard, insertSelector, text);
    return YES;
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
        NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:values.count];
        for (id value in values) {
            CGFloat pointX = 0;
            CGFloat pointY = 0;
            if (JBP1lotPointFromValue(value, &pointX, &pointY)) {
                [points addObject:[NSValue valueWithCGPoint:CGPointMake(pointX, pointY)]];
            }
        }
        if (!hasPoint && points.count > 0) {
            CGPoint firstPoint = points.firstObject.CGPointValue;
            x = firstPoint.x;
            y = firstPoint.y;
            hasPoint = YES;
        }
        if (!hasPoint || points.count == 0 || !JBP1lotHIDPoint(x, y, YES)) {
            return NO;
        }
        CGPoint lastPoint = CGPointMake(x, y);
        for (NSValue *value in points) {
            lastPoint = value.CGPointValue;
            if (!JBP1lotHIDPoint(lastPoint.x, lastPoint.y, YES)) {
                return NO;
            }
            usleep(8000);
        }
        return JBP1lotHIDPoint(lastPoint.x, lastPoint.y, NO);
    }
    if ([action isEqualToString:@"text"]) {
        NSString *text = [params[@"text"] isKindOfClass:[NSString class]] ? params[@"text"] : @"";
        return JBP1lotInsertText(text);
    }
    return NO;
}
