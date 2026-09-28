import Foundation

/// 扫描期的「谁正打开着这个文件」事实来源（lsof 反查表）。
///
/// ## 为什么必须有这一层
///
/// 在此之前，"所属 App 是否在用"只能靠**目录名像不像**运行中的 App 来猜
/// （`CleanPaths.ownerApp`）。猜不中时 `Scanner.annotateUsage` 写的是
/// `owner?.isRunning ?? false` —— 把"查不到"折叠成了"没在用"。于是"未知"变成了
/// "可以删"，而且 `~/Library/Developer`、`~/.gradle`、`~/.npm`、`/var/folders`
/// 这些**根本不在归属表覆盖范围内**的路径全部走这条退化路径。
///
/// 真机实测（本机，macOS 26 / Apple Silicon）：`lsof -nP -w -F pcn` 用时 0.15 秒、
/// 约 1.7 万行。同一时刻 `GeoServices`、`com.apple.AppleMediaServices`、
/// `com.apple.appstoreagent`、`com.netease.uuremote.server` 等进程正持有
/// `~/Library/Caches` 下对应目录——**而同一份扫描把它们全部标成了「可清理」**。
/// 事实本来伸手可得，只是没接到决策链上。
///
/// ## 设计约束
///
/// - **一轮扫描只转储一次**（`ensureFresh`），绝不每个清理项 fork 一次 lsof。
/// - 查不到 ≠ 没在用。lsof 看不见（进程已退出、文件已关闭、权限不足）时返回空，
///   调用方必须把它当**没有证据**，不得当"确定没在用"。
/// - 转储失败时**清空**而不是留旧表：拿上一轮的进程快照配这一轮的 mtime 出结论，
///   比完全没有事实更糟。
enum ProcessOccupancy {

    /// 转储的新鲜度上限。扫描通常几十秒内跑完，2 分钟足够覆盖一轮；
    /// 超过就重取，避免长时间挂着的进程用一份过期事实下结论。
    static let freshness: TimeInterval = 120

    private static let stateLock = NSLock()
    /// 串行化"重取"，避免 6 个并发分类同时 fork lsof。
    private static let refreshLock = NSLock()

    private static var openPaths: [String] = []
    private static var holdersByPath: [String: Set<String>] = [:]
    private static var lastRefresh: Date?
    /// 最近一次转储是否成功。self 检与 UI 诊断要能区分"没人持有"和"没查成"。
    private static var lastRefreshSucceeded = false

    // MARK: - 转储

    /// 一次 lsof 全量转储，建立"被打开路径 → 进程名"反查表。
    @discardableResult
    static func refresh() -> Bool {
        let text = SafeProcess.output("/usr/sbin/lsof", ["-nP", "-w", "-F", "pcn"], timeout: 20)
        guard let text else {
            stateLock.lock()
            openPaths = []
            holdersByPath = [:]
            lastRefresh = nil
            lastRefreshSucceeded = false
            stateLock.unlock()
            return false
        }
        let parsed = parse(text)
        stateLock.lock()
        openPaths = parsed.paths
        holdersByPath = parsed.holders
        lastRefresh = Date()
        lastRefreshSucceeded = true
        stateLock.unlock()
        return true
    }

