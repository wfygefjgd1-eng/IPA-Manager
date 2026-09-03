import SwiftUI

/// 分享投递日志查看页：以时间倒序展示 ExternalDeliveryJournal 的所有记录，
/// 用户分享文件到 App 后可在此查看投递链路发生了什么。
struct DeliveryLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ExternalDeliveryJournal.Entry] = []
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("暂无投递记录")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("分享文件到 IPA Manager 后，\n投递日志会实时显示在这里。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // 摘要卡片
                    summaryCard
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    
                    // 日志列表（按时间倒序）
                    List {
                        ForEach(entries.reversed(), id: \.timestamp) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.timestamp, style: .time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(.secondary)
                                Text(entry.event)
                                    .font(.subheadline.monospaced())
                                    .foregroundColor(eventColor(for: entry.event))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("分享投递日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                entries = ExternalDeliveryJournal.getEntries()
            }
        }
    }
    
    /// 摘要卡片：显示关键状态
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: AppGroup.containerURL != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(AppGroup.containerURL != nil ? .green : .red)
                Text(AppGroup.containerURL != nil ? "App Group 可用" : "App Group 不可用")
                    .font(.subheadline.weight(.medium))
            }
            if !entries.isEmpty {
                Text("共 \(entries.count) 条记录")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(UIColor.systemGray6))
        )
    }
    
    /// 根据事件内容着色：错误红色、警告橙色、成功绿色、普通灰色
    private func eventColor(for event: String) -> Color {
        if event.contains("不可用") || event.contains("失败") || event.contains("错误") {
            return .red
        } else if event.contains("警告") {
            return .orange
        } else if event.contains("成功") || event.contains("可用") || event.contains("已接收") {
            return .green
        }
        return .primary
    }
}
