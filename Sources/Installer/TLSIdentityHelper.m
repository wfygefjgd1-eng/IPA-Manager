#import "TLSIdentityHelper.h"

void IPMSetTLSIdentity(sec_protocol_options_t options, SecIdentityRef identity) {
    if (options == NULL || identity == NULL) {
        return;
    }
    sec_identity_t secIdentity = sec_identity_create_with_identity(identity);
    if (secIdentity != NULL) {
        sec_protocol_options_set_local_identity(options, secIdentity);
    }
}