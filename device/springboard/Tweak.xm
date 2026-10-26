#import <Foundation/Foundation.h>
#import "BridgeProtocol.h"
#import "DisplayControl.h"
#import "InputInjector.h"

%hook SBHomeHardwareButton

- (void)initialButtonUp:(id)gestureRecognizer {
    %orig;
    if (!JBP1lotSyntheticButtonPressActive())
        JBP1lotRegisterHomeButtonPress();
}

%end

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        JBP1lotAgentStart();
    });
}
