import SwiftUI

struct PasswordPromptView: View {
    @Environment(\.dismiss) private var dismiss
    let importURL: URL?
    let onImport: (CertificateInfo) -> Void
    /// 用户取消/关闭密码框时通知父级：清理托管 P12 明文副本与解压目录
    /// （私钥材料不常驻 Documents），dismiss 前调用。
    var onCancel: (() -> Void)?

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

                Text("请输入证书的解压密码以读取证书信息；无密码证书可留空直接导入")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                SecureField("证书密码（无密码证书可留空）", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    .autocorrectionDisabled()

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
                // 允许空密码提交：CertificateManager 支持无密码 P12
                .disabled(isImporting)
            }
            .padding()
            .navigationTitle("证书导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        // 取消前清空密码并通知父级清理托管 P12 明文副本与解压目录，
                        // 不留私钥材料常驻 Documents；父级另有 onDismiss 兜底
                        password = ""
                        onCancel?()
                        dismiss()
                    }
                }
            }
        }
    }

    private func importCertificate() {
        guard let url = importURL else { return }
        isImporting = true
        showError = false

        CertificateManager.shared.importCertificate(from: url, password: password) { result in
            DispatchQueue.main.async {
                isImporting = false
                switch result {
                case .success(let certificate):
                    Logger.info("证书导入成功: \(certificate.name)")
                    onImport(certificate)
                    // dismiss 后清空密码，避免敏感信息滞留内存
                    password = ""
                    dismiss()
                case .failure(let error):
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}