#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*ZSignProgressCallback)(void* context, int percent, const char* message);

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
    void* context;
} ZSignOptions;

typedef struct {
    char name[256];
    char teamID[64];
    char commonName[256];
    char organization[256];
    long startTime;      // epoch seconds
    long endTime;        // epoch seconds
} ZSignP12Info;

int zsign_sign(const ZSignOptions* options);
int zsign_p12_info(const char* p12Path, const char* password, ZSignP12Info* info);
const char* zsign_last_error(void);

#ifdef __cplusplus
}
#endif