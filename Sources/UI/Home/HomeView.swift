import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showFileImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var selectedApp: AppInfo?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusCard
                    functionGrid
                    appsSection
                    recentSignings
                }
                .padding()
            }
            .navigationTitle("IPA Manager")
            .sheet(isPresented: $showFileImporter) {
                DocumentPicker(onPick: { url in
                    handleImportedFile(url)
                }, allowsMultiple: true)
            }
            .alert("提示", isPresented: $showAlert) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .sheet(item: $selectedApp) { app in
                AppDetailView(app: app)
            }
        }
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的应用")
                .font(.headline)

            if appState.importedApps.isEmpty && appState.installedApps.isEmpty {
                Text("还没有导入任何应用，点"导入文件"导入 IPA / ZIP")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let unsigned = appState.importedApps.filter { !$0.isSigned }
                if !unsigned.isEmpty {
                    Text("待签名 (\(unsigned.count))")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                    ForEach(unsigned) { app in
                        appRow(app)
                    }
                }
                if !appState.installedApps.isEmpty {
                    Text("已签名 (\(appState.installedApps.count))")
                        .font(.subheadline)
                        .foregroundColor(.green)
                    ForEach(appState.installedApps) { app in
                        appRow(app)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appRow(_ app: AppInfo) -> some View {
        Button {
            selectedApp = app
        } label: {
            HStack(spacing: 12) {
                AppIconView(iconPath: app.iconPath)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name.isEmpty ? "未命名" : app.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(app.bundleID.isEmpty ? "未知 Bundle ID" : app.bundleID)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: app.isSigned ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .foregroundColor(app.isSigned ? .green : .orange)
            }
            .padding(.vertical, 6)
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

    private func handleImportedFile(_ url: URL) {
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

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                handleImportedFile(url)
            }
        case .failure(let error):
            alertMessage = error.localizedDescription
            Logger.error("导入失败: \(error)")
            showAlert = true
        }
    }
}


