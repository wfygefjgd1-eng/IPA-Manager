#include "zsign_bridge.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <openssl/pem.h>
#include <openssl/objects.h>
#include <openssl/obj_mac.h>
#include <openssl/pkcs12.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/err.h>
#include <openssl/provider.h>

#include "common.h"
#include "openssl.h"
#include "bundle.h"
#include "archive.h"
#include "timer.h"
#include "fs.h"
#include "util.h"

static std::string g_lastError;

const char* zsign_last_error(void) {
    return g_lastError.c_str();
}

int zsign_sign(const ZSignOptions* options) {
    if (!options) {
        g_lastError = "Invalid options";
        return -1;
    }

    std::string strInputPath = options->inputIpaPath ? options->inputIpaPath : "";
    std::string strOutputPath = options->outputIpaPath ? options->outputIpaPath : "";
    std::string strCertFile = options->certPath ? options->certPath : "";
    std::string strPKeyFile = options->pkeyPath ? options->pkeyPath : "";
    std::string strProvFile = options->provisionPath ? options->provisionPath : "";
    std::string strEntitleFile = options->entitlementsPath ? options->entitlementsPath : "";
    std::string strPassword = options->password ? options->password : "";
    std::string strBundleId = options->bundleId ? options->bundleId : "";
    std::string strBundleName = options->bundleName ? options->bundleName : "";
    std::string strBundleVersion = options->bundleVersion ? options->bundleVersion : "";

    if (strInputPath.empty() || strOutputPath.empty()) {
        g_lastError = "Input and output paths are required";
        return -1;
    }

    if (!ZFile::IsFileExists(strInputPath.c_str())) {
        g_lastError = "Input file not found: " + strInputPath;
        return -1;
    }

    // 优先使用调用方传入的临时目录（iOS 沙箱内 NSTemporaryDirectory 保证可写）；
    // 未传入时回退到 ZFile::GetTempFolder()。
    std::string strTempRoot;
    if (options->tempFolder && options->tempFolder[0] != '\0') {
        strTempRoot = options->tempFolder;
    } else {
        const char* szTempFolder = ZFile::GetTempFolder();
        if (szTempFolder != NULL) {
            strTempRoot = szTempFolder;
        }
    }
    if (strTempRoot.empty() || !ZFile::IsFolder(strTempRoot.c_str())) {
        g_lastError = "Invalid temp folder";
        return -1;
    }

    ZTimer timer;

    // 1. Initialize signing asset (P12 + provisioning profile)
    ZSignAsset zsa;
    if (!zsa.Init(strCertFile, strPKeyFile, strProvFile, strEntitleFile, strPassword, false, true, false)) {
        // Init 失败后逐项排查具体原因：仅依赖 ZSignAsset 的 public 成员/静态方法，
        // 以及 ZFile::IsFileExists 与 zsign_p12_info，全部为空值安全（不崩溃）。
        std::string strDiagnostics;
        std::string strProvContent;

        if (zsa.m_strProvData.empty()) {
            strDiagnostics += "| 描述文件读取失败（文件不存在或无法读取）";
        } else if (!ZSignAsset::GetCMSContent(zsa.m_strProvData, strProvContent)) {
            strDiagnostics += "| 描述文件 CMS 解析失败";
        } else if (zsa.m_strTeamId.empty()) {
            strDiagnostics += "| 描述文件缺少 TeamIdentifier";
        }

        if (!ZFile::IsFileExists(strPKeyFile.c_str())) {
            strDiagnostics += "| 私钥文件不存在";
        } else {
            // zsign_p12_info 成功时会清空 g_lastError，故调用前先暂存、调用后取回；
            // 其失败返回 -1（格式/打开失败）或 -2（密码/格式错误）前会写入具体原因。
            std::string strSavedError = g_lastError;
            ZSignP12Info p12Info;
            int nP12Ret = zsign_p12_info(strPKeyFile.c_str(), strPassword.c_str(), &p12Info);
            std::string strP12Reason = g_lastError;
            g_lastError = strSavedError;

            if (nP12Ret != 0) {
                std::string strDetail = strP12Reason;
                if (strDetail.empty()) {
                    strDetail = (nP12Ret == -2) ? "密码错误或格式不支持" : "证书/私钥文件无效";
                }
                strDiagnostics += "| 证书/私钥加载失败：" + strDetail;
            } else {
                strDiagnostics += "| 证书与私钥可正常解析";
            }
        }

        g_lastError = "签名初始化失败：证书或描述文件无效" + strDiagnostics;
        return -1;
    }

    // 2. Extract IPA to temp folder
    bool bZipFile = ZFile::IsZipFile(strInputPath.c_str());
    if (!bZipFile) {
        g_lastError = "Input file is not a valid IPA/ZIP archive";
        return -1;
    }

    std::string strTempFolder = ZFile::GetRealPathV("%s/zsign_folder_%llu",
        strTempRoot.c_str(), ZUtil::GetMicroSecond());

    if (options->progressCallback) {
        options->progressCallback(options->context, 5, "正在解压 IPA...");
    }

    if (!Zip::Extract(strInputPath.c_str(), strTempFolder.c_str())) {
        g_lastError = "Failed to extract IPA";
        ZFile::RemoveFolder(strTempFolder.c_str());
        return -1;
    }

    // 3. Sign the app bundle folder
    if (options->progressCallback) {
        options->progressCallback(options->context, 20, "正在签名主程序...");
    }

    ZBundle bundle;
    bundle.m_bEnableDocuments = (options->enableDocuments != 0);

    bool bRet = bundle.SignFolder(&zsa, strTempFolder,
        strBundleId, strBundleVersion, strBundleName,
        std::vector<std::string>(), std::vector<std::string>(),
        (options->force != 0), false, true, false);

    if (!bRet) {
        g_lastError = "Signing failed";
        ZFile::RemoveFolder(strTempFolder.c_str());
        return -1;
    }

    // 4. Repackage to IPA
    if (options->progressCallback) {
        options->progressCallback(options->context, 85, "正在重新打包...");
    }

    size_t pos = bundle.m_strAppFolder.rfind("Payload");
    if (std::string::npos == pos || pos == 0) {
        g_lastError = "Can't find payload directory";
        ZFile::RemoveFolder(strTempFolder.c_str());
        return -1;
    }

    std::string strBaseFolder = bundle.m_strAppFolder.substr(0, pos - 1);
    // zipLevel 直接传 int（0-9 为合法压缩级别；-1 由 Zip::Archive 解释为默认级别）
    int nZipLevel = options->zipLevel;
    if (nZipLevel < -1 || nZipLevel > 9) {
        nZipLevel = 6;
    }
    if (!Zip::Archive(strBaseFolder.c_str(), strOutputPath.c_str(), nZipLevel)) {
        g_lastError = "Failed to archive signed IPA";
        ZFile::RemoveFolder(strTempFolder.c_str());
        return -1;
    }

    // 5. Cleanup
    ZFile::RemoveFolder(strTempFolder.c_str());

    if (options->progressCallback) {
        options->progressCallback(options->context, 100, "签名完成");
    }

    return 0;
}

