import Foundation
import AppKit

/// 文件系统工具：目录大小、枚举、安全检查
enum FileSystem {

    // MARK: - 软链判定（安全关键）
    //
    // 整个扫描/清理链路都必须"不跟随软链"，理由不是洁癖而是安全：
    // 在家目录里放一个指向 `/System` 的软链，任何只看路径字符串的护栏都会被绕过去。
    // 实测（Selftest 已锁）：`~/xxx-link/Library/CoreServices` 字面上在家目录内，
    // `removeItem` 却会顺着软链删进受保护位置。

    // 下面三个判定全部走 `lstat`/`stat` 直连系统调用，不用 Foundation 的
    // `URL.resourceValues` —— 后者每次都要构造 URL、走一趟 getattrlist，在目录树遍历里
    // 是热点（实测把 `__pycache__` 递归与轮转日志遍历拖慢了近一倍）。
    // 三者语义必须严格区分，混用就是软链逃逸漏洞的来源：
    //   · isSymlink  —— lstat，只认"本身是软链"
    //   · isRealDir  —— lstat，只认"本身是真实目录"（**不跟随软链**，遍历用）
    //   · isDir      —— stat，跟随软链（仅用于"这个目标存不存在/是不是目录"的存在性判断）

    /// 该路径本身是否是符号链接（不跟随）。
    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// 是否是**真实目录**（不跟随软链）。
    ///
    /// 递归扫描必须用它，而不是 `isDir` —— 后者会跟随软链，把"指向目录的软链"也报成目录，
    /// 于是递归会顺着它走到家目录之外去。
    static func isRealDir(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// 解析到真实路径（消除路径中所有已存在的软链）。
    ///
    /// 不存在的末段保持原样——`resolvingSymlinksInPath()` 会尽力解析已存在的父级部分。
    static func realPath(_ path: String) -> String {
        URL(fileURLWithPath: CleanPaths.expand(path)).resolvingSymlinksInPath().path
    }

    // MARK: - 扫描期测量（体积 + 最近写入，一次遍历）
    //
    // 背景：每个清理项此前会被**走两遍** —— 构造时 `size(at:)` 为算体积做一次全量递归，
    // 随后 `annotateUsage` 又为"最近写入时间"抽样枚举一次。同一个目录两次 I/O，
    // 而这两件事本来就该在同一次遍历里做完（实测本机 ~/Library/Caches 有 86 个子目录）。
    //
    // 现在合并成一次遍历，并在一次扫描会话内缓存：`size` 与 `usage` 都读同一份结果。

    /// 一次遍历得到的测量结果。
    struct Measurement: Equatable, Codable {
        var size: Int64 = 0
        var newest: Date?
        /// 7 天内修改过的文件数（活跃度信号）
        var recentCount: Int = 0
        var isDirectory: Bool = false
        var exists: Bool = false
    }

    private static var measurementCache: [String: Measurement] = [:]
    /// 只做过**有界抽样**、体积不可信（`size` 是 0 或局部值）的键。
    ///
    /// 必须单独标记：抽样结果可以回答"最近什么时候被写过"，但绝不能被
    /// `measure()` 当成体积复用——那会把一个几 GB 的目录报成 0 字节。
    private static var sampledOnlyKeys: Set<String> = []
    private static let measurementLock = NSLock()

    /// 取"最近写入"相关的测量结果。
    ///
    /// **与 `measure` 的关键区别**：绝不为了 usage 把整棵目录树走完。
    ///
    /// 为什么必须区分：聚合型清理项（Maven 仓库、Homebrew Cellar、轮转日志…）的 `path`
    /// 是**巨大的父目录**，而它的体积是在扫描时逐个文件累加出来的、从未对父目录调用过 `size`。
    /// 如果这里无条件全量遍历，就会为了一个"最近写入时间"把 `~/.m2/repository` 整棵树走一遍。
    /// 实测这一处让整轮扫描从 3.4s 退化到 6.7s。
    ///
    /// 策略：
    /// ① 若该路径已有完整测量（`size` 刚走过）→ 直接复用，零额外成本；
    /// ② 否则退回**有界抽样**（深度不设限但样本上限 2000，够用即提前终止），
    ///    这正是合并前的行为。
    static func usageMeasurement(at path: String) -> Measurement {
        let key = cacheKey(path)
        measurementLock.lock()
        let cached = measurementCache[key]
        measurementLock.unlock()
        if let cached { return cached }

        let sampled = sampleMeasurement(at: path)
        // v1.72 修：抽样结果原先**从不回填**，于是同一个大目录在一轮扫描里
        // 每被问一次"最近写过吗"就要重新枚举至多 2000 项。
        // 实测 ~/Library/Caches 单次 192.8 ms、Containers 166.8 ms，
        // 而 `annotateUsage` 是每个清理项都要问一次。
        // 回填时把它记为"仅抽样"，`measure()` 就不会误把这个没有体积的结果当成全量值。
        measurementLock.lock()
        if measurementCache[key] == nil {
            measurementCache[key] = sampled
            sampledOnlyKeys.insert(key)
        }
        measurementLock.unlock()
        return sampled
    }

    /// 测量缓存的键。
    ///
    /// **必须归一化**：同一个目录会被不同调用方写成 `/tmp/x` 与 `/private/tmp/x`
    /// （`realPath` 走的是 `/tmp`，而调用方常拿 `/private/tmp`），字面量做键会让
    /// 失效操作打偏——删掉 `/tmp/x/a.bin` 之后，键为 `/private/tmp/x` 的那条缓存
    /// 依然活着，重新扫描就会报出已经释放掉的体积。实测就是这么漏的。
    private static func cacheKey(_ path: String) -> String {
        normalizePath(path)
    }

    /// 开启新一轮测量会话（清空缓存）。
    ///
    /// **每次扫描开始时必须调用**：否则缓存会跨扫描累积，用户清理完之后
    /// 再扫还会拿到旧体积。
    static func beginMeasurementSession() {
        measurementLock.lock()
        measurementCache.removeAll(keepingCapacity: true)
        sampledOnlyKeys.removeAll()
        measurementLock.unlock()

        // 新一轮扫描开始时丢弃运行态快照。
        //
        // `CleanPaths.runningSnapshot` 有 5 秒 TTL（为的是别在每个清理项上重枚举运行中
        // 应用）。但"刚启动的 App 要能被看见"这条 G5 保证不该被那个缓存跨扫描拖住：
        // 用户先开了 Xcode、再点扫描，这次扫描就必须看到 Xcode 在跑。
        CleanPaths.invalidateRunningSnapshot()
    }

    /// 让若干路径的缓存失效。
    ///
    /// `Cleaner` 删除后必须调用：否则紧接着的重新扫描会命中旧缓存，
    /// 给一个已经删掉的目录报出删除前的体积。
    static func invalidateMeasurements(for paths: [String]) {
        // v1.34.0 联动跨会话增量指纹缓存失效
        IncrementalCache.invalidate(paths)

        measurementLock.lock()
        defer { measurementLock.unlock() }
        for p in paths {
            for candidate in [p, realPath(p)] {
                // 连**所有祖先目录**一起失效：删掉 `dir/a.bin` 之后，`dir` 自己的
                // 缓存体积就不对了。只失效被删路径本身会让父目录继续报出旧体积。
                // 深度有限（家目录下通常 5–10 层），代价可忽略。
                var current = normalizePath(candidate)
                while current.count > 1 {
                    measurementCache.removeValue(forKey: current)
                    sampledOnlyKeys.remove(current)
                    let parent = normalizePath((current as NSString).deletingLastPathComponent)
                    if parent == current { break }
                    current = parent
                }
            }
        }
    }

    /// 有界抽样：只看最近修改时间，不做全量统计。
    private static func sampleMeasurement(at path: String) -> Measurement {
        var st = stat()
        guard lstat(path, &st) == 0 else { return Measurement() }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK { return Measurement() }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isSymbolicLinkKey]
        guard mode == S_IFDIR else {
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            let isRecent = Date().timeIntervalSince(mtime) < 7 * 86400
            return Measurement(newest: mtime, recentCount: isRecent ? 1 : 0,
                               isDirectory: false, exists: true)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return Measurement(newest: modificationDate(path), isDirectory: true, exists: true)
        }
        var result = Measurement(isDirectory: true, exists: true)
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var samples = 0
        for case let fileURL as URL in enumerator {
            samples += 1
            if samples > 2000 { break }
            guard let v = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { continue }
            if let m = v.contentModificationDate {
                if result.newest == nil || m > result.newest! { result.newest = m }
                if m > weekAgo { result.recentCount += 1 }
            }
            if result.recentCount >= 5 { break }   // 已确认活跃，提前终止
        }
        return result
    }

