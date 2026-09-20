import Foundation
import AppKit

// MARK: - Spotlight 废弃索引与搜索数据库深度重建治理引擎 (v1.69.0)

public final class SpotlightScanner {
    public static let shared = SpotlightScanner()

    private init() {}

    /// Apple 官方核心服务 Bundle ID 前缀白名单（受保护）
    public static let appleCorePrefixes: Set<String> = [
        "com.apple.",
        "apple.",
        "system."
    ]

    /// 获取本地所有已安装应用的 Bundle Identifier 集合
    public static func getInstalledBundleIDs() -> Set<String> {
        var bundleIDs = Set<String>()
        let appDirs = [
            "/Applications",
            "/System/Applications",
            NSString(string: "~/Applications").expandingTildeInPath
        ]

        let fm = FileManager.default
        for appDir in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: appDir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = (appDir as NSString).appendingPathComponent(item)
                if let bundle = Bundle(path: fullPath), let bid = bundle.bundleIdentifier {
                    bundleIDs.insert(bid.lowercased())
                }
            }
        }
        return bundleIDs
    }

    /// 扫描指定目录或系统默认 Spotlight 存储库
    public func scan(
        customCoreSpotlightDir: String? = nil,
        customCacheDir: String? = nil,
        customVolumeDirs: [String]? = nil
    ) -> SpotlightSummary {
        let fm = FileManager.default
        let installedBIDs = Self.getInstalledBundleIDs()

        var items: [SpotlightStoreItem] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0

        // 1. 扫描 CoreSpotlight 用户索引 (~/Library/Metadata/CoreSpotlight)
        let coreSpotlightPath = customCoreSpotlightDir ?? NSString(string: "~/Library/Metadata/CoreSpotlight").expandingTildeInPath
        if fm.fileExists(atPath: coreSpotlightPath) {
            if let subdirs = try? fm.contentsOfDirectory(atPath: coreSpotlightPath) {
                for sub in subdirs {
                    guard !sub.hasPrefix(".") else { continue }
                    let subPath = (coreSpotlightPath as NSString).appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: subPath, isDirectory: &isDir) else { continue }

                    let (dirSize, fileCount, mtime) = calculateDirectoryMetrics(at: subPath)
                    guard dirSize > 0 || fileCount > 0 else { continue }

                    let (kind, status) = Self.evaluateCoreSpotlightEntry(name: sub, path: subPath, installedBIDs: installedBIDs)

                    let isOrphan = status.isOrphanOrCorrupted
                    if isOrphan {
                        orphanCount += 1
                        orphanSize += dirSize
                    } else if status == .activeHealthy {
                        activeCount += 1
                    }

                    let item = SpotlightStoreItem(
                        id: subPath,
                        name: sub,
                        path: subPath,
                        kind: kind,
                        status: status,
                        size: dirSize,
                        fileCount: fileCount,
                        modificationDate: mtime,
                        isSelected: isOrphan
                    )
                    items.append(item)
                    totalSize += dirSize
                }
            }
        }

        // 2. 扫描 Spotlight 用户搜索缓存 (~/Library/Caches/com.apple.Spotlight)
        let cachePath = customCacheDir ?? NSString(string: "~/Library/Caches/com.apple.Spotlight").expandingTildeInPath
        if fm.fileExists(atPath: cachePath) {
            let (cacheSize, fileCount, mtime) = calculateDirectoryMetrics(at: cachePath)
            if cacheSize > 0 {
                orphanCount += 1
                orphanSize += cacheSize

                let cacheItem = SpotlightStoreItem(
                    id: cachePath,
                    name: "com.apple.Spotlight (搜索临时缓存)",
                    path: cachePath,
                    kind: .spotlightCache,
                    status: .bloatedOrCorrupted,
                    size: cacheSize,
                    fileCount: fileCount,
                    modificationDate: mtime,
                    isSelected: true
                )
                items.append(cacheItem)
                totalSize += cacheSize
            }
        }

        // 3. 扫描磁盘卷根索引库 (.Spotlight-V100)
        let volumeRoots = customVolumeDirs ?? ["/"]
        for volRoot in volumeRoots {
            let spotlightV100 = (volRoot as NSString).appendingPathComponent(".Spotlight-V100")
            if fm.fileExists(atPath: spotlightV100) {
                let isSystemRoot = volRoot == "/"
                let status: SpotlightIndexStatus = isSystemRoot ? .systemProtected : .activeHealthy
                let (volSize, fileCount, mtime) = calculateDirectoryMetrics(at: spotlightV100)

                if status == .activeHealthy {
                    activeCount += 1
                }

                let volItem = SpotlightStoreItem(
                    id: spotlightV100,
                    name: isSystemRoot ? "系统根卷 Spotlight 索引库 (/)" : "卷索引库 (\(volRoot))",
                    path: spotlightV100,
                    kind: .volumeIndex,
                    status: status,
                    size: volSize,
                    fileCount: fileCount,
                    modificationDate: mtime,
                    isSelected: false // 卷索引默认不直接文件删除，推荐 mdutil 重建
                )
                items.append(volItem)
                totalSize += volSize
            }
        }

        // 优先将可清理的孤儿/损坏项排在前面
        let sorted = items.sorted { a, b in
            if a.status.isOrphanOrCorrupted != b.status.isOrphanOrCorrupted {
                return a.status.isOrphanOrCorrupted
            }
            return a.size > b.size
        }

        return SpotlightSummary(
            items: sorted,
            totalSize: totalSize,
            orphanCount: orphanCount,
            orphanSize: orphanSize,
            activeCount: activeCount
        )
    }

    /// 评估 CoreSpotlight 子项的状态与归属
    public static func evaluateCoreSpotlightEntry(
        name: String,
        path: String,
        installedBIDs: Set<String>
    ) -> (kind: SpotlightStoreKind, status: SpotlightIndexStatus) {
        let lower = name.lowercased()

        // 1. 系统核心服务前缀保护
        for prefix in appleCorePrefixes {
            if lower.hasPrefix(prefix) {
                return (.coreSpotlightIndex, .activeHealthy)
            }
        }

        // 2. 匹配当前已安装应用 Bundle ID
        if installedBIDs.contains(lower) {
            return (.coreSpotlightIndex, .activeHealthy)
        }

        // 3. 未安装的第三方应用残留
        return (.coreSpotlightIndex, .orphanAppResidue)
    }

    /// 清理选中的 Spotlight 孤儿索引与缓存
    public func clean(
        items: [SpotlightStoreItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            let path = item.path

            // 安全防线 1：系统核心目录与系统受保护项绝对拦截
            if path == "/" || path == "/.Spotlight-V100" || item.status == .systemProtected {
                errorCount += 1
                continue
            }

            // 安全防线 2：仅允许清理 CoreSpotlight 孤儿项与 Spotlight 缓存
            guard item.status.isOrphanOrCorrupted else {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

            do {
                if toTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: path)
                }
                cleanedCount += 1
                freedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (cleanedCount, freedBytes, errorCount)
    }

    /// 调用系统标准 mdutil 工具擦除并重建指定卷的 Spotlight 索引
    public func rebuildVolumeIndex(volumePath: String = "/") -> (success: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        process.arguments = ["-E", volumePath]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return (true, "已成功向系统发送 Spotlight 索引重建指令（\(volumePath)）: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                return (false, "重建指令执行返回码 \(process.terminationStatus): \(output.trimmingCharacters(in: .whitespacesAndNewlines))。可能需要管理员权限。")
            }
        } catch {
            return (false, "启动 mdutil 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 辅助：递归统计目录指标
    private func calculateDirectoryMetrics(at path: String) -> (size: Int64, fileCount: Int, modificationDate: Date) {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        var fileCount = 0
        var latestMTime = Date.distantPast

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0, latestMTime)
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
                continue
            }

            if values.isDirectory == false {
                totalSize += Int64(values.fileSize ?? 0)
                fileCount += 1
            }
            if let mtime = values.contentModificationDate, mtime > latestMTime {
                latestMTime = mtime
            }
        }

        return (totalSize, fileCount, latestMTime)
    }
}
