import SwiftUI

struct SettingsView: View {
    @State private var showAbout = false
    /// 诊断报告临时文件（写入成功后再赋值为非 nil，触发分享 sheet）
    @State private var shareItem: ShareItem?
    /// 诊断报告写入失败时的错误提示
    @State private var reportError: String?
    /// 分享投递日志查看弹窗
    @State private var showDeliveryLog = false
    /// 导入/下载完成后自动签名并安装（默认开）
    @AppStorage("setting_auto_sign_and_install") private var autoSignAndInstall = true
    /// 签名完成后自动返回桌面（默认开）
    @AppStorage("setting_auto_return_home") private var autoReturnHomeAfterSigning = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    announcementCard
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    sectionHeader(icon: "megaphone.fill", title: "功能亮点")
                }

                Section {
                    toggleRow(
                        icon: "arrow.triangle.2.circlepath",
                        tint: .accentColor,
                        title: "导入后自动签名",
                        subtitle: "导入 IPA / 下载完成后立即自动签名并安装",
                        isOn: $autoSignAndInstall
                    )
                    .rowCard()
                    toggleRow(
                        icon: "house",
                        tint: .blue,
                        title: "签名后自动返回桌面",
                        subtitle: "签名完成并安装后自动回到桌面",
                        isOn: $autoReturnHomeAfterSigning
                    )
                    .rowCard()
                } header: {
                    sectionHeader(icon: "gearshape", title: "自动流程")
                }

                Section {
                    Button {
                        showDeliveryLog = true
                    } label: {
                        actionRow(
                            icon: "tray.and.arrow.down",
                            tint: .purple,
                            title: "查看分享投递日志",
                            subtitle: "查看文件分享到 App 时的实时投递记录"
                        )
                    }
                    .rowCard()
                    Button {
                        prepareReportForSharing()
                    } label: {
                        actionRow(
                            icon: "ant.circle",
                            tint: .red,
                            title: "收集全部错误并导出",
                            subtitle: "导出 ZIP / 签名 / 安装等失败原因，直接发送给开发者"
                        )
                    }
                    .rowCard()
                    Button {
                        clearDiagnosticCaches()
                    } label: {
                        actionRow(
                            icon: "paintbrush",
                            tint: .orange,
                            title: "清除诊断缓存",
                            subtitle: "清空投递日志、失败记录与最近日志缓冲"
                        )
                    }
                    .rowCard()
                } header: {
                    sectionHeader(icon: "wrench.and.screwdriver", title: "诊断与反馈")
                }

                Section {
                    Button {
                        showAbout = true
                    } label: {
                        actionRow(
                            icon: "info.circle",
                            tint: .green,
                            title: "关于 IPA Manager",
                            subtitle: "版本 \(Self.currentVersion)"
                        )
                    }
                    .rowCard()
                } header: {
                    sectionHeader(icon: "info.circle", title: "关于")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("设置")
            .alert("IPA Manager", isPresented: $showAbout) {
                Button("确定", role: .cancel) {}
            } message: {
                Text("本地 IPA 签名与管理工具\n版本 \(Self.currentVersion)\n所有签名均在设备本地完成，不上传任何文件")
            }
            // 诊断报告写入失败提示（与分享 sheet 分开，避免相互覆盖）
            .alert("提示", isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(reportError ?? "")
            }
            // 分享投递日志查看弹窗
            .sheet(isPresented: $showDeliveryLog) {
                DeliveryLogView()
            }
            // 用 sheet(item:) 绑定 URL，避免旧实现“isPresented + sheet 内 if let”的时序问题：
            // 之前表现为“第一次点击分享是空白的，要返回再点才弹出”。
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
        // 毛玻璃背景：置于 NavigationView 外层，列表/空态/导航栏区域统一一个底色，
        // 列表已用 scrollContentBackground(.hidden) 透出其上的玻璃质感
        .background(GlassBackground().ignoresSafeArea())
    }

    // MARK: - 行组件（图标 + 标题 + 副标题，统一精致风格）

    /// Section 标题：小图标 + 文字，避免光秃秃一行字
    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .textCase(nil)
    }

    /// 带开关的行：图标瓦片 + 标题 + 副标题 + 开关
    private func toggleRow(icon: String, tint: Color, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconTile(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    /// 可点击的行：图标瓦片 + 标题 + 副标题
    private func actionRow(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            iconTile(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// 圆角浅色底图标瓦片
    private func iconTile(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 36, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.13))
            )
    }

    /// 功能亮点公告卡：虚线边框 + 浅品牌色底，明显与下方可点的操作卡片区分，
    /// 用户一眼知道这是"纯展示信息"而不是可点击的按钮
    private var announcementCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("本地签名，数据不出设备")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text("所有签名均在设备本地完成，不上传任何文件")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .overlay(Color.secondary.opacity(0.3))

            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.green)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.green.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("证书安全存储")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Text("证书与私钥保存在系统 Keychain")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.orange)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.orange.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动流程可选")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Text("导入后自动签名、签名后自动回桌面，可在下方开关")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [6]))
        )
    }

    /// 当前安装包的真实版本号（读 Info.plist 的 CFBundleShortVersionString + CFBundleVersion，
    /// 与诊断报告头部显示的版本一致，避免用户误以为一直是 1.0）。
    private static var currentVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (构建 \(build))"
    }

    /// 把诊断报告写入临时 .txt 文件再分享（直接分享 String 时，
    /// 系统"存储到文件"会保存成 NSKeyedArchiver 二进制 plist，无法阅读）。
    /// 每次导出先删除上一次的临时报告：旧实现每次新建带时间戳的文件且从不删除，
    /// 多次导出会在 tmp 目录无限堆积。
    private static var lastReportURL: URL?

    private func prepareReportForSharing() {
        let report = Logger.diagnosticsReport()
        if let last = Self.lastReportURL {
            try? FileManager.default.removeItem(at: last)
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPA-Manager-诊断报告-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try report.write(to: tempURL, atomically: true, encoding: .utf8)
            Self.lastReportURL = tempURL
            // 写成功后赋值为非 nil 才弹 sheet，避免分享空内容
            shareItem = ShareItem(url: tempURL)
        } catch {
            Logger.error("诊断报告写入失败: \(error.localizedDescription)")
            reportError = "诊断报告生成失败: \(error.localizedDescription)"
        }
    }

    /// 清除诊断缓存：投递日志（含扩展吞入记录）、失败专区（内存+持久化）、
    /// 最近日志缓冲、已导出的临时报告文件。让下一轮排查从干净状态开始，
    /// 不会被历史噪音淹没。
    private func clearDiagnosticCaches() {
        ExternalDeliveryJournal.clear()
        Logger.clearAll()
        if let last = Self.lastReportURL {
            try? FileManager.default.removeItem(at: last)
            Self.lastReportURL = nil
        }
        reportError = nil
        AppState.shared.showToast("诊断缓存已清空")
    }
}

/// 包装 URL 使其满足 Identifiable，供 .sheet(item:) 绑定。
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// 设置页行卡片容器：与其他页面统一——半透明圆角底 + 细描边 + 行间留白，
/// 透出 GlassBackground 毛玻璃质感，不再是一格格系统默认圆角分组
private extension View {
    func rowCard() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}