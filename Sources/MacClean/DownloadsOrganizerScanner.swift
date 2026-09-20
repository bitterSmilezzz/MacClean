import Foundation

// MARK: - 下载目录智能时效归档与治理扫描引擎 (v1.62.0)

public final class DownloadsOrganizerScanner {
    public static let shared = DownloadsOrganizerScanner()

    private init() {}

    /// 扫描指定的下载目录（默认 ~/Downloads）
    public func scan(customDirectory: String? = nil) -> DownloadsSummary {
        let downloadsPath = customDirectory ?? NSString(string: "~/Downloads").expandingTildeInPath
        let fm = FileManager.default

        // 安全防线：绝对不扫描系统目录
        if downloadsPath.hasPrefix("/System") || downloadsPath == "/Library" {
            return DownloadsSummary()
        }

        guard fm.fileExists(atPath: downloadsPath) else {
            return DownloadsSummary()
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: downloadsPath),
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else {
            return DownloadsSummary()
        }

        var items: [DownloadItem] = []
        let now = Date()

        for case let fileURL as URL in enumerator {
            let path = fileURL.path
            let fileName = fileURL.lastPathComponent

            // 忽略由本工具创建的归档分类文件夹
            if fileName.hasPrefix("Archived_") || fileName.hasPrefix(".") {
                continue
            }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isPackageKey,
                .contentModificationDateKey,
                .fileSizeKey,
                .totalFileAllocatedSizeKey
            ]) else { continue }

            let isDirectory = resourceValues.isDirectory ?? false
            let isPackage = resourceValues.isPackage ?? false

            // 如果是普通目录且不是包（如 .app、.pkg），跳过或视情况统计，避免深入误删用户子文件夹
            if isDirectory && !isPackage && !fileName.hasSuffix(".app") {
                continue
            }

            let mtime = resourceValues.contentModificationDate ?? Date.distantPast
            let ageDays = max(0, Calendar.current.dateComponents([.day], from: mtime, to: now).day ?? 0)

            let size: Int64
            if isDirectory {
                size = AppLocalizationScanner.directorySize(at: path)
            } else {
                size = Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileSize ?? 0)
            }

            let kind = DownloadItemKind.from(path: path)
            let item = DownloadItem(
                id: path,
                fileName: fileName,
                path: path,
                size: size,
                kind: kind,
                modificationDate: mtime,
                ageDays: ageDays,
                isSelected: false
            )

            var configuredItem = item
            if item.isHighlyRecommendedToClean {
                configuredItem.isSelected = true
            }

            items.append(configuredItem)
        }

        // 统计指标
        var totalSize: Int64 = 0
        var installerSize: Int64 = 0
        var installerCount: Int = 0
        var archiveSize: Int64 = 0
        var archiveCount: Int = 0
        var staleSize: Int64 = 0
        var staleCount: Int = 0

        for item in items {
            totalSize += item.size
            if item.kind == .installer {
                installerSize += item.size
                installerCount += 1
            } else if item.kind == .archive {
                archiveSize += item.size
                archiveCount += 1
            }

            if item.ageDays >= 30 {
                staleSize += item.size
                staleCount += 1
            }
        }

        // 默认按大小降序排序
        let sorted = items.sorted { $0.size > $1.size }

        return DownloadsSummary(
            items: sorted,
            totalSize: totalSize,
            installerSize: installerSize,
            installerCount: installerCount,
            archiveSize: archiveSize,
            archiveCount: archiveCount,
            staleSize: staleSize,
            staleCount: staleCount
        )
    }

    /// 执行安全清理（移入废纸篓或删除）
    public func clean(
        items: [DownloadItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            // 安全防线：严禁删除系统目录
            if item.path.hasPrefix("/System") || item.path.hasPrefix("/Library") {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: item.path) else { continue }

            do {
                if toTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: item.path)
                }
                cleanedCount += 1
                freedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (cleanedCount, freedBytes, errorCount)
    }

    /// 执行智能归档整理（将选定文件归档移动到指定子目录）
    public func archive(
        items: [DownloadItem],
        targetDirectory: String
    ) -> (movedCount: Int, errorCount: Int) {
        let fm = FileManager.default
        var movedCount = 0
        var errorCount = 0

        // 安全防线：目标目录严禁为系统目录
        if targetDirectory.hasPrefix("/System") || targetDirectory == "/Library" {
            return (0, items.count)
        }

        // 确保目标目录存在
        if !fm.fileExists(atPath: targetDirectory) {
            do {
                try fm.createDirectory(atPath: targetDirectory, withIntermediateDirectories: true)
            } catch {
                return (0, items.count)
            }
        }

        for item in items {
            guard fm.fileExists(atPath: item.path) else { continue }

            var destPath = (targetDirectory as NSString).appendingPathComponent(item.fileName)
            // 解决重名冲突
            if fm.fileExists(atPath: destPath) {
                let ext = (item.fileName as NSString).pathExtension
                let base = (item.fileName as NSString).deletingPathExtension
                let uniqueName = ext.isEmpty ? "\(base)_\(UUID().uuidString.prefix(6))" : "\(base)_\(UUID().uuidString.prefix(6)).\(ext)"
                destPath = (targetDirectory as NSString).appendingPathComponent(uniqueName)
            }

            do {
                try fm.moveItem(atPath: item.path, toPath: destPath)
                movedCount += 1
            } catch {
                errorCount += 1
            }
        }

        return (movedCount, errorCount)
    }
}
