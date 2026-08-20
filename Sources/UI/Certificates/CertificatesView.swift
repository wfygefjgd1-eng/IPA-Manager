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
    /// 一键卸载全部证书的确认弹窗
    @State private var showUninstallAllAlert = false

    var body: some View {
        NavigationView {
            List {
                certificatesSection
                profilesSection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("证书管理")
            .toolbar {
                // 左上角：一键卸载证书（删除语义明确，配合右滑单删全部具备）
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showUninstallAllAlert = true
                    } label: {
                        Label("卸载证书", systemImage: "trash")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(appState.certificates.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // 一键导入：支持 zip（含 p12 + mobileprovision）/ 单独 p12 / mobileprovision；
                    // 原先的“+”与一键导入完全相同（打开同一个文件选择器），已合并为一个按钮
                    Button {
                        showImporter = true
                    } label: {
                        Label("一键导入", systemImage: "square.and.arrow.down")
                            .font(.subheadline.weight(.medium))
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
            // 卸载全部证书：确认后逐个走 removeCertificate（同步清理 Keychain 私钥/密码条目），
            // 右滑单删功能不受影响
            .alert("一键卸载全部证书？", isPresented: $showUninstallAllAlert) {
                Button("卸载", role: .destructive) {
                    let all = appState.certificates
                    for certificate in all {
                        appState.removeCertificate(certificate)
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("将卸载全部 \(appState.certificates.count) 张证书及对应 Keychain 私钥，此操作不可撤销。")
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
        Section {
            if appState.certificates.isEmpty {
                emptyCard(
                    icon: "key.fill",
                    title: "暂无企业证书",
                    subtitle: "点击右上角「一键导入」\n支持 P12 / PFX 或 zip 一键导入"
                )
            } else {
                ForEach(appState.certificates) { certificate in
                    certificateRow(certificate)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
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
        } header: {
            sectionHeader(icon: "key.fill", title: "企业证书")
        }
    }

    private var profilesSection: some View {
        Section {
            if appState.profiles.isEmpty {
                emptyCard(
                    icon: "doc.badge.gearshape",
                    title: "暂无描述文件",
                    subtitle: "点击右上角「一键导入」\n支持 zip 或单独 mobileprovision"
                )
            } else {
                ForEach(appState.profiles) { profile in
                    profileRow(profile)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
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
        } header: {
            sectionHeader(icon: "doc.badge.gearshape", title: "描述文件")
        }
    }

    /// Section 标题：左侧小图标 + 文字，与卡片化布局呼应，不再光秃秃一行字
    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .textCase(nil)
        .padding(.vertical, 2)
    }

    /// 空态卡片：虚线圆角框，图标 + 主标题 + 引导文字，比单行灰字完整
    private func emptyCard(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundColor(.secondary.opacity(0.7))
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.8)
        )
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// 卡片通用容器：半透明圆角底 + 细描边，与已签应用/下载页一致
    private func cardContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }

    private func certificateRow(_ certificate: CertificateInfo) -> some View {
        cardContainer {
            HStack(spacing: 12) {
                // 图标底：有效/过期不同浅色，一眼看到状态
                Image(systemName: "key.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(certificate.status == .valid ? .green : (certificate.status == .expired ? .red : .secondary))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill((certificate.status == .valid ? Color.green : (certificate.status == .expired ? Color.red : Color.secondary)).opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(certificate.name.isEmpty ? "未命名证书" : certificate.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        // 「默认」徽章：自动签名默认使用的证书，
                        // 用安静的胶囊徽章而非可点的勾选圈，突出“展示、不可操作”
                        if appState.selectedCertificate?.id == certificate.id {
                            Text("默认")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }

                    if !certificate.organization.isEmpty || !certificate.commonName.isEmpty {
                        Label(
                            certificate.organization.isEmpty ? certificate.commonName : certificate.organization,
                            systemImage: "building.2"
                        )
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    }

                    Label("Team ID：\(certificate.teamID.isEmpty ? "未知" : certificate.teamID)", systemImage: "number")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        Label(dateSpanText(certificate.startDate, certificate.expireDate), systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        statusChip(certificate.statusDescription, isGood: certificate.status != .expired, expired: certificate.status == .expired)
                    }
                }

                Spacer(minLength: 4)
            }
        }
        // 纯展示卡片：不设点击手势，证书页供查看，不承担默认选择等交互
    }

    private func profileRow(_ profile: ProvisioningInfo) -> some View {
        cardContainer {
            HStack(spacing: 12) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(profile.status == .valid ? .blue : (profile.status == .expired ? .red : .secondary))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill((profile.status == .valid ? Color.blue : (profile.status == .expired ? Color.red : Color.secondary)).opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(profile.name.isEmpty ? "未命名描述文件" : profile.name)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        // 「默认」徽章：自动签名默认使用的描述文件
                        if appState.selectedProfile?.uuid == profile.uuid {
                            Text("默认")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }

                    Label("Bundle ID：\(profile.bundleID.isEmpty ? "未知" : profile.bundleID)", systemImage: "app.badge")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    if !profile.teamID.isEmpty {
                        Label("Team ID：\(profile.teamID)", systemImage: "number")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Label(deviceScopeText(profile), systemImage: "iphone")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        Label(dateSpanText(profile.createdAt, profile.expireDate), systemImage: "calendar")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        statusChip(profile.statusDescription, isGood: profile.status != .expired, expired: profile.status == .expired)
                    }
                }

                Spacer(minLength: 4)
            }
        }
        // 纯展示卡片：不设点击手势，证书页供查看，不承担默认选择等交互
    }

    /// 有效期范围文案："yyyy-MM-dd ~ yyyy-MM-dd"，缺失端显示"未知"
    private func dateSpanText(_ start: Date?, _ end: Date?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let startText = start.map { f.string(from: $0) } ?? "未知"
        let endText = end.map { f.string(from: $0) } ?? "未知"
        return "\(startText) ~ \(endText)"
    }

    /// 描述文件的设备范围：非空为限定设备数量，否则为企业分发通配
    private func deviceScopeText(_ profile: ProvisioningInfo) -> String {
        if profile.provisionedDevices.isEmpty {
            return "不限设备（企业 / 通配）"
        }
        return "限定 \(profile.provisionedDevices.count) 台设备"
    }

    /// 状态胶囊：有效/无效统一浅色圆角底，与下载页 statusChip 同款
    private func statusChip(_ text: String, isGood: Bool, expired: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(expired ? .red : (isGood ? .green : .secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((expired ? Color.red : (isGood ? Color.green : Color.secondary)).opacity(0.12))
            )
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