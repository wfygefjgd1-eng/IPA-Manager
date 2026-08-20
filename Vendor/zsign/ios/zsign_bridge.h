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
// outKeyBits：RSA 私钥的实际位数（EVP_PKEY_bits），供 Swift 侧按真实位数构造 SecKey，
//             避免对 4096/1024 位证书硬编码 2048 导致 SecKeyCreateWithData 失败。
int zsign_p12_export_identity(const char* p12Path, const char* password,
                              unsigned char** outCertDER, int* outCertLen,
                              unsigned char** outKeyDER,  int* outKeyLen,
                              int* outIsRSA, int* outKeyFormat, int* outKeyBits);

// 把 p12 中的证书+私钥重新打包成"传统加密"的 p12（PBE-SHA1-3DES/RC2-40），
// 供 iOS SecPKCS12Import 直接导入。成功返回 0，失败返回 -1（g_lastError 有详情）。
// outLegacyPath 由调用方提供缓冲区（PATH_MAX），须先填入目标文件路径；
// 内部按 outPathLen 用 snprintf 确保不越界；不分配长生命周期内存。
int zsign_p12_recreate_legacy(const char* p12Path, const char* password, char* outLegacyPath, int outPathLen);

const char* zsign_last_error(void);

#ifdef __cplusplus
}
#endif