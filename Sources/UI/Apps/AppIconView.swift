import SwiftUI
import UIKit
import ImageIO

struct AppIconView: View {
    let iconPath: String?
    /// 目标渲染尺寸（pt）：调用方通过此参数控制大小，
    /// 内部不再写死 48pt 导致详情页大图标实际只有 48、首页小图标内容溢出。
    var size: CGFloat = 48
    /// 屏幕显示了倍率（SwiftUI 环境，iOS 13+）：替代已弃用的 UIScreen.main——
    /// 旧实现注释声称修复了 iOS 17 弃用警告，实际 UIScreen.main.traitCollection
    /// 仍踩在弃用 API 上。displayScale 为 0（无渲染上下文）时按 2.0 兜底。
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let iconPath = iconPath,
               let uiImage = Self.loadIcon(at: iconPath, targetSize: size, scale: displayScale) {
                Image(uiImage: uiImage)
                    .resizable()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .foregroundColor(.gray)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }

    /// 图标缓存：同一路径只解码一次，避免列表滚动/重绘时反复读盘 + 全尺寸解码。
    /// 特别是详情页大图标与首页行图标共用同一文件时，缓存能显著减少内存与 IO。
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 100
        c.totalCostLimit = 20 * 1024 * 1024
        return c
    }()

    /// 用 ImageIO 降采样加载：图标常为 512~1024px，按目标渲染尺寸解码小图，
    /// 避免在内存中保留全分辨率位图。解码失败回退 nil（调用方显示占位图）。
    /// scale 由调用方从 SwiftUI 环境（\.displayScale）注入，0 时按 2.0 兜底
    /// （无渲染上下文的预览/离屏场景）。
    static func loadIcon(at path: String, targetSize: CGFloat, scale: CGFloat) -> UIImage? {
        // 缓存键含文件修改时间：重导入覆盖同名图标文件后内容变化，mtime 变化 → 新键
        // → 强制重新解码，避免 NSCache 一直命中旧图（NSCache 不感知文件内容变化）。
        let mtime = Self.modificationTime(of: path)
        let effectiveScale = scale > 0 ? scale : 2.0
        let cacheKey = NSString(string: "\(path)#\(Int(targetSize * effectiveScale))#\(mtime)")
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        // 目标像素尺寸 = pt * scale：配合 .resizable() 已经足够清晰。
        // 旧实现再 *2 过采样（详情页 80pt@3x → 480px 位图），缓存 cost 直接翻倍，
        // 在 countLimit=100 + 20MB 上限下等于白占一半缓存。
        let pixelSize = Int(targetSize * effectiveScale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelSize, 64)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        let cost = cgImage.bytesPerRow * cgImage.height
        cache.setObject(image, forKey: cacheKey, cost: cost > 0 ? cost : Int(targetSize * targetSize * 4))
        return image
    }

    /// mtime 读取的记忆缓存（5 秒 TTL）：缓存命中路径每次 body 重算也要 stat 一次
    /// 磁盘参与缓存键，而 AppState 任一 @Published 变化都会让列表整页重算 body
    /// （导入期间每秒多次 × N 个图标）。mtime 校验只对"重导入覆盖同名文件"有意义，
    /// 5 秒 TTL 在覆盖场景下最多延迟一次刷新，IO 放大却完全消除。
    private static let mtimeLock = NSLock()
    private static var mtimeMemo: [String: (value: TimeInterval, at: Date)] = [:]

    /// 文件修改时间戳（秒）：随缓存键参与比较；文件缺失时返回 0（loadIcon 会因
    /// 打不开文件源返回 nil，占位图兜底），保证键值稳定。
    private static func modificationTime(of path: String) -> TimeInterval {
        mtimeLock.lock()
        if let memo = mtimeMemo[path], Date().timeIntervalSince(memo.at) < 5 {
            mtimeLock.unlock()
            return memo.value
        }
        mtimeLock.unlock()

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let value = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        mtimeLock.lock()
        // 条目仅在读取时有 5s TTL 判定、从不移除——长会话浏览大量应用后随
        // 图标路径数无限增长。超过上限时按过期时间剪枝一次（TTL 内的条目保留）
        if mtimeMemo.count > 512 {
            let cutoff = Date().addingTimeInterval(-5)
            mtimeMemo = mtimeMemo.filter { $0.value.at >= cutoff }
        }
        mtimeMemo[path] = (value, Date())
        mtimeLock.unlock()
        return value
    }
}