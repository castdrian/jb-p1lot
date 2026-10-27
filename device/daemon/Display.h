#import <Foundation/Foundation.h>

void JBP1lotDisplayStart(void);
BOOL JBP1lotSetBlackout(BOOL enabled, NSString *source);
BOOL JBP1lotBlackoutEnabled(void);
void JBP1lotRefreshBlackout(void);
NSDictionary *JBP1lotDisplayStatus(void);
