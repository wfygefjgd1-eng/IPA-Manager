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
    const char* tempFolder;
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

// zsign_p12_export_identity / zsign_p12_recreate_legacy（TLS 身份路径）已删除：
// 本地安装服务器改明文 HTTP 后 Swift 侧无任何调用方（README v1.0.99），
// 保留约 420 行带手写 malloc/free 契约的代码纯属审计/攻击面。

const char* zsign_last_error(void);

#ifdef __cplusplus
}
#endif