import Foundation
import Darwin

// MARK: - 硬链接 / 写时复制去重结果

struct HardlinkDedupResult: Equatable {
    var succeededCount: Int = 0
    var freedBytes: Int64 = 0
    var skippedCount: Int = 0
    var failures: [String] = []

    /// 被**安全护栏拒绝**的项（受保护位置 / G6 用户数据 / 云盘 / 照片库）
    var rejections: [String] = []
    /// 稳定性判据不满足而跳过的项（文件已变化、疑似正在被写、nlink 复核不过）
    var stabilitySkips: [String] = []

    init(succeededCount: Int = 0, freedBytes: Int64 = 0, skippedCount: Int = 0, failures: [String] = [],
         rejections: [String] = [], stabilitySkips: [String] = []) {
        self.succeededCount = succeededCount
        self.freedBytes = freedBytes
        self.skippedCount = skippedCount
        self.failures = failures
        self.rejections = rejections
        self.stabilitySkips = stabilitySkips
    }

    /// 未成功处理的项总数（拒绝 + 跳过 + 失败），用于"绝不把失败计成已释放"的核对
    var notDoneCount: Int { rejections.count + stabilitySkips.count + failures.count }

    var summaryText: String {
        var parts: [String] = []
        if succeededCount > 0 {
            parts.append("成功无损硬链接去重 \(succeededCount) 个副本，释放物理空间 \(freedBytes.byteStringCN)")
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) 项已是硬链接已跳过")
        }
        if !stabilitySkips.isEmpty {
            parts.append("\(stabilitySkips.count) 项文件已变化或疑似在用，跳过去重")
        }
        if !rejections.isEmpty {
            parts.append("\(rejections.count) 项位于受保护位置，拒绝链接")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) 项去重失败")
        }
        return parts.isEmpty ? "没有可去重的项目" : parts.joined(separator: "，")
    }
}

// MARK: - 执行前指纹（v1.72.0 安全加固）

/// 一次 inode 级操作**唯一**可依赖的文件身份快照。
///
/// 旧版只比 `st_size` 就敢 `rename()` 覆盖目标目录项——而 `.exact` 结论来自
/// **上一轮扫描**。扫描与执行之间用户可能已经改写了副本，或被某进程持续写入：
/// `rename` 换掉 inode 之后，那个进程后续写入全部静默落到已成孤儿的旧 inode 上，
/// 用户看到的就是"文件没变、内容丢了"。
struct DedupFingerprint: Equatable {
    /// `设备号:inode`
    let inodeKey: String
    let size: Int64
    let mtime: Date
    /// 链接数；扫描阶段拿不到时为 nil（`DuplicateFileItem` 未记录）
    var nlink: Int?

    /// 与另一份指纹是否指向"同一份未被改动过的内容"。
    ///
    /// mtime 用 1 秒容差比对：扫描侧走 `URLResourceKey.contentModificationDateKey`、
    /// 执行侧走 `lstat.st_mtimespec`，两者亚秒精度口径不同；
    /// 真正被改写过的文件不可能落在 1 秒内还不改大小和 inode。
    func matches(_ other: DedupFingerprint?, tolerance: TimeInterval = 1) -> Bool {
        guard let other else { return false }
        guard inodeKey == other.inodeKey, size == other.size else { return false }
        if let a = nlink, let b = other.nlink, a != b { return false }
        return abs(mtime.timeIntervalSince(other.mtime)) <= tolerance
    }
}

// MARK: - APFS 硬链接 / 写时复制克隆无损去重引擎

enum HardlinkDedupService {

    /// 单对去重的完整结论（对外仍保留旧的 `(succeeded, freedBytes)` 形状）
    struct DedupOutcome: Equatable {
        enum Status: Equatable {
            case linked(freedBytes: Int64)     // 真的换了 inode
            case alreadyLinked                 // 本来就是同一 inode
            case skipped(reason: String)       // 稳定性/在用判据不满足
            case rejected(reason: String)      // 安全护栏拒绝
            case failed(reason: String)        // 系统调用失败
        }

        let status: Status

        var succeeded: Bool {
            switch status {
            case .linked, .alreadyLinked: return true
            default: return false
            }
        }
        var freedBytes: Int64 {
            if case .linked(let bytes) = status { return bytes }
            return 0
        }
        /// 是否"没做成但也没坏处"（跳过）
        var isSkipped: Bool {
            if case .skipped = status { return true }
            if case .alreadyLinked = status { return true }
            return false
        }
        var reason: String? {
            switch status {
            case .skipped(let r), .rejected(let r), .failed(let r): return r
            default: return nil
            }
        }
    }

