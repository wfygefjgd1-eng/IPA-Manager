#import "TLSIdentityHelper.h"
#import <Security/SecIdentity.h>
#import <Security/SecProtocolTypes.h>

void IPMSetTLSIdentity(sec_protocol_options_t options, SecIdentityRef identity) {
    if (options == NULL || identity == NULL) {
        return;
    }

    // 用 sec_identity_create 包装 SecIdentityRef（同时包含证书与私钥）。
    // 之前用 sec_identity_create_with_certificates(cert, NULL) 传了 NULL 私钥，
    // 导致 TLS 握手永远失败（服务器拿不出私钥）。
    sec_identity_t secIdentity = sec_identity_create(identity);
    if (secIdentity != NULL) {
        sec_protocol_options_set_local_identity(options, secIdentity);
    }
}