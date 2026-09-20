import Foundation

// MARK: - 屏幕截图与录屏归档引擎 (v1.64.0)

public final class ScreenshotsOrganizerScanner {
    public static let shared = ScreenshotsOrganizerScanner()

    private init() {}

    /// 判定文件是否为屏幕截图或录屏
    public static func detectCaptureType(fileName: String) -> CaptureType? {
        let lower = fileName.lowercased()
        let ext = (fileName as NSString).pathExtension.lowercased()

        // 录屏扩展名与命名匹配
        let recordingExtensions = ["mov", "mp4", "m4v"]
        if recordingExtensions.contains(ext) {
            if lower.contains("screen recording") ||
               lower.contains("screen_recording") ||
               fileName.contains("屏幕录制") ||
               fileName.contains("录屏") ||
               lower.contains("cleanshot") ||
               lower.contains("kap") ||
               lower.contains("record") {
                return .recording
            }
        }

        // 截图扩展名与命名匹配
        let screenshotExtensions = ["png", "jpg", "jpeg", "heic", "tiff"]
        if screenshotExtensions.contains(ext) {
            if lower.contains("screen shot") ||
               lower.contains("screenshot") ||
               fileName.contains("截屏") ||
               fileName.contains("屏幕快照") ||
               lower.contains("cleanshot") ||
               lower.contains("shottr") ||
               lower.contains("snipaste") {
                return .screenshot
            }
        }

        return nil
    }

    /// 扫描指定目录列表（默认为桌面、下载与图片目录）
    public func scan(directories: [String]? = nil) -> ScreenshotsSummary {
        let fm = FileManager.default
        let defaultPaths = [
            NSString(string: "~/Desktop").expandingTildeInPath,
            NSString(string: "~/Downloads").expandingTildeInPath,
            NSString(string: "~/Pictures").expandingTildeInPath
        ]

        let searchPaths = directories ?? defaultPaths
        var allItems: [ScreenshotItem] = []
        let now = Date()

        for dirPath in searchPaths {
            // 安全防线：绝对不扫描系统关键目录
            if dirPath.hasPrefix("/System") || dirPath == "/Library" || dirPath.hasPrefix("/Applications") {
                continue
            }

            guard fm.fileExists(atPath: dirPath) else { continue }

            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .totalFileAllocatedSizeKey],
                options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                let fileName = fileURL.lastPathComponent

                // 排除由本工具归档的目录与系统隐蔽文件
                if fileName.hasPrefix("Screenshots_Archive") || fileName.hasPrefix("Archived_") || fileName.hasPrefix(".") {
                    continue
                }

                guard let type = Self.detectCaptureType(fileName: fileName) else {
                    continue
                }

                guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .totalFileAllocatedSizeKey
                ]) else { continue }

                // 忽略目录
                if resourceValues.isDirectory == true {
                    continue
                }

                let mtime = resourceValues.contentModificationDate ?? Date.distantPast
                let ageDays = max(0, Calendar.current.dateComponents([.day], from: mtime, to: now).day ?? 0)
                let size = Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.fileSize ?? 0)

                var item = ScreenshotItem(
                    id: path,
                    fileName: fileName,
                    path: path,
                    size: size,
                    captureType: type,
                    modificationDate: mtime,
                    ageDays: ageDays,
                    isSelected: false
                )

                if item.isHighRiskStale {
                    item.isSelected = true
                }

                allItems.append(item)
            }
        }

        // 统计汇总
        var totalSize: Int64 = 0
        var screenshotSize: Int64 = 0
        var screenshotCount = 0
        var recordingSize: Int64 = 0
        var recordingCount = 0
        var staleSize: Int64 = 0
        var staleCount = 0

        for item in allItems {
            totalSize += item.size
            if item.captureType == .screenshot {
                screenshotSize += item.size
                screenshotCount += 1
            } else {
                recordingSize += item.size
                recordingCount += 1
            }

            if item.ageDays >= 30 {
                staleSize += item.size
                staleCount += 1
            }
        }

        // 按文件大小降序排序（录屏大文件优先置顶）
        let sorted = allItems.sorted { $0.size > $1.size }

        return ScreenshotsSummary(
            items: sorted,
            totalSize: totalSize,
            screenshotSize: screenshotSize,
            screenshotCount: screenshotCount,
            recordingSize: recordingSize,
            recordingCount: recordingCount,
            staleSize: staleSize,
            staleCount: staleCount
        )
    }

    /// 归档选中的截图/录屏文件
    public func archive(
        items: [ScreenshotItem],
        targetDirectory: String? = nil,
        strategy: ArchiveStrategy = .byYearMonth
    ) -> (archivedCount: Int, archivedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        let baseDir = targetDirectory ?? NSString(string: "~/Pictures/Screenshots_Archive").expandingTildeInPath

        // 安全防线
        if baseDir.hasPrefix("/System") || baseDir == "/Library" || baseDir.hasPrefix("/Applications") {
            return (0, 0, items.count)
        }

        var archivedCount = 0
        var archivedBytes: Int64 = 0
        var errorCount = 0

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM"

        for item in items {
            // 安全防线
            if item.path.hasPrefix("/System") || item.path.hasPrefix("/Library") {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: item.path) else { continue }

            let subDirName: String
            switch strategy {
            case .byYearMonth:
                subDirName = dateFormatter.string(from: item.modificationDate)
            case .byType:
                subDirName = item.captureType == .screenshot ? "Screenshots" : "Recordings"
            }

            let destFolder = (baseDir as NSString).appendingPathComponent(subDirName)
            if !fm.fileExists(atPath: destFolder) {
                do {
                    try fm.createDirectory(atPath: destFolder, withIntermediateDirectories: true)
                } catch {
                    errorCount += 1
                    continue
                }
            }

            var destPath = (destFolder as NSString).appendingPathComponent(item.fileName)
            if fm.fileExists(atPath: destPath) {
                let ext = (item.fileName as NSString).pathExtension
                let base = (item.fileName as NSString).deletingPathExtension
                let suffix = UUID().uuidString.prefix(6)
                let uniqueName = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
                destPath = (destFolder as NSString).appendingPathComponent(uniqueName)
            }

            do {
                try fm.moveItem(atPath: item.path, toPath: destPath)
                archivedCount += 1
                archivedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (archivedCount, archivedBytes, errorCount)
    }

    /// 安全清理或移入废纸篓
    public func clean(
        items: [ScreenshotItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
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
}
