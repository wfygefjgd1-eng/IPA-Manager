#include "zsign_bridge.h"

#include <cstring>
#include <string>
#include <vector>

#include <openssl/pem.h>
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

    const char* szTempFolder = ZFile::GetTempFolder();
    if (szTempFolder == NULL || !ZFile::IsFolder(szTempFolder)) {
        g_lastError = "Invalid temp folder";
        return -1;
    }

    ZTimer timer;

    // 1. Initialize signing asset (P12 + provisioning profile)
    ZSignAsset zsa;
    if (!zsa.Init(strCertFile, strPKeyFile, strProvFile, strEntitleFile, strPassword, false, true, false)) {
        g_lastError = "Failed to initialize signing asset. Check certificate or profile.";
        return -1;
    }

    // 2. Extract IPA to temp folder
    bool bZipFile = ZFile::IsZipFile(strInputPath.c_str());
    if (!bZipFile) {
        g_lastError = "Input file is not a valid IPA/ZIP archive";
        return -1;
    }

    std::string strTempFolder = ZFile::GetRealPathV("%s/zsign_folder_%llu",
        szTempFolder, ZUtil::GetMicroSecond());

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
    if (!Zip::Archive(strBaseFolder.c_str(), strOutputPath.c_str(), (uint32_t)(options->zipLevel >= 0 ? options->zipLevel : -1))) {
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
        g_lastError = "Invalid p12 file";
        ERR_clear_error();
        return -1;
    }

    EVP_PKEY* pkey = NULL;
    X509* cert = NULL;
    STACK_OF(X509)* ca = NULL;
    const char* pwd = password ? password : "";
    if (PKCS12_parse(p12, pwd, &pkey, &cert, &ca) != 1) {
        g_lastError = "Wrong password or unsupported p12 format";
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