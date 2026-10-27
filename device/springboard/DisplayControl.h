#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL JBP1lotSetDisplayEnabled(BOOL enabled);
BOOL JBP1lotDisplayIsEnabled(void);
void JBP1lotWakeDisplay(void);
typedef NS_ENUM(NSInteger, JBP1lotPressType) {
    JBP1lotPressTypeHome = 101,
    JBP1lotPressTypeVolumeUp = 102,
    JBP1lotPressTypeVolumeDown = 103,
};

void JBP1lotRegisterButtonPress(NSInteger type);

#ifdef __cplusplus
}
#endif
