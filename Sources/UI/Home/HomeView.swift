import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showFileImporter = false
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var selectedApp: AppInfo?
    /// 多选导入：记录成功/失败数，全部结束后弹汇总（当前 sheet 打开详情页时仍显示）
    @State private var importSuccessCount = 0
    @State private var importFailureCount = 0
    @State private var pendingImportCount = 0

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
                    // 多选导入：串行逐个导入，进度 "正在导入 i/N" 随文件推进；每个文件独立出结果提示
                    onPickMany: { urls in
                        showFileImporter = false
                        importSuccessCount = 0
                        importFailureCount = 0
                        pendingImportCount = urls.count
                        importRemaining(urls, startIndex: 0)
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
        // 导入进度浮层：导入进行中显示黑色胶囊进度卡（与全局 toast 同风格），
        // 用户无需干等——ProgressView 转圈 + 文件名 + 阶段文字 + i/N 进度
        .overlay(alignment: .bottom) {
            if let progress = appState.importProgress {
                importProgressCard(progress)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.importProgress)
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
                AppIconView(iconPath: app.iconPath, size: 40)
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

    private func handleImportedFile(
        _ url: URL,
        index: Int = 1,
        total: Int = 1,
        completion: (() -> Void)? = nil
    ) {
        let isZip = (url.pathExtension.lowercased() == "zip")
        // progressContext 传入序号/总数，导入进度卡片据此显示 "正在导入 i/N"
        appState.importFile(from: url, progressContext: (index: index, total: total)) { importResult in
            // 无论成功/失败/提前 return 都通知串行导入器继续下一个文件
            defer { completion?() }
            switch importResult {
            case .success(let app):
                importSuccessCount += 1
                // 导入成功且是应用（bundleID 非空）
                guard !app.bundleID.isEmpty else {
                    alertMessage = "导入成功，但无法识别该应用的 Bundle ID"
                    showAlert = true
                    return
                }
                // 单个导入：立即打开签名详情页；多选：全部完成后弹汇总
                if pendingImportCount <= 1 {
                    selectedApp = app
                } else if importSuccessCount + importFailureCount >= pendingImportCount {
                    showImportSummary()
                }
            case .failure(let error):
                importFailureCount += 1
                if pendingImportCount > 1, importSuccessCount + importFailureCount >= pendingImportCount {
                    // 多选：错误并入汇总，不逐一弹窗打断
                    showImportSummary()
                } else {
                    alertMessage = isZip
                        ? zipImportFailureMessage(error.localizedDescription)
                        : error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    /// 串行导入剩余文件：每个文件完成后再导入下一个，
    /// 保证进度卡片上的 "正在导入 i/N" 随文件逐个推进（多选导入）。
    private func importRemaining(_ urls: [URL], startIndex: Int) {
        guard startIndex < urls.count else { return }
        handleImportedFile(urls[startIndex], index: startIndex + 1, total: urls.count) {
            importRemaining(urls, startIndex: startIndex + 1)
        }
    }

    /// 导入进度卡片：黑色胶囊 + 转圈 + 文件名 + 阶段文字，与全局 toast（ContentView）同风格。
    private func importProgressCard(_ progress: ImportProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            VStack(alignment: .leading, spacing: 3) {
                Text("正在导入 \(progress.fileName)")
                    .font(.footnote)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if progress.totalCount > 1 {
                    Text("正在导入 \(progress.currentIndex)/\(progress.totalCount) · \(progress.phase)")
                        .font(.caption2)
                        .opacity(0.85)
                } else {
                    Text(progress.phase)
                        .font(.caption2)
                        .opacity(0.85)
                }
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Capsule().fill(Color.black.opacity(0.8)))
        .padding(.bottom, 12)
    }

    /// 多选导入结束后的汇总提示（成功/失败个数）
    private func showImportSummary() {
        let total = importSuccessCount + importFailureCount
        guard total > 1 else { return }
        let summary: String
        if importFailureCount > 0 {
            summary = "已导入 \(importSuccessCount)/\(total) 个应用，\(importFailureCount) 个失败（详见具体提示）。"
        } else {
            summary = "已成功导入 \(importSuccessCount) 个应用。"
        }
        alertMessage = summary
        showAlert = true
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


