#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BridgeProtocol.h"
#import "DisplayControl.h"
#import "InputInjector.h"

static NSInteger const JBP1lotHomePressType = 101;

static BOOL JBP1lotEndsHomePress(UIPressesEvent *event) {
    if (![event isKindOfClass:[UIPressesEvent class]])
        return NO;
    for (UIPress *press in event.allPresses) {
        if ((NSInteger)press.type == JBP1lotHomePressType && press.phase == UIPressPhaseEnded)
            return YES;
    }
    return NO;
}

%hook SpringBoard

- (BOOL)_handlePhysicalButtonEvent:(UIPressesEvent *)event {
    BOOL handled = %orig;
    if (JBP1lotEndsHomePress(event) && !JBP1lotSyntheticButtonPressActive())
        JBP1lotRegisterHomeButtonPress();
    return handled;
}

%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        JBP1lotAgentStart();
    });
}
