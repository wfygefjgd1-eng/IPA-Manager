#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ZSignProgressCallback)(int percent, const char* message);

typedef struct {
    const char* inputIpaPath;
    const char* outputIpaPath;
    const char* certPath;
    const char* pkeyPath;
    const char* provisionPath;
    const char* entitlementsPath;
    const char* password;
    const char* bundleId;
    const char* bundleName;
    const char* bundleVersion;
    int zipLevel;
    int force;
    int enableDocuments;
    ZSignProgressCallback progressCallback;
} ZSignOptions;

int zsign_sign(const ZSignOptions* options);
const char* zsign_last_error(void);

#ifdef __cplusplus
}
#endif
