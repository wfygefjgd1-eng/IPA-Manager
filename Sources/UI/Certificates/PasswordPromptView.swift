import SwiftUI

struct PasswordPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let importURL: URL?
    let onImport: (CertificateInfo) -> Void

    @State private var password = ""
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("输入 P12 密码")
                    .font(.headline)

                Text("请输入证书的解压密码以读取证书信息")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("证书密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                if showError {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                Button {
                    importCertificate()
                } label: {
                    if isImporting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("导入")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .disabled(password.isEmpty || isImporting)
            }
            .padding()
            .navigationTitle("证书导入")
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

    private func importCertificate() {
        guard let url = importURL, !password.isEmpty else { return }
        isImporting = true
        showError = false

        CertificateManager.shared.importCertificate(from: url, password: password) { result in
            DispatchQueue.main.async {
                isImporting = false
                switch result {
                case .success(let certificate):
                    Logger.info("证书导入成功: \(certificate.name)")
                    onImport(certificate)
                    dismiss()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}