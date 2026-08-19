import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showImporter = false
    @State private var pendingImportURL: URL?
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
            .sheet(isPresented: $showPasswordSheet) {
                PasswordPromptView(importURL: pendingImportURL) { cert in
                    appState.addCertificate(cert)
                }
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
                    for index in indexSet {
                        appState.removeCertificate(appState.certificates[index])
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
                    for index in indexSet {
                        appState.removeProfile(appState.profiles[index])
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

    // 一键导入 zip（自动识别 p12 + mobileprovision）
    private func importBundle(_ url: URL) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let content = try CertificateBundleImporter.shared.extract(from: url)
                let moved = try CertificateBundleImporter.shared.moveToManagedLocation(
                    p12URL: content.p12URL,
                    profileURL: content.profileURL
                )

                DispatchQueue.main.async {
                    isImporting = false
                    var summary = ""

                    // 导入描述文件
                    if let profileURL = moved.profileURL {
                        do {
                            // importProfile 内部归档到 Documents/Profiles（目标本就在该目录时直接复用），
                            // 返回的 path 稳定，无需再覆盖
                            let profile = try ProvisioningManager.shared.importProfile(from: profileURL)
                            if !appState.profiles.contains(where: { $0.uuid == profile.uuid }) {
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
                        showPasswordSheet = true
                    } else {
                        alertMessage = summary + "未找到证书"
                        showAlert = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isImporting = false
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
            // 按 uuid 去重：同一描述文件重复导入只保留一份
            if !appState.profiles.contains(where: { $0.uuid == profile.uuid }) {
                appState.addProfile(profile)
                alertMessage = "描述文件导入成功: \(profile.name)"
            } else {
                Logger.info("描述文件已存在，跳过重复导入: \(profile.name)")
                alertMessage = "描述文件已存在: \(profile.name)"
            }
        } catch {
            alertMessage = error.localizedDescription
        }
        showAlert = true
    }
}