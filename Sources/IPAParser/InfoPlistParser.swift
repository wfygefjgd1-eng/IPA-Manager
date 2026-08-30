import Foundation

protocol InfoPlistParsing {
    func parse(at url: URL) throws -> AppInfo
    func extractIcon(from plistURL: URL, appURL: URL) throws -> String?
}

final class InfoPlistParser {
    func parse(at url: URL) throws -> AppInfo {
        guard let data = try? Data(contentsOf: url) else {
            throw AppError.operationFailed("无法读取 Info.plist")
        }

        // 区分"合法 plist 但顶层不是字典"与"解析失败"：旧实现把前者静默降级为
        // 空字典（`as? [String: Any] ?? [:]`），产出的应用 bundleID 为空串，导入后
        // 按空 bundleID 与其它坏包互相静默覆盖。
        let plist: [String: Any]
        do {
            let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            guard let dict = raw as? [String: Any] else {
                throw AppError.operationFailed("Info.plist 格式异常（顶层不是字典），无法提取应用信息")
            }
            plist = dict
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.operationFailed("Info.plist 解析失败: \(error.localizedDescription)")
        }

        var info = AppInfo()
        info.name = plist["CFBundleDisplayName"] as? String
            ?? plist["CFBundleName"] as? String
            ?? "未知应用"
        info.bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        info.version = plist["CFBundleShortVersionString"] as? String ?? ""
        info.build = plist["CFBundleVersion"] as? String ?? ""
        info.minimumOSVersion = plist["MinimumOSVersion"] as? String

        return info
    }

    func extractIcon(from plistURL: URL, appURL: URL) throws -> String? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        // 收集所有可能的图标名候选：多种 Info.plist 结构全部尝试，不只取 first。
        // 关键修复点：iOS 12+ 用资源目录（asset catalog）构建的应用常只声明
        // CFBundleIconName（如 "AppIcon"）而没有 CFBundleIconFiles，此时图标
        // PNG（AppIcon60x60@2x.png 等）仍在 .app 根目录里，旧实现会漏掉 → 显示灰图标。
        var candidates: [String] = []

        if let iconsDict = plist["CFBundleIcons"] as? [String: Any] {
            if let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any] {
                if let files = primaryIcon["CFBundleIconFiles"] as? [String] {
                    candidates.append(contentsOf: files)
                }
                if let name = primaryIcon["CFBundleIconName"] as? String {
                    candidates.append(name)
                }
            }
            if let files = iconsDict["CFBundleIconFiles"] as? [String] {
                candidates.append(contentsOf: files)
            }
        }
        if let files = plist["CFBundleIconFiles"] as? [String] {
            candidates.append(contentsOf: files)
        }
        if let name = plist["CFBundleIconName"] as? String {
            candidates.append(name)
        }
        // 旧式单图标键（可能带 .png/.jpg 扩展名）
        if let file = plist["CFBundleIconFile"] as? String {
            candidates.append(file)
        }
        // ~ipad 变体
        if let iconsDict = plist["CFBundleIcons~ipad"] as? [String: Any],
           let primaryIcon = iconsDict["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primaryIcon["CFBundleIconFiles"] as? [String] {
            candidates.append(contentsOf: files)
        }

        // 先一次性枚举 .app 根目录内容并缓存（items）交给候选匹配，避免每个候选
        // 都重新 contentsOfDirectory（候选多 + 大目录时反复全目录 IO）。
        let rootItems: [URL]
        if let items = try? FileManager.default.contentsOfDirectory(
            at: appURL,
            includingPropertiesForKeys: nil
        ) {
            rootItems = items
        } else {
            rootItems = []
        }

        for candidate in candidates {
            if let found = searchIcon(named: candidate, in: appURL, cachedItems: rootItems) {
                return found
            }
        }

        // plist 给出的名字全都匹配不到实际文件（或该应用只有资源目录图标名）：
        // 回退扫描 .app 内的图标形态位图，保证「有独立图标 PNG 就一定显示」。
        return fallbackIcon(in: appURL)
    }

    private func searchIcon(named name: String, in appDir: URL, cachedItems: [URL]) -> String? {
        // 去掉候选名可能带的扩展名（"AppIcon60x60@2x.png" → "AppIcon60x60@2x"），
        // 统一转小写后按前缀匹配实际文件（真实文件形如 AppIcon60x60@2x.png）。
        let base = name
            .replacingOccurrences(of: ".png", with: "")
            .replacingOccurrences(of: ".jpg", with: "")
            .replacingOccurrences(of: ".jpeg", with: "")
            .lowercased()
        guard !base.isEmpty else { return nil }

        // 复用调用方缓存的目录枚举结果，避免每个候选都重新列目录
        let items = cachedItems

        let matched = items
            .filter { item in
                guard ["png", "jpg", "jpeg"].contains(item.pathExtension.lowercased()) else { return false }
                return item.lastPathComponent.lowercased().hasPrefix(base)
            }
            // 高分屏优先：@3x > @2x > 无；同档取文件名更长者
            .sorted { lhs, rhs in
                let l = scaleRank(lhs.lastPathComponent)
                let r = scaleRank(rhs.lastPathComponent)
                if l != r { return l > r }
                return lhs.lastPathComponent.count > rhs.lastPathComponent.count
            }

        return matched.first?.path
    }

    /// 文件名高分屏档位：@3x=3 / @2x=2 / 其余=1
    private func scaleRank(_ fileName: String) -> Int {
        if fileName.contains("@3x") { return 3 }
        if fileName.contains("@2x") { return 2 }
        return 1
    }

    /// plist 图标名全部失效时，递归扫描 .app 内所有位图，用启发式挑最像主图标的那张。
    /// 只认图标形态文件名（AppIcon*/Icon*/icon*/含 "icon"），优先：名称更像图标 > 高分屏 >
    /// 路径更浅 > 文件更大。找不到任何图标形态文件才返回 nil（调用方显示占位图）。
    private func fallbackIcon(in appDir: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(
            at: appDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: URL?
        var bestScore = -1

        while let element = enumerator.nextObject() as? URL {
            let isRegular = (try? element.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
            guard isRegular else { continue }
            let ext = element.pathExtension.lowercased()
            guard ["png", "jpg", "jpeg"].contains(ext) else { continue }

            let fileName = element.lastPathComponent.lowercased()
            let looksLikeIcon = fileName.hasPrefix("appicon")
                || fileName.hasPrefix("icon")
                || fileName.contains("icon")
            guard looksLikeIcon else { continue }

            var score = 0
            if fileName.hasPrefix("appicon") || fileName.hasPrefix("icon") { score += 100 }
            if fileName.contains("icon") { score += 10 }
            score += scaleRank(element.lastPathComponent) * 10
            // 路径越浅越可能是主图标（.app 根目录 > 子目录）：相对 appDir 的层数
            let depth = element.pathComponents.count - appDir.pathComponents.count
            score += max(0, 10 - depth)
            let size = (try? element.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            score += size > 0 ? min(Int(size) / 10_000, 100) : 0

            if score > bestScore {
                bestScore = score
                best = element
            }
        }

        return best?.path
    }
}