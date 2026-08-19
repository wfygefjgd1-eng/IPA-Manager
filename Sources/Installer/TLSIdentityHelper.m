#import "TLSIdentityHelper.h"
#import <Security/SecIdentity.h>
#import <Security/SecProtocolTypes.h>

void IPMSetTLSIdentity(sec_protocol_options_t options, SecIdentityRef identity) {
    if (options == NULL || identity == NULL) {
        return;
    }

    // Extract the leaf certificate from the identity
    SecCertificateRef cert = NULL;
    if (SecIdentityCopyCertificate(identity, &cert) != errSecSuccess || cert == NULL) {
        return;
    }

    sec_identity_t secIdentity = sec_identity_create_with_certificates(cert, NULL);
    CFRelease(cert);
    if (secIdentity != NULL) {
        sec_protocol_options_set_local_identity(options, secIdentity);
    }
}