    /// 取路径的测量结果（带会话内缓存与跨会话增量指纹缓存）。
    ///
    /// v1.34.0 增强：
    /// ① 先查单次扫描会话缓存 `measurementCache`（零成本）；
    /// ② 未命中则查跨会话增量指纹缓存 `IncrementalCache`（仅微秒级 lstat 校验指纹）；
    /// ③ 指纹匹配直接复用上次全量递归结果，避免成千上万小文件重复遍历；
    /// ④ 均未命中才执行实际 `computeMeasurement`，并回填两级缓存。
    static func measure(at path: String) -> Measurement {
        let key = cacheKey(path)
        measurementLock.lock()
        // 只做过抽样的条目**不能**当体积用：它的 `size` 不是全量递归的结果，
        // 复用会把几 GB 的目录报成 0 字节。这类条目必须重新完整测算。
        if let hit = measurementCache[key], !sampledOnlyKeys.contains(key) {
            measurementLock.unlock()
            return hit
        }
        measurementLock.unlock()

        // ② 查跨会话增量指纹缓存
        if let incHit = IncrementalCache.lookup(at: path) {
            measurementLock.lock()
            measurementCache[key] = incHit
            sampledOnlyKeys.remove(key)   // 增量缓存存的是上次的**全量**结果
            measurementLock.unlock()
            return incHit
        }

        // ④ 深度递归遍历测算
        let computed = computeMeasurement(at: path)

        measurementLock.lock()
        measurementCache[key] = computed
        sampledOnlyKeys.remove(key)
        measurementLock.unlock()

        // 写入增量指纹缓存
        IncrementalCache.update(at: path, measurement: computed)

        return computed
    }

