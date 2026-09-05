import SwiftUI

/// 分享投递日志查看页（v1.0.142 重构）：
/// - 数据实时：绑定 appState.deliveryLogEntries（每次扫描后 AppState 更新该
///   @Published），不再像旧版只在 onAppear 拉一次、声称"实时"却永不刷新；
/// - 可操作：立即扫描 / 复制全部 / 清空，排查时无需来回退出页面；
/// - 可过滤：全部 / 仅扩展（跨进程日志）/ 仅异常（警告与错误），扫描降噪后
///   剩余条目以真实信号为主，过滤用于快速定位；
/// - 摘要卡信息量：可用容器组名（探针实测）、扩展最近活动时间、最近一条真实
///   投递、错误计数——普通用户不看逐条日志也能读出"链路断在哪"。
struct DeliveryLogView: View {
    @Environment(\.dismiss) private var dismiss
    /// 直接订阅单例而非 @EnvironmentObject：本视图经 SettingsView 的 sheet 弹出，
    /// 个别系统版本对 sheet 内容的环境对象注入不可靠，单例订阅无此依赖
    @ObservedObject private var appState = AppState.shared
    /// 过滤器：全部 / 仅扩展 / 仅异常
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable {
        case all = "全部"
        case extensionOnly = "扩展"
        case issues = "异常"
    }

    private var visibleEntries: [ExternalDeliveryJournal.Entry] {
        let entries = appState.deliveryLogEntries
        switch filter {
        case .all:
            return entries
        case .extensionOnly:
            return entries.filter { $0.event.hasPrefix("扩展：") }
        case .issues:
            return entries.filter { $0.level == .error || $0.level == .warning }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                summaryCard
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Picker("过滤", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if visibleEntries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }
            .navigationTitle("分享投递日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        // 手动触发一轮投递扫描（含扩展日志吞入与 UI 同步），
                        // 排查时不必切后台再回前台来触发扫描
                        appState.processInboxFilesIfNeeded()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = ExternalDeliveryJournal.reportText()
                            appState.showToast("投递日志已复制到剪贴板")
                        } label: {
                            Label("复制全部日志", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) {
                            ExternalDeliveryJournal.clear()
                            appState.refreshDeliveryLogEntries()
                            appState.showToast("投递日志已清空")
                        } label: {
                            Label("清空日志", systemImage: "trash")
                        }
                        Button("关闭") {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                // 打开页面即扫描一次：用户从分享动作直接进日志页时立刻看到最新状态
                appState.processInboxFilesIfNeeded()
            }
        }
    }

    // MARK: - 摘要卡

    private var summaryCard: some View {
        let containers = AppGroup.usableContainers()
        // 扩展最近活动：优先用共享容器里日志文件的 mtime（真值，主 App 未在线时
        // 扩展写入也能看到），无日志文件再退回投递日志里已吞入的扩展行
        let lastExtension = AppGroup.extensionLogLastModifiedDate
            ?? ExternalDeliveryJournal.lastExtensionActivityDate()
        let lastDelivery = ExternalDeliveryJournal.lastDeliveryEvent()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: containers.isEmpty
                    ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundColor(containers.isEmpty ? .red : .green)
                Text(containers.isEmpty
                    ? "共享容器不可用（扩展无法交接文件）"
                    : "共享容器可用（\(containers.map { $0.identifier }.joined(separator: "、"))）")
                    .font(.subheadline.weight(.medium))
            }
            summaryRow(label: "扩展最近活动", value: lastExtension.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "从未记录到扩展日志")
            summaryRow(label: "最近投递", value: lastDelivery.map {
                "\($0.event.prefix(24))（\($0.timestamp.formatted(date: .omitted, time: .shortened))）"
            } ?? "从未记录")
            if ExternalDeliveryJournal.errorCount() > 0 {
                summaryRow(label: "错误", value: "\(ExternalDeliveryJournal.errorCount()) 条（见「异常」过滤）")
                    .foregroundColor(.red)
            }
            Text("共 \(appState.deliveryLogEntries.count) 条记录")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.systemGray6))
        )
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    // MARK: - 列表与空态

    private var entryList: some View {
        List {
            // enumerated 的 offset 作 id：Entry 无稳定唯一标识（旧版用 timestamp
            // 作 id，同毫秒两条会触发 SwiftUI 重复 id 警告并丢行）
            ForEach(Array(visibleEntries.reversed().enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(for: entry.level))
                            .font(.caption2)
                            .foregroundColor(color(for: entry.level))
                        Text(entry.timestamp, style: .time)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Text(entry.event)
                        .font(.subheadline.monospaced())
                        .foregroundColor(entry.level == .error ? .red : .primary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(emptyTitle)
                .font(.headline)
                .foregroundColor(.secondary)
            Text("分享文件到 IPA Manager 后，\n投递链路的每一步都会记录在这里。\n也可点左上角刷新立即扫描。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        switch filter {
        case .all: return "暂无投递记录"
        case .extensionOnly: return "暂无扩展记录"
        case .issues: return "没有异常记录"
        }
    }

    // MARK: - 级别样式

    private func symbol(for level: ExternalDeliveryJournal.Level) -> String {
        switch level {
        case .info: return "circle.fill"
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        }
    }

    private func color(for level: ExternalDeliveryJournal.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .ok: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
