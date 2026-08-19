import SwiftUI

struct SettingsView: View {
    @State private var showAbout = false
    @State private var reportToShare = ""
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
                        reportToShare = Logger.diagnosticsReport()
                        showShare = true
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
                ShareSheet(items: [reportToShare])
            }
        }
    }
}