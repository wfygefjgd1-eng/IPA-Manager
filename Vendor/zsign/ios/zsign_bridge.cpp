#include "zsign_bridge.h"

#include <cstring>
#include <string>
#include <vector>

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

    if (!ZFile::IsFolder(ZFile::GetTempFolder().c_str())) {
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
        ZFile::GetTempFolder().c_str(), ZUtil::GetMicroSecond());

    if (options->progressCallback) {
        options->progressCallback(options->context, , "正在解压 IPA...");
    }

    if (!Zip::Extract(strInputPath.c_str(), strTempFolder.c_str())) {
        g_lastError = "Failed to extract IPA";
        ZFile::RemoveFolder(strTempFolder.c_str());
        return -1;
    }

    // 3. Sign the app bundle folder
    if (options->progressCallback) {
        options->progressCallback(options->context, , "正在签名主程序...");
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
        options->progressCallback(options->context, , "正在重新打包...");
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
        options->progressCallback(options->context, , "签名完成");
    }

    return 0;
}