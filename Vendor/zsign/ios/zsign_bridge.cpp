#include "zsign_bridge.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
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

// 线程安全：Swift 侧签名任务在并发全局队列执行，多个任务可同时进入桥接层。
// 文件级 static std::string 是数据竞争（UB），改为 thread_local 使错误缓冲
// 每个线程独立，杜绝跨线程串扰与崩溃。
static thread_local std::string g_lastError;

const char* zsign_last_error(void) {
    return g_lastError.c_str();
}

int zsign_sign_impl(const ZSignOptions* options) {
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
            // PEM 私钥（Swift 侧 SecKey 导出路径产出 sign-key-*.pem）不能按 p12 诊断：
            // 拿 p12 解析器读 PEM 必然失败，会把"描述文件问题"误报成"证书/私钥问题"
            bool bPEMKey = false;
            {
                std::ifstream ifsKey(strPKeyFile, std::ios::binary);
                if (ifsKey) {
                    char szHead[16] = {0};
                    ifsKey.read(szHead, sizeof(szHead) - 1);
                    bPEMKey = (ifsKey.gcount() >= 10 && strncmp(szHead, "-----BEGIN", 10) == 0);
                }
            }
            if (bPEMKey) {
                strDiagnostics += "| 私钥为 PEM 格式（跳过 p12 解析诊断）";
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

    // bEnableCache=false：签名缓存 JSON 会写到进程 CWD 的 ./.zsign_cache（iOS 下
    // CWD 通常是只读的 /，静默失败无害；CWD 可写时会在沙箱根部累积文件）。
    // 本工程恒定 force=true，缓存读取本就永不生效，关闭写入只减益处。
    bool bRet = bundle.SignFolder(&zsa, strTempFolder,
        strBundleId, strBundleVersion, strBundleName,
        std::vector<std::string>(), std::vector<std::string>(),
        (options->force != 0), false, false, false);

    if (!bRet) {
        g_lastError = "Signing failed";
        ZFile::RemoveFolder(strTempFolder.c_str());
        return -1;
    }

    // 4. Repackage to IPA
    if (options->progressCallback) {
        options->progressCallback(options->context, 85, "正在重新打包...");
    }

    // 用路径组件匹配（避免裸 rfind 子串误判）：找目录组件 /Payload/ 的最后一个
    // 出现位置并以此为根目录边界。若 .app 目录名本身含 "Payload" 子串
    // （如 MyAppPayload.app），裸 rfind("Payload") 会命中名字内部，导致
    // strBaseFolder 截断错误、打包出结构损坏的 IPA；按组件匹配则不会。
    size_t pos = bundle.m_strAppFolder.rfind("/Payload/");
    if (std::string::npos == pos || pos == 0) {
        // 兼容 Payload 恰为末尾组件的异常形式（如 /tmp/x/Payload/）
        pos = bundle.m_strAppFolder.rfind("/Payload");
        if (std::string::npos == pos || pos == 0) {
            g_lastError = "Can't find payload directory";
            ZFile::RemoveFolder(strTempFolder.c_str());
            return -1;
        }
    }

    std::string strBaseFolder = bundle.m_strAppFolder.substr(0, pos);
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

int zsign_p12_info_impl(const char* p12Path, const char* password, ZSignP12Info* info) {
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

    // Load providers (best effort): 进程级一次性加载（default 必需、legacy 尽力
    // 而为且失败即清错误队列）。旧实现每次调用都 OSSL_PROVIDER_load 且从不
    // unload，provider 引用计数随导入次数持续累积。
    ZSignAsset::EnsurePKCS12ProvidersLoaded();
    ERR_clear_error();

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

// ---------------------------------------------------------------------------
// extern "C" 异常屏障：异常穿越 C ABI 属 UB（std::terminate）。签名输入是
// 不可信 IPA/p12，深解析路径上的 std::string/vector 分配失败（std::bad_alloc）
// 等异常不得逃逸出桥接层。
// ---------------------------------------------------------------------------

int zsign_sign(const ZSignOptions* options) {
    try {
        return zsign_sign_impl(options);
    } catch (const std::exception& e) {
        g_lastError = std::string("签名内部异常: ") + e.what();
        return -1;
    } catch (...) {
        g_lastError = "签名内部异常（未知 C++ 异常）";
        return -1;
    }
}

int zsign_p12_info(const char* p12Path, const char* password, ZSignP12Info* info) {
    try {
        return zsign_p12_info_impl(p12Path, password, info);
    } catch (const std::exception& e) {
        g_lastError = std::string("p12 解析内部异常: ") + e.what();
        return -1;
    } catch (...) {
        g_lastError = "p12 解析内部异常（未知 C++ 异常）";
        return -1;
    }
}
