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

    // MARK: - 权限盲区登记（G9 / 规则 v2 步骤 6）
    //
    // 扫描链路里每一个"存在但读不到"的位置，都会从测量遍历的
    // `errorHandler: { _, _ in true }` 里过一遍然后被丢掉。于是**权限不足和真的空
    // 在结果上完全一样**（都是 0 项），用户看到「用户缓存 65 项」不会想到
    // `~/Library/Caches/CloudKit` 与 Safari 容器根本没能打开。
    //
    // 记录点选在测量遍历里，是因为它是**唯一真正看见这些错误的地方**：
    // 想"发现盲区"另外补一趟 stat/opendir 是白花 I/O，而这一趟本来就要走。
    //
    // 单独一把锁（不复用 `measurementLock`）：errorHandler 是在遍历回调里被同步调用的，
    // 复用同一把锁就把"调用方恰好持锁"变成了一条必须永远为真的隐式约定。
    private static let deniedLock = NSLock()
    private static var deniedRoots: [String: Int] = [:]
    /// 盲区条目上限。真出问题时一个卷上能拒几百次，界面只需要知道"有多少处、举几例"。
    static let deniedAccessLimit = 64

    /// 记一次"存在但读不到"。
    ///
    /// 只收权限类错误：`EPERM`（TCC / 沙盒拒绝）与 `EACCES`（Unix 权限拒绝）。
    /// 其余错误（遍历中途文件被删、符号链断裂）不算盲区——那是真的没了，
    /// 报出来会把用户训练成忽略这条提示。
    ///
    /// **必须顺着 `NSUnderlyingErrorKey` 往外剥**：`FileManager` 交给调用方的
    /// 是 `NSCocoaErrorDomain 257`（`NSFileReadNoPermissionError`），真正的
    /// `POSIX EACCES(13)` 藏在 userInfo 里。只判顶层 domain 的话，
    /// 整条盲区记账在真机上一条都不会成立——这条是自检先红出来的。
    static func recordDeniedAccess(_ url: URL, error: Error) {
        guard isPermissionError(error) else { return }
        noteDeniedRoot(normalizePath(url.path))
    }

    /// 盲区记账本体（调用方负责不持 `deniedLock`）。
    ///
    /// 单独拆出来是因为超时那条路径手上没有 `Error`：`isPermissionError` 那道
    /// 过滤器对它天然不成立，而"授权请求未决"和"授权被拒"对用户是同一件事。
    private static func noteDeniedRoot(_ path: String) {
        guard !path.isEmpty else { return }
        deniedLock.lock()
        defer { deniedLock.unlock() }
        if deniedRoots[path] != nil {
            deniedRoots[path, default: 1] += 1
            return
        }
        // 父目录已经记过 → 子项被拒是同一件事，不重复占额度
        if deniedRoots.keys.contains(where: { path.hasPrefix($0 + "/") }) { return }
        // 反过来：这次记到的是更浅的位置，把先前记的深层条目并进来
        for existing in deniedRoots.keys where existing.hasPrefix(path + "/") {
            deniedRoots.removeValue(forKey: existing)
        }
        guard deniedRoots.count < deniedAccessLimit else { return }
        deniedRoots[path] = 1
    }

    /// 是不是"权限不够"类错误（顺着 underlying 链最多剥三层）。
    static func isPermissionError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        for _ in 0..<3 {
            guard let ns = current else { return false }
            if ns.domain == NSPOSIXErrorDomain,
               ns.code == Int(EACCES) || ns.code == Int(EPERM) { return true }
            // Cocoa 侧的"没权限读/写"码，即使拿不到 underlying 也认
            if ns.domain == NSCocoaErrorDomain,
               ns.code == 257 || ns.code == 513 { return true }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// 本轮看到的权限盲区，已剔除"我们本来就不该去读"的位置。
    ///
    /// 最后一步很重要：`~/Library/Mobile Documents`、照片图库、`~/Library/Accounts`
    /// 这些是 G6 主动硬排除的用户数据，读不到是**设计如此**。把它们也报成盲区，
    /// 就等于每轮扫描都喊一次狼来了，真正该授权的 Safari 容器反而被忽略。
    static func deniedAccessSnapshot() -> [String] {
        deniedLock.lock()
        let all = Array(deniedRoots.keys)
        deniedLock.unlock()
        return all
            .filter { !isSystemProtectedNormalized($0) && !isHardExcludedNormalized($0) }
            .sorted()
    }

    /// **一次遍历自己的**「被权限掐断过」标记。
    ///
    /// 为什么不用全局盲区清单（`deniedRoots`）反查：那份账是进程级、**64 条封顶**、
    /// 会做父子合并、并且每次 `beginMeasurementSession()` 都被整片清空。拿它当
    /// "这份统计完整吗"的输入，三条途径都能让一次**完全读不到**的遍历得到
    /// `readable = true`——而 `readable` 在若干治理模块里是**默认勾选删除**的唯一屏障。
    /// 反过来，邻居模块在同一前缀下撞过一次拒绝，又会让一次干净的遍历被判成不可读、
    /// 整项从面板上无声消失。两个方向都错，所以判定依据必须由遍历自己带着。
    ///
    /// 给 `@Sendable` 的 `errorHandler` 闭包用，因此自带锁。
    public final class WalkBlockFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var blocked = false
        public init() {}
        public func set() { lock.lock(); blocked = true; lock.unlock() }
        public var value: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    }

    static func resetDeniedAccess() {
        deniedLock.lock()
        deniedRoots.removeAll()
        deniedLock.unlock()
        // 注意：**不清** `wedgedReads`。它按扫描轮清空的话，每轮都会对每个仍然卡死的
        // 目录重新 dispatch 一条永不返回的 block——死线程就是这么攒出来的。
        // 那份状态靠 TTL 自己过期，见 `wedgedRetryInterval`。
    }

    /// 清空"卡过的目录"记录。**只给自检用**。
    ///
    /// 生产路径上这个集合是**故意跨轮**的（见上面 `resetDeniedAccess` 的注释），
    /// 所以测试要一个确定起点时只能显式清，不能指望每轮自动清。
    static func resetWedgedReadsForSelftest() {
        wedgedLock.lock()
        wedgedReads.removeAll()
        inFlightReads.removeAll()
        wedgedLock.unlock()
    }

    // MARK: - 读取可能被 TCC 拦住的目录：必须带截止时间

    /// 出厂值。自检钉的是这个常量，不是运行时可能被测试改小的当前值。
    static let defaultGatedReadDeadline: TimeInterval = 5

    /// 打开一个目录**最多**等多久。
    ///
    /// 授权请求处于"未决"时，`opendir` 与 `contentsOfDirectory` 不是返回错误，而是
    /// 停在内核的 `__open` 上永不返回。实测本机 `~/Downloads` 挂着一个再没人应答的
    /// TCC 请求（屏幕上并没有等着点的对话框——对话框已经成了孤儿），于是
    /// `--scan`、`--selftest` 和 GUI 里点「扫描」全部 0% CPU 卡死在同一条栈：
    /// `FileSystem.children → contentsOfDirectory → __open`（2335/2335 次采样都在那一帧）。
    ///
    /// 没有截止时间时，代价不是"这一处看不见"，而是"整个应用没有响应"——
    /// 而后者会让用户以为工具坏了，再也不看它的任何结论。
    static var gatedReadDeadline: TimeInterval {
        get { deadlineLock.lock(); defer { deadlineLock.unlock() }; return _gatedReadDeadline }
        set { deadlineLock.lock(); defer { deadlineLock.unlock() }; _gatedReadDeadline = newValue }
    }
    private static let deadlineLock = NSLock()
    private static var _gatedReadDeadline: TimeInterval = defaultGatedReadDeadline

    private static let gatedReadQueue = DispatchQueue(label: "com.macclean.gated-read",
                                                     attributes: .concurrent)

    /// 同时在途的门禁读取上限。
    ///
    /// 超时那条 block 仍卡在内核里，用户态收不回来，而 GCD 同一 QoS 只有约 64 条
    /// 工作线程。不设上限的话攒满之后**所有**门禁读取都排不上队、一律超时，
    /// 于是可读的目录被成片报成盲区——谎报比漏报糟，本项目把这条排在第一位。
    /// 有了上限，最坏情况是"这一轮少看几处"，且立刻发生而不是拖垮整轮。
    private static let gatedReadSlots = DispatchSemaphore(value: 4)

    /// 卡过的目录 -> 记下的时刻。TTL 内不再重试（重试只会再多漏一条死线程）；
    /// TTL 之后给一次机会，因为授权可能在这期间被补上。
    private static let wedgedLock = NSLock()
    private static var wedgedReads: [String: Date] = [:]
    /// 正在途的目录。与上面的查询**必须在同一次临界区里**读写：6 个分类并发扫描时
    /// `Application Support` 同时属于 `.appResidue` 与 `.browserAndSystem`，
    /// 先查后占会让同一个目录放行两次，各漏一条永不返回的线程。
    private static var inFlightReads: Set<String> = []
    static let wedgedRetryInterval: TimeInterval = 600

    private final class BoundedReadBox<T> { var value: T? }

    /// 截止时间到之前完成就返回值；超时则记盲区并返回 nil。
    ///
    /// nil 与"读到了空结果"必须能区分开，所以调用方拿到 nil 时只能跳过，
    /// 不能把这里当成"0 项 / 很干净"。
    ///
    /// 两种 nil 不是一回事：**真的等过、超时**才记盲区；**令牌满了根本没试**不记——
    /// 对我们没碰过的目录声称"读不到"，就是凭空造一条权限告警。
    ///
    /// internal 是给自检留的缝：自检传一个**真的永不返回**的 body 进来，就能在没有
    /// 卡死卷宗的开发机上复现这条路径——不去伪造 `opendir` 的行为，只替换被包住的那次读取。
    /// 有截止读取的结果。**四种结局必须分得开**，尤其"没去试"与"试了读不到"：
    /// 后者是盲区（要告诉用户），前者只是本轮没顾上（告诉用户就是谎报）。
    enum GatedRead<T> {
        case value(T)
        /// 真去开了，被拒或等到超时——这是盲区。
        case unreadable
        /// 在途额度已满 / 同一目录正被别的线程读：**根本没去 open**，不得声称读不到。
        case deferred
    }

    private static func readWithinDeadlineDetailed<T>(_ path: String,
                                                      _ body: @escaping () -> T) -> GatedRead<T> {
        let key = normalizePath(path)
        let now = Date()
        wedgedLock.lock()
        if let at = wedgedReads[key], now.timeIntervalSince(at) < wedgedRetryInterval {
            wedgedLock.unlock()
            // TTL 内的短路不是"没试"：上一次真的失败了，只是不再为它多漏一条线程。
            // 这里补记盲区，免得面板说"读不到"而诊断清单上却查无此处。
            noteDeniedRoot(key)
            return .unreadable
        }
        if inFlightReads.contains(key) {
            wedgedLock.unlock()
            return .deferred
        }
        inFlightReads.insert(key)
        wedgedLock.unlock()

        guard gatedReadSlots.wait(timeout: .now()) == .success else {
            wedgedLock.lock(); inFlightReads.remove(key); wedgedLock.unlock()
            return .deferred
        }

        let done = DispatchSemaphore(value: 0)
        let box = BoundedReadBox<T>()
        gatedReadQueue.async {
            box.value = body()
            gatedReadSlots.signal()
            done.signal()
        }
        if done.wait(timeout: .now() + gatedReadDeadline) == .timedOut {
            wedgedLock.lock()
            inFlightReads.remove(key)
            wedgedReads[key] = Date()      // 占位改记成"卡过"：那条 block 还在内核里
            wedgedLock.unlock()
            noteDeniedRoot(key)
            return .unreadable
        }
        wedgedLock.lock()
        inFlightReads.remove(key)
        wedgedReads.removeValue(forKey: key)   // 读通了，别再当它卡过
        wedgedLock.unlock()
        return .value(box.value!)
    }

    /// 见 `readWithinDeadlineDetailed`。返回 nil = 本轮没看清（盲区或没顾上，不区分）。
    static func readWithinDeadline<T>(_ path: String, _ body: @escaping () -> T) -> T? {
        switch readWithinDeadlineDetailed(path, body) {
        case .value(let v): return v
        case .unreadable, .deferred: return nil
        }
    }

    /// 有截止地"开一下这个目录"，并区分**读不到**与**没去试**。
    /// 给要把结论直接讲给用户看的调用方用（归档面板），别用折叠成 Bool 的那一个。
    enum GatedProbe { case readable, unreadable, deferred }

    static func probeDirectory(_ path: String) -> GatedProbe {
        // 判类型必须用 `stat`（**跟随软链**）而不是 `lstat`：`opendir` 会跟着链接走进目标目录，
        // 未决授权就卡在目标上。用 lstat 判会让一个软链形态的缓存目录直接被判成"不是目录、
        // 不用探测"而放行，恰好绕开这套机制存在的唯一理由。
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            return .readable      // 不存在 / 不是目录：不是"读不到"，交给调用方原有的存在性判断
        }
        switch readWithinDeadlineDetailed(path, { canOpenDirectory(path) }) {
        case .value(true): return .readable
        case .value(false):
            // 真去开了、被拒：这就是盲区，必须记账，否则面板说"读不到"而诊断清单查无此处。
            noteDeniedRoot(normalizePath(path))
            return .unreadable
        case .unreadable: return .unreadable
        case .deferred: return .deferred
        }
    }

    /// 扫描**本来就要读**某个可能被 TCC 拦住的目录时，先用带截止的探测过一遍：
    /// 打不开或卡住就整项跳过，并已记入盲区。
    ///
    /// 与 `proactiveBlindSpotProbe` 无关，而且刻意不受它管：那个开关管的是"要不要
    /// **额外**多开一次去记账"（那一次才是无人值守会撞上模态授权框的东西），
    /// 而这里这次开本来就要发生——把它关掉不会省掉那次 `open`，只会把无截止的那次
    /// 留给紧随其后的 `size(at:)`。有了截止时间，无人值守才敢照开不误。
    ///
    /// **只许用于"跳过"这一种决策**。它把"读不到"和"本轮没顾上"都折成 false；
    /// 对扫描器来说两者都是"这轮不看这里"，语义没问题，但**不许拿它去生成
    /// 用户可见的"读不到"文案**——那要用 `probeDirectory`。
    static func isReadableWithDeadline(_ path: String) -> Bool {
        probeDirectory(path) == .readable
    }

    /// 带截止时间的目录列举，**只**用在可能被 TCC 拦住的家目录根
    /// （下载 / 文稿 / 桌面 / 影片）。
    ///
    /// 不给 `children(of:)` 整体加截止时间是刻意的：它在递归遍历里被调用成千上万次，
    /// 每次都跳一次线程、等一次信号量，会把扫描本身变成瓶颈。TCC 拦的是"打开容器目录"
    /// 那一刻，所以只要在根上守住就够了。
    ///
    /// 返回 nil = 这一轮没能看清这里（已记入盲区）；返回 `[]` = 这里确实是空的。
    static func childrenBounded(of path: String, keepHidden: Bool = false) -> [String]? {
        readWithinDeadline(path) { children(of: path, keepHidden: keepHidden) }
    }

    /// 带截止时间的"开不开得了"探测。返回 nil = 超时（授权未决）。
    ///
    /// 三种结果里只有 `true` 不是盲区，所以 `false`（被拒）和 nil（卡住）都记进盲区清单：
    /// 这条探测正是"存在但读不到"的判定本身，放过其中一种就等于把它报成"干净"。
    static func canOpenDirectoryBounded(_ path: String) -> Bool? {
        switch readWithinDeadline(path, { canOpenDirectory(path) }) {
        case .some(true): return true
        case .some(false):
            noteDeniedRoot(normalizePath(path))
            return false
        case nil: return nil
        }
    }

    /// 显式问一次"这个目录读得到吗"，读不到就记进盲区清单并返回 true。
    ///
    /// 为什么不能只靠遍历顺手记：`measure(at:)` 会命中**跨会话增量指纹缓存**，
    /// 而指纹只看目录自身的 lstat——一次被权限挡住的遍历得到的 0 字节会被缓存成
    /// "这个目录是空的"，之后每轮都直接复用、再也不会走进去，也就再也不会报错。
    /// 于是"看不见"被永久固化成"干净"，正是这一步要消灭的失败模式。
    ///
    /// 但"主动去开"必须只在人在屏幕前时做，见 `proactiveBlindSpotProbe`。
    static func recordBlindSpotIfNeeded(at path: String) -> Bool {
        guard proactiveBlindSpotProbe else { return false }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        switch canOpenDirectoryBounded(path) {
        case true: return false                       // 读得到，不是盲区
        case nil:  return true                        // 没等到：盲区已记下
        case false: break
        }
        recordDeniedAccess(URL(fileURLWithPath: path, isDirectory: true),
                           error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
        return true
    }

    private static let probeModeLock = NSLock()
    private static var _proactiveBlindSpotProbe = false

    /// 本轮扫描要不要**额外**打开可能被 TCC 拒掉的目录去做盲区记账。**默认关**。
    ///
    /// 真机实测：打开别的 App 的容器/缓存会让 macOS 弹出
    /// "「MacClean」想访问其他 App 的数据"——那是个**模态**对话框。
    /// 用户亲手点扫描时弹得正好（他正想找授权入口）；无人值守路径弹出来没人点。
    ///
    /// **这个开关不保证"不卡死"，也从来没保证过。** 关掉它只是不做那次*额外*的记账探测：
    /// 扫描本来就要 `size(at:)` 同一个目录，那一次 `open` 照样发生，所以"少弹一个框"
    /// 之外它什么也没省掉。真正兜住卡死的是 `gatedReadDeadline`
    /// （见 `isReadableWithDeadline` 与 `Scanner` 里 C1/C6/A1 那三处补的有截止跳过）。
    ///
    /// **为什么默认仍是 false**：`Scanner.scan` 是所有无头入口的必经之地，而它从来没设过
    /// 这个开关（注释却写着设了）。默认关之后，"忘记设"的代价退化成"这一轮盲区少报几个"，
    /// 而不是"多弹一批没人点的模态框"——失败要往轻的方向倒。
    ///
    /// **约定**：只有人在屏幕前亲手触发的交互扫描才显式打开
    /// （`AppState.scan(_:)`、`AppState.scanAll(unattended: false)`）；无头入口保持默认关。
    static var proactiveBlindSpotProbe: Bool {
        get {
            probeModeLock.lock()
            defer { probeModeLock.unlock() }
            return _proactiveBlindSpotProbe
        }
        set {
            probeModeLock.lock()
            defer { probeModeLock.unlock() }
            _proactiveBlindSpotProbe = newValue
        }
    }

    /// 开启新一轮测量会话（清空缓存）。
    ///
    /// **每次扫描开始时必须调用**：否则缓存会跨扫描累积，用户清理完之后
    /// 再扫还会拿到旧体积。
    static func beginMeasurementSession() {
        measurementLock.lock()
        measurementCache.removeAll(keepingCapacity: true)
        sampledOnlyKeys.removeAll()
        incompleteWalks.removeAll()
        measurementLock.unlock()
        // 盲区清单按"一轮扫描"为口径：跨轮累积会让界面永远显示一堆早就解决掉的授权提示。
        resetDeniedAccess()

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
                    incompleteWalks.remove(current)
                    // 包内口径的键是同一个路径加后缀，**必须一起删**：只删裸键的话，
                    // 删掉一个 `.app` 之后同一会话里 `bundleSize` 仍会命中删除前的旧值。
                    let pkg = current + packageSizingSuffix
                    measurementCache.removeValue(forKey: pkg)
                    sampledOnlyKeys.remove(pkg)
                    incompleteWalks.remove(pkg)
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
            errorHandler: { url, error in
                recordDeniedAccess(url, error: error)
                return true
            }
        ) else {
            if isPermissionDenied(path) {
                recordDeniedAccess(URL(fileURLWithPath: path, isDirectory: true),
                                   error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)))
            }
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
        measure(at: path, descendIntoPackages: false, sessionKey: cacheKey(path))
    }

    /// 给"包内也要算"的调用方用的口径：`.app`/`.pkg` 里嵌套的 framework、helper bundle
    /// 一并计入。与 `measure(at:)` **不能共用缓存**——两者对同一个路径给出的数不同，
    /// 混用就等于把少算 3%~35% 的结果当成权威值复用（v1.73.5 复审 F3）。
    static func bundleSize(at path: String) -> Int64 {
        measure(at: path, descendIntoPackages: true,
                sessionKey: sessionKey(path, descendIntoPackages: true)).size
    }

    /// 会话缓存的键。**两种口径必须走这一个函数生成**：口径是键的第二维，
    /// 谁手写拼接就迟早会漏掉某一维（`invalidateMeasurements` 就漏过一次，
    /// 结果是删掉 `.app` 之后同一会话内 `bundleSize` 仍报删除前的大数）。
    private static func sessionKey(_ path: String, descendIntoPackages: Bool) -> String {
        cacheKey(path) + (descendIntoPackages ? packageSizingSuffix : "")
    }
    private static let packageSizingSuffix = "\u{1F}pkg"

    private static func measure(at path: String, descendIntoPackages: Bool,
                                sessionKey: String) -> Measurement {
        let key = sessionKey
        measurementLock.lock()
        // 只做过抽样的条目**不能**当体积用：它的 `size` 不是全量递归的结果，
        // 复用会把几 GB 的目录报成 0 字节。这类条目必须重新完整测算。
        if let hit = measurementCache[key], !sampledOnlyKeys.contains(key) {
            measurementLock.unlock()
            return hit
        }
        measurementLock.unlock()

        // 包内口径不查跨会话缓存：那份缓存的键里没有"是否下钻包"这一维，
        // 复用它会把两种口径互相污染。代价是这几处每次走一遍遍历。
        if !descendIntoPackages, let incHit = IncrementalCache.lookup(at: path) {
            measurementLock.lock()
            measurementCache[key] = incHit
            sampledOnlyKeys.remove(key)   // 增量缓存存的是上次的**全量**结果
            measurementLock.unlock()
            return incHit
        }

        // ④ 深度递归遍历测算
        let computed = computeMeasurement(at: path, descendIntoPackages: descendIntoPackages)

        measurementLock.lock()
        measurementCache[key] = computed
        sampledOnlyKeys.remove(key)
        let walkWasBlocked = incompleteWalks.contains(key)
        if walkWasBlocked { incompleteWalks.remove(key) }
        measurementLock.unlock()

        // 写入增量指纹缓存——**但被权限挡住过的除外**。
        // 那一支的 size 是 0，而指纹只看目录自身的 lstat 与顶层子项数：授权补上之后
        // 两者都没变，于是"0 字节"会被固化最长 7 天，正是 §7.2 要消灭的那个形状。
        if !descendIntoPackages && !walkWasBlocked {
            IncrementalCache.update(at: path, measurement: computed)
        }

        return computed
    }

    /// 本轮遍历中被挡住过的条目。只用于"不要把残缺结果写进跨会话缓存"。
    private static var incompleteWalks: Set<String> = []

    private static func computeMeasurement(at path: String,
                                         descendIntoPackages: Bool = false) -> Measurement {
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
            options: descendIntoPackages ? [] : [.skipsPackageDescendants],
            errorHandler: { url, error in
                recordDeniedAccess(url, error: error)
                measurementLock.lock()
                incompleteWalks.insert(sessionKey(path, descendIntoPackages: descendIntoPackages))
                measurementLock.unlock()
                return true
            }
        ) else {
            // 枚举器建不起来（权限等）→ 至少保留"存在"这一事实，并把盲区记下来。
            // 同时标成残缺：这一支的 size 是 0，绝不能被当成权威体积缓存下去。
            let k = sessionKey(path, descendIntoPackages: descendIntoPackages)
            measurementLock.lock()
            incompleteWalks.insert(k); incompleteWalks.insert(cacheKey(path))
            measurementLock.unlock()
            // **无条件**记账，不要再拿 `isPermissionDenied` 当门槛：枚举器返回 nil
            // 本身就是一手失败证据。而 `isPermissionDenied` 在"在途额度已满、这次根本没
            // 去 open"时返回 false，于是这条真实失败会被漏记，界面就把读不到的目录
            // 报成 0 字节——正是 G9 立起来要挡的那一个。
            // 实测这条分支在本机几乎不可达：`FileManager.enumerator` 对 mode 000 的目录
            // 返回的是**可用的**枚举器，拒绝发生在迭代时、由 errorHandler 兜住。
            // 所以这里改的是防御性正确，不是复现过的现场——也因此**没有**为它配自检
            // （强行造一条会造出恒绿断言，v1.73.5 复审就是这么被证伪的）。
            noteDeniedRoot(normalizePath(path))
            return Measurement(newest: modificationDate(path), isDirectory: true, exists: true)
        }

        var result = Measurement(isDirectory: true, exists: true)
        let now = Date()
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            if count > 200_000 {          // 防御：超大目录只估算前 20 万文件
                measurementLock.lock()
                incompleteWalks.insert(sessionKey(path, descendIntoPackages: descendIntoPackages))
                measurementLock.unlock()
                break
            }
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
    ///
    /// 读不到时返回 `[]`——但**先记进盲区清单**：扫描器大量用 `children(of:)`，
    /// 一个被 TCC 拒掉的容器在这里和"空容器"长得一模一样。
    static func children(of path: String, keepHidden: Bool = false) -> [String] {
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: path)
            return items.filter { keepHidden || !$0.hasPrefix(".") }
                .map { (path as NSString).appendingPathComponent($0) }
        } catch {
            recordDeniedAccess(URL(fileURLWithPath: path, isDirectory: true), error: error)
            return []
        }
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

    // MARK: - 归属与时间证据（规则 v2 判据的底座）

    /// 一趟 `lstat` 拿到的归属、时间与类型事实。
    ///
    /// 为什么不用 Foundation：`attributesOfItem` 给不出属主 uid，`resourceValues` 要先构造
    /// URL 再走一趟 getattrlist，而这类判定要对每个候选项各跑一次。
    /// 用 `lstat` 而非 `stat`：粘滞目录里"能不能删"取决于**软链本身**的属主（sticky(7)）。
    struct ItemEvidence {
        let ownerUID: UInt32
        let modificationDate: Date
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymlink: Bool
        let isSocket: Bool
        let isFIFO: Bool
    }

    static func evidence(at path: String) -> ItemEvidence? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        func date(_ tv: timespec) -> Date {
            Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_nsec) / 1_000_000_000)
        }
        return ItemEvidence(ownerUID: st.st_uid,
                            modificationDate: date(st.st_mtimespec),
                            isDirectory: type == S_IFDIR,
                            isRegularFile: type == S_IFREG,
                            isSymlink: type == S_IFLNK,
                            isSocket: type == S_IFSOCK,
                            isFIFO: type == S_IFIFO)
    }

    /// "这一项的用途完成了吗"的判定结果。
    ///
    /// 分档返回而不是给 Bool：自检要能钉住**是哪一维把它挡住的**，
    /// 只测"列出/没列出"的话，一条永远返回 false 的判据也能测过。
    enum IdleVerdict: Equatable {
        case discardable
        /// 阈值内还有写入，用途可能没完
        case writtenRecently
        /// 属主不是当前用户。`/private/tmp` 可写不等于"我们能删"——
        /// sticky(7)：粘滞目录里只有文件属主、目录属主和 root 有删除权。
        case notOwnedByCurrentUser
        /// socket / FIFO：长期不动也可能是某个进程唯一的 IPC 地址，删了没人能重建
        case interprocessChannel
        /// 软链：真正的东西在别处，该按目标的位置判，不在临时目录判据里处理
        case symlink
        case unreadable
    }

    /// Apple 自己的临时文件阈值，本机复核过两处一手依据：
    /// `confstr(3)` 的 `_CS_DARWIN_USER_TEMP_DIR` 说明"放了 3 天以后可能被丢弃"，
    /// `/System/Library/LaunchDaemons/com.apple.bsd.dirhelper.plist` 的
    /// `CLEAN_FILES_OLDER_THAN_DAYS = 3`（每天 03:35 跑）。
    /// 用它不是为了跟 Apple 保持一致，而是为了**不依赖某个用户的习惯**。
    static let appleTempIdleDays = 3

    /// 临时目录项与进程日志的"已完成用途"判定。
    ///
    /// 时间只看 **mtime**，不用 atime。本机实测三条：
    /// ① 读文件、读目录，等 20–25 秒后 atime 不动；
    /// ② 挑一个 atime 已落后 9.5 天的既有文件（`~/Library/Caches/com.apple.appleaccountd/Cache.db`）
    ///    整读一遍，atime 仍不动——这台机器的 Data 卷读取不更新 atime，atime 没有"谁还在读"的信息量；
    /// ③ 抽样 `~/Library/Caches` 800 个文件仍有 260 个 atime > mtime，来源无法解释（拷贝、还原都会造成）。
    /// 更根本的约束是：**判据用的字段不能是自家探查会改动的字段**。
    /// `size(at:)` 对目录要 opendir，在会更新 atime 的卷上，每轮扫描都会把候选项的 atime 刷新，
    /// 那些项就永远过不了 3 天门槛——扫描把自己扫成了"还在用"。
    static func idleVerdict(at path: String,
                            now: Date = Date(),
                            idleDays: Int = appleTempIdleDays,
                            ownerUID: UInt32 = geteuid()) -> IdleVerdict {
        guard let e = evidence(at: path) else { return .unreadable }
        if e.isSymlink { return .symlink }
        if e.isSocket || e.isFIFO { return .interprocessChannel }
        guard e.ownerUID == ownerUID else { return .notOwnedByCurrentUser }
        guard now.timeIntervalSince(e.modificationDate) >= Double(idleDays) * 86400 else {
            return .writtenRecently
        }
        return .discardable
    }

    // MARK: - 使用频率检测（用户诉求：最近使用时间 + 使用频率，判断值不值得删）

    /// 轻量使用检测结果
    struct UsageInfo {
        var lastUsed: Date?      // 最近使用时间（**只看修改时间**；目录取样本内最新 mtime）
        var level: UsageLevel    // 使用频率分级
    }

    /// 使用频率分级的阈值（7 / 30 / 90 天）。抽出来是为了让"按父目录量"和"按本项自己的
    /// 路径量"两条路共用同一套分级，不出现同一个时间在两处算出不同档位。
    static func usageLevel(forAge age: TimeInterval) -> UsageLevel {
        let day: TimeInterval = 86400
        switch age {
        case ..<(7 * day): return .active
        case ..<(30 * day): return .recent
        case ..<(90 * day): return .occasional
        default: return .dormant
        }
    }

    /// 一组路径的合并使用度：以"最近被碰过的那一个"为准。
    ///
    /// 为什么需要：聚合项（D19 守护进程日志、L5 旋转旧日志、C4 过期下载）的主路径是**父目录**，
    /// 而父目录里总有别的文件在写。按父目录量，就把"这 16 个 3 天没动的日志"说成
    /// "几秒前还有写入"，`.staleArtifact` 随即被运行时钳制成「使用中」——
    /// 那不是保守，是**假**：要删的那批一个都没在动。实测本机 D19 就是这么被压住的。
    /// 成本：每项一次 `lstat`，最多看 400 条；一旦已经落进"活跃"档就提前停。
    static func usage(ofPaths paths: [String], now: Date = Date(), limit: Int = 400) -> UsageInfo {
        var newest: Date?
        for path in paths.prefix(limit) {
            guard let e = evidence(at: path) else { continue }
            if newest == nil || e.modificationDate > newest! { newest = e.modificationDate }
            if let n = newest, now.timeIntervalSince(n) < 7 * 86400 { break }
        }
        guard let newest else { return UsageInfo(lastUsed: nil, level: .unknown) }
        return UsageInfo(lastUsed: newest, level: usageLevel(forAge: now.timeIntervalSince(newest)))
    }

    /// 检测路径最近使用情况。
    /// - 单文件：只看 mtime，按距今天数分级（atime 不参与任何判据，见 `usage` 内的说明）。
    /// - 目录：先看目录自身 mtime（快速路径）；较旧时抽样枚举内部文件（限深度 3、样本 2000，
    ///   找到近期修改文件即提前终止），统计最新修改时间与近期文件数来分级。
    /// 性能约束：最坏情况枚举 2000 个文件元数据即停，不做全量求和。
    static func usage(of path: String) -> UsageInfo {
        let now = Date()
        let day: TimeInterval = 86400

        func level(for age: TimeInterval) -> UsageLevel { usageLevel(forAge: age) }

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

    /// 能不能打开这个目录（一次 `opendir`，不读条目）。
    ///
    /// **注意：本函数没有截止时间**，授权未决时会永不返回。判定用
    /// `canOpenDirectoryBounded` / `isPermissionDenied`，别直接用这个——下面两条
    /// "为什么不用别的"只解释了选哪个 API，并不保证它会返回。
    ///
    /// 为什么不用 `access(path, R_OK)`：TCC 是在**打开**那一刻拒绝的，`access` 只看
    /// Unix 权限位——`~/Library/Caches/CloudKit` 的权限位是允许的，`access` 会答"可以"，
    /// 于是恰好漏掉这一整类盲区。
    /// 为什么不用 `contentsOfDirectory`：那要把顶层条目全读一遍，而扫描紧接着就要
    /// 为同一条路径做一次全量遍历；探测只需要回答"开不开得了"。
    static func canOpenDirectory(_ path: String) -> Bool {
        guard let handle = opendir(path) else { return false }
        closedir(handle)
        return true
    }

    /// G9：区分「因权限读不到」与「真的空目录」。
    /// 教训来源（v1.1）：`ls xxx 2>/dev/null | wc -l` 在权限不足时 stdout 为空、
    /// 被 `wc` 计成 `0`，于是「权限被拒」被误读为「空目录」——务必用本函数显式判定。
    ///
    /// 走带截止时间的探测：授权**未决**时 `opendir` 永不返回，判成"读不到"是对的
    /// （这一轮确实没看到内容），但为它一直等下去就把一处盲区换成了整轮无响应。
    static func isPermissionDenied(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            return !FileManager.default.isReadableFile(atPath: path)
        }
        // `.deferred` = 一次都没去 open（在途额度满 / 同路径正被别的线程读）。
        // 把它算成"权限不足"会对没碰过的目录凭空记一条盲区告警。
        return probeDirectory(path) == .unreadable
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
