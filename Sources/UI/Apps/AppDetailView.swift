import SwiftUI

struct AppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let app: AppInfo

    @State private var showShareSheet = false
    @State private var showSignOptions = false
    @State private var showInstallCertificatePicker = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var isSigning = false
    @State private var signProgress: Double = 0
    /// 本次会话中签名完成后的输出路径，用于在详情页实时反映“已签名”状态
    @State private var signedOutputPath: String?
    /// 签名完成弹窗：true 表示签名已成功并已发起安装
    @State private var showSignedAlert = false
    /// 签名完成后是否已自动安装（决定弹窗文案与“返回”行为）
    @State private var signedDidInstall = false
    /// 删除二次确认
    @State private var showDeleteConfirm = false
    /// 进度节流：仅当变化 ≥1% 或距离上次更新 ≥0.1s 才写入 @State
    @State private var lastProgressUpdate = Date.distantPast
    /// 签名中禁止关闭详情页
    @State private var closeLocked = false
    /// 当前签名阶段文字（"正在解压…/正在签名主程序…/正在重新打包…"），
    /// 由 SigningEngine 回调透传，与进度条同步刷新。
    @State private var signPhase = ""
    /// 签名开始时间：用于计算"已用/预计剩余"时间显示。
    @State private var signStartTime: Date?
    /// 刷新时间显示的定时器（已用/剩余秒数需要独立于进度回调持续更新；
    /// 进度数值由 smoother 推进，但时间也要随真实时钟走）。
    @State private var signTimer: Timer?
    /// 当前已用秒数（显示用，随 signTimer 刷新）
    @State private var elapsedSeconds: Int = 0
    /// 预计剩余秒数（按当前速度外推：elapsed / progress × (1 - progress)）
    @State private var etaSeconds: Int = 0

    /// 展示层使用的“实时”AppInfo：
    /// - 签名刚完成 → 以签名输出为准（合并原快照的元数据，isSigned = true，path 指向签名产物）；
    /// - 否则优先 importedApps 中 id 相同的最新副本，其次 installedApps 中 path 相同的条目；
    /// - 兜底使用传入快照。
    private var liveApp: AppInfo {
        if let signedPath = signedOutputPath,
           let installed = appState.installedApps.first(where: { $0.path == signedPath }) {
            var merged = app
            merged.isSigned = true
            merged.path = installed.path
            merged.signedPath = installed.path
            merged.size = installed.size
            return merged
        }
        if let imported = appState.importedApps.first(where: { $0.id == app.id }) {
            return imported
        }
        if let installed = appState.installedApps.first(where: { $0.path == app.path }) {
            return installed
        }
        return app
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerSection
                    .padding()

                Divider()

                infoList

                if isSigning {
                    signingProgressView
                }

                actionButtons
                    .padding()
            }
            .navigationTitle("应用详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // 签名进行中禁用“关闭”，避免用户关掉页面后签名完成无任何反馈
                    Button("关闭") {
                        dismiss()
                    }
                    .disabled(closeLocked)
                }
            }
            .sheet(isPresented: $showSignOptions) {
                SignOptionsView(app: app) { cert, profile, installAfter in
                    startSigning(certificate: cert, profile: profile, installAfter: installAfter)
                }
            }
            .sheet(isPresented: $showInstallCertificatePicker) {
                InstallCertificatePicker { cert in
                    do {
                        try appState.installApp(liveApp, certificate: cert)
                        alertMessage = "安装请求已发出"
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                    showAlert = true
                }
            }
            .sheet(isPresented: $showShareSheet) {
                // 用 fileURLWithPath 构造 URL，避免路径含空格/中文时分享失效
                ShareSheet(items: [URL(fileURLWithPath: liveApp.path)])
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            // 签名完成弹窗：内容“签名完成，已发起安装”，旁边“确定”和“返回”两个按钮。
            // “返回”：关闭当前详情界面、切回首页 Tab，并挂起 App 直接回到 iOS 桌面（主屏幕）。
            .alert("签名完成", isPresented: $showSignedAlert) {
                Button("确定", role: .cancel) {}
                Button("返回") {
                    dismiss()
                    appState.selectedTab = 0
                    // 挂起 App 回到 iOS 桌面（主屏幕）；App 保留在后台，点图标可恢复
                    appState.minimizeToHomeScreen()
                }
            } message: {
                Text(signedDidInstall ? "签名完成，已发起安装" : "签名完成，未自动安装")
            }
            .confirmationDialog(
                "删除后文件不可恢复，确定删除吗？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    appState.removeSignedApp(liveApp)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
            // 签名进行中禁止下滑手势关闭详情页：仅禁用 toolbar 关闭按钮时，
            // 下滑手势仍可关页，签名完成/失败将无任何反馈
            .interactiveDismissDisabled(isSigning)
            // 视图消失时停止签名时间显示定时器（切页/关闭后不得残留空转）
            .onDisappear {
                stopSignTimer()
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            AppIconView(iconPath: liveApp.iconPath, size: 80)
                .frame(width: 80, height: 80)

            Text(liveApp.name.isEmpty ? "未命名" : liveApp.name)
                .font(.title2)
                .fontWeight(.semibold)

            if liveApp.isSigned {
                Label("已签名", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundColor(.green)
            } else {
                Label("未签名", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
        }
    }

    private var infoList: some View {
        List {
            infoRow("Bundle ID", liveApp.bundleID.isEmpty ? "未知" : liveApp.bundleID)
            infoRow("版本", liveApp.version.isEmpty ? "未知" : liveApp.version)
            infoRow("构建号", liveApp.build.isEmpty ? "未知" : liveApp.build)
            infoRow("文件大小", liveApp.sizeDescription)
            infoRow("最低系统", liveApp.minimumOSVersion ?? "未知")
        }
        .listStyle(.insetGrouped)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var signingProgressView: some View {
        VStack(spacing: 6) {
            ProgressView(value: signProgress)
            HStack {
                // 阶段文字（"正在解压…/正在签名主程序…/正在重新打包…"）
                Text(signPhase.isEmpty ? "签名中…" : signPhase)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f%%", signProgress * 100))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            // 时间显示：已用 Xs · 预计剩余 Ys（进度 >0 才预估；完成即显示总用时）
            if signProgress >= 1.0 {
                Text("总用时 \(elapsedSeconds) 秒")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            } else {
                Text("已用 \(elapsedSeconds) 秒 · 预计剩余 \(etaSeconds) 秒")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.7)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // 签名主操作：直接使用默认选中的有效证书 + 描述文件 + “签名后自动安装”开关一键签名并安装；
            // 默认证书/描述文件缺失或无效时才退回可选面板（SignOptionsView）。
            Button {
                startSigningWithDefaults()
            } label: {
                Label(liveApp.isSigned ? "重新签名并安装" : "开始签名并安装", systemImage: "pencil.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSigning
                      || appState.certificates.isEmpty
                      || appState.profiles.isEmpty
                      || !FileManager.default.fileExists(atPath: liveApp.path))

            if liveApp.isSigned {
                Button {
                    showInstallCertificatePicker = true
                } label: {
                    Label("安装", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isSigning)
            }

            Button {
                showShareSheet = true
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSigning)

            Button(role: .destructive) {
                // 删除是永久性磁盘操作，加二次确认，与全部清除一致的交互风格
                showDeleteConfirm = true
            } label: {
                Label("删除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
            .disabled(isSigning)
        }
    }

    /// 一键签名并安装：默认选中的有效证书 + 描述文件（且仍在证书/描述文件列表中）+ AppStorage
    /// installAfterSigning（默认 true，未设置过时按 true 处理）直接签名并安装；
    /// 默认证书/描述文件缺失或无效时退回 SignOptionsView 让用户手动选择。
    private func startSigningWithDefaults() {
        if let cert = appState.selectedCertificate, cert.status == .valid,
           let profile = appState.selectedProfile, profile.status == .valid,
           appState.certificates.contains(where: { $0.id == cert.id }),
           appState.profiles.contains(where: { $0.id == profile.id }) {
            let installAfter = (UserDefaults.standard.object(forKey: "installAfterSigning") as? Bool) ?? true
            startSigning(certificate: cert, profile: profile, installAfter: installAfter)
        } else {
            showSignOptions = true   // fallback 让用户选
        }
    }

    private func startSigning(certificate: CertificateInfo, profile: ProvisioningInfo, installAfter: Bool) {
        isSigning = true
        closeLocked = true
        signProgress = 0
        signPhase = "准备中…"
        elapsedSeconds = 0
        etaSeconds = 0
        lastProgressUpdate = Date.distantPast
        // 启动时间显示：每 0.5s 刷新"已用/预计剩余"（进度由 smoother 推进，
        // 时间必须随真实时钟走，不能只依赖进度回调）
        signStartTime = Date()
        startSignTimer()
        appState.signApp(app, certificate: certificate, profile: profile, progress: { progress, phase in
            // 进度节流：变化 ≥1% 或间隔 ≥0.1s 才更新 @State，避免详情页频繁重算
            let now = Date()
            if abs(progress - signProgress) >= 0.01 || now.timeIntervalSince(lastProgressUpdate) >= 0.1 {
                signProgress = progress
                lastProgressUpdate = now
            }
            if !phase.isEmpty {
                signPhase = phase
            }
            // 用当前速度外推预计剩余：已用 / 进度 × (1 - 进度)。
            // 进度为 0 时无法预估，保持 0 显示"预计剩余 0 秒"由下方计算兜底。
            if progress > 0 {
                if let start = signStartTime {
                    let elapsed = now.timeIntervalSince(start)
                    elapsedSeconds = Int(elapsed)
                    let ratio = (1.0 - progress) / max(progress, 0.001)
                    etaSeconds = Int(elapsed * ratio)
                }
            }
        }, completion: { [self] result in
            stopSignTimer()
            switch result {
            case .success(let signedPath):
                isSigning = false
                closeLocked = false
                // 记录签名产物路径，供 liveApp 实时反映“已签名”状态（installedApps 会在回调前由 refreshInstalledApps 刷新）
                signedOutputPath = signedPath
                signedDidInstall = installAfter
                // 归正显示：进度 100% + 阶段"签名完成"（smoother 已归正，但兜底再设一次）
                signProgress = 1.0
                signPhase = "签名完成"
                if let start = signStartTime {
                    elapsedSeconds = Int(Date().timeIntervalSince(start))
                }
                etaSeconds = 0
                if installAfter {
                    do {
                        try appState.installSignedPath(signedPath, certificate: certificate)
                        // 弹窗内容：签名完成，已发起安装（旁边有“确定”与“返回”）
                        showSignedAlert = true
                    } catch {
                        alertMessage = "签名完成，安装失败: \(error.localizedDescription)"
                        showAlert = true
                    }
                } else {
                    // 未自动安装也给出明确反馈（否则静默成功用户不确定是否完成）
                    showSignedAlert = true
                }
            case .failure(let error):
                isSigning = false
                closeLocked = false
                alertMessage = signingFailureMessage(for: error)
                showAlert = true
            }
        })
    }

    /// 启动时间显示定时器：每 0.5s 更新"已用秒数"，并在进度>0 时重算"预计剩余"。
    /// 与 smoother 的进度推进解耦——进度回调只负责推进百分比，这里负责真实时钟。
    private func startSignTimer() {
        stopSignTimer()
        signTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [self] _ in
            guard let start = signStartTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            elapsedSeconds = Int(elapsed)
            // 进度未达 100% 时按当前速度外推剩余；到达后归零（由 completion 兜底）
            if signProgress > 0 && signProgress < 1.0 {
                let ratio = (1.0 - signProgress) / max(signProgress, 0.001)
                etaSeconds = Int(elapsed * ratio)
            } else if signProgress >= 1.0 {
                etaSeconds = 0
            }
        }
    }

    private func stopSignTimer() {
        signTimer?.invalidate()
        signTimer = nil
    }

    /// 当失败原因是“源文件丢失”时，在错误信息后附加一行恢复指引，
    /// 避免用户只看到 zsign 桥接层返回的 "Input file not found" 英文错误。
    private func signingFailureMessage(for error: Error) -> String {
        let base = "签名失败: \(error.localizedDescription)"
        let description = error.localizedDescription
        if description.contains("文件已被删除") || description.contains("Input file not found") || description.contains("源文件") {
            return base + "\n\n该应用的源文件已丢失（可能被清理），请在首页重新导入后再签名。"
        }
        return base
    }
}

struct InstallCertificatePicker: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let onConfirm: (CertificateInfo) -> Void

    var body: some View {
        NavigationView {
            List {
                Section("选择用于安装的证书") {
                    ForEach(appState.certificates) { cert in
                        Button {
                            onConfirm(cert)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(cert.name)
                                    .foregroundColor(.primary)
                                Text("到期: \(cert.expireDateDescription)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("安装")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct SignOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    let app: AppInfo
    let onConfirm: (CertificateInfo, ProvisioningInfo, Bool) -> Void

    @State private var selectedCert: CertificateInfo?
    @State private var selectedProfile: ProvisioningInfo?
    @AppStorage("installAfterSigning") private var installAfterSigning = true

    var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle("签名后自动安装", isOn: $installAfterSigning)
                } footer: {
                    Text("开启后签名完成会自动调用安装")
                }

                Section("选择证书") {
                    if appState.certificates.isEmpty {
                        Text("还没有证书，请先在「证书」标签页导入 P12/zip 证书包")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appState.certificates) { cert in
                            Button {
                                selectedCert = cert
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(cert.name)
                                            .foregroundColor(.primary)
                                        Text("到期: \(cert.expireDateDescription)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedCert?.id == cert.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("选择描述文件") {
                    if appState.profiles.isEmpty {
                        Text("还没有描述文件，请先在「证书」标签页导入 mobileprovision/zip 证书包")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(appState.profiles) { profile in
                            Button {
                                selectedProfile = profile
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(profile.name)
                                            .foregroundColor(.primary)
                                        Text("到期: \(profile.expireDateDescription)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedProfile?.id == profile.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("签名选项")
            .navigationBarTitleDisplayMode(.inline)
            // 打开弹窗时，若尚未手动选择，则默认勾选 AppState 中自动选中的默认证书/描述文件（存在且有效时）
            .onAppear {
                if selectedCert == nil,
                   let cert = appState.selectedCertificate,
                   cert.status == .valid,
                   appState.certificates.contains(where: { $0.id == cert.id }) {
                    selectedCert = cert
                }
                if selectedProfile == nil,
                   let profile = appState.selectedProfile,
                   profile.status == .valid,
                   appState.profiles.contains(where: { $0.id == profile.id }) {
                    selectedProfile = profile
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("开始签名") {
                        if let cert = selectedCert, let profile = selectedProfile {
                            onConfirm(cert, profile, installAfterSigning)
                            dismiss()
                        }
                    }
                    .disabled(selectedCert == nil || selectedProfile == nil)
                }
            }
        }
    }
}