    /// 刚被写过就认为可能被进程持有（换 inode 会丢写入）。自检可放宽。
    static var recentWriteGuard: TimeInterval = 60

    /// 稳定性双采样间隔：两次 `lstat` 之间 inode/size/mtime 必须完全不动。
    static var stabilitySampleInterval: TimeInterval = 0.12

    /// 内容抽查的取样长度（头 + 尾各这么多字节）
    static var contentProbeLength: Int = 64 * 1024

    /// 额外硬拒位置：G6 清单里没有、但同样"一旦被链接就可能毁掉用户数据"的地方。
    static var extraDeniedRoots: [String] = [
        "~/Pictures/Photos Library.photoslibrary",
        "~/Pictures/Photos Library.photoslibrary.original",
        "~/Library/Application Support/MobileSync",
        "~/Library/Application Support/com.apple.cloudpd",
        "~/Library/Mobile Documents",
        "~/Library/CloudStorage",
        "~/Library/Group Containers",
        "~/Library/Containers",
        "~/Library/Mail",
        "~/Library/Keychains",
        "~/Library/Messages",
    ]

    /// 系统"永不可碰"位置（与 `FileSystem.isSafeToClean` 的 never 清单同口径）。
    ///
    /// **为什么这里要自己再列一遍**：`coreGuardVerdict` 只覆盖 G8 精确清单与 G6，
    /// 而硬链接替换**不可撤销、不进废纸篓** —— 判据必须比删除更严，
    /// 所以额外把 `/usr`、`/bin`、`/etc`、`/Volumes` 这类位置钉死。
    static var systemNeverRoots: [String] = [
        "/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var/db", "/Volumes",
    ]

    // MARK: 指纹与稳定性

