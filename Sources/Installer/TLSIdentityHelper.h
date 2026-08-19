#ifndef TLSIdentityHelper_h
#define TLSIdentityHelper_h

#import <Foundation/Foundation.h>
#import <Network/Network.h>
#import <Security/Security.h>

#ifdef __cplusplus
extern "C" {
#endif

void IPMSetTLSIdentity(sec_protocol_options_t options, SecIdentityRef identity);

#ifdef __cplusplus
}
#endif

#endif /* TLSIdentityHelper_h */