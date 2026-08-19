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

// 从 p12 导出证书与私钥的 DER（不加密，证书用 i2d_X509、私钥优先 PKCS#8、失败回退 PKCS#1/SEC1），
// 供 iOS Security framework 在 SecPKCS12Import 无法解析 OpenSSL 3 新式 p12 时构造 TLS 身份。
// 返回 0 成功；-1 文件/解析失败；-2 密码错误。成功时通过 out 输出 DER 字节（调用方负责 free()）。
// outIsRSA：1=RSA, 0=EC。outKeyFormat：1=PKCS#8（首选路径），2=PKCS#1/SEC1（i2d_PrivateKey 回退）。
int zsign_p12_export_identity(const char* p12Path, const char* password,
                              unsigned char** outCertDER, int* outCertLen,
                              unsigned char** outKeyDER,  int* outKeyLen,
                              int* outIsRSA, int* outKeyFormat);

const char* zsign_last_error(void);

#ifdef __cplusplus
}
#endif