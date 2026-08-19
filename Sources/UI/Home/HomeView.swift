import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showFileImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    functionGrid
                    recentSignings
                }
                .padding()
            }
            .navigationTitle("IPA Manager")
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.ipaType, .zip, .pkcs12],
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("证书状态")
                .font(.headline)

            if let cert = appState.selectedCertificate {
                Label {
                    Text("\(cert.name) · \(cert.statusDescription)")
                } icon: {
                    Image(systemName: cert.status == .valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(cert.status == .valid ? .green : .red)
                }
            } else {
                Label {
                    Text("未选择证书")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            }

            Divider()

            if let profile = appState.selectedProfile {
                Label {
                    Text("\(profile.name) · \(profile.statusDescription)")
                } icon: {
                    Image(systemName: "doc.badge.gearshape")
                        .foregroundColor(profile.status == .valid ? .green : .red)
                }
            } else {
                Label {
                    Text("未选择描述文件")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var functionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            functionCard(
                title: "下载应用",
                icon: "arrow.down.circle.fill",
                color: .blue
            ) {
                // TODO: 跳转到内置浏览器
            }

            functionCard(
                title: "导入文件",
                icon: "square.and.arrow.down.fill",
                color: .green
            ) {
                showFileImporter = true
            }

            functionCard(
                title: "证书管理",
                icon: "lock.shield.fill",
                color: .orange
            ) {
                // TODO: 跳转到证书管理
            }

            functionCard(
                title: "已签应用",
                icon: "apps.iphone",
                color: .purple
            ) {
                // TODO: 跳转到已签应用
            }
        }
    }

    private func functionCard(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
        }
    }

    private var recentSignings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近签名任务")
                .font(.headline)

            if appState.signingTasks.isEmpty {
                Text("暂无签名任务")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(appState.signingTasks.prefix(5)) { task in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(task.sourceAppName.isEmpty ? "未命名" : task.sourceAppName)
                                .font(.subheadline)
                            Text(task.createdAt, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(task.statusDescription)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(statusColor(task.status))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusColor(_ status: SigningTask.Status) -> Color {
        switch status {
        case .success: return .green.opacity(0.2)
        case .failed: return .red.opacity(0.2)
        case .processing: return .blue.opacity(0.2)
        case .queued: return .gray.opacity(0.2)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                appState.importFile(from: url) { importResult in
                    switch importResult {
                    case .success(let app):
                        self.alertMessage = "已导入: \(app.name) (\(app.version))"
                    case .failure(let error):
                        self.alertMessage = error.localizedDescription
                    }
                    self.showAlert = true
                }
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
            Logger.error("导入失败: \(error)")
            showAlert = true
        }
    }
}


