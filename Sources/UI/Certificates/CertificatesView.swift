import SwiftUI
import UniformTypeIdentifiers

struct CertificatesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showImporter = false
    @State private var importType: ImportType = .certificate
    @State private var pendingImportURL: URL?
    @State private var showPasswordSheet = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    enum ImportType {
        case certificate
        case profile
    }

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
                        importType = .profile
                        showImporter = true
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }

                    Button {
                        importType = .certificate
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: importType == .certificate ? [.p12Type] : [.mobileprovisionType],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result, type: importType)
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
        }
    }

    private var certificatesSection: some View {
        Section("企业证书") {
            if appState.certificates.isEmpty {
                Text("暂无证书，点击右上角 + 导入 P12")
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
                Text("暂无描述文件，点击右上角导入 mobileprovision")
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

    private func handleImport(_ result: Result<[URL], Error>, type: ImportType) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            switch type {
            case .certificate:
                pendingImportURL = url
                showPasswordSheet = true
            case .profile:
                importProfile(url)
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
            showAlert = true
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
            var profile = try ProvisioningManager.shared.importProfile(from: destination)
            profile.path = destination.path
            appState.addProfile(profile)
            alertMessage = "描述文件导入成功: \(profile.name)"
        } catch {
            alertMessage = error.localizedDescription
        }
        showAlert = true
    }
}