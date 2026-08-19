import SwiftUI
import UniformTypeIdentifiers
import Foundation

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
                    importBar
                    appsSection
                    recentSignings
                }
                .padding()
            }
            .navigationTitle("IPA Manager")
            .sheet(isPresented: $showFileImporter) {
                DocumentPicker(
                    onPick: { _ in },
                    // 多选导入：逐个交给 handleImportedFile，每个文件独立出结果提示
                    onPickMany: { urls in
                        showFileImporter = false
                        for url in urls {
                            handleImportedFile(url)
                        }
                    },
                    allowsMultiple: true
                )
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
                Text("还没有导入任何应用，点「导入文件」导入 IPA / ZIP")
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
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(versionText(for: app))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(timeText(for: app))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
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

    // 首页功能入口：仅保留可用的「导入文件」，显示为整条可点的长条卡片
    private var importBar: some View {
        Button {
            showFileImporter = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                    .frame(width: 44, height: 44)
                    .background(Color.green.opacity(0.15))
                    .cornerRadius(10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入文件")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("导入 IPA / ZIP，支持多选")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // 版本号展示：为空时显示"未知"
    private func versionText(for app: AppInfo) -> String {
        app.version.isEmpty ? "版本 未知" : "版本 v\(app.version)"
    }

    private static let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    // 时间信息：已签名应用显示"签名于"（优先取签名产物文件时间），未签名显示"导入于"；文件不存在则显示"时间未知"
    private func timeText(for app: AppInfo) -> String {
        let path = app.isSigned ? (app.signedPath ?? app.path) : app.path
        guard !path.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let date = (attributes[.modificationDate] as? Date) ?? (attributes[.creationDate] as? Date) else {
            return "时间未知"
        }
        let prefix = app.isSigned ? "签名于" : "导入于"
        return "\(prefix) \(Self.fileDateFormatter.string(from: date))"
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
}


