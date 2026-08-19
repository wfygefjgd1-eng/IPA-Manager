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
                        try appState.installApp(app, certificate: cert)
                        alertMessage = "安装请求已发出"
                    } catch {
                        alertMessage = error.localizedDescription
                    }
                    showAlert = true
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = URL(string: app.path) {
                    ShareSheet(items: [url])
                }
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
            AppIconView(iconPath: app.iconPath)
                .frame(width: 80, height: 80)

            Text(app.name.isEmpty ? "未命名" : app.name)
                .font(.title2)
                .fontWeight(.semibold)

            if app.isSigned {
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
            infoRow("Bundle ID", app.bundleID.isEmpty ? "未知" : app.bundleID)
            infoRow("版本", app.version.isEmpty ? "未知" : app.version)
            infoRow("构建号", app.build.isEmpty ? "未知" : app.build)
            infoRow("文件大小", app.sizeDescription)
            infoRow("最低系统", app.minimumOSVersion ?? "未知")
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
            if app.isSigned {
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
                Label(app.isSigned ? "重新签名" : "签名", systemImage: "pencil.circle.fill")
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
                appState.removeSignedApp(app)
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