    private static func computeMeasurement(at path: String) -> Measurement {
        // 软链本身几乎不占空间 —— 删掉它释放的是 0 字节，不是目标的体积。
        // 返回目标体积会让界面虚报"可释放 896 MB"，而实际一个字节都没释放。
        if isSymlink(path) { return Measurement() }

        var st = stat()
        guard lstat(path, &st) == 0 else { return Measurement() }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK { return Measurement() }   // 软链：见上，不计体积
        guard mode == S_IFDIR else {
            // 普通文件：一次 lstat 就把体积和 mtime 都拿到了
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            let isRecent = Date().timeIntervalSince(mtime) < 7 * 86400
            return Measurement(size: Int64(st.st_size), newest: mtime,
                               recentCount: isRecent ? 1 : 0,
                               isDirectory: false, exists: true)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey,
                                      .totalFileAllocatedSizeKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            // 枚举器建不起来（权限等）→ 至少保留"存在"这一事实
            return Measurement(newest: modificationDate(path), isDirectory: true, exists: true)
        }

        var result = Measurement(isDirectory: true, exists: true)
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 200_000 { break }   // 防御：超大目录只估算前 20 万文件
            let values = autoreleasepool { () -> URLResourceValues? in
                try? fileURL.resourceValues(forKeys: Set(keys))
            }
            guard let values else { continue }
            if values.isSymbolicLink == true { continue }
            if let m = values.contentModificationDate {
                if result.newest == nil || m > result.newest! { result.newest = m }
                if m > weekAgo { result.recentCount += 1 }
            }
            if values.isRegularFile == true {
                result.size += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return result
    }

    /// 计算目录/文件大小（递归，跳过符号链接，遇权限错误跳过不中断）
    static func size(at path: String) -> Int64 {
        measure(at: path).size
    }

    /// 目录下的直接子项（不含 . 开头隐藏项，除非 keepHidden）
    static func children(of path: String, keepHidden: Bool = false) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return items.filter { keepHidden || !$0.hasPrefix(".") }
            .map { (path as NSString).appendingPathComponent($0) }
    }

