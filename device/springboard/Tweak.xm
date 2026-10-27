#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BridgeProtocol.h"
#import "DisplayControl.h"
#import "InputInjector.h"

static void JBP1lotRegisterEndedPresses(UIPressesEvent *event) {
    if (![event isKindOfClass:[UIPressesEvent class]])
        return;
    for (UIPress *press in event.allPresses) {
        if (press.phase == UIPressPhaseEnded)
            JBP1lotRegisterButtonPress((NSInteger)press.type);
    }
}

%hook SpringBoard

- (BOOL)_handlePhysicalButtonEvent:(UIPressesEvent *)event {
    BOOL handled = %orig;
    JBP1lotRegisterEndedPresses(event);
    return handled;
}

%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        JBP1lotAgentStart();
    });
}
