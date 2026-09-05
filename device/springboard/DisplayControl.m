#import "DisplayControl.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreFoundation/CoreFoundation.h>

@protocol JBP1lotBacklightControllerProtocol <NSObject>
+ (instancetype)sharedInstance;
- (BOOL)screenIsOn;
- (BOOL)screenIsDim;
- (NSInteger)backlightState;
- (void)_animateBacklightToFactor:(float)factor duration:(double)duration source:(NSInteger)source silently:(BOOL)silently completion:(id)completion;
- (void)_startFadeOutAnimationFromLockSource:(int)source;
- (void)turnOffScreenForSource:(NSInteger)source;
- (void)turnOnScreenFullyWithBacklightSource:(NSInteger)source;
- (void)setBacklightState:(NSInteger)state source:(NSInteger)source;
- (void)setBacklightState:(NSInteger)state source:(NSInteger)source animated:(BOOL)animated completion:(id)completion;
- (void)preventIdleSleep;
- (void)allowIdleSleep;
@end

@protocol JBP1lotBrightnessSystemClientProtocol <NSObject>
- (id)copyPropertyForKey:(NSString *)key;
- (BOOL)setProperty:(id)value forKey:(NSString *)key;
@end

static id JBP1lotIvarObject(id instance, const char *name) {
    if (!instance) {
        return nil;
    }
    Ivar ivar = class_getInstanceVariable([instance class], name);
    return ivar ? object_getIvar(instance, ivar) : nil;
}

static id<JBP1lotBacklightControllerProtocol> JBP1lotBacklightController(void) {
    Class backlightClass = NSClassFromString(@"SBBacklightController");
    if (!backlightClass || ![backlightClass respondsToSelector:@selector(sharedInstance)]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)((id)backlightClass, @selector(sharedInstance));
}

static id<JBP1lotBrightnessSystemClientProtocol> JBP1lotBrightnessClient(void) {
    id backlight = JBP1lotBacklightController();
    return JBP1lotIvarObject(backlight, "_brightnessSystemClient");
}

static BOOL JBP1lotSetBrightnessFactor(NSNumber *factor) {
    id<JBP1lotBrightnessSystemClientProtocol> client = JBP1lotBrightnessClient();
    if (!client || ![client respondsToSelector:@selector(setProperty:forKey:)]) {
        return NO;
    }
    return [client setProperty:factor forKey:@"DisplayBrightnessFactor"];
}

