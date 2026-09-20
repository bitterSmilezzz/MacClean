import Foundation

// MARK: - 终端与命令行开发缓存治理扫描引擎 (v1.65.0)

public final class CLICacheScanner {
    public static let shared = CLICacheScanner()

    private init() {}

    /// 危险系统与关键用户文件黑名单（绝不允许清理）
    private static let protectedKeywords = [
        ".npmrc",
        ".zshrc",
        ".bashrc",
        ".bash_profile",
        "config.toml",
        "settings.json",
        ".gitconfig",
        "/System",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin"
    ]

    /// 扫描所有或指定的命令行缓存目录
    public func scan(customPaths: [CLIToolKind: [String]]? = nil) -> CLICacheSummary {
        let fm = FileManager.default
        var items: [CLICacheItem] = []
        var totalSize: Int64 = 0

        let toolsToScan = customPaths != nil ? Array(customPaths!.keys) : CLIToolKind.allCases

        for tool in toolsToScan {
            let pathsToScan = customPaths?[tool] ?? tool.typicalPaths.map { NSString(string: $0).expandingTildeInPath }

            for path in pathsToScan {
                // 安全防线：绝对不扫描系统关键目录
                if path.hasPrefix("/System") || path == "/Library" || path == NSString(string: "~").expandingTildeInPath {
                    continue
                }

                guard fm.fileExists(atPath: path) else { continue }

                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    continue
                }

                let (size, count) = Self.calculateDirectoryStats(at: path)
                if size > 0 && count > 0 {
                    let item = CLICacheItem(
                        id: path,
                        toolKind: tool,
                        title: "\(tool.rawValue)",
                        path: path,
                        size: size,
                        fileCount: count,
                        isSelected: true
                    )
                    items.append(item)
                    totalSize += size
                    // 每个工具只要命中了一个主有效缓存目录即可（避免子目录重复累加）
                    break
                }
            }
        }

        // 按体积降序排序
        let sorted = items.sorted { $0.size > $1.size }

        return CLICacheSummary(
            items: sorted,
            totalSize: totalSize,
            toolCount: sorted.count
        )
    }

    /// 安全清空选中的 CLI 缓存目录子项
    public func clean(
        items: [CLICacheItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            let path = item.path

            // 安全防线 1：系统与核心目录拦截
            if path.hasPrefix("/System") || path == "/Library" || path.hasPrefix("/Applications") || path == NSString(string: "~").expandingTildeInPath {
                errorCount += 1
                continue
            }

            // 安全防线 2：用户全局配置文件保护
            if Self.protectedKeywords.contains(where: { path.contains($0) }) {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

            // 保持缓存根目录存在，只清空其内部子项（避免破坏 CLI 工具的目录结构假设）
            guard let contents = try? fm.contentsOfDirectory(atPath: path) else {
                errorCount += 1
                continue
            }

            var itemCleaned = false
            for child in contents {
                let childPath = (path as NSString).appendingPathComponent(child)
                do {
                    if toTrash {
                        try fm.trashItem(at: URL(fileURLWithPath: childPath), resultingItemURL: nil)
                    } else {
                        try fm.removeItem(atPath: childPath)
                    }
                    itemCleaned = true
                } catch {
                    errorCount += 1
                }
            }

            if itemCleaned {
                cleanedCount += 1
                freedBytes += item.size
            }
        }

        return (cleanedCount, freedBytes, errorCount)
    }

    /// 统计目录内文件大小与文件数
    public static func calculateDirectoryStats(at path: String) -> (size: Int64, fileCount: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var totalSize: Int64 = 0
        var count = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]) else {
                continue
            }
            if values.isDirectory == true {
                continue
            }
            let s = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            totalSize += s
            count += 1
        }

        return (totalSize, count)
    }
}