    /// 目录下的直接子目录。
    ///
    /// **不跟随软链**：软链不算子目录。递归扫描（大文件、__pycache__ 等）依赖这个语义，
    /// 否则一个软链就能把扫描带到家目录之外。
    static func subdirs(of path: String) -> [String] {
        children(of: path).filter { isRealDir($0) }
    }

    /// 是否是目录（**跟随软链**）。
    /// 只用于"这个目标存不存在"的存在性判断；遍历请用 `isRealDir`。
    static func isDir(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// 路径是否存在（不跟随软链，软链本身也算存在）。
    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// 文件/目录最后修改时间
    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// 文件/目录访问时间
    static func accessDate(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
    }

    // MARK: - 使用频率检测（用户诉求：最近使用时间 + 使用频率，判断值不值得删）

    /// 轻量使用检测结果
    struct UsageInfo {
        var lastUsed: Date?      // 最近使用时间（文件 accessDate/mtime 较新者；目录为样本内最新）
        var level: UsageLevel    // 使用频率分级
    }

    /// 检测路径最近使用情况。
    /// - 单文件：取 accessDate 与 mtime 较新者，按距今天数分级。
    /// - 目录：先看目录自身 mtime（快速路径）；较旧时抽样枚举内部文件（限深度 3、样本 2000，
    ///   找到近期修改文件即提前终止），统计最新修改时间与近期文件数来分级。
    /// 性能约束：最坏情况枚举 2000 个文件元数据，远轻于 directorySize 的 20 万上限。
    static func usage(of path: String) -> UsageInfo {
        let now = Date()
        let day: TimeInterval = 86400

        func level(for age: TimeInterval) -> UsageLevel {
            switch age {
            case ..<(7 * day): return .active
            case ..<(30 * day): return .recent
            case ..<(90 * day): return .occasional
            default: return .dormant
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return UsageInfo(lastUsed: nil, level: .unknown)
        }

        // 单文件：以修改时间为主判据（macOS atime 默认 lazy 更新，不可靠）
        if !isDir.boolValue {
            guard let m = modificationDate(path) else { return UsageInfo(lastUsed: nil, level: .unknown) }
            return UsageInfo(lastUsed: m, level: level(for: now.timeIntervalSince(m)))
        }

        // 目录：优先复用 `size` 刚走过的那次全量测量（零额外 I/O）；
        // 没有则做有界抽样，绝不为了 usage 全量遍历巨大父目录。
        let m = usageMeasurement(at: path)

        // 快速路径：目录自身 mtime 很新 → 直接判活跃（不必看内部文件）
        if let dm = modificationDate(path), now.timeIntervalSince(dm) < 7 * day {
            return UsageInfo(lastUsed: dm, level: .active)
        }
        // 内部有多个 7 天内的文件 → 活跃（比"最新一个文件的 mtime"更稳，
        // 避免单个被 touch 的陈旧文件把整目录判活）
        if m.recentCount >= 5 {
            return UsageInfo(lastUsed: m.newest ?? modificationDate(path), level: .active)
        }
        guard let newest = m.newest else {
            // 空目录：退化为目录自身 mtime
            if let dm = modificationDate(path) {
                return UsageInfo(lastUsed: dm, level: level(for: now.timeIntervalSince(dm)))
            }
            return UsageInfo(lastUsed: nil, level: .unknown)
        }
        return UsageInfo(lastUsed: newest, level: level(for: now.timeIntervalSince(newest)))
    }

    // MARK: - v1.1 安全护栏（G8/G9）与受限放行

    // MARK: 护栏清单的预归一化缓存
    //
    // 闸门清单的内容在整个进程生命周期里不变，而 `normalizePath` 是**纯字符串函数**
    // （完全不触碰文件系统，同输入必得同输出），所以每条常量的归一化结果算一次就够。
    //
    // 为什么必须缓存：分段计时（一次性插桩，数字记录在 docs/CLEANUP-RULES.md 的 v1.72.4
    // 条目里）显示原先每判一个候选项要把 13 条 G6 + 6 条 G8 + 3 条放行根 + 临时残留三件套
    // + 2 个 Cellar 根 + 全局 node_modules 根反复重新归一化，占掉单次判定 299 µs 里的
    // 约 215 µs。而每个扫描器对**每个候选项**都要过一次闸门。
    /// 一条"整段前缀匹配"的护栏路径：预先归一，并预先备好 `+ "/"` 形态，
    /// 免得每次比较都临时拼一个新串。
    private struct GuardPath {
        let exact: String
        let childPrefix: String
        init(raw: String) {
            let n = normalizePath(raw)
            exact = n
            childPrefix = n + "/"
        }
        /// 命中自身或其下任意层级。入参必须已归一化。
        func matches(_ normalized: String) -> Bool {
            normalized == exact || normalized.hasPrefix(childPrefix)
        }
    }

    private static let guardSystemProtected = CleanPaths.systemProtected.map { GuardPath(raw: $0) }
    private static let guardHardExclude = CleanPaths.hardExclude.map { GuardPath(raw: $0) }
    private static let guardNever = ["/System", "/Library", "/usr", "/bin", "/sbin",
                                     "/etc", "/var/db", "/Volumes"].map { GuardPath(raw: $0) }
    /// 常规放行根。`home` 单独留出，闸门还要用它判"是不是主目录本身"。
    private static let guardHome = GuardPath(raw: NSHomeDirectory())
    private static let guardAllowedRoots: [GuardPath] =
        [guardHome.exact, "/tmp", "/var/tmp"].map { GuardPath(raw: $0) }

    // D13/D14 的两个精确路径 + L6 的 `$TMPDIR` 父段。
    // 用 `static let` 意味着取的是**首次访问时**的 `NSTemporaryDirectory()`：
    // 本进程不会改 `TMPDIR`（自检只重定向 `MACCLEAN_STATE_DIR`），故无失效问题。
    private static let guardClangModuleCache = normalizePath(CleanPaths.clangModuleCache)
    private static let guardNodeCompileCache = normalizePath(CleanPaths.nodeCompileCache)
    private static let normalizedUserTempDir = normalizePath(CleanPaths.userTempDir)

    // D12/D15 的扫描根
    private static let guardCellarRoots = [CleanPaths.homebrewCellar, CleanPaths.homebrewCellarIntel]
        .map { normalizePath($0) + "/" }
    private static let guardNodeModulesRoots = CleanupRules.globalNodeModulesRoots
        .map { normalizePath($0) + "/" }

    /// G9：检测是否拥有「完全磁盘访问权限」(TCC)。
    /// 判据：能否打开 `~/Library/Application Support/com.apple.TCC/TCC.db`（仅 FDA 授权进程可读）。
    /// 用途：无此权限时 `~/.Trash`、照片图库等目录扫描结果为空——必须让 UI 能区分
    /// 「读不到」与「真的空」，否则用户会以为「废纸篓是空的」而实际里面有几十 GB。
    static func hasFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
        guard let handle = FileHandle(forReadingAtPath: probe) else { return false }
        handle.closeFile()
        return true
    }

    /// G9：区分「因权限读不到」与「真的空目录」。
    /// 教训来源（v1.1）：`ls xxx 2>/dev/null | wc -l` 在权限不足时 stdout 为空、
    /// 被 `wc` 计成 `0`，于是「权限被拒」被误读为「空目录」——务必用本函数显式判定。
    static func isPermissionDenied(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        if !isDir.boolValue {
            return !FileManager.default.isReadableFile(atPath: path)
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return false
        } catch {
            return true
        }
    }

    /// G8：系统级硬保护判定（文档 §7：SIP restricted / sunlnk / 系统必需）。
    /// sudo 同样无解或会破坏系统，工具绝不列为可清理项。
    static func isSystemProtected(_ path: String) -> Bool {
        isSystemProtectedNormalized(normalizePath(path))
    }

    /// 入参必须已是 `normalizePath` 形态。闸门内部用它，避免同一个串归一两次。
    static func isSystemProtectedNormalized(_ normalized: String) -> Bool {
        guardNormalized(normalized, in: guardSystemProtected)
    }

    /// G6 用户数据硬排除，入参必须已是 `normalizePath` 形态。
    /// 与 `isSafeToClean` 共用同一份预归一清单，杜绝"两套标准"。
    static func isHardExcludedNormalized(_ normalized: String) -> Bool {
        guardNormalized(normalized, in: guardHardExclude)
    }

    private static func guardNormalized(_ normalized: String, in list: [GuardPath]) -> Bool {
        for g in list where g.matches(normalized) { return true }
        return false
    }

    /// 确定性路径归一化（G1/G6/G8/D12/D15 判定专用）。
    ///
    /// **为什么不能只用 `standardizingPath`**：该 API 会视**路径在文件系统中是否真实存在**
    /// 而决定是否解析 `/private` 别名 —— 实测 `/private/var/db/receipts`（存在）
    /// 被改成 `/var/db/receipts`，而虚构的 `/private/tmp/nonexistent` 保持原样。
    /// 于是同一个目录会因"存在性不同"得到两种形态，比较时互相匹配不上 ——
    /// 曾导致 7 项清理与护栏测试失败（含 `Cleaner` 彻底删除／移入废纸篓、
    /// `isSafeToClean` Cellar 边界等）。
    ///
    /// 本函数只做**确定性变换、完全不触碰文件系统**：
    /// ① 展开 `~`；② 消解 `.`、`..` 与多余分隔符；③ 统一剥离 `/private` 前缀别名，
    /// 使 `/private/tmp/x` 与 `/tmp/x`、`/private/var/db` 与 `/var/db` 判定一致。
    private static let privateAliasPrefix = "/private/"

    /// 快速通道判据：输入已经是"确定性归一化之后 would 得到的那个形态"。
    /// 即：绝对路径、无重复分隔符、无 `.`/`..` 段、无结尾斜杠——这种串只需要处理
    /// `/private` 别名，其余原样返回。
    ///
    /// 为什么手写一趟 UTF-8 扫描而不是 `contains("//") || contains("/./") || …`：
    /// 每种写法都要把整个路径走一遍，`String.contains` 在调试构建下是逐 Character
    /// 的泛型迭代。护栏对每个候选项要调这个函数一次，路径又普遍有七八十个字符，
    /// 八趟扫描比一趟字节扫描贵一个数量级。
    private static func isPlainAbsolutePath(_ p: String) -> Bool {
        guard p.hasPrefix("/"), p.utf8.count >= 2, p.utf8.last != UInt8(ascii: "/") else { return false }
        var prevWasSlash = false
        var dots = 0        // 当前段开头连续的 '.'
        var sawOther = false  // 当前段出现过非 '.' 字符
        for b in p.utf8 {
            if b == UInt8(ascii: "/") {
                if prevWasSlash { return false }                       // "//"
                if !sawOther && (dots == 1 || dots == 2) { return false }  // "." / ".." 段
                prevWasSlash = true
                dots = 0
                sawOther = false
            } else {
                if b == UInt8(ascii: "."), !sawOther { dots += 1 } else { sawOther = true }
                prevWasSlash = false
            }
        }
        return dots == 0 || sawOther || dots > 2
    }

    static func normalizePath(_ path: String) -> String {
        // ①+② 已是干净绝对路径时跳过展开与消解（见 `isPlainAbsolutePath`）
        if isPlainAbsolutePath(path) {
            return path.hasPrefix(privateAliasPrefix)
                ? String(path.dropFirst(privateAliasPrefix.count - 1))
                : path
        }

        let expanded = CleanPaths.expand(path)
        // 手动消解 . 与 ..（不查询文件系统，保证同输入必得同输出）
        var parts: [String] = []
        for seg in expanded.split(separator: "/", omittingEmptySubsequences: true) {
            if seg == "." { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(String(seg))
        }
        var normalized = "/" + parts.joined(separator: "/")
        // 统一 /private 别名（/tmp→/private/tmp、/var→/private/var 的逆映射）
        if normalized.hasPrefix(privateAliasPrefix) {
            normalized = String(normalized.dropFirst(privateAliasPrefix.count - 1))
        }
        return normalized
    }

    /// v1.1 受限放行①：用户临时目录（`$TMPDIR`）内的**已知残留**（L6 / D13 / D14）。
    ///
    /// 安全约束：**绝不放行整个 `$TMPDIR`**。实测该目录混有正在运行的构建与工具活跃产物
    /// （本机 `/private/tmp` 中 3.1 GiB 全部为当日 agent 工作流产物，并非垃圾），
    /// 因此只认下列精确路径与命名模式：
    /// - D13 `<TMPDIR 同级>/C/clang/ModuleCache`
    /// - D14 `<TMPDIR>/node-compile-cache`
    /// - L6  `<TMPDIR>/<bundle-id>.ShipIt.<字母数字后缀>`（仅顶层直接子项）
    static func isKnownTempResidue(_ path: String) -> Bool {
        isKnownTempResidueNormalized(normalizePath(path))
    }

    /// 入参必须已是 `normalizePath` 形态。
    static func isKnownTempResidueNormalized(_ normalized: String) -> Bool {
        // D13：Clang 模块缓存
        if normalized == guardClangModuleCache { return true }

        // D14：Node 编译缓存
        if normalized == guardNodeCompileCache { return true }

        // L6：应用更新残留，仅限 $TMPDIR 顶层直接子项
        guard (normalized as NSString).deletingLastPathComponent == normalizedUserTempDir else { return false }
        let name = (normalized as NSString).lastPathComponent
        guard let range = name.range(of: CleanupRules.shipItMarker),
              range.lowerBound != name.startIndex else { return false }   // 标记前必须有 bundle-id 段
        let suffix = name[range.upperBound...]
        return !suffix.isEmpty && suffix.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// v1.1 受限放行②：全局 `node_modules` 下的废弃版本副本（D15）。
    ///
    /// 安全约束：只放行**包目录本身**（`<pkg>` 或 `@scope/<pkg>`，最多两段），
    /// 且目录名必须命中废弃标记且标记后紧跟版本号/日期；
    /// 绝不放行其父级，禁止整根或整个 scope 目录被清理。
    static func isRetiredGlobalPackage(_ path: String) -> Bool {
        isRetiredGlobalPackageNormalized(normalizePath(path))
    }

    /// 入参必须已是 `normalizePath` 形态。
    static func isRetiredGlobalPackageNormalized(_ normalized: String) -> Bool {
        for prefix in guardNodeModulesRoots {
            guard normalized.hasPrefix(prefix) else { continue }
            let parts = normalized.dropFirst(prefix.count).split(separator: "/")
            // 仅 <pkg> 或 <@scope>/<pkg>
            guard parts.count == 1 || (parts.count == 2 && parts[0].hasPrefix("@")) else { return false }
            guard let pkg = parts.last.map(String.init), !pkg.hasPrefix(".") else { return false }
            return CleanupRules.isRetiredPackageName(pkg)
        }
        return false
    }

    /// 安全检查：路径是否允许操作（G1/G6/G8）
    static func isSafeToClean(_ path: String) -> Bool {
        // 输入为空（空串会归一化成 "/"）时拒绝
        guard !path.isEmpty else { return false }

        // ── 软链防跳板（安全关键）──
        // ① 末段本身是软链：删除它不释放空间，且它可能指向任何地方 → 直接拒绝。
        //    这条也顺带挡掉了"列出一堆 0 字节软链"的误导。
        if isSymlink(path) { return false }
        // ② 解析路径中所有已存在的软链，用**真实位置**做后续全部判定。
        //    否则 `~/link/Library/CoreServices`（link → /System）字面上在家目录内，
        //    会一路通过检查，而 removeItem 真的会顺着软链删进 /System。
        return isResolvedPathSafeToClean(normalizePath(realPath(path)))
    }

    /// 对**已解析真实位置**的路径做放行判定。
    ///
    /// 入参必须是 `normalizePath(realPath(...))` 之后的形态——也就是闸门链路上游
    /// 已经付过那次软链解析的地方（`governanceVerdictWithinHome` 就是这个调用方）。
    /// 再解析一遍是幂等的，但幂等不等于免费：一趟逐段 lstat。
    static func isResolvedPathSafeToClean(_ normalized: String) -> Bool {
        // 绝对禁止删除用户主目录本身
        guard normalized != guardHome.exact, normalized != "/" else { return false }

        // G8：系统级硬保护（最高优先级，任何放行规则都不得绕过）
        if isSystemProtectedNormalized(normalized) { return false }

        // G6：硬排除白名单（用户数据：邮件/钥匙串/共享容器/云盘等）
        if guardNormalized(normalized, in: guardHardExclude) { return false }

        // 用户自定义白名单（路径与扩展名防误删底层护栏）
        // 必须置于下方三处放行之前：白名单优先级高于一切放行规则
        // 走 `resolvedPath` 入口：传进来的已经是解析后的真实位置，
        // 让 `isWhitelisted` 再解析一遍只会得到同一个串（`normalizePath ∘ realPath` 幂等），
        // 却要再付一次全路径逐段 lstat。有白名单规则的用户实测每判一项多 9.5 µs。
        if WhitelistManager.shared.isWhitelisted(resolvedPath: normalized)
            || WhitelistManager.shared.isExtensionWhitelisted(path: normalized) {
            return false
        }

        // 三处受限放行（均需通过上方 G8/G6 与白名单检查后方可生效）：
        // ① $TMPDIR 内已知残留（L6/D13/D14）
        // ② 全局 node_modules 废弃副本（D15）
        // ③ Homebrew Cellar 具体版本目录（D12）
        // 命中即直接放行——这些目标位于常规允许根目录之外（Cellar 在 /opt 或 /usr/local），
        // 若继续走下方常规检查会被 `/usr` 等系统位置禁令误拦（曾导致 `/usr/local/Cellar` 失效）；
        // 放行前已通过 G8 系统硬保护、G6 用户数据白名单与自定义白名单三道检查。
        if isKnownTempResidueNormalized(normalized) { return true }
        if isRetiredGlobalPackageNormalized(normalized) { return true }
        if isCellarVersionDirNormalized(normalized) { return true }

        // 常规路径：只允许主目录内 或 tmp 目录
        guard guardNormalized(normalized, in: guardAllowedRoots) else { return false }

        // 禁止删除关键系统位置
        return !guardNormalized(normalized, in: guardNever)
    }

    /// D12 放行判定：`<Cellar>/<formula>/<version>` 形态，且版本段以数字或 `v` 开头。
    /// 只允许删除某 formula 的某个具体版本，不允许整 Cellar 或整 formula 目录。
    static func isCellarVersionDir(_ path: String) -> Bool {
        isCellarVersionDirNormalized(normalizePath(path))
    }

    /// 入参必须已是 `normalizePath` 形态。
    static func isCellarVersionDirNormalized(_ normalized: String) -> Bool {
        for prefix in guardCellarRoots {
            guard normalized.hasPrefix(prefix) else { continue }
            let parts = normalized.dropFirst(prefix.count).split(separator: "/")
            // 需要 formula 名 + 版本号（≥2 段，且版本段以数字/v 开头防误删目录）
            guard parts.count >= 2, !parts[0].isEmpty, parts[0].first != "." else { return false }
            let version = parts[1]
            return version.first?.isNumber == true || version.hasPrefix("v")
        }
        return false
    }
}
