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

    // MARK: - 清理与归档（v1.72.0 安全加固）

    /// 疑似"还在下载中"的写入窗口：此时间内被写过的安装包/压缩包不动。
    static let inFlightWriteWindow: TimeInterval = 300

    /// 清理历史类名
    static let historyCategory = "下载目录归档"

    /// 执行安全清理（移入废纸篓或删除）。
    ///
    /// 全部交给统一删除网关：软链防跳板 → G8 → G6 → 用户白名单 → 主目录护栏 → 真实权限；
    /// 释放量取**删除前实测**（旧版直接累加扫描缓存的 `item.size`，
    /// 文件早在用户手动删过或已被改大时也照报），并写历史记录。
    func clean(
        items: [DownloadItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: DownloadsOrganizerScanner.historyCategory),
        now: Date = Date()
    ) -> DownloadsCleanResult {
        var candidates: [ResidueDeletionGate.Candidate] = []
        var blocked: [ResidueDeletionGate.Rejection] = []
        /// 真实路径 → 是否属于"可能还在下载"的类型
        var watchInFlight: Set<String> = []

        for item in items {
            guard item.isSelected else {
                blocked.append(Self.rejection(item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "未勾选，已跳过"))
                continue
            }
            guard FileSystem.exists(item.path) else {
                blocked.append(Self.rejection(item.fileName, path: item.path, reason: .missing,
                                              message: GovernanceVerdict.rejected(.missing).message))
                continue
            }
            candidates.append(ResidueDeletionGate.Candidate(item.fileName, path: item.path))
            if item.kind == .installer || item.kind == .archive {
                watchInFlight.insert(FileSystem.normalizePath(FileSystem.realPath(item.path)))
            }
        }

        let outcome = ResidueDeletionGate.execute(
            candidates, toTrash: toTrash, journal: journal
        ) { candidate in
            let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))
            guard watchInFlight.contains(real) else { return nil }
            // 刚被写过的安装包/压缩包 → 可能正在下载，删了就是毁一次下载
            guard let mtime = FileSystem.modificationDate(real) else { return .missing }
            return now.timeIntervalSince(mtime) < Self.inFlightWriteWindow
                ? GovernanceVerdict.Reason.blockedByBaseGate : nil
        }
        var merged = outcome
        merged.rejected.append(contentsOf: blocked)
        return DownloadsCleanResult(outcome: merged)
    }

    /// 执行智能归档整理（将选定文件归档移动到指定子目录）。
    ///
    /// 移动不是删除，但同样要有护栏与依据：
    /// ① 源路径过网关同款核心护栏（受保护/硬排除/白名单位置里的文件不许被挪走）；
    /// ② 目标目录必须落在主目录或临时目录内，且不得是被保护位置、不得在源内部；
    /// ③ 记账取**移动前实测**体积，跨宗卷移动才是真释放，同宗卷只算"已移动"；
    /// ④ 结果写历史（bytes 记 0，避免把移动谎报成释放）。
    func archive(
        items: [DownloadItem],
        targetDirectory: String,
        journal: ResidueDeletionGate.Journal = .module(categoryName: DownloadsOrganizerScanner.historyCategory),
        now: Date = Date()
    ) -> DownloadsArchiveResult {
        let fm = FileManager.default
        var blocked: [ResidueDeletionGate.Rejection] = []
        var failed: [(name: String, path: String, message: String)] = []
        var moved = 0
        var movedBytes: Int64 = 0
        var movedPaths: [String] = []

        // 目标目录护栏：拒绝受保护/硬排除位置
        if let reason = Self.destinationRejection(targetDirectory) {
            return DownloadsArchiveResult(movedCount: 0, movedBytes: 0,
                                          rejected: items.map {
                                              Self.rejection($0.fileName, path: $0.path, reason: reason,
                                                             message: "归档目标 \(targetDirectory) 不在允许位置：\(GovernanceVerdict.rejected(reason).message)")
                                          },
                                          failed: [])
        }

        let realDest = FileSystem.normalizePath(FileSystem.realPath(targetDirectory))
        if !fm.fileExists(atPath: realDest) {
            do {
                try fm.createDirectory(atPath: realDest, withIntermediateDirectories: true)
            } catch {
                return DownloadsArchiveResult(movedCount: 0, movedBytes: 0, rejected: [],
                                              failed: items.map {
                                                  ($0.fileName, $0.path, "无法创建归档目录：\(error.localizedDescription)")
                                              })
            }
        }

        for item in items {
            guard item.isSelected else {
                blocked.append(Self.rejection(item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "未勾选，已跳过"))
                continue
            }
            // 源侧护栏：与删除同一套判据（挪不走的东西也不该被挪走）
            let verdict = FileSystem.governanceVerdictWithinHome(item.path)
            guard verdict.isAllowed else {
                let reason: GovernanceVerdict.Reason
                if case .rejected(let r) = verdict { reason = r } else { reason = .blockedByBaseGate }
                blocked.append(Self.rejection(item.fileName, path: item.path, reason: reason, message: verdict.message))
                continue
            }
            let realSrc = FileSystem.normalizePath(FileSystem.realPath(item.path))
            guard realSrc != realDest, !realDest.hasPrefix(realSrc + "/") else {
                blocked.append(Self.rejection(item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "归档目标就在该项内部，拒绝自我嵌套移动"))
                continue
            }
            if item.kind == .installer || item.kind == .archive,
               let mtime = FileSystem.modificationDate(realSrc),
               now.timeIntervalSince(mtime) < Self.inFlightWriteWindow {
                blocked.append(Self.rejection(item.fileName, path: item.path, reason: .blockedByBaseGate,
                                              message: "疑似仍在下载（\(Int(now.timeIntervalSince(mtime))) 秒前刚被写入），未移动"))
                continue
            }

            var destPath = (realDest as NSString).appendingPathComponent(item.fileName)
            if fm.fileExists(atPath: destPath) {
                let ext = (item.fileName as NSString).pathExtension
                let base = (item.fileName as NSString).deletingPathExtension
                let uniqueName = ext.isEmpty ? "\(base)_\(UUID().uuidString.prefix(6))" : "\(base)_\(UUID().uuidString.prefix(6)).\(ext)"
                destPath = (realDest as NSString).appendingPathComponent(uniqueName)
            }

            // 移动前实测体积（旧版沿用扫描缓存）
            let actual = FileSystem.size(at: realSrc)
            do {
                try fm.moveItem(atPath: realSrc, toPath: destPath)
                moved += 1
                movedBytes += actual
                movedPaths.append(realSrc)
                FileSystem.invalidateMeasurements(for: [realSrc, destPath])
            } catch {
                failed.append((item.fileName, item.path, "移动失败：\(error.localizedDescription)"))
            }
        }

        if case .module(let categoryName) = journal, moved > 0 {
            Self.recordArchiveMove(categoryName: categoryName, count: moved, failures: blocked.count)
        }
        FileSystem.invalidateMeasurements(for: movedPaths)
        return DownloadsArchiveResult(movedCount: moved, movedBytes: movedBytes,
                                      rejected: blocked, failed: failed)
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

    static func rejection(_ name: String, path: String, reason: GovernanceVerdict.Reason,
                          message: String) -> ResidueDeletionGate.Rejection {
        ResidueDeletionGate.Rejection(name: name, path: path, reason: reason, message: message)
    }
}
