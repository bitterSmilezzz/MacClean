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

    /// 归档/清理历史类名
    static let historyCategory = "截图与录屏归档"

    /// "刚刚还在写"的判定窗口：录屏是**边录边写**的 `.mov`，截图完成后也可能仍被
    /// 预览/剪贴板持有。此窗口内的文件既不删也不挪。
    static let inFlightWriteWindow: TimeInterval = 120

    /// 归档选中的截图/录屏文件
    ///
    /// v1.72.0：源与目标都过统一护栏（旧版只有 `hasPrefix("/System")` 字符串检查，
    /// 照片图库、iCloud 与用户白名单全都不设防），体积取**移动前实测**，结果写历史。
    func archive(
        items: [ScreenshotItem],
        targetDirectory: String? = nil,
        strategy: ArchiveStrategy = .byYearMonth,
        journal: ResidueDeletionGate.Journal = .module(categoryName: ScreenshotsOrganizerScanner.historyCategory),
        now: Date = Date()
    ) -> ScreenshotsArchiveResult {
        let fm = FileManager.default
        let baseDir = targetDirectory ?? NSString(string: "~/Pictures/Screenshots_Archive").expandingTildeInPath

        var blocked: [ResidueDeletionGate.Rejection] = []
        var failed: [(name: String, path: String, message: String)] = []
        var archivedCount = 0
        var archivedBytes: Int64 = 0
        var touched: [String] = []

        if let reason = Self.destinationRejection(baseDir) {
            return ScreenshotsArchiveResult(
                archivedCount: 0, archivedBytes: 0,
                rejected: items.map {
                    .make(name:$0.fileName, path: $0.path, reason: reason,
                                   message: "归档目标 \(baseDir) 不在允许位置：\(GovernanceVerdict.rejected(reason).message)")
                },
                failed: [])
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM"

        for item in items {
            guard item.isSelected else {
                blocked.append(.make(name:item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "未勾选，已跳过"))
                continue
            }
            // 源侧护栏：与删除同一套判据
            let verdict = FileSystem.governanceVerdictWithinHome(item.path)
            guard verdict.isAllowed else {
                let reason: GovernanceVerdict.Reason
                if case .rejected(let r) = verdict { reason = r } else { reason = .blockedByBaseGate }
                blocked.append(.make(name:item.fileName, path: item.path, reason: reason, message: verdict.message))
                continue
            }
            let realSrc = FileSystem.normalizePath(FileSystem.realPath(item.path))
            if Self.isInFlight(realSrc, now: now) {
                blocked.append(.make(name:item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "最近 \(Int(Self.inFlightWriteWindow)) 秒内还在被写入（可能正在录屏），未移动"))
                continue
            }

            let subDirName: String
            switch strategy {
            case .byYearMonth:
                subDirName = dateFormatter.string(from: item.modificationDate)
            case .byType:
                subDirName = item.captureType == .screenshot ? "Screenshots" : "Recordings"
            }

            let destFolder = (baseDir as NSString).appendingPathComponent(subDirName)
            let realFolder = FileSystem.normalizePath(FileSystem.realPath(destFolder))
            guard !realFolder.hasPrefix(realSrc + "/") else {
                blocked.append(.make(name:item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "归档目标就在该项内部，拒绝自我嵌套移动"))
                continue
            }
            if !fm.fileExists(atPath: realFolder) {
                do {
                    try fm.createDirectory(atPath: realFolder, withIntermediateDirectories: true)
                } catch {
                    failed.append((item.fileName, item.path, "无法创建归档目录：\(error.localizedDescription)"))
                    continue
                }
            }

            var destPath = (realFolder as NSString).appendingPathComponent(item.fileName)
            if fm.fileExists(atPath: destPath) {
                let ext = (item.fileName as NSString).pathExtension
                let base = (item.fileName as NSString).deletingPathExtension
                let suffix = UUID().uuidString.prefix(6)
                let uniqueName = ext.isEmpty ? "\(base)_\(suffix)" : "\(base)_\(suffix).\(ext)"
                destPath = (realFolder as NSString).appendingPathComponent(uniqueName)
            }

            let actual = FileSystem.size(at: realSrc)   // 移动前实测
            do {
                try fm.moveItem(atPath: realSrc, toPath: destPath)
                archivedCount += 1
                archivedBytes += actual
                touched.append(contentsOf: [realSrc, destPath])
            } catch {
                failed.append((item.fileName, item.path, "移动失败：\(error.localizedDescription)"))
            }
        }

        FileSystem.invalidateMeasurements(for: touched)
        if case .module(let categoryName) = journal, archivedCount > 0 {
            Self.recordArchiveMove(categoryName: categoryName, count: archivedCount, failures: blocked.count + failed.count)
        }
        return ScreenshotsArchiveResult(archivedCount: archivedCount, archivedBytes: archivedBytes,
                                        rejected: blocked, failed: failed)
    }

    /// 安全清理或移入废纸篓（统一网关：G8/G6/白名单/软链/权限 + 删除前实测 + 写历史）
    func clean(
        items: [ScreenshotItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: ScreenshotsOrganizerScanner.historyCategory),
        now: Date = Date()
    ) -> ScreenshotsCleanResult {
        var candidates: [ResidueDeletionGate.Candidate] = []
        var blocked: [ResidueDeletionGate.Rejection] = []

        for item in items {
            guard item.isSelected else {
                blocked.append(.make(name:item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "未勾选，已跳过"))
                continue
            }
            candidates.append(ResidueDeletionGate.Candidate(item.fileName, path: item.path))
        }

        // 模块预筛的拦截项与网关结果合成一份完整结论（合并实现只有一份）
        return ScreenshotsCleanResult(outcome: ResidueDeletionGate.Outcome(rejected: blocked)
            .merging(ResidueDeletionGate.execute(
                candidates, toTrash: toTrash, journal: journal
            ) { candidate in
                guard !Self.isInFlight(FileSystem.normalizePath(FileSystem.realPath(candidate.path)), now: now) else {
                    return .make(candidate, reason: .inUse,
                                 message: "截图文件刚刚还在被写入（保护窗口 \(Int(Self.inFlightWriteWindow)) 秒内），未删除")
                }
                return nil
            }))
    }

    /// 文件是否"刚刚还在被写"（mtime 落在保护窗口内）。mtime 读不到时按"在用"处理。
    static func isInFlight(_ realPath: String, now: Date) -> Bool {
        guard let mtime = FileSystem.modificationDate(realPath) else { return true }
        return now.timeIntervalSince(mtime) < inFlightWriteWindow
    }

    /// 归档目标是否落在禁止位置。
    static func destinationRejection(_ targetDirectory: String) -> GovernanceVerdict.Reason? {
        if targetDirectory.isEmpty { return .emptyPath }
        let real = FileSystem.normalizePath(FileSystem.realPath(targetDirectory))
        guard real != "/" else { return .resolvesToRoot }
        if let blocked = FileSystem.coreGuardVerdict(real), blocked != .userWhitelisted { return blocked }
        let home = FileSystem.normalizePath(NSHomeDirectory())
        if real == home || real.hasPrefix(home + "/") { return nil }
        for root in ["/tmp", "/var/tmp"] where real.hasPrefix(root + "/") { return nil }
        return .outsideDomain
    }

    /// 归档移动写历史：bytes 记 0（同宗卷移动不释放空间），只留"挪了多少项"的痕迹。
    static func recordArchiveMove(categoryName: String, count: Int, failures: Int) {
        var records = HistoryStore.load()
        records.insert(CleanRecord(id: UUID(), date: Date(), categoryName: categoryName,
                                   itemCount: count, bytes: 0, mode: "归档移动", failures: failures), at: 0)
        HistoryStore.save(records)
    }
}
