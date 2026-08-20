import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showImporter = false
    @State private var pendingImportURL: URL?
    @State private var managedPendingP12: URL?
    @State private var pendingExtractDir: URL?
    @State private var showPasswordSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            List {
                certificatesSection
                profilesSection
            }
            .scrollContentBackground(.hidden)
            // 毛玻璃背景：List 已透明化（scrollContentBackground(.hidden)），
            // 这里在导航容器外层铺渐变 + 半透明材质，列表内容透出玻璃质感
            .navigationTitle("证书管理")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Text("一键导入")
                    }

                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showImporter) {
                DocumentPicker { url in
                    handleImportedFile(url)
                }
            }
            .sheet(isPresented: $showPasswordSheet, onDismiss: {
                // 兜底清理：下滑手势关闭等未走 onImport/onCancel 的关闭路径，
                // 托管 P12 与解压目录若仍在，必须清理（明文私钥不得常驻 Documents）
                cleanupPendingCertImport()
            }) {
                PasswordPromptView(
                    importURL: pendingImportURL,
                    onImport: { cert in
                        appState.addCertificate(cert)
                        // 证书已导入 Keychain：删除 Documents 中的 P12 明文副本与解压目录，
                        // 避免私钥材料明文常驻（iTunes 文件共享/备份可导出）
                        cleanupPendingCertImport()
                    },
                    onCancel: {
                        // 用户取消密码输入：同样清理托管 P12 与解压目录，避免明文私钥常驻
                        cleanupPendingCertImport()
                    }
                )
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .overlay {
                if isImporting {
                    ProgressView("正在导入...")
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }
            }
        }
        // 毛玻璃背景：置于 NavigationView 外层，列表/空态/导航栏区域统一一个底色，
        // 列表已用 scrollContentBackground(.hidden) 透出其上的玻璃质感
        .background(GlassBackground().ignoresSafeArea())
    }

    private var certificatesSection: some View {
        Section("企业证书") {
            if appState.certificates.isEmpty {
                Text("暂无证书，点击右上角 + 导入 P12 或 zip 一键导入")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(appState.certificates) { certificate in
                    certificateRow(certificate)
                }
                .onDelete { indexSet in
                    // 快照待删证书再统一删除，避免循环内数组缩短导致删错/越界
                    let toDelete = indexSet.compactMap { index -> CertificateInfo? in
                        guard index < appState.certificates.count else { return nil }
                        return appState.certificates[index]
                    }
                    for certificate in toDelete {
                        appState.removeCertificate(certificate)
                    }
                }
            }
        }
    }

    private var profilesSection: some View {
        Section("描述文件") {
            if appState.profiles.isEmpty {
                Text("暂无描述文件，导入 zip 或单独导入 mobileprovision")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(appState.profiles) { profile in
                    profileRow(profile)
                }
                .onDelete { indexSet in
                    // 快照待删描述文件再统一删除，避免循环内数组缩短导致删错/越界
                    let toDelete = indexSet.compactMap { index -> ProvisioningInfo? in
                        guard index < appState.profiles.count else { return nil }
                        return appState.profiles[index]
                    }
                    for profile in toDelete {
                        appState.removeProfile(profile)
                    }
                }
            }
        }
    }

    private func certificateRow(_ certificate: CertificateInfo) -> some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundColor(certificate.status == .valid ? .green : .red)

            VStack(alignment: .leading, spacing: 4) {
                Text(certificate.name.isEmpty ? "未命名证书" : certificate.name)
                    .font(.headline)
                Text("Team ID: \(certificate.teamID.isEmpty ? "未知" : certificate.teamID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("到期: \(certificate.expireDateDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 默认选中态标记：与 SignOptionsView 的选中样式一致，让用户明确知道
            // 「一键签名」默认使用哪张证书
            if appState.selectedCertificate?.id == certificate.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }

            Text(certificate.statusDescription)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(certificate.status == .valid ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                .cornerRadius(6)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedCertificate = certificate
        }
    }

    private func profileRow(_ profile: ProvisioningInfo) -> some View {
        HStack {
            Image(systemName: "doc.badge.gearshape")
                .foregroundColor(profile.status == .valid ? .green : .red)

            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name.isEmpty ? "未命名描述文件" : profile.name)
                    .font(.headline)
                Text("Bundle ID: \(profile.bundleID.isEmpty ? "未知" : profile.bundleID)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("到期: \(profile.expireDateDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 默认选中态标记
            if appState.selectedProfile?.uuid == profile.uuid {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }

            Text(profile.statusDescription)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(profile.status == .valid ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                .cornerRadius(6)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            appState.selectedProfile = profile
        }
    }

    private func handleImportedFile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip":
            importBundle(url)
        case "p12", "pfx":
            pendingImportURL = url
            showPasswordSheet = true
        case "mobileprovision":
            importProfile(url)
        default:
            alertMessage = "不支持的文件类型: \(ext)"
            showAlert = true
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            handleImportedFile(url)
        case .failure(let error):
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    /// 清理当前待导入证书流程残留的敏感文件：托管 P12 明文副本（Certificates/cert-*.p12）
    /// 与解压目录（bundle-extract-*）。onImport 成功 / onCancel / 下滑关闭兜底共用，
    /// 内部幂等：状态已清空时不再重复清理。
    private func cleanupPendingCertImport() {
        let managed = managedPendingP12
        let extractDir = pendingExtractDir
        managedPendingP12 = nil
        pendingExtractDir = nil
        pendingImportURL = nil
        if let managed = managed {
            CertificateBundleImporter.shared.deleteManagedP12(managed)
        }
        if let extractDir = extractDir {
            CertificateBundleImporter.shared.cleanup(extractDir: extractDir)
        }
    }

    // 一键导入 zip（自动识别 p12 + mobileprovision）
    private func importBundle(_ url: URL) {
        isImporting = true
        var extractDir: URL? = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try CertificateBundleImporter.shared.extract(from: url)
                // 记录解压目录：无论成功失败都要删除，避免 bundle-extract-* 明文泄漏堆积
                extractDir = content.p12URL?.deletingLastPathComponent()
                let moved = try CertificateBundleImporter.shared.moveToManagedLocation(
                    p12URL: content.p12URL,
                    profileURL: content.profileURL
                )
                // 证书导入 Keychain 成功后删除 Documents 中的 P12 明文副本
                let managedP12 = moved.p12URL

                DispatchQueue.main.async {
                    isImporting = false
                    var summary = ""

                    // 导入描述文件
                    if let profileURL = moved.profileURL {
                        do {
                            // importProfile 内部归档到 Documents/Profiles（目标本就在该目录时直接复用），
                            // 返回的 path 稳定，无需再覆盖
                            let profile = try ProvisioningManager.shared.importProfile(from: profileURL)
                            // 按 uuid 去重/更新：同名记录已存在时不重复添加，原地把 path
                            // 更新为最新稳定路径（修复旧 Bundle 内失效路径），保持记录 id 不变
                            if let index = appState.profiles.firstIndex(where: { $0.uuid == profile.uuid }) {
                                appState.profiles[index].path = profile.path
                                if appState.selectedProfile?.uuid == profile.uuid {
                                    appState.selectedProfile?.path = profile.path
                                }
                                appState.saveState()
                            } else {
                                appState.addProfile(profile)
                            }
                            summary += "描述文件 ✓\n"
                        } catch {
                            summary += "描述文件失败: \(error.localizedDescription)\n"
                        }
                    } else {
                        summary += "未找到描述文件\n"
                    }

                    // 导入证书（需要密码）—— 只弹密码框，避免与 alert 冲突
                    if let p12URL = moved.p12URL {
                        pendingImportURL = p12URL
                        managedPendingP12 = managedP12
                        pendingExtractDir = extractDir
                        showPasswordSheet = true
                    } else {
                        // 无证书：解压目录与托管副本都不需要保留
                        if let extractDir = extractDir {
                            CertificateBundleImporter.shared.cleanup(extractDir: extractDir)
                        }
                        alertMessage = summary + "未找到证书"
                        showAlert = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isImporting = false
                    // 解压/移动失败：清理解压残留
                    if let extractDir = extractDir {
                        CertificateBundleImporter.shared.cleanup(extractDir: extractDir)
                    }
                    alertMessage = "导入失败: \(error.localizedDescription)"
                    showAlert = true
                }
            }
        }
    }

    private func importProfile(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = AppFileManager.shared.directoryURL(.profiles)
            .appendingPathComponent(url.lastPathComponent)

        do {
            try AppFileManager.shared.copyItem(from: url, to: destination)
            // importProfile 检测到源已在 Documents/Profiles 内，会直接复用该路径，无需再覆盖
            let profile = try ProvisioningManager.shared.importProfile(from: destination)
            // 按 uuid 去重/更新：同一描述文件重复导入不重复添加，原地把 path 更新为最新稳定路径
            // （修复旧 Bundle 内失效路径）；保持记录 id 不变，避免破坏 selectedProfile 等引用
            if let index = appState.profiles.firstIndex(where: { $0.uuid == profile.uuid }) {
                appState.profiles[index].path = profile.path
                if appState.selectedProfile?.uuid == profile.uuid {
                    appState.selectedProfile?.path = profile.path
                }
                appState.saveState()
                Logger.info("描述文件已存在，更新路径: \(profile.path)")
                alertMessage = "描述文件已存在: \(profile.name)"
            } else {
                appState.addProfile(profile)
                alertMessage = "描述文件导入成功: \(profile.name)"
            }
        } catch {
            alertMessage = error.localizedDescription
        }
        showAlert = true
    }
}