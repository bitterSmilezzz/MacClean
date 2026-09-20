import Foundation

// MARK: - 访达快速查看（QuickLook）缩略图缓存释放引擎 (v1.66.0)

public final class QuickLookThumbnailPurger {
    public static let shared = QuickLookThumbnailPurger()

    private init() {}

    /// 获取当前 macOS 系统用户的 Darwin 缓存根目录
    public static func getDarwinUserCacheDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        if len > 0 {
            return String(cString: buffer)
        }
        // 兜底策略：由 NSTemporaryDirectory() 向上推导 (通常为 /var/folders/xx/xxxx/T/ -> /var/folders/xx/xxxx/C/)
        let tempDir = NSTemporaryDirectory()
        let parent = (tempDir as NSString).deletingLastPathComponent
        let cDir = (parent as NSString).appendingPathComponent("C")
        if FileManager.default.fileExists(atPath: cDir) {
            return cDir
        }
        return nil
    }

    /// 扫描 QuickLook 缩略图数据库与生成缓存
    public func scan(customDirectories: [String]? = nil) -> QuickLookThumbnailSummary {
        let fm = FileManager.default
        var candidatePaths: [(path: String, kind: QuickLookCacheKind, title: String)] = []

        if let custom = customDirectories {
            for p in custom {
                candidatePaths.append((p, .thumbnailDatabase, "测试缩略图数据库"))
            }
        } else {
            // 系统动态缓存目录
            if let darwinCache = Self.getDarwinUserCacheDir() {
                let p1 = (darwinCache as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
                candidatePaths.append((p1, .thumbnailDatabase, "系统级 QuickLook 缩略图数据库"))

                let p2 = (darwinCache as NSString).appendingPathComponent("com.apple.QuickLookUIFramework.QLPreviewGenerationExtension")
                candidatePaths.append((p2, .previewExtensionCache, "预览生成扩展渲染缓存"))

                let p3 = (darwinCache as NSString).appendingPathComponent("com.apple.quicklook.QuickLookUIService")
                candidatePaths.append((p3, .uiServiceCache, "QuickLook UI 服务临时缓存"))
            }

            // 用户个人缓存目录
            let userCaches = NSString(string: "~/Library/Caches").expandingTildeInPath
            let u1 = (userCaches as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            candidatePaths.append((u1, .thumbnailDatabase, "用户级 QuickLook 缩略图数据库"))

            let u2 = (userCaches as NSString).appendingPathComponent("com.apple.quicklook.ui.helper")
            candidatePaths.append((u2, .userQuickLookCache, "QuickLook UI 辅助组件缓存"))
        }

        var items: [QuickLookCacheItem] = []
        var totalSize: Int64 = 0

        for candidate in candidatePaths {
            let path = candidate.path

            // 安全防线：绝对不扫描系统关键目录
            if path.hasPrefix("/System") || path == "/Library" || path == NSString(string: "~").expandingTildeInPath {
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

            let (size, count) = CLICacheScanner.calculateDirectoryStats(at: path)
            if size > 0 && count > 0 {
                let item = QuickLookCacheItem(
                    id: path,
                    kind: candidate.kind,
                    title: candidate.title,
                    path: path,
                    size: size,
                    fileCount: count,
                    isSelected: true
                )
                items.append(item)
                totalSize += size
            }
        }

        let sorted = items.sorted { $0.size > $1.size }

        return QuickLookThumbnailSummary(
            items: sorted,
            totalSize: totalSize
        )
    }

    /// 安全清空选中的 QuickLook 缓存并重置系统缩略图数据库
    public func purge(
        items: [QuickLookCacheItem],
        resetSystemCache: Bool = true
    ) -> (purgedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var purgedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            let path = item.path

            // 安全防线 1：系统目录与主目录拦截
            if path.hasPrefix("/System") || path == "/Library" || path.hasPrefix("/Applications") || path == NSString(string: "~").expandingTildeInPath {
                errorCount += 1
                continue
            }

            // 安全防线 2：必须明确包含 quicklook 关键字（大小写不敏感）
            let lower = path.lowercased()
            if !lower.contains("quicklook") {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

            guard let children = try? fm.contentsOfDirectory(atPath: path) else {
                errorCount += 1
                continue
            }

            var itemCleaned = false
            for child in children {
                let childPath = (path as NSString).appendingPathComponent(child)
                do {
                    try fm.removeItem(atPath: childPath)
                    itemCleaned = true
                } catch {
                    errorCount += 1
                }
            }

            if itemCleaned {
                purgedCount += 1
                freedBytes += item.size
            }
        }

        // 调用系统内置 qlmanage 工具重置 QuickLook 缓存与守护进程
        if resetSystemCache {
            Self.executeQLManageReset()
        }

        return (purgedCount, freedBytes, errorCount)
    }

    /// 执行系统级 qlmanage 重置命令
    public static func executeQLManageReset() {
        let p1 = Process()
        p1.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p1.arguments = ["-r", "cache"]
        try? p1.run()
        p1.waitUntilExit()

        let p2 = Process()
        p2.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        p2.arguments = ["-r"]
        try? p2.run()
        p2.waitUntilExit()
    }
}
