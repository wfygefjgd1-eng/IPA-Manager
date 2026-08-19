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

void IPMSetTLSIdentityFromCertKey(sec_protocol_options_t options, SecCertificateRef cert, SecKeyRef key) {
    if (options == NULL || cert == NULL || key == NULL) {
        return;
    }

    // iOS 15+ 的 sec_identity_create_with_certificates 直接用证书 + 私钥构造 TLS 身份，
    // 绕开 SecPKCS12Import（它不支持 OpenSSL 3 的 PBES2/AES 新式 p12）。
    // 项目最低部署版本为 iOS 16，实际总会走 available 分支；旧系统下仅记录日志并忽略。
    if (@available(iOS 15.0, *)) {
        sec_identity_t secIdentity = sec_identity_create_with_certificates(cert, key);
        if (secIdentity != NULL) {
            sec_protocol_options_set_local_identity(options, secIdentity);
        } else {
            NSLog(@"IPMSetTLSIdentityFromCertKey: sec_identity_create_with_certificates 返回 NULL");
        }
    } else {
        NSLog(@"IPMSetTLSIdentityFromCertKey: 需要 iOS 15+，已忽略 TLS 身份设置");
    }
}