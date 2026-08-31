#import "BridgeProtocol.h"
#import <Security/SecTrust.h>

static dispatch_queue_t JBP1lotTLSQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("dev.adrian.jb-p1lot.tls", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static SecIdentityRef JBP1lotIdentity(void) {
    NSString *path = @"/var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.server.p12";
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data.length == 0) {
        return NULL;
    }
    NSDictionary *options = @{(__bridge id)kSecImportExportPassphrase: @""};
    CFArrayRef items = NULL;
    OSStatus status = SecPKCS12Import((__bridge CFDataRef)data, (__bridge CFDictionaryRef)options, &items);
    if (status != errSecSuccess || !items || CFArrayGetCount(items) == 0) {
        if (items) {
            CFRelease(items);
        }
        return NULL;
    }
    NSDictionary *item = CFArrayGetValueAtIndex(items, 0);
    SecIdentityRef identity = (__bridge_retained SecIdentityRef)item[(__bridge id)kSecImportItemIdentity];
    CFRelease(items);
    return identity;
}

nw_parameters_t JBP1lotCreateTLSParameters(void) {
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(^(nw_protocol_options_t options) {
        sec_protocol_options_t securityOptions = nw_tls_copy_sec_protocol_options(options);
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, tls_protocol_version_TLSv13);
        sec_protocol_options_set_peer_authentication_required(securityOptions, true);
        SecIdentityRef identity = JBP1lotIdentity();
        if (identity) {
            sec_protocol_options_set_local_identity(securityOptions, sec_identity_create(identity));
            CFRelease(identity);
        }
        NSData *caData = [NSData dataWithContentsOfFile:@"/var/jb/var/root/Library/Preferences/dev.adrian.jb-p1lot.ca.der"];
        if (caData.length > 0) {
            sec_protocol_options_set_verify_block(securityOptions, ^(sec_protocol_metadata_t metadata, sec_trust_t trust, sec_protocol_verify_complete_t complete) {
                SecTrustRef cfTrust = sec_trust_copy_ref(trust);
                SecCertificateRef caCertificate = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)caData);
                if (!cfTrust || !caCertificate) {
                    if (cfTrust) CFRelease(cfTrust);
                    if (caCertificate) CFRelease(caCertificate);
                    complete(false);
                    return;
                }
                NSArray *anchors = @[(__bridge id)caCertificate];
                OSStatus anchorStatus = SecTrustSetAnchorCertificates(cfTrust, (__bridge CFArrayRef)anchors);
                OSStatus onlyStatus = SecTrustSetAnchorCertificatesOnly(cfTrust, true);
                SecPolicyRef policy = SecPolicyCreateBasicX509();
                OSStatus policyStatus = policy ? SecTrustSetPolicies(cfTrust, policy) : errSecParam;
                BOOL valid = anchorStatus == errSecSuccess && onlyStatus == errSecSuccess && policyStatus == errSecSuccess && SecTrustEvaluateWithError(cfTrust, NULL);
                if (policy) CFRelease(policy);
                CFRelease(caCertificate);
                CFRelease(cfTrust);
                complete(valid);
            }, JBP1lotTLSQueue());
        }
    }, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    return parameters;
}
