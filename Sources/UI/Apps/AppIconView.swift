import SwiftUI
import UIKit
import ImageIO

struct AppIconView: View {
    let iconPath: String?
    /// 目标渲染尺寸（pt）：调用方通过此参数控制大小，
    /// 内部不再写死 48pt 导致详情页大图标实际只有 48、首页小图标内容溢出。
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let iconPath = iconPath,
               let uiImage = Self.loadIcon(at: iconPath, targetSize: size) {
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

    /// 当前屏幕显示倍率：修复 UIScreen.main.scale 在 iOS17+ 的废弃警告，
    /// 优先取 traitCollection.displayScale，异常时回退到 2.0/3.0 兼容值
    private static var displayScale: CGFloat {
        // UIScreen.main.scale deprecated -> traitCollection.displayScale
        let scale = UIScreen.main.traitCollection.displayScale
        if scale > 0 { return scale }
        // 回退：尝试从 windowScene 获取，否则用 3.0（高分屏兜底）
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let s = scene.screen.traitCollection.displayScale
            if s > 0 { return s }
        }
        return 2.0
    }

    /// 用 ImageIO 降采样加载：图标常为 512~1024px，按目标渲染尺寸解码小图，
    /// 避免在内存中保留全分辨率位图。解码失败回退 nil（调用方显示占位图）。
    static func loadIcon(at path: String, targetSize: CGFloat) -> UIImage? {
        // 缓存键含文件修改时间：重导入覆盖同名图标文件后内容变化，mtime 变化 → 新键
        // → 强制重新解码，避免 NSCache 一直命中旧图（NSCache 不感知文件内容变化）。
        let mtime = Self.modificationTime(of: path)
        let scale = Self.displayScale
        let cacheKey = NSString(string: "\(path)#\(Int(targetSize * scale))#\(mtime)")
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        // 目标像素尺寸 = pt * scale：配合 .resizable() 已经足够清晰。
        // 旧实现再 *2 过采样（详情页 80pt@3x → 480px 位图），缓存 cost 直接翻倍，
        // 在 countLimit=100 + 20MB 上限下等于白占一半缓存。
        let pixelSize = Int(targetSize * scale)
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

    /// 文件修改时间戳（秒）：随缓存键参与比较；文件缺失时返回 0（loadIcon 会因
    /// 打不开文件源返回 nil，占位图兜底），保证键值稳定。
    private static func modificationTime(of path: String) -> TimeInterval {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}