    /// 解析 `lsof -F pcn` 的字段流。
    ///
    /// 抽成静态纯函数是为了自检能拿**固定输入**钉住它——真机转储每次都不一样，
    /// 拿真机输出去断言解析器等于什么都没测。
    ///
    /// 字段语义：`p<pid>` 起一个新进程块，`c<command>` 是该进程的命令名，
    /// `n<name>` 是该进程持有的路径。其余字段（`f` fd、`t` type 等）对本用途无意义。
    static func parse(_ text: String) -> (paths: [String], holders: [String: Set<String>]) {
        var holders: [String: Set<String>] = [:]
        var command = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                // 新进程块开始：先清空，否则 `c` 缺失时会把文件记到上一个进程头上。
                command = ""
            case "c":
                command = value
            case "n":
                // lsof 在管道 / 匿名 inode / socket 上给出的不是文件系统路径。
                // 它们永远匹配不到清理项，留着只会把前缀索引撑大。
                guard value.hasPrefix("/") else { continue }
                let name = command.isEmpty ? "未知进程" : command
                holders[value, default: []].insert(name)
            default:
                continue
            }
        }
        return (holders.keys.sorted(), holders)
    }

    /// 需要时重取。并发调用下只会真的转储一次。
    private static func ensureFresh() {
        stateLock.lock()
        let stale = lastRefresh.map { Date().timeIntervalSince($0) > freshness } ?? true
        stateLock.unlock()
        guard stale else { return }

        refreshLock.lock()
        defer { refreshLock.unlock() }
        // 排队期间别人可能已经刷过了：进锁后必须复查，否则 6 路并发会转储 6 次。
        stateLock.lock()
        let stillStale = lastRefresh.map { Date().timeIntervalSince($0) > freshness } ?? true
        stateLock.unlock()
        if stillStale { refresh() }
    }

    // MARK: - 查询

    /// 此刻持有 `path` 本身、或它下面任意文件的进程名（已排序去重）。
    ///
    /// 必须连后代一起查：lsof 列的是**被打开的那个文件**，不是目录项。
    /// 缓存目录本身很少被 open，真正被持有的是它下面的一层层文件，
    /// 只比 exact 匹配会漏掉绝大多数真实占用。
    static func holders(of path: String) -> [String] {
        ensureFresh()
        let key = normalize(path)
        guard !key.isEmpty, key != "/" else { return [] }
        var probes = [key]
        // lsof 报的是解析后的真实路径（`/var/folders` 会显示成 `/private/var/folders`）。
        // 清理项的路径没解析过，两边必须都试，否则这一整类永远查不到占用者。
        let resolved = normalize(FileSystem.realPath(path))
        if resolved != key, !resolved.isEmpty { probes.append(resolved) }

        stateLock.lock()
        // 数组/字典都是值类型：这里拿到的是 COW 引用，解开锁之后再遍历不会读到半更新状态。
        let paths = openPaths
        let table = holdersByPath
        stateLock.unlock()

        var names = Set<String>()
        for probe in probes {
            if let exact = table[probe] { names.formUnion(exact) }
            let prefix = probe + "/"
            var i = lowerBound(paths, prefix)
            while i < paths.count, paths[i].hasPrefix(prefix) {
                if let hit = table[paths[i]] { names.formUnion(hit) }
                i += 1
            }
        }
        return names.sorted()
    }

    /// 聚合项要量自己那批路径，语义与 `annotateUsage` 保持一致。
    static func holders(ofPaths paths: [String]) -> [String] {
        var names = Set<String>()
        for path in paths { names.formUnion(holders(of: path)) }
        return names.sorted()
    }

    static func isInUse(_ path: String) -> Bool { !holders(of: path).isEmpty }

    /// 最近一次转储是否成功、表中条目数、观测时刻——供诊断与自检使用。
    static func diagnostics() -> (succeeded: Bool, pathCount: Int, observedAt: Date?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (lastRefreshSucceeded, openPaths.count, lastRefresh)
    }

    /// 从当前反查表里取若干条被打开的路径。
    /// 只给自检与诊断用：让"反查表 ↔ 查询接口"能做一次真实的往返验证，
    /// 而不是只拿手工构造的固定输入自证解析器。
    static func sampleOpenPaths(limit: Int = 3) -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(openPaths.prefix(max(0, limit)))
    }

    // MARK: - 内部

    private static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// 已排序数组里第一个 `>= target` 的下标。
    /// 用于把"所有以 prefix 开头的路径"这个连续区间定位出来。
    private static func lowerBound(_ sorted: [String], _ target: String) -> Int {
        var lo = 0
        var hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
