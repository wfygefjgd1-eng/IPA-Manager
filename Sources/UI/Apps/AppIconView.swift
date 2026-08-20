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
    private static let cache = NSCache<NSString, UIImage>()

    /// 用 ImageIO 降采样加载：图标常为 512~1024px，按目标渲染尺寸解码小图，
    /// 避免在内存中保留全分辨率位图。解码失败回退 nil（调用方显示占位图）。
    static func loadIcon(at path: String, targetSize: CGFloat) -> UIImage? {
        let cacheKey = NSString(string: "\(path)#\(Int(targetSize * UIScreen.main.scale))")
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }
        // 目标像素尺寸 = pt * scale，留一点余量（*2）确保缩放后依然清晰
        let pixelSize = Int(targetSize * UIScreen.main.scale * 2)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(pixelSize, 64)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}