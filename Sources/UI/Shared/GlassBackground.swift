import SwiftUI

/// 全局毛玻璃背景层：柔和品牌色渐变 + 半透明材质，供各页面作底层背景，
/// 列表/内容透明化后透出玻璃质感；深浅色模式自适应。
/// 用法：在页面最外层 `.background(GlassBackground().ignoresSafeArea())`，
/// 列表需配合 `.scrollContentBackground(.hidden)` 才能透出底层。
struct GlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color(.systemGroupedBackground),
                    Color(.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 半透明材质：透出渐变与滚动内容，形成毛玻璃
            Rectangle()
                .fill(.ultraThinMaterial)
        }
    }
}