static long ASN1TimeToEpoch(const ASN1_TIME* time) {
    if (time == NULL) return 0;
    struct tm t;
    memset(&t, 0, sizeof(t));
    if (ASN1_TIME_to_tm(time, &t) != 1) return 0;
#if defined(_WIN32)
    return (long)_mkgmtime(&t);
#else
    return (long)timegm(&t);
#endif
}

static void CopyField(char* dst, size_t dstSize, const char* src) {
    if (!dst || dstSize == 0) return;
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    strncpy(dst, src, dstSize - 1);
    dst[dstSize - 1] = '\0';
}

static std::string GetOpenSSLErrors(const char* prefix) {
    std::string result = prefix ? prefix : "";
    unsigned long err = 0;
    char buf[256] = {0};
    while ((err = ERR_get_error()) != 0) {
        ERR_error_string_n(err, buf, sizeof(buf));
        result += " | ";
        result += buf;
    }
    return result;
}

int zsign_p12_info(const char* p12Path, const char* password, ZSignP12Info* info) {
    if (!p12Path || !info) {
        g_lastError = "Invalid p12 info arguments";
        return -1;
    }

    memset(info, 0, sizeof(ZSignP12Info));

    BIO* bio = BIO_new_file(p12Path, "rb");
    if (!bio) {
        g_lastError = "Cannot open p12 file";
        return -1;
    }

    // Load legacy provider for older p12 encryption schemes
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");

    PKCS12* p12 = d2i_PKCS12_bio(bio, NULL);
    BIO_free(bio);
    if (!p12) {
        g_lastError = GetOpenSSLErrors("Invalid p12 file");
        ERR_clear_error();
        return -1;
    }

    EVP_PKEY* pkey = NULL;
    X509* cert = NULL;
    STACK_OF(X509)* ca = NULL;
    const char* pwd = password ? password : "";
    if (PKCS12_parse(p12, pwd, &pkey, &cert, &ca) != 1) {
        g_lastError = GetOpenSSLErrors("Wrong password or unsupported p12 format");
        PKCS12_free(p12);
        ERR_clear_error();
        return -2; // distinct: password/format error
    }
    PKCS12_free(p12);

    if (cert == NULL) {
        g_lastError = "No certificate found in p12";
        if (pkey) EVP_PKEY_free(pkey);
        if (ca) sk_X509_pop_free(ca, X509_free);
        return -1;
    }

    // Subject fields: CN, OU (TeamID), O (Organization)
    X509_NAME* name = X509_get_subject_name(cert);
    if (name) {
        char buf[512] = {0};
        if (X509_NAME_get_text_by_NID(name, NID_commonName, buf, sizeof(buf)) > 0) {
            CopyField(info->commonName, sizeof(info->commonName), buf);
        }
        memset(buf, 0, sizeof(buf));
        if (X509_NAME_get_text_by_NID(name, NID_organizationalUnitName, buf, sizeof(buf)) > 0) {
            CopyField(info->teamID, sizeof(info->teamID), buf);
        }
        memset(buf, 0, sizeof(buf));
        if (X509_NAME_get_text_by_NID(name, NID_organizationName, buf, sizeof(buf)) > 0) {
            CopyField(info->organization, sizeof(info->organization), buf);
        }
    }

    // Validity
    info->startTime = ASN1TimeToEpoch(X509_get0_notBefore(cert));
    info->endTime = ASN1TimeToEpoch(X509_get0_notAfter(cert));

    // Build display name: "CN (TEAMID)" if possible
    std::string display;
    if (info->commonName[0] != '\0') {
        display = info->commonName;
        if (info->teamID[0] != '\0') {
            display += " (";
            display += info->teamID;
            display += ")";
        }
    } else if (info->organization[0] != '\0') {
        display = info->organization;
    } else {
        display = "P12 证书";
    }
    CopyField(info->name, sizeof(info->name), display.c_str());

    if (pkey) EVP_PKEY_free(pkey);
    if (ca) sk_X509_pop_free(ca, X509_free);
    X509_free(cert);

    g_lastError.clear();
    return 0;
}

