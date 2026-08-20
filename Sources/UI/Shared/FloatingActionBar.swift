import SwiftUI

/// 底部悬浮操作条容器：半透明材质胶囊 + 轻阴影，悬浮在内容底部（Tab 栏上方）。
/// 供“已签应用 / 下载应用”两个页面共用，保证操作按钮风格一致：
/// 不突兀（材质透出背景），又让用户明确知道这里有可操作按钮（阴影边缘）。
struct FloatingActionBar<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            content
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}