    /// `lstat` 快照（不跟随软链）。普通文件之外一律返回 nil。
    static func fingerprint(ofPath path: String) -> DedupFingerprint? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return DedupFingerprint(inodeKey: "\(st.st_dev):\(st.st_ino)",
                                size: Int64(st.st_size),
                                mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                nlink: Int(st.st_nlink))
    }

    /// 链接后复核：两条路径必须落在同一 inode，且该 inode 的链接数 **≥ 2**。
    ///
    /// 这就是 `nlink < 2` 判据的落点：`nlink < 2` 说明这次 `link + rename` 压根没
    /// 把两条目录项并成一个 inode —— 一律按**失败**计，绝不记已释放。
    /// （注意不能拿"操作前副本的 nlink"当判据：没被链接过的普通副本 nlink 恒为 1，
    ///  那样写会把全部正常去重否掉。）
    static func isLinkVerified(source: DedupFingerprint?, target: DedupFingerprint?) -> Bool {
        guard let source, let target else { return false }
        return source.inodeKey == target.inodeKey && (target.nlink ?? 0) >= 2
    }

    /// 文件是否正被其它进程以咨询锁（POSIX record lock）持有。
    ///
    /// `fcntl(F_GETLK)` 能看到别的进程持有的 fcntl/flock 锁。
    /// **局限**：只是"打开着写"而不加锁的进程看不到 —— 因此还叠了
    /// `recentWriteGuard` + 双采样稳定性两道替代判据。
    static func advisoryLockHolderPID(_ path: String) -> pid_t? {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0,
                         l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_GETLK, &lock) == 0 else { return nil }
        return lock.l_type == Int16(F_UNLCK) ? nil : lock.l_pid
    }

    /// 稳定性判据：间隔采样两次，inode / size / mtime 任一变化即"文件正在被改动"。
    static func isStable(path: String, sampleInterval: TimeInterval? = nil) -> Bool {
        guard let first = fingerprint(ofPath: path) else { return false }
        let wait = sampleInterval ?? stabilitySampleInterval
        usleep(useconds_t(max(0, wait) * 1_000_000))
        guard let second = fingerprint(ofPath: path) else { return false }
        return first.matches(second, tolerance: 0)
    }

    // MARK: 安全护栏

    /// 路径是否落在"绝不允许参与硬链接替换"的位置。
    ///
    /// 硬链接替换**不进废纸篓、不可撤销**：源与目标任一处踩到 G8 系统硬保护、
    /// G6 用户数据硬排除、用户白名单，或本清单额外登记的照片库/iCloud/云盘/邮件等，
    /// 一律直接拒绝。
    static func guardRejection(forPath path: String) -> GovernanceVerdict.Reason? {
        if path.isEmpty { return .emptyPath }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        guard real != "/" else { return .resolvesToRoot }
        if let blocked = FileSystem.coreGuardVerdict(real) { return blocked }
        for root in systemNeverRoots {
            let denied = FileSystem.normalizePath(root)
            if real == denied || real.hasPrefix(denied + "/") { return .systemProtected }
        }
        for root in extraDeniedRoots {
            let denied = FileSystem.normalizePath(CleanPaths.expand(root))
            if real == denied || real.hasPrefix(denied + "/") { return .hardExcluded }
        }
        return nil
    }

    /// 执行前的全部判据。`blocked == nil` 表示可以动，此时 `source`/`target`
    /// 是**通过判据那一刻**的指纹，供 `link()` 之前再做一次复核（压小 TOCTOU 窗口）。
    private static func preflight(source: String, target: String,
                                  sourceFingerprint: DedupFingerprint?,
                                  targetFingerprint: DedupFingerprint?)
        -> (blocked: DedupOutcome?, source: DedupFingerprint?, target: DedupFingerprint?) {
        let realSource = FileSystem.normalizePath(FileSystem.realPath(source))
        let realTarget = FileSystem.normalizePath(FileSystem.realPath(target))
        guard realSource != realTarget else { return (DedupOutcome(status: .skipped(reason: "源与目标是同一个路径")), nil, nil) }

        for (role, path) in [("源", realSource), ("目标", realTarget)] {
            if isSymlink(path) {
                return (DedupOutcome(status: .rejected(reason: "\(role)是符号链接，不参与硬链接替换")), nil, nil)
            }
            if let reason = guardRejection(forPath: path) {
                return (DedupOutcome(status: .rejected(
                    reason: "\(role)位于受保护位置（\(GovernanceVerdict.rejected(reason).message)），拒绝硬链接替换")), nil, nil)
            }
        }

        guard let src = fingerprint(ofPath: realSource) else {
            return (DedupOutcome(status: .failed(reason: "源文件不存在或无法 stat：\(realSource)")), nil, nil)
        }
        guard let tgt = fingerprint(ofPath: realTarget) else {
            return (DedupOutcome(status: .failed(reason: "目标副本不存在或无法 stat：\(realTarget)")), nil, nil)
        }
        let currentSource = src, currentTarget = tgt

        // ① 扫描指纹复核：任一不符就是"文件已变化"
        if let recorded = sourceFingerprint, !currentSource.matches(recorded) {
            return (DedupOutcome(status: .skipped(reason: "文件已变化，跳过去重（源指纹不符）")), nil, nil)
        }
        if let recorded = targetFingerprint, !currentTarget.matches(recorded) {
            return (DedupOutcome(status: .skipped(reason: "文件已变化，跳过去重（目标指纹不符）")), nil, nil)
        }

        // ② 同一设备
        let srcDev = currentSource.inodeKey.split(separator: ":").first.map(String.init)
        let tgtDev = currentTarget.inodeKey.split(separator: ":").first.map(String.init)
        guard srcDev == tgtDev else {
            return (DedupOutcome(status: .rejected(reason: "源文件与目标副本不在同一磁盘宗卷，无法建立硬链接")), nil, nil)
        }

        // ③ 已是同一 inode → 无需处理
        if currentSource.inodeKey == currentTarget.inodeKey {
            return (DedupOutcome(status: .alreadyLinked), currentSource, currentTarget)
        }

        // ④ 大小必须一致（内容一致性的第一道）
        guard currentSource.size == currentTarget.size else {
            return (DedupOutcome(status: .rejected(reason: "文件大小不一致，安全拒绝硬链接去重")), nil, nil)
        }

        // ⑤ 在用判据：咨询锁 + 刚被写过 + 双采样不稳定
        for (role, path) in [("源", realSource), ("目标", realTarget)] {
            if let pid = advisoryLockHolderPID(path) {
                return (DedupOutcome(status: .skipped(reason: "\(role)正被进程 \(pid) 锁定，跳过去重")), nil, nil)
            }
            if let mtime = fingerprint(ofPath: path)?.mtime,
               Date().timeIntervalSince(mtime) < recentWriteGuard {
                return (DedupOutcome(status: .skipped(reason: "\(role)\(Int(recentWriteGuard)) 秒内刚被写入，疑似在用，跳过去重")), nil, nil)
            }
            if !isStable(path: path) {
                return (DedupOutcome(status: .skipped(reason: "\(role)在稳定性采样期间发生变化，跳过去重")), nil, nil)
            }
        }

        // ⑥ 内容抽查：大小相同 + 头尾各 64 KB 逐字节相同（不再单纯依赖上游 `.exact`）
        guard contentProbeMatches(realSource, realTarget) else {
            return (DedupOutcome(status: .rejected(reason: "内容抽查不一致，安全拒绝硬链接去重")), nil, nil)
        }
        return (nil, currentSource, currentTarget)
    }

    private static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// 头尾取样比对。**局限**：不重算整文件 SHA-256（GB 级副本代价过高），
    /// 因此仍沿用上游 `.exact` 的哈希结论，抽查只负责兜住"扫描之后内容被局部改写"这一类漂移。
    static func contentProbeMatches(_ a: String, _ b: String) -> Bool {
        guard let fa = FileHandle(forReadingAtPath: a), let fb = FileHandle(forReadingAtPath: b) else { return false }
        defer { fa.closeFile(); fb.closeFile() }
        let sizeA = fa.seekToEndOfFile()
        let sizeB = fb.seekToEndOfFile()
        guard sizeA == sizeB else { return false }          // 尺寸不同 → 内容必然不同
        let probe = UInt64(contentProbeLength)
        fa.seek(toFileOffset: 0); fb.seek(toFileOffset: 0)
        let headLen = Int(min(probe, sizeA))
        if fa.readData(ofLength: headLen) != fb.readData(ofLength: headLen) { return false }
        if sizeA > probe {
            fa.seek(toFileOffset: sizeA - probe)
            fb.seek(toFileOffset: sizeA - probe)
            if fa.readData(ofLength: Int(probe)) != fb.readData(ofLength: Int(probe)) { return false }
        }
        return true
    }
    // MARK: - 执行

    /// 对单对完全相同的重复文件执行硬链接替换。
    ///
    /// - Parameters:
    ///   - sourcePath: 推荐保留的主文件绝对路径
    ///   - targetPath: 待去重的重复副本绝对路径
    ///   - sourceFingerprint / targetFingerprint: **扫描时**记录的指纹。
    ///     传入后执行前必须逐字段复核；不传（nil）则只靠"刚采样 + 双采样稳定"兜住。
    /// - Returns: 是否成功及释放的字节数（已是硬链接或被判据跳过时为 0）
    @discardableResult
    static func dedup(sourcePath: String, targetPath: String,
                      sourceFingerprint: DedupFingerprint? = nil,
                      targetFingerprint: DedupFingerprint? = nil,
                      journal: ResidueDeletionGate.Journal = .module(categoryName: HardlinkDedupService.historyCategory)) throws -> (succeeded: Bool, freedBytes: Int64) {
        let outcome = performDedup(sourcePath: sourcePath, targetPath: targetPath,
                                   sourceFingerprint: sourceFingerprint,
                                   targetFingerprint: targetFingerprint,
                                   journal: journal)
        if case .failed(let reason) = outcome.status {
            throw NSError(domain: "HardlinkDedup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        if case .rejected(let reason) = outcome.status {
            // 安全护栏拒绝：与旧版一致地抛错，调用方计 failure 而不是"已释放"
            throw NSError(domain: "HardlinkDedup", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: reason])
        }
        return (outcome.succeeded, outcome.freedBytes)
    }

    /// 完整结论版（批量入口与自检用）。
    static func performDedup(sourcePath: String, targetPath: String,
                             sourceFingerprint: DedupFingerprint? = nil,
                             targetFingerprint: DedupFingerprint? = nil,
                             journal: ResidueDeletionGate.Journal = .module(categoryName: HardlinkDedupService.historyCategory)) -> DedupOutcome {
        let checked = preflight(source: sourcePath, target: targetPath,
                                sourceFingerprint: sourceFingerprint,
                                targetFingerprint: targetFingerprint)
        if let blocked = checked.blocked {
            return blocked
        }
        let realSource = FileSystem.normalizePath(FileSystem.realPath(sourcePath))
        let realTarget = FileSystem.normalizePath(FileSystem.realPath(targetPath))
        guard let before = fingerprint(ofPath: realTarget) else {
            return DedupOutcome(status: .failed(reason: "目标副本无法 stat"))
        }
        // 链接前最后一道：源与目标必须仍是**通过全部判据那一刻**的那一份 inode。
        // 少了这一步，判据与 `rename()` 之间的窗口足够长，能被一次改写挤进来。
        if let validated = checked.target, !before.matches(validated, tolerance: 0) {
            return DedupOutcome(status: .skipped(reason: "文件已变化，跳过去重（链接前复核不符）"))
        }
        if let validatedSource = checked.source,
           let sourceNow = fingerprint(ofPath: realSource),
           !sourceNow.matches(validatedSource, tolerance: 0) {
            return DedupOutcome(status: .skipped(reason: "文件已变化，跳过去重（链接前源已变动）"))
        }

        // 原子替换：link(源, 临时) → rename(临时, 目标)。
        // 注意：rename 覆盖**不可撤销、不进废纸篓**，所以每一步都要留证据。
        let tempLinkPath = realTarget + ".macclean_dedup_tmp_\(UUID().uuidString)"
        if link(realSource, tempLinkPath) != 0 {
            let err = String(cString: strerror(errno))
            return DedupOutcome(status: .failed(reason: "创建硬链接失败: \(err)"))
        }
        if rename(tempLinkPath, realTarget) != 0 {
            let err = String(cString: strerror(errno))
            unlink(tempLinkPath)   // 清理临时链接
            return DedupOutcome(status: .failed(reason: "覆盖替换目标副本失败: \(err)"))
        }

        // 事后复核：inode 必须与源一致，且 nlink ≥ 2，否则按失败计、**不记已释放**
        let srcAfter = fingerprint(ofPath: realSource)
        let tgtAfter = fingerprint(ofPath: realTarget)
        guard isLinkVerified(source: srcAfter, target: tgtAfter) else {
            return DedupOutcome(status: .failed(reason: "链接后复核未通过（inode 不一致或 nlink < 2），未计入已释放"))
        }
        guard let after = tgtAfter, after.size == before.size else {
            // 换 inode 不该改变内容长度
            return DedupOutcome(status: .failed(reason: "链接后目标大小发生变化，未计入已释放"))
        }

        FileSystem.invalidateMeasurements(for: [realTarget])
        let freed = Int64(before.size)
        if case .module(let categoryName) = journal {
            record(categoryName: categoryName, freedBytes: freed, path: realTarget)
        }
        return DedupOutcome(status: .linked(freedBytes: freed))
    }

    /// 写历史：硬链接替换不进废纸篓、无法撤销，**必须**留下可追溯记录。
    static func record(categoryName: String, freedBytes: Int64, path: String) {
        HistoryStore.append(CleanRecord(id: UUID(), date: Date(), categoryName: categoryName,
                                        itemCount: 1, bytes: freedBytes,
                                        mode: "APFS 硬链接（原位，不可撤销）", failures: 0))
    }

    static let historyCategory = "APFS 硬链接无损去重"

    /// 扫描阶段可记录的指纹（`DuplicateFileItem` 里已有的信息）
    static func scanFingerprint(of item: DuplicateFileItem) -> DedupFingerprint? {
        guard let mtime = item.modificationDate else { return nil }
        return DedupFingerprint(inodeKey: item.inodeKey ?? "", size: item.size, mtime: mtime, nlink: nil)
    }

    /// 批量对选中的完全一致重复文件执行硬链接去重
    static func dedupSelected(
        in groups: [DuplicateGroup],
        journal: ResidueDeletionGate.Journal = .module(categoryName: HardlinkDedupService.historyCategory)
    ) -> HardlinkDedupResult {
        var result = HardlinkDedupResult()

        for group in groups {
            // 只对内容 100% 精确一致的组执行；**并且**仍要做自己的内容抽查
            guard group.matchKind == .exact else { continue }

            guard let original = group.items.first(where: { $0.isOriginal })
                ?? group.items.first(where: { !$0.isSelected })
                ?? group.items.first else { continue }
            let sourceRecord = scanFingerprint(of: original)

            for item in group.items where item.isSelected && item.id != original.id {
                let targetRecord = scanFingerprint(of: item)
                let outcome = performDedup(sourcePath: original.path, targetPath: item.path,
                                           sourceFingerprint: sourceRecord,
                                           targetFingerprint: targetRecord,
                                           journal: .none)   // 批量只落一条汇总历史，见文件末尾
                switch outcome.status {
                case .linked(let bytes):
                    result.succeededCount += 1
                    result.freedBytes += bytes
                case .alreadyLinked:
                    result.skippedCount += 1
                case .skipped(let reason):
                    result.skippedCount += 1
                    result.stabilitySkips.append("\(item.name): \(reason)")
                case .rejected(let reason):
                    result.rejections.append("\(item.name): \(reason)")
                case .failed(let reason):
                    result.failures.append("\(item.name): \(reason)")
                }
            }
        }

        // 整批只写**一条**历史记录：不可撤销的操作必须留痕，且失败/跳过如实带在 failures 里
        if case .module(let categoryName) = journal, result.succeededCount > 0 {
            HistoryStore.append(CleanRecord(id: UUID(), date: Date(), categoryName: categoryName,
                                             itemCount: result.succeededCount, bytes: result.freedBytes,
                                             mode: "APFS 硬链接（原位，不可撤销）",
                                             failures: result.notDoneCount))
        }
        return result
    }
}
