import SwiftUI

/// 全局毛玻璃背景层：统一中性底色 + 彩色光斑 + 半透明材质。
///
/// 设计要点：
/// - 底色是"系统分组背景 → 系统背景"的柔和过渡（对比弱、不割裂），
///   避免整块品牌色渐变造成"两种颜色"的观感；
/// - 彩色光斑（模糊半径远大于光斑自身）透过 regularMaterial 后呈现柔和色晕，
///   滚动/内容掠过时玻璃质感肉眼可辨；
/// - 深浅色模式自适应。
///
/// 用法：在页面最外层 `.background(GlassBackground().ignoresSafeArea())`，
/// 列表需配合 `.scrollContentBackground(.hidden)` 才能透出底层。
struct GlassBackground: View {
    var body: some View {
        ZStack {
            // 统一底色：柔和过渡，视觉上是一个整体
            LinearGradient(
                colors: [
                    Color(.systemGroupedBackground),
                    Color(.systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // 彩色光斑：给玻璃层提供"可模糊的内容"，是毛玻璃质感的主要来源
            Circle()
                .fill(Color.accentColor.opacity(0.30))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: -170, y: -280)
            Circle()
                .fill(Color.purple.opacity(0.22))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: 190, y: 140)
            Circle()
                .fill(Color.orange.opacity(0.16))
                .frame(width: 280, height: 280)
                .blur(radius: 100)
                .offset(x: -200, y: 320)
            // 半透明材质：透出光斑的柔和色晕，形成毛玻璃质感
            Rectangle()
                .fill(.regularMaterial)
        }
    }
}