static BOOL JBP1lotTurnOffScreen(id backlight) {
    BOOL performed = NO;
    @try {
        if ([backlight respondsToSelector:@selector(_startFadeOutAnimationFromLockSource:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(backlight, @selector(_startFadeOutAnimationFromLockSource:), 3);
            performed = YES;
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        if ([backlight respondsToSelector:@selector(_animateBacklightToFactor:duration:source:silently:completion:)]) {
            ((void (*)(id, SEL, float, double, NSInteger, BOOL, id))objc_msgSend)(backlight,
                @selector(_animateBacklightToFactor:duration:source:silently:completion:), 0.0f, 0.25, 3, YES, nil);
            performed = YES;
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        if ([backlight respondsToSelector:@selector(turnOffScreenForSource:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(backlight, @selector(turnOffScreenForSource:), 3);
            performed = YES;
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        if ([backlight respondsToSelector:@selector(setBacklightState:source:animated:completion:)]) {
            ((void (*)(id, SEL, NSInteger, NSInteger, BOOL, id))objc_msgSend)(backlight, @selector(setBacklightState:source:animated:completion:), 0, 3, NO, nil);
            performed = YES;
        } else if ([backlight respondsToSelector:@selector(setBacklightState:source:)]) {
            ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(backlight, @selector(setBacklightState:source:), 0, 3);
            performed = YES;
        }
    } @catch (__unused NSException *exception) {
    }
    return performed;
}

static NSUInteger JBP1lotHomePressCount = 0;
static CFAbsoluteTime JBP1lotLastHomePress = 0;
static BOOL JBP1lotDisplayOverrideSet = NO;
static BOOL JBP1lotRequestedDisplayEnabled = YES;

void JBP1lotRegisterHomeButtonPress(void) {
    BOOL displayWasEnabled = JBP1lotDisplayIsEnabled();
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - JBP1lotLastHomePress > 1.0)
        JBP1lotHomePressCount = 0;
    JBP1lotLastHomePress = now;
    JBP1lotHomePressCount += 1;
    if (JBP1lotHomePressCount >= 3) {
        JBP1lotHomePressCount = 0;
        BOOL nextEnabled = !JBP1lotRequestedDisplayEnabled;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            JBP1lotSetDisplayEnabled(nextEnabled);
        });
    } else if (!displayWasEnabled) {
        JBP1lotSetDisplayEnabled(NO);
    }
}

void JBP1lotWakeDisplay(void) {
    UIApplication *application = UIApplication.sharedApplication;
    id backlight = JBP1lotBacklightController();
    @try {
        if ([backlight respondsToSelector:@selector(turnOnScreenFullyWithBacklightSource:)]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(backlight, @selector(turnOnScreenFullyWithBacklightSource:), 3);
        } else if ([backlight respondsToSelector:@selector(setBacklightState:source:)]) {
            ((void (*)(id, SEL, NSInteger, NSInteger))objc_msgSend)(backlight, @selector(setBacklightState:source:), 1, 3);
        }
        if ([backlight respondsToSelector:@selector(_animateBacklightToFactor:duration:source:silently:completion:)]) {
            ((void (*)(id, SEL, float, double, NSInteger, BOOL, id))objc_msgSend)(backlight,
                @selector(_animateBacklightToFactor:duration:source:silently:completion:), 1.0f, 0.0, 3, YES, nil);
        }
    } @catch (__unused NSException *exception) {
    }
    if ([application respondsToSelector:@selector(undim)]) {
        ((void (*)(id, SEL))objc_msgSend)(application, @selector(undim));
    }

    Class awayControllerClass = NSClassFromString(@"SBAwayController");
    id awayController = awayControllerClass && [awayControllerClass respondsToSelector:@selector(sharedAwayController)]
        ? ((id (*)(id, SEL))objc_msgSend)((id)awayControllerClass, @selector(sharedAwayController))
        : nil;
    if ([awayController respondsToSelector:@selector(undim)]) {
        ((void (*)(id, SEL))objc_msgSend)(awayController, @selector(undim));
    }
}

BOOL JBP1lotSetDisplayEnabled(BOOL enabled) {
    __block BOOL performed = NO;
    void (^change)(void) = ^{
        JBP1lotDisplayOverrideSet = YES;
        JBP1lotRequestedDisplayEnabled = enabled;
        @try {
            id<JBP1lotBacklightControllerProtocol> backlight = JBP1lotBacklightController();
            if (enabled) {
                performed = JBP1lotSetBrightnessFactor(@1);
                if ([backlight respondsToSelector:@selector(allowIdleSleep)]) {
                    [backlight allowIdleSleep];
                    performed = YES;
                }
                JBP1lotWakeDisplay();
            } else {
                performed = JBP1lotSetBrightnessFactor(@0);
                performed = JBP1lotTurnOffScreen(backlight) || performed;
                if ([backlight respondsToSelector:@selector(preventIdleSleep)]) {
                    [backlight preventIdleSleep];
                    performed = YES;
                }
            }
        } @catch (__unused NSException *exception) {
            performed = NO;
        }
    };
    if ([NSThread isMainThread]) {
        change();
    } else {
        dispatch_sync(dispatch_get_main_queue(), change);
    }
    return performed;
}

BOOL JBP1lotDisplayIsEnabled(void) {
    if (JBP1lotDisplayOverrideSet)
        return JBP1lotRequestedDisplayEnabled;
    __block BOOL enabled = YES;
    void (^readState)(void) = ^{
        @try {
            id<JBP1lotBacklightControllerProtocol> backlight = JBP1lotBacklightController();
            if ([backlight respondsToSelector:@selector(backlightState)] && [backlight backlightState] == 0) {
                enabled = NO;
                return;
            }
            if ([backlight respondsToSelector:@selector(screenIsOn)] && ![backlight screenIsOn]) {
                enabled = NO;
                return;
            }
            id<JBP1lotBrightnessSystemClientProtocol> client = JBP1lotBrightnessClient();
            id factor = client && [client respondsToSelector:@selector(copyPropertyForKey:)]
                ? [client copyPropertyForKey:@"DisplayBrightnessFactor"]
                : nil;
            if ([factor respondsToSelector:@selector(doubleValue)]) {
                enabled = [factor doubleValue] > 0.01;
                return;
            }
            enabled = YES;
        } @catch (__unused NSException *exception) {
            enabled = YES;
        }
    };
    if ([NSThread isMainThread]) {
        readState();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readState);
    }
    return enabled;
}