int zsign_p12_export_identity(const char* p12Path, const char* password,
                              unsigned char** outCertDER, int* outCertLen,
                              unsigned char** outKeyDER,  int* outKeyLen,
                              int* outIsRSA, int* outKeyFormat) {
    if (!p12Path || !outCertDER || !outCertLen || !outKeyDER || !outKeyLen || !outIsRSA || !outKeyFormat) {
        g_lastError = "无效的 p12 导出参数";
        return -1;
    }

    *outCertDER = NULL;
    *outCertLen = 0;
    *outKeyDER = NULL;
    *outKeyLen = 0;
    *outIsRSA = 0;
    *outKeyFormat = 0;

    BIO* bio = BIO_new_file(p12Path, "rb");
    if (!bio) {
        g_lastError = "无法打开 p12 文件";
        return -1;
    }

    // 与 zsign_p12_info 一致：加载 legacy + default provider，
    // 兼容新版 PBES2/AES 与旧版加密算法的 p12。
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");

    PKCS12* p12 = d2i_PKCS12_bio(bio, NULL);
    BIO_free(bio);
    if (!p12) {
        g_lastError = GetOpenSSLErrors("无效的 p12 文件");
        ERR_clear_error();
        return -1;
    }

    EVP_PKEY* pkey = NULL;
    X509* cert = NULL;
    STACK_OF(X509)* ca = NULL;
    const char* pwd = password ? password : "";
    if (PKCS12_parse(p12, pwd, &pkey, &cert, &ca) != 1) {
        g_lastError = GetOpenSSLErrors("密码错误或 p12 格式不受支持");
        PKCS12_free(p12);
        ERR_clear_error();
        return -2; // distinct: password/format error
    }
    PKCS12_free(p12);

    if (cert == NULL || pkey == NULL) {
        g_lastError = (cert == NULL) ? "p12 中未找到证书" : "p12 中未找到私钥";
        if (pkey) EVP_PKEY_free(pkey);
        if (cert) X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        ERR_clear_error();
        return -1;
    }

    int isRSA = (EVP_PKEY_base_id(pkey) == EVP_PKEY_RSA) ? 1 : 0;

    // 证书 DER（i2d_X509：先取长度，再写入并推进指针）
    int nCertLen = i2d_X509(cert, NULL);
    if (nCertLen <= 0) {
        g_lastError = "证书 DER 编码失败";
        EVP_PKEY_free(pkey);
        X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        ERR_clear_error();
        return -1;
    }
    unsigned char* certDER = (unsigned char*)malloc((size_t)nCertLen);
    if (!certDER) {
        g_lastError = "内存分配失败";
        EVP_PKEY_free(pkey);
        X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        return -1;
    }
    {
        unsigned char* pCert = certDER;
        if (i2d_X509(cert, &pCert) <= 0) {
            free(certDER);
            g_lastError = "证书 DER 编码失败";
            EVP_PKEY_free(pkey);
            X509_free(cert);
            if (ca) sk_X509_pop_free(ca, X509_free);
            ERR_clear_error();
            return -1;
        }
    }

    // 私钥 DER：优先 PKCS#8（SecKeyCreateWithData 最稳）；不可用或失败时回退 i2d_PrivateKey（RSA 输出 PKCS#1，EC 输出 SEC1）。
    // 注意：PKCS#8 路径受 OPENSSL_NO_DEPRECATED 系列宏保护（本工程构建未启用 no-deprecated，条件成立 → 走 PKCS#8）；
    // 为保证只读诊断也能区分实际导出格式，nKeyFormat 会随成功结果输出（1=PKCS#8, 2=PKCS#1/SEC1）。
    unsigned char* keyDER = NULL;
    int nKeyLen = 0;
    int nKeyFormat = 0;
#if !defined(OPENSSL_NO_DEPRECATED) && !defined(OPENSSL_NO_DEPRECATED_3_0)
    {
        PKCS8_PRIV_KEY_INFO* p8info = EVP_PKEY2PKCS8(pkey);
        if (p8info != NULL) {
            int nP8Len = i2d_PKCS8_PRIV_KEY_INFO(p8info, NULL);
            if (nP8Len > 0) {
                unsigned char* buf = (unsigned char*)malloc((size_t)nP8Len);
                if (buf != NULL) {
                    unsigned char* pKey = buf;
                    if (i2d_PKCS8_PRIV_KEY_INFO(p8info, &pKey) > 0) {
                        keyDER = buf;
                        nKeyLen = nP8Len;
                        nKeyFormat = 1; // PKCS#8
                    } else {
                        free(buf);
                    }
                }
            }
            PKCS8_PRIV_KEY_INFO_free(p8info);
        }
    }
#endif
    if (keyDER == NULL) {
        int nP1Len = i2d_PrivateKey(pkey, NULL);
        if (nP1Len <= 0) {
            free(certDER);
            g_lastError = "私钥 DER 编码失败";
            EVP_PKEY_free(pkey);
            X509_free(cert);
            if (ca) sk_X509_pop_free(ca, X509_free);
            ERR_clear_error();
            return -1;
        }
        unsigned char* buf = (unsigned char*)malloc((size_t)nP1Len);
        if (!buf) {
            free(certDER);
            g_lastError = "内存分配失败";
            EVP_PKEY_free(pkey);
            X509_free(cert);
            if (ca) sk_X509_pop_free(ca, X509_free);
            return -1;
        }
        unsigned char* pKey = buf;
        if (i2d_PrivateKey(pkey, &pKey) <= 0) {
            free(buf);
            free(certDER);
            g_lastError = "私钥 DER 编码失败";
            EVP_PKEY_free(pkey);
            X509_free(cert);
            if (ca) sk_X509_pop_free(ca, X509_free);
            ERR_clear_error();
            return -1;
        }
        keyDER = buf;
        nKeyLen = nP1Len;
        nKeyFormat = 2; // PKCS#1/SEC1 回退
    }

    *outCertDER = certDER;
    *outCertLen = nCertLen;
    *outKeyDER = keyDER;
    *outKeyLen = nKeyLen;
    *outIsRSA = isRSA;
    *outKeyFormat = nKeyFormat;

    EVP_PKEY_free(pkey);
    X509_free(cert);
    if (ca) sk_X509_pop_free(ca, X509_free);
    ERR_clear_error();
    g_lastError.clear();
    return 0;
}

