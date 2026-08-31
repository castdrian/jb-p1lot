#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

FOUNDATION_EXPORT NSString * const JBP1lotAgentSocketPath;
FOUNDATION_EXPORT NSString * const JBP1lotBonjourType;
FOUNDATION_EXPORT uint16_t const JBP1lotPort;
FOUNDATION_EXPORT NSString * const JBP1lotVersionString;

nw_parameters_t JBP1lotCreateTLSParameters(void);
NSData *JBP1lotFrameForDictionary(NSDictionary *dictionary);
NSDictionary *JBP1lotDictionaryFromFrame(NSData *frame);
NSDictionary *JBP1lotErrorPayload(NSString *code, NSString *message);
NSDictionary *JBP1lotHandleRequest(NSDictionary *request);
BOOL JBP1lotForwardToAgent(NSDictionary *request, NSDictionary **response);
void JBP1lotStartService(void);
void JBP1lotAgentStart(void);

#ifdef __cplusplus
}
#endif
