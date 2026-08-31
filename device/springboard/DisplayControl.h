#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL JBP1lotSetDisplayEnabled(BOOL enabled);
BOOL JBP1lotDisplayIsEnabled(void);
void JBP1lotWakeDisplay(void);
void JBP1lotRegisterHomeButtonPress(void);

#ifdef __cplusplus
}
#endif
