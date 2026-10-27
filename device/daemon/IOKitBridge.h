#import <Foundation/Foundation.h>
#import <mach/mach.h>

typedef mach_port_t JBP1lotIOObject;

NSDictionary *JBP1lotIORegistryProperties(const char *serviceClass);
BOOL JBP1lotSMCRead(const char *key, void *bytes, uint32_t size);
BOOL JBP1lotSMCWrite(const char *key, const void *bytes, uint32_t size);
