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
                    Button("关闭") {
                        dismiss()
                    }
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
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            AppIconView(iconPath: liveApp.iconPath)
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
        VStack(spacing: 8) {
            ProgressView(value: signProgress)
            Text(String(format: "%.0f%%", signProgress * 100))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            if liveApp.isSigned {
                Button {
                    showInstallCertificatePicker = true
                } label: {
                    Label("安装", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSigning)
            }

            Button {
                showSignOptions = true
            } label: {
                Label(liveApp.isSigned ? "重新签名" : "签名", systemImage: "pencil.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSigning || appState.certificates.isEmpty || appState.profiles.isEmpty)

            Button {
                showShareSheet = true
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isSigning)

            Button(role: .destructive) {
                appState.removeSignedApp(liveApp)
                dismiss()
            } label: {
                Label("删除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .foregroundColor(.red)
            .disabled(isSigning)
        }
    }

    private func startSigning(certificate: CertificateInfo, profile: ProvisioningInfo, installAfter: Bool) {
        isSigning = true
        signProgress = 0
        appState.signApp(app, certificate: certificate, profile: profile, progress: { progress in
            signProgress = progress
        }, completion: { [self] result in
            switch result {
            case .success(let signedPath):
                isSigning = false
                // 记录签名产物路径，供 liveApp 实时反映“已签名”状态（installedApps 会在回调前由 refreshInstalledApps 刷新）
                signedOutputPath = signedPath
                if installAfter {
                    do {
                        try appState.installSignedPath(signedPath, certificate: certificate)
                        alertMessage = "签名完成，已发起安装"
                    } catch {
                        alertMessage = "签名完成，安装失败: \(error.localizedDescription)"
                    }
                    showAlert = true
                }
            case .failure(let error):
                isSigning = false
                alertMessage = "签名失败: \(error.localizedDescription)"
                showAlert = true
            }
        })
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

                Section("选择描述文件") {
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