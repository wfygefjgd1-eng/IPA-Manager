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
                    importBar
                    appsSection
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
        let isZip = (url.pathExtension.lowercased() == "zip")
        appState.importFile(from: url) { importResult in
            switch importResult {
            case .success(let app):
                // 导入成功且是应用（bundleID 非空）→ 自动打开签名详情页，不再弹“已导入”提示
                guard !app.bundleID.isEmpty else {
                    self.alertMessage = "导入成功，但无法识别该应用的 Bundle ID"
                    self.showAlert = true
                    return
                }
                self.selectedApp = app
            case .failure(let error):
                self.alertMessage = isZip
                    ? self.zipImportFailureMessage(error.localizedDescription)
                    : error.localizedDescription
                self.showAlert = true
            }
        }
    }

    /// zip 导入失败时给出更贴合用户的中文提示：含 .app/.ipa 才是应用包；
    /// 否则（如证书包 zip）提示去证书页导入，而不是把底层解析错误直接抛给用户。
    private func zipImportFailureMessage(_ detail: String) -> String {
        if detail.contains("未找到 .app") {
            return "该 ZIP 不含应用（无 .app/.ipa），可能是证书包，请到证书页导入。\n\(detail)"
        }
        return detail
    }
}