int zsign_p12_recreate_legacy(const char* p12Path, const char* password,
                              char* outLegacyPath, int outPathLen) {
    if (!p12Path || !outLegacyPath || outPathLen <= 0) {
        g_lastError = "无效的传统 p12 重打包参数";
        return -1;
    }

    // 调用方已在 outLegacyPath 中填入目标文件路径；按 outPathLen 用 snprintf 防御性回写，
    // 保证缓冲区内路径以 \0 结尾且不越界（从本地副本写入，避免 snprintf 重叠拷贝的 UB）。
    std::string strPath = outLegacyPath;
    snprintf(outLegacyPath, (size_t)outPathLen, "%s", strPath.c_str());
    if (strPath.empty()) {
        g_lastError = "输出路径为空";
        return -1;
    }

    BIO* bio = BIO_new_file(p12Path, "rb");
    if (!bio) {
        g_lastError = "无法打开 p12 文件";
        return -1;
    }

    // 与 zsign_p12_info / zsign_p12_export_identity 一致：加载 legacy + default provider。
    // 解析旧式加密的输入 p12 需要 legacy；重打包用的 RC2-40-CBC 也只由 legacy provider 提供。
    OSSL_PROVIDER_load(NULL, "legacy");
    OSSL_PROVIDER_load(NULL, "default");

    PKCS12* p12 = d2i_PKCS12_bio(bio, NULL);
    BIO_free(bio);
    if (!p12) {
        g_lastError = GetOpenSSLErrors("无效的 p12 文件");
        ERR_clear_error();
        return -1;
    }

    EVP_PKEY* pkey = NULL;
    X509* cert = NULL;
    STACK_OF(X509)* ca = NULL;
    const char* pwd = password ? password : "";
    if (PKCS12_parse(p12, pwd, &pkey, &cert, &ca) != 1) {
        g_lastError = GetOpenSSLErrors("密码错误或 p12 格式不受支持");
        PKCS12_free(p12);
        ERR_clear_error();
        return -2; // distinct: password/format error
    }
    PKCS12_free(p12);

    if (cert == NULL || pkey == NULL) {
        g_lastError = (cert == NULL) ? "p12 中未找到证书" : "p12 中未找到私钥";
        if (pkey) EVP_PKEY_free(pkey);
        if (cert) X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        ERR_clear_error();
        return -1;
    }

    // 重打包为"传统加密" p12：私钥用 PBE-SHA1-3DES、证书用 PBE-SHA1-40bit-RC2，
    // 这是 iOS SecPKCS12Import（CDSA 解码器）原生支持的格式——OpenSSL 3 默认的
    // PBES2/PBKDF2+AES 新式加密 iOS 无法导入，而传统 PBE 一定可以。
    // iter/mac_iter 用 2048：满足 iOS 对 MAC 迭代次数的要求（太低会被拒），也不会太慢。
    // NID 用 OBJ_txt2nid 运行时查询（不依赖 obj_mac.h 的宏，跨构建环境最稳），
    // 查询失败时回退到 objects.txt 里的固定数值：PBE-SHA1-3DES=36、PBE-SHA1-RC2-40=39。
    int nidKey = OBJ_txt2nid("PBE-SHA1-3DES");
    int nidCert = OBJ_txt2nid("PBE-SHA1-RC2-40");
    if (nidKey == NID_undef) { nidKey = 36; }
    if (nidCert == NID_undef) { nidCert = 39; }
    PKCS12* legacy = PKCS12_create("IPA Manager Server Identity", "IPA Manager Server Identity",
                                   pkey, cert, ca,
                                   nidKey, nidCert,
                                   2048, 2048, 0);
    if (!legacy) {
        g_lastError = GetOpenSSLErrors("传统 p12 重打包失败（PKCS12_create）");
        EVP_PKEY_free(pkey);
        X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        ERR_clear_error();
        return -1;
    }

    // 写出 DER（i2d_PKCS12_bio 返回编码字节数，>0 即输出非空；MAC 校验交给 SecPKCS12Import）
    BIO* out = BIO_new_file(strPath.c_str(), "wb");
    if (!out) {
        g_lastError = "无法创建输出 p12 文件：" + strPath;
        PKCS12_free(legacy);
        EVP_PKEY_free(pkey);
        X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        ERR_clear_error();
        return -1;
    }
    if (i2d_PKCS12_bio(out, legacy) <= 0) {
        BIO_free(out);
        g_lastError = GetOpenSSLErrors("传统 p12 DER 写出失败");
        PKCS12_free(legacy);
        EVP_PKEY_free(pkey);
        X509_free(cert);
        if (ca) sk_X509_pop_free(ca, X509_free);
        ERR_clear_error();
        return -1;
    }
    BIO_free(out);

    PKCS12_free(legacy);
    EVP_PKEY_free(pkey);
    X509_free(cert);
    if (ca) sk_X509_pop_free(ca, X509_free);
    ERR_clear_error();
    g_lastError.clear();
    return 0;
}