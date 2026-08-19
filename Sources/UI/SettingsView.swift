import SwiftUI

struct SettingsView: View {
    @State private var showAbout = false
    @State private var reportFileURL: URL?
    @State private var showShare = false

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
                Text("本地 IPA 签名与管理工具\n版本 1.0\n所有签名均在设备本地完成，不上传任何文件")
            }
            .sheet(isPresented: $showShare) {
                if let url = reportFileURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }

    /// 把诊断报告写入临时 .txt 文件再分享（直接分享 String 时，
    /// 系统"存储到文件"会保存成 NSKeyedArchiver 二进制 plist，无法阅读）。
    private func prepareReportForSharing() {
        let report = Logger.diagnosticsReport()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPA-Manager-诊断报告-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try report.write(to: tempURL, atomically: true, encoding: .utf8)
            reportFileURL = tempURL
            showShare = true
        } catch {
            Logger.error("诊断报告写入失败: \(error.localizedDescription)")
        }
    }
}