import SwiftUI

struct SettingsView: View {
    @State private var showAbout = false
    /// 诊断报告临时文件（写入成功后再赋值为非 nil，触发分享 sheet）
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationView {
            List {
                Section("使用说明") {
                    Label("本工具全部在本地完成签名", systemImage: "lock.shield.fill")
                    Label("证书与私钥保存在系统 Keychain", systemImage: "key.fill")
                }

                Section("诊断与反馈") {
                    Button {
                        prepareReportForSharing()
                    } label: {
                        Label("收集全部错误并导出", systemImage: "ant.circle")
                    }
                    Text("导出 ZIP/签名/安装等失败原因，直接发送给开发者")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("关于") {
                    Button {
                        showAbout = true
                    } label: {
                        HStack {
                            Label("关于 IPA Manager", systemImage: "info.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("设置")
            .alert("IPA Manager", isPresented: $showAbout) {
                Button("确定", role: .cancel) {}
            } message: {
                Text("本地 IPA 签名与管理工具\n版本 \(Self.currentVersion)\n所有签名均在设备本地完成，不上传任何文件")
            }
            // 用 sheet(item:) 绑定 URL，避免旧实现“isPresented + sheet 内 if let”的时序问题：
            // 之前表现为“第一次点击分享是空白的，要返回再点才弹出”。
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
        }
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
    private func prepareReportForSharing() {
        let report = Logger.diagnosticsReport()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPA-Manager-诊断报告-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try report.write(to: tempURL, atomically: true, encoding: .utf8)
            // 写成功后赋值为非 nil 才弹 sheet，避免分享空内容
            shareItem = ShareItem(url: tempURL)
        } catch {
            Logger.error("诊断报告写入失败: \(error.localizedDescription)")
        }
    }
}

/// 包装 URL 使其满足 Identifiable，供 .sheet(item:) 绑定。
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}