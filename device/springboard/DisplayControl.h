#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL JBP1lotSetDisplayEnabled(BOOL enabled);
BOOL JBP1lotDisplayIsEnabled(void);
void JBP1lotWakeDisplay(void);
void JBP1lotRegisterHomeButtonPress(void);
void JBP1lotRegisterHomeTriplePress(void);

#ifdef __cplusplus
}
#endif
