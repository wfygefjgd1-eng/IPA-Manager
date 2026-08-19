#ifndef TLSIdentityHelper_h
#define TLSIdentityHelper_h

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

void IPMSetTLSIdentity(sec_protocol_options_t options, SecIdentityRef identity);

// 用证书 + 私钥（非 SecPKCS12Import 路径，例如 OpenSSL 导出的 DER）构造 TLS 身份并设置到 options。
// 依赖 iOS 15+ 的 sec_identity_create_with_certificates，不可用/失败时静默忽略（仅日志）。
void IPMSetTLSIdentityFromCertKey(sec_protocol_options_t options, SecCertificateRef cert, SecKeyRef key);

#ifdef __cplusplus
}
#endif

#endif /* TLSIdentityHelper_h */