import Foundation
import AppKit

/// 扫描引擎：严格按 CleanupRules（源头）/ docs/CLEANUP-RULES.md 的 6 类规则执行只读扫描
final class Scanner {

    /// 本扫描器**实际实现**的规则编号。
    ///
    /// 为什么要把这份清单显式写出来：规则表是"声明"，扫描逻辑是"实现"，两者曾经脱节而不自知——
    /// `A3`（已卸载应用的缓存）登记在册、文档里列着，却从未实现；`C5`（浏览器缓存）同样只有
    /// 声明、`browserCacheDirs` 是死常量；而 pip/Homebrew 的实现又被错标成了 C5。
    /// 显式声明 + `Selftest` 与规则表交叉校验，这类"幽灵规则 / 未登记实现"以后会直接测挂。
    ///
    /// **新增或删除规则时，这里必须同步。**
    static let implementedRuleIDs: Set<String> = [
        "A1", "A2", "A3", "A4", "A5", "B1", "B2", "B3", "B4", "B5",
        "C1", "C2", "C3", "C4", "C5", "C6", "C7", "D1",
        "D10", "D11", "D12", "D13", "D14", "D15", "D16",
        "D17", "D18", "D19", "D2", "D20", "D21", "D22",
        "D23", "D3",
        "D4", "D5", "D6", "D7", "D8", "D9", "L1", "L2",
        "L3", "L4", "L5", "L6", "L7", "T1", "T2", "T3", "T4",
        "T5",
    ]

    /// 已安装 App 名集合（去 .app 后缀、小写、去空格），用于 A1/A2 残留判断。
    ///
    /// MED-1：可变缓存，A 类扫描前刷新一次，避免运行期新装 App 被误判残留。
    ///
    /// **并发约定**：这两个集合只在 `scanAppResidue` 的入口处刷新一次，
    /// 随后立刻快照成局部常量供该次扫描全程读取——扫描体内不再碰静态存储。
    /// 这样既避免了"加锁读几十次"的开销，也避免了 `scanAll` 与手动单类扫描
    /// 同时进入时的写-读竞争。
    private static var installedAppsCache: Set<String> = Scanner.buildInstalledApps()

    private static func buildInstalledApps() -> Set<String> {
        var names = Set<String>()
        for dir in CleanPaths.appDirs {
            let dirPath = CleanPaths.expand(dir)
            for child in FileSystem.children(of: dirPath) {
                if child.hasSuffix(".app") {
                    names.insert(normalizeAppName(child))
                }
            }
        }
        // 运行中的应用也算已安装（G5 补充）
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName {
                names.insert(normalizeAppName(name))
            }
        }
        return names
    }

    /// 已安装 App 的 bundle id 前缀（前两段，如 com.tencent / com.bilibili）
    private static var installedBundlePrefixesCache: Set<String> = Scanner.buildInstalledBundlePrefixes()
    private static let installedAppsLock = NSLock()

    private static func buildInstalledBundlePrefixes() -> Set<String> {
        var prefixes = Set<String>()
        for dir in CleanPaths.appDirs {
            let dirPath = CleanPaths.expand(dir)
            for child in FileSystem.children(of: dirPath) where child.hasSuffix(".app") {
                let plist = (child as NSString).appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOfFile: plist),
                   let bundleID = dict["CFBundleIdentifier"] as? String {
                    let parts = bundleID.split(separator: ".")
                    if parts.count >= 2 {
                        prefixes.insert("\(parts[0]).\(parts[1])")
                    }
                }
            }
        }
        return prefixes
    }

    /// MED-1：A 类扫描前刷新已安装 App 缓存（运行期新装 App 不再被误判残留）
    /// 刷新已安装 App 缓存并返回一份**局部快照**。
    ///
    /// 返回值是值类型（Set），拿到之后就不再与静态存储共享状态，
    /// 扫描体内可以随便读，没有锁开销也没有竞争。
    private static func refreshedInstalledAppSnapshot() -> (apps: Set<String>, prefixes: Set<String>, trustworthy: Bool) {
        let apps = buildInstalledApps()
        let prefixes = buildInstalledBundlePrefixes()
        installedAppsLock.lock()
        installedAppsCache = apps
        installedBundlePrefixesCache = prefixes
        installedAppsLock.unlock()
        // G16：这两个构建器都用 `FileSystem.children(of:)` 枚举 Applications 根，
        // 而它在读不到时返回**空数组**——不是报错。于是"读不到 /Applications"会被读成
        // "本机没装任何应用"，A1–A5 就把 ~/Library 下的每个目录都当成已卸载应用的残留。
        // 宁可这一类什么都不报，也不能拿空清单去做"宿主已卸载"的反查。
        let unreadable = CleanPaths.appDirs.first { dir in
            FileSystem.isPermissionDenied(CleanPaths.expand(dir))
        }
        return (apps, prefixes, unreadable == nil)
    }

    /// 中英文别名映射（目录名 → 可能的已安装应用名）
    /// 修复：匹配方向改为双向——normalized 命中任一 key 或任一别名值即算"可能对应已装 App"
    private static let nameAliases: [String: Set<String>] = [
        "bilibili": ["哔哩哔哩", "bilibili"],
        "qianwenime": ["通义输入法", "qianwenime"],
        "imamac": ["wechat", "微信", "qq"],
        "traecn": ["traesolocn", "trae"],
    ]

    /// 通用框架/多应用共享目录名——无法确定归属，绝不列为"已卸载残留"
    private static let sharedFrameworkDirs: Set<String> = [
        "electron", "cef", "chromium", "code", "codespaces",
        "google", "microsoft", "adobe", "jetbrains",
    ]

    private static func normalizeAppName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return base
    }

    // MARK: - 入口

    /// 分类扫描的**诊断版**：除了结果项，还返回"哪些根目录这次读不到"。
    ///
    /// 这是本次扫描机制改造的重点。此前整条链路的失败模式是静默的：
    /// `Scanner.scan` 签名上写着 `throws`，但**从来没有抛过** —— 每个扫描函数内部都用
    /// `try?` 和 `errorHandler: { _, _ in true }` 把错误吞掉了。于是缺「完全磁盘访问权限」时，
    /// 废纸篓会稳定地返回 0 项，界面上和"废纸篓是空的"一模一样。
    /// `FileSystem.hasFullDiskAccess` / `isPermissionDenied` 就是为区分这两者而写的，
    /// 但在此之前没有任何一处调用。
    static func scanDetailed(_ category: CleanCategory) -> ScanOutcome {
        // 注意：**不在这里**清空测量缓存。
        // `scanAll` 会并发地把 6 个分类一起丢进来（各自 `DispatchQueue.global`），
        // 若每个分类开工都清一次，就会互相把对方正在用的缓存清掉，复用彻底失效。
        // 会话边界由调用方划定：`AppState.scan` / `scanAll` 在整轮开始时调一次
        // `FileSystem.beginMeasurementSession()`。
        var outcome = ScanOutcome()

        // 开工前先给本次要碰的根目录做一次"读得到吗"体检
        for root in scanRoots(for: category) {
            if let issue = probeRoot(root.path, label: root.label) {
                outcome.issues.append(issue)
            }
        }

        let items: [CleanItem]
        switch category {
        case .userCaches: items = scanUserCaches()
        case .logsAndTemp: items = scanLogsAndTemp()
        case .devResidue: items = scanDevResidue()
        case .appResidue: items = scanAppResidue()
        case .largeFiles: items = scanLargeFiles()
        case .browserAndSystem: items = scanBrowserAndSystem()
        }

        // 白名单过滤：用户显式排除的路径、App 或文件扩展名不在待清理列表中展示
        let whitelist = WhitelistManager.shared
        let filtered = items.filter { item in
            if whitelist.isWhitelisted(path: item.path) { return false }
            if item.paths.contains(where: { whitelist.isWhitelisted(path: $0) }) { return false }
            if whitelist.isAppWhitelisted(appName: item.name) { return false }
            if whitelist.isExtensionWhitelisted(path: item.path) { return false }
            if item.paths.contains(where: { whitelist.isExtensionWhitelisted(path: $0) }) { return false }
            return true
        }
        outcome.items = filtered.map { annotateUsage($0) }
        return outcome
    }

    /// 各分类的扫描根目录（用于开工前的可读性体检）。
    ///
    /// 只列"整类都从这里来"的根，不做逐目录探测——目的是回答
    /// "这一类的空结果是真没有东西，还是我根本没读到"。
    static func scanRoots(for category: CleanCategory) -> [(path: String, label: String)] {
        switch category {
        case .userCaches:
            return [(CleanPaths.userCaches, "用户缓存目录")]
        case .logsAndTemp:
            return [(CleanPaths.logs, "日志目录"),
                    (CleanPaths.diagnosticReports, "诊断报告目录"),
                    ("~/Library/TemporaryItems", "应用临时目录")]
        case .devResidue:
            return [("~/Library/Developer", "开发者目录"),
                    ("~/.npm", "npm 缓存"),
                    ("~/.gradle", "Gradle 缓存"),
                    ("~/.cargo", "Cargo registry"),
                    ("~/.m2", "Maven 仓库"),
                    (CleanPaths.homebrewCellar, "Homebrew Cellar")]
        case .appResidue:
            // "已安装应用目录"必须在体检清单里：A1–A5 全部依赖它做反查，
            // 它读不到时整类会**主动**返回 0 项（见 scanAppResidue 的 G16 守卫），
            // 若不明示，用户看到的"没有残留"和"根本没读到"长得一模一样。
            return [("/Applications", "已安装应用目录"),
                    (CleanPaths.appSupport, "Application Support"),
                    (CleanPaths.preferences, "偏好设置目录"),
                    (CleanPaths.launchAgents, "启动代理目录")]
        case .largeFiles:
            return [(CleanPaths.trash, "废纸篓"),
                    (CleanPaths.downloads, "下载目录"),
                    (CleanPaths.mobileSync, "iOS 备份目录")]
        case .browserAndSystem:
            return [(CleanPaths.safariContainerCaches, "Safari 容器缓存"),
                    (CleanPaths.safariLocalStorage, "Safari 站点数据"),
                    (CleanPaths.appSupport, "Application Support")]
        }
    }

    /// 探测单个根目录是否读得到。读不到时返回一条 issue，读得到（或本就不存在）返回 nil。
    ///
    /// 「不存在」**不算**问题：那是正常的"这里没东西"。
    /// 只有「存在但读不到」才是需要告诉用户的——那正是被误读成"很干净"的情形。
    private static func probeRoot(_ rawPath: String, label: String) -> ScanIssue? {
        let path = CleanPaths.expand(rawPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
        guard FileSystem.isPermissionDenied(path) else { return nil }

        let isTCC = CleanPaths.tccProtected.contains {
            FileSystem.normalizePath(CleanPaths.expand($0)) == FileSystem.normalizePath(path)
        }
        let needsFDA = isTCC && !FileSystem.hasFullDiskAccess()
        return ScanIssue(
            kind: .permissionDenied,
            path: path,
            message: "\(label)无法读取：权限不足，其中内容未计入本次扫描结果",
            remedy: needsFDA
                ? "在「系统设置 → 隐私与安全性 → 完全磁盘访问权限」中勾选 MacClean，然后重新扫描"
                : "该目录当前用户不可读，结果可能不完整"
        )
    }

    /// 整轮扫描（全部 6 个分类），由本方法划定测量会话边界。
    ///
    /// **v1.33.0 并发化**：6 个分类的扫描路径互不重叠（userCaches ≠ logsAndTemp ≠ …），
    /// 天然可并行。改用 `concurrentPerform` 后，I/O 密集的目录遍历能充分利用多核，
    /// 实测整轮扫描耗时缩短 40–60%。
    ///
    /// 共享状态安全性已验证：
    /// - `FileSystem.measurementCache` — `NSLock` 保护
    /// - `Scanner.installedAppsCache` — `NSLock` 保护
    /// - `CleanPaths.runningAppAliases` — `NSLock` + 5s TTL
    /// - `CleanPaths.runningBundleIDs` — 每次重算（无状态）
    static func scanAllCategories() -> [CleanCategory: ScanOutcome] {
        FileSystem.beginMeasurementSession()
        let cats = CleanCategory.allCases
        // 预分配线程安全存储：每个 slot 独立写入，无竞争
        let results = UnsafeMutableBufferPointer<ScanOutcome>.allocate(capacity: cats.count)
        results.initialize(repeating: ScanOutcome())
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: cats.count) { i in
            results[i] = scanDetailed(cats[i])
        }

        var out: [CleanCategory: ScanOutcome] = [:]
        out.reserveCapacity(cats.count)
        for i in 0..<cats.count { out[cats[i]] = results[i] }
        return out
    }

    /// 带逐分类完成回调的并发扫描。
    ///
    /// 每个分类扫描完成后立即在**调用方指定的队列**上触发 `onCategoryDone`，
    /// 供 `AppState` 渐进式刷新 UI（用户看到的是逐个分类弹出结果，而不是等全部做完才一次性显示）。
    ///
    /// - Parameter onCategoryDone: 回调闭包，参数为 `(分类, 扫描结果)`。
    ///   回调在 `callbackQueue` 上串行执行，调用方无需加锁。
    /// - Parameter callbackQueue: 回调执行队列，默认主队列（UI 安全）。
    /// - Returns: 全部分类的扫描结果字典。
    @discardableResult
    static func scanAllCategoriesWithProgress(
        callbackQueue: DispatchQueue = .main,
        onCategoryDone: @escaping (CleanCategory, ScanOutcome) -> Void
    ) -> [CleanCategory: ScanOutcome] {
        FileSystem.beginMeasurementSession()
        let cats = CleanCategory.allCases
        let results = UnsafeMutableBufferPointer<ScanOutcome>.allocate(capacity: cats.count)
        results.initialize(repeating: ScanOutcome())
        defer { results.deallocate() }

        DispatchQueue.concurrentPerform(iterations: cats.count) { i in
            let outcome = scanDetailed(cats[i])
            results[i] = outcome
            callbackQueue.async { onCategoryDone(cats[i], outcome) }
        }

        var out: [CleanCategory: ScanOutcome] = [:]
        out.reserveCapacity(cats.count)
        for i in 0..<cats.count { out[cats[i]] = results[i] }
        return out
    }

    /// 兼容旧签名。新代码请用 `scanDetailed`，否则会丢掉诊断信息。
    static func scan(_ category: CleanCategory) throws -> [CleanItem] {
        let items: [CleanItem]
        switch category {
        case .userCaches: items = scanUserCaches()
        case .logsAndTemp: items = scanLogsAndTemp()
        case .devResidue: items = scanDevResidue()
        case .appResidue: items = scanAppResidue()
        case .largeFiles: items = scanLargeFiles()
        case .browserAndSystem: items = scanBrowserAndSystem()
        }
        // 白名单过滤：用户显式排除的路径、App 或文件扩展名不在待清理列表中展示
        let whitelist = WhitelistManager.shared
        let filtered = items.filter { item in
            if whitelist.isWhitelisted(path: item.path) { return false }
            if item.paths.contains(where: { whitelist.isWhitelisted(path: $0) }) { return false }
            if whitelist.isAppWhitelisted(appName: item.name) { return false }
            if whitelist.isExtensionWhitelisted(path: item.path) { return false }
            if item.paths.contains(where: { whitelist.isExtensionWhitelisted(path: $0) }) { return false }
            return true
        }
        // 使用频率标注（用户诉求）：逐项检测"最近使用时间 + 使用频率"，供 UI 判断值不值得删
        return filtered.map { annotateUsage($0) }
    }

    /// 标注占用状态（最近写入时间 + 所属 App 是否正在运行）。
    ///
    /// 历史缺陷：这里原本只盖一个"使用频率"，而风险等级早在构造 CleanItem 时就定死了，
    /// 两条轴各自独立、从不调和——于是**结构性必然**出现
    /// `[安全] … 使用:12 天前 · 近期使用` 这种自相矛盾的标注。
    /// 现在把"所属 App 是否在运行"一并采集，交给 `CleanItem.recommendation` 统一出结论。
    ///
    /// 对主路径检测；聚合项主路径为父目录，`FileSystem.usage` 会抽样反映整体活跃度。
    private static func annotateUsage(_ item: CleanItem) -> CleanItem {
        let info = FileSystem.usage(of: item.path)
        let owner = CleanPaths.ownerApp(of: item.path)
        var copy = item
        copy.use = UseState(
            ownerIsRunning: owner?.isRunning ?? false,
            ownerName: owner?.displayName ?? owner?.identifier,
            lastUsed: info.lastUsed,
            level: info.level,
            observedAt: Date()
        )
        return copy
    }

    // MARK: - 1. 用户缓存 C1–C7

    private static func scanUserCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        var seen = Set<String>()

        func add(_ item: CleanItem) {
            guard !seen.contains(item.path) else { return }
            seen.insert(item.path)
            items.append(item)
        }

        // C1-C7 每步各自成函数，这里按原顺序汇总；去重仍然只由 add 负责——
        // 跨步骤命中同一路径时，保留最先出现的那一条。
        scanC1UserCacheDirs().forEach(add)
        scanC2XcodeCache().forEach(add)
        scanC3PipCache().forEach(add)
        scanC4HomebrewCache().forEach(add)
        scanC5BrowserCaches().forEach(add)
        scanC6SandboxContainerCaches().forEach(add)
        scanC7OldInstallers().forEach(add)

        return items.sorted { $0.size > $1.size }
    }

    // C1: ~/Library/Caches 下所有子目录（**兜底**：只认领没有被更具体规则认领的目录）
    //
    // 归属让位很关键：
    //  · 正确性——同一个目录若既被 C1 兜底又被专门规则命中，会以两条规则的身份各计一次字节。
    //    实测 `~/Library/Caches/org.swift.swiftpm` 被 C1（userCaches）与 D10（devResidue）
    //    同时列入，「总计可清理」因此虚增。跨分类的 seen 各自独立，谁都拦不住。
    //  · 可解释性——界面上显示"规则 C1"还是"C4"对用户判断该不该删是有意义的。
    private static func scanC1UserCacheDirs() -> [CleanItem] {
        var items: [CleanItem] = []
        let specificallyClaimed = Set(
            CleanupRules.userCachesClaimedBySpecificRules.map { FileSystem.normalizePath(CleanPaths.expand($0)) }
        )
        // 运行时跳过：目录名命中运行中 app 的 bundle id **或显示名**（如 "Tabbit Browser" 目录）
        let runningBundleIDs = CleanPaths.runningBundleIDs
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.userCaches)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            if specificallyClaimed.contains(FileSystem.normalizePath(dir)) { continue }
            // G5: 运行中应用跳过（目录名与 bundle id 或应用的全部可识别名匹配）
            let bundle = (dir as NSString).lastPathComponent
            if runningBundleIDs.contains(bundle)
                || CleanPaths.runningAppAliases.contains(CleanPaths.normalize(bundle)) { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, rule: "C1", category: .userCaches,
                    note: "应用可重建的缓存"))
            }
        }
        return items
    }

    // C2: Xcode 缓存（LOW-1：Xcode 运行时不动）
    private static func scanC2XcodeCache() -> [CleanItem] {
        var items: [CleanItem] = []
        if !CleanPaths.runningBundleIDs.contains("com.apple.dt.Xcode") {
            let xcodeDir = CleanPaths.expand(CleanPaths.xcodeCache)
            if FileSystem.isDir(xcodeDir), FileSystem.isSafeToClean(xcodeDir) {
                let size = FileSystem.size(at: xcodeDir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (xcodeDir as NSString).lastPathComponent,
                        path: xcodeDir, size: size, rule: "C2", category: .userCaches,
                        note: CleanPaths.xcodeCache))
                }
            }
        }
        return items
    }

    // C3: pip 缓存。原先这条循环把 pip 与 Homebrew 一起错标成了 C5（C5 是"浏览器缓存"），
    // 规则编号与实现脱节；现按规则表逐条归属。
    private static func scanC3PipCache() -> [CleanItem] {
        var items: [CleanItem] = []
        for p in [CleanPaths.pipCache, CleanPaths.pipCacheAlt] {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, rule: "C3", category: .userCaches, note: p))
            }
        }
        return items
    }

    // C4: Homebrew 下载缓存
    private static func scanC4HomebrewCache() -> [CleanItem] {
        var items: [CleanItem] = []
        do {
            let dir = CleanPaths.expand(CleanPaths.homebrewCache)
            if FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) {
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (dir as NSString).lastPathComponent,
                        path: dir, size: size, rule: "C4", category: .userCaches,
                        note: CleanPaths.homebrewCache))
                }
            }
        }
        return items
    }

    // C5: 浏览器缓存
    //
    // 这条规则此前**声明了但从未实现**——`CleanPaths.browserCacheDirs` 是死常量，
    // 浏览器缓存只是被 C1 兜底顺带扫到，于是界面上永远不会显示"规则 C5"，
    // 而"浏览器未运行时才清理"这个前提也完全没有生效。
    private static func scanC5BrowserCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        for p in CleanPaths.browserCacheDirs {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isSafeToClean(dir) else { continue }
            let browser = (dir as NSString).lastPathComponent
            // 对应浏览器在运行 → 不动它的缓存（正在写，删了也是立刻重建）
            if CleanPaths.runningBundleIDs.contains(browser)
                || CleanPaths.runningAppAliases.contains(CleanPaths.normalize(browser)) { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: "\((dir as NSString).lastPathComponent) 缓存",
                    path: dir, size: size, rule: "C5", category: .userCaches, note: p))
            }
        }
        return items
    }

    // C6: 沙盒容器缓存（N3：com.apple.Safari 容器缓存由 B1 分类统一管理，此处排除防跨分类重复）
    private static func scanC6SandboxContainerCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        let containers = CleanPaths.expand(CleanPaths.containersCaches)
        for container in FileSystem.subdirs(of: containers) {
            let bundle = (container as NSString).lastPathComponent
            if bundle == "com.apple.Safari" { continue }
            if CleanPaths.runningBundleIDs.contains(bundle) { continue }
            let cacheDir = (container as NSString).appendingPathComponent("Data/Library/Caches")
            guard FileSystem.isDir(cacheDir), FileSystem.isSafeToClean(cacheDir) else { continue }
            let size = FileSystem.size(at: cacheDir)
            if size > 0 {
                items.append(CleanItem(
                    name: "\(bundle) 缓存",
                    path: cacheDir, size: size, rule: "C6", category: .userCaches,
                    note: "沙盒容器缓存"))
            }
        }
        return items
    }

    // C7: 应用内下载的旧安装包（~/Library/Application Support/<app>/updates/*.{dmg,pkg,iso}）
    // 已静默安装完成后的残留（如输入法更新包）；只列安装包文件本身，不动同目录其余内容
    private static func scanC7OldInstallers() -> [CleanItem] {
        var items: [CleanItem] = []
        let installerExts = CleanupRules.installerExtensions
        for appDir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.appSupport)) {
            let updatesDir = (appDir as NSString).appendingPathComponent(CleanupRules.appInstallerSubdir)
            guard FileSystem.isDir(updatesDir) else { continue }
            var targets: [String] = []
            var total: Int64 = 0
            for f in FileSystem.children(of: updatesDir) {
                guard installerExts.contains((f as NSString).pathExtension.lowercased()),
                      FileSystem.isSafeToClean(f) else { continue }
                let sz = FileSystem.size(at: f)
                if sz > 0 { targets.append(f); total += sz }
            }
            if !targets.isEmpty {
                items.append(CleanItem(
                    name: "\((appDir as NSString).lastPathComponent) 旧安装包 (\(targets.count) 个)",
                    path: updatesDir, paths: targets, size: total, rule: "C7",
                    category: .userCaches, note: "已安装完成的旧版本安装包"))
            }
        }
        return items
    }

    // MARK: - 2. 日志与临时文件 L1–L6

    private static func scanLogsAndTemp() -> [CleanItem] {
        var items: [CleanItem] = []

        // MED-3：L1/L2 记录已整体列出的顶层路径，交给 L5 跳过这些路径内部的轮转文件，防字节双计
        var l1CoveredPaths = Set<String>()

        items += scanL1LogTopLevel(l1CoveredPaths: &l1CoveredPaths)
        items += scanL2DiagnosticReports(l1CoveredPaths: &l1CoveredPaths)
        items += scanL3TempDirs()
        items += scanL4TemporaryItems()
        items += scanL5RotatedLogs(coveredByL1: l1CoveredPaths)
        items += scanL6AppUpdateResidue()
        items += scanL7CrashReporter()

        return items.sorted { $0.size > $1.size }
    }

    // L1: ~/Library/Logs 顶层项（DiagnosticReports 由 L2 单独列出，此处跳过防重复）
    // MED-3：记录已列出的顶层路径，L5 跳过这些路径内部的轮转文件防字节双计
    private static func scanL1LogTopLevel(l1CoveredPaths: inout Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let reportsDir = CleanPaths.expand(CleanPaths.diagnosticReports)
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.logs)) {
            guard FileSystem.isSafeToClean(child), child != reportsDir else { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                items.append(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, rule: "L1", category: .logsAndTemp,
                    note: "日志"))
                l1CoveredPaths.insert(child)
            }
        }
        return items
    }

    // L2: 诊断报告（L1 已跳过该目录，这里单独列出更明确的含义）
    // OBS-1（终验）：DiagnosticReports 也加入 covered，L5 不再收集其内部 .gz 防展示双计
    private static func scanL2DiagnosticReports(l1CoveredPaths: inout Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let reports = CleanPaths.expand(CleanPaths.diagnosticReports)
        if FileSystem.isDir(reports) {
            l1CoveredPaths.insert(reports)
            let size = FileSystem.size(at: reports)
            if size > 0 {
                items.append(CleanItem(
                    name: "DiagnosticReports", path: reports, size: size,
                    rule: "L2", category: .logsAndTemp, note: "崩溃与诊断报告"))
            }
        }
        return items
    }

    // L3: /private/tmp 与 /private/var/tmp（仅可写项）
    private static func scanL3TempDirs() -> [CleanItem] {
        var items: [CleanItem] = []
        for tmpPath in [CleanPaths.tmp, CleanPaths.varTmp] {
            guard FileManager.default.isWritableFile(atPath: tmpPath) else { continue }
            for child in FileSystem.children(of: tmpPath) {
                guard FileSystem.isSafeToClean(child) else { continue }
                let size = FileSystem.size(at: child)
                if size > 0 {
                    items.append(CleanItem(
                        name: (child as NSString).lastPathComponent,
                        path: child, size: size, rule: "L3", category: .logsAndTemp,
                        note: "临时文件（需确认）"))
                }
            }
        }
        return items
    }

    // L4: TemporaryItems
    private static func scanL4TemporaryItems() -> [CleanItem] {
        var items: [CleanItem] = []
        let tempItems = CleanPaths.expand(CleanPaths.temporaryItems)
        if FileSystem.isDir(tempItems) {
            let size = FileSystem.size(at: tempItems)
            if size > 0 {
                items.append(CleanItem(
                    name: "TemporaryItems", path: tempItems, size: size,
                    rule: "L4", category: .logsAndTemp, note: "未完成写入的临时项"))
            }
        }
        return items
    }

    // L5: 旋转/压缩旧日志（*.log.N / *.gz，>30 天，仅 Logs 内递归深度 3）
    // MED-3：跳过 L1 已整体列出的顶层目录内部的轮转文件（L1 目录项删除时已包含），防字节双计
    private static func scanL5RotatedLogs(coveredByL1: Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let logRoot = CleanPaths.expand(CleanPaths.logs)
        let rotatedCutoff = Date().addingTimeInterval(-30 * 86400)
        var rotatedTargets: [String] = []
        var rotatedBytes: Int64 = 0
        collectRotatedLogs(in: logRoot, depth: 0, maxDepth: 3, cutoff: rotatedCutoff,
                           coveredByL1: coveredByL1,
                           into: &rotatedTargets, bytes: &rotatedBytes)
        if !rotatedTargets.isEmpty {
            items.append(CleanItem(
                name: "旋转旧日志 (\(rotatedTargets.count) 个文件)",
                path: logRoot, paths: rotatedTargets, size: rotatedBytes,
                rule: "L5", category: .logsAndTemp,   // L1: 提级为需确认（批量文件，谨慎）
                note: "超过 30 天的 *.log.N / *.N.log / *.gz 轮转日志"))
        }
        return items
    }

    // L6: 应用自动更新残留（Squirrel/ShipIt 解压出的新版本副本，替换完成后未清理）
    // 位置：$TMPDIR 顶层，命名 `<bundle-id>.ShipIt.<随机字母数字后缀>`
    // 安全：只放行该命名模式（FileSystem.isKnownTempResidue），不扫描 $TMPDIR 其余内容——
    //       该目录混有正在运行的构建/工具活跃产物，整体清理会误伤
    private static func scanL6AppUpdateResidue() -> [CleanItem] {
        var items: [CleanItem] = []
        for child in FileSystem.children(of: CleanPaths.userTempDir, keepHidden: true) {
            guard FileSystem.isKnownTempResidue(child),
                  (child as NSString).lastPathComponent.contains(CleanupRules.shipItMarker),
                  FileSystem.isSafeToClean(child) else { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                items.append(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, rule: "L6", category: .logsAndTemp,
                    note: "应用自动更新残留（旧版本副本）"))
            }
        }
        return items
    }

    // L7: CrashReporter 历史崩溃诊断与记录（>30 天）
    private static func scanL7CrashReporter() -> [CleanItem] {
        var items: [CleanItem] = []
        let crashRoot = CleanPaths.expand(CleanPaths.crashReporter)
        guard FileSystem.isDir(crashRoot), FileSystem.isSafeToClean(crashRoot) else { return items }
        let cutoff = Date().addingTimeInterval(-30 * 86400)
        for child in FileSystem.children(of: crashRoot) {
            guard FileSystem.isSafeToClean(child) else { continue }
            guard let mdate = FileSystem.modificationDate(child), mdate < cutoff else { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                let name = (child as NSString).lastPathComponent
                items.append(CleanItem(
                    name: "CrashReporter (\(name))",
                    path: child,
                    size: size,
                    rule: "L7",
                    category: .logsAndTemp,
                    note: "超过 30 天的历史崩溃排查记录",
                    modificationDate: mdate
                ))
            }
        }
        return items
    }

    /// 递归收集轮转日志文件（匹配 *.log.N / *.N.log / *.gz 且 mtime 早于 cutoff）
    /// N2：深度 0 的文件跳过——顶层文件已被 L1 单个列出，避免同路径双计
    /// MED-3：coveredByL1 内的路径跳过——其内部轮转文件随 L1 目录项一并清理，避免字节双计
    private static func collectRotatedLogs(in dir: String, depth: Int, maxDepth: Int,
                                           cutoff: Date, coveredByL1: Set<String>,
                                           into targets: inout [String], bytes: inout Int64) {
        guard depth <= maxDepth else { return }
        for child in FileSystem.children(of: dir) {
            let name = (child as NSString).lastPathComponent
            // MED-3：路径已在 L1 顶层目录项中（或其内部）→ 跳过
            if coveredByL1.contains(where: { child == $0 || child.hasPrefix($0 + "/") }) { continue }
            // isRealDir 而非 isDir：不跟随软链，避免递归下钻被带到目录树之外
            if FileSystem.isRealDir(child) {
                if !name.hasPrefix(".") {
                    collectRotatedLogs(in: child, depth: depth + 1, maxDepth: maxDepth,
                                       cutoff: cutoff, coveredByL1: coveredByL1,
                                       into: &targets, bytes: &bytes)
                }
            } else if depth > 0 {
                guard Scanner.isRotatedLogName(name),
                      let mdate = FileSystem.modificationDate(child), mdate < cutoff else { continue }
                let sz = FileSystem.size(at: child)
                if sz > 0 { targets.append(child); bytes += sz }
            }
        }
    }

    /// 轮转日志文件名判断（*.log.N / *.N.log / *.gz），供自检复用
    static func isRotatedLogName(_ name: String) -> Bool {
        name.range(of: #"\.log\.\d+$"#, options: .regularExpression) != nil
            || name.range(of: #"\.\d+\.log$"#, options: .regularExpression) != nil
            || name.hasSuffix(".gz")
    }

    // MARK: - 3. 开发残留 D1–D15

    private static func scanDevResidue() -> [CleanItem] {
        // LOW-1：Xcode 运行时不扫 D1（DerivedData）
        let xcodeRunning = CleanPaths.runningBundleIDs.contains("com.apple.dt.Xcode")
        var items: [CleanItem] = []

        items += scanD1DerivedData(xcodeRunning: xcodeRunning)
        items += scanD2OldArchives()
        items += scanD3SimulatorCaches()
        items += scanD4ToD10PackageManagerCaches()
        items += scanD8MavenStaleMetadata()
        items += scanD11Pycache()
        items += scanD12HomebrewOldVersions()
        items += scanD13D14TempBuildCaches()
        items += scanD15RetiredNodeModules()
        items += scanD16CocoaPods()
        items += scanD17DockerCache()
        items += scanD18CargoGit()
        items += scanD19GradleDaemonAndWrapper()
        items += scanD20JetBrains()
        items += scanD21XcodeDeviceSupport(xcodeRunning: xcodeRunning)
        items += scanD22XcodePreviews(xcodeRunning: xcodeRunning)
        items += scanD23DockerVm()

        return items.sorted { $0.size > $1.size }
    }

    // D1: DerivedData
    private static func scanD1DerivedData(xcodeRunning: Bool) -> [CleanItem] {
        var items: [CleanItem] = []
        if !xcodeRunning {
            for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.derivedData)) {
                guard FileSystem.isSafeToClean(dir) else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (dir as NSString).lastPathComponent,
                        path: dir, size: size, rule: "D1", category: .devResidue,
                        note: "Xcode 构建产物"))
                }
            }
        }
        return items
    }

    // D2: Archives 超过 90 天
    private static func scanD2OldArchives() -> [CleanItem] {
        var items: [CleanItem] = []
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.archives)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            guard let mdate = FileSystem.modificationDate(dir), mdate < cutoff else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, rule: "D2", category: .devResidue,
                    note: "超过 90 天的归档"))
            }
        }
        return items
    }

    // D3: 模拟器缓存
    private static func scanD3SimulatorCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        let simCaches = CleanPaths.expand(CleanPaths.simulatorCaches)
        if FileSystem.isDir(simCaches), FileSystem.isSafeToClean(simCaches) {
            let size = FileSystem.size(at: simCaches)
            if size > 0 {
                items.append(CleanItem(name: "CoreSimulator Caches", path: simCaches,
                                       size: size, rule: "D3", category: .devResidue,
                                       note: "模拟器缓存"))
            }
        }
        return items
    }

    // D4–D10: 包管理器缓存（整目录，可无损失重建）
    private static func scanD4ToD10PackageManagerCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        let pkgDirs: [(String, String, String)] = [
            (CleanPaths.npmCache, "npm 缓存", "D4"),
            (CleanPaths.yarnCache, "yarn 缓存", "D5"),
            (CleanPaths.pnpmStore, "pnpm store", "D6"),
            (CleanPaths.gradleCaches, "Gradle 缓存", "D7"),
            (CleanPaths.cargoRegistry, "Cargo registry", "D9"),
            (CleanPaths.swiftpmCache, "SwiftPM 缓存", "D10"),
        ]
        for (p, note, ruleID) in pkgDirs {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, rule: ruleID, category: .devResidue, note: note))
            }
        }
        return items
    }

    // D8: Maven 失效元数据（只清 *.lastUpdated 与 _remote.repositories）
    private static func scanD8MavenStaleMetadata() -> [CleanItem] {
        var items: [CleanItem] = []
        let m2 = CleanPaths.expand(CleanPaths.m2Repository)
        if FileSystem.isDir(m2) {
            var targets: [String] = []
            var total: Int64 = 0
            if let en = FileManager.default.enumerator(atPath: m2) {
                for case let file as String in en {
                    if file.hasSuffix(".lastUpdated") || file.hasSuffix("_remote.repositories") {
                        let full = (m2 as NSString).appendingPathComponent(file)
                        let sz = FileSystem.size(at: full)
                        if sz > 0 { targets.append(full); total += sz }
                    }
                }
            }
            if !targets.isEmpty {
                items.append(CleanItem(
                    name: "Maven 失效元数据 (\(targets.count) 个文件)",
                    path: m2, paths: targets, size: total, rule: "D8",
                    category: .devResidue, note: "*.lastUpdated / _remote.repositories"))
            }
        }
        return items
    }

    // D11: __pycache__（限定代码目录，深度 ≤ 5）
    private static func scanD11Pycache() -> [CleanItem] {
        var items: [CleanItem] = []
        for root in CleanPaths.codeRoots {
            let rootPath = CleanPaths.expand(root)
            guard FileSystem.isDir(rootPath) else { continue }
            collectPycache(in: rootPath, depth: 0, maxDepth: 5, into: &items)
        }
        return items
    }

    // D12: Homebrew Cellar 旧版本（保留当前链接版本，其余移入候选）
    private static func scanD12HomebrewOldVersions() -> [CleanItem] {
        var items: [CleanItem] = []
        for cellar in [CleanPaths.homebrewCellar, CleanPaths.homebrewCellarIntel] {
            let cellarPath = CleanPaths.expand(cellar)
            guard FileSystem.isDir(cellarPath) else { continue }
            // opt 目录与 cellar 同级（/opt/homebrew/opt 或 /usr/local/opt）
            let optDir = ((cellarPath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("opt")
            for formula in FileSystem.subdirs(of: cellarPath) {
                let versions = FileSystem.subdirs(of: formula)
                guard versions.count > 1 else { continue }
                let formulaName = (formula as NSString).lastPathComponent
                // 当前版本 = opt/<formula> 软链指向的版本目录名
                let optLink = (optDir as NSString).appendingPathComponent(formulaName)
                let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: optLink))
                    .map { ($0 as NSString).lastPathComponent }
                // M2：软链解析失败时无法判定当前版本——保守跳过整个 formula，防误删在用版本
                guard let current, !current.isEmpty else { continue }
                // #5（二轮）：悬空 opt 链接（指向不存在的版本）→ current 不在 versions 中，
                // 无法安全判定旧版本，跳过整个 formula
                let versionNames = versions.map { ($0 as NSString).lastPathComponent }
                guard versionNames.contains(current) else { continue }
                var targets: [String] = []
                var total: Int64 = 0
                for ver in versions {
                    let verName = (ver as NSString).lastPathComponent
                    if verName == current { continue }   // 保留当前版本
                    // LOW-2：只收"版本形态"目录（数字/v 开头，与 isSafeToClean 放行口径一致），
                    // 排除 HEAD 等非版本目录——否则 Cleaner 整项判失败、旧版本永远清不掉
                    guard verName.first?.isNumber == true || verName.hasPrefix("v") else { continue }
                    let sz = FileSystem.size(at: ver)
                    if sz > 0 { targets.append(ver); total += sz }
                }
                if !targets.isEmpty {
                    items.append(CleanItem(
                        name: "\(formulaName) 旧版本 (\(targets.count) 个)",
                        path: formula, paths: targets, size: total,
                        rule: "D12", category: .devResidue,
                        note: "Homebrew 旧版本，当前为 \(current)"))
                }
            }
        }
        return items
    }

    // D13/D14: 用户临时目录内的构建缓存（受限放行，见 FileSystem.isKnownTempResidue）
    // 位置特殊（$TMPDIR 及其同级 C 目录），故走受控白名单判定，不属于常规路径规则
    private static func scanD13D14TempBuildCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        let tempArtifacts: [(String, String, String)] = [
            (CleanPaths.clangModuleCache, "Clang 模块缓存", "D13"),
            (CleanPaths.nodeCompileCache, "Node 编译缓存", "D14"),
        ]
        for (p, note, ruleID) in tempArtifacts {
            guard FileSystem.isDir(p), FileSystem.isSafeToClean(p) else { continue }
            let size = FileSystem.size(at: p)
            if size > 0 {
                items.append(CleanItem(
                    name: (p as NSString).lastPathComponent, path: p, size: size,
                    rule: ruleID, category: .devResidue, note: note))
            }
        }
        return items
    }

    // D15: 全局 node_modules 下的废弃版本副本（名字含 old/retired/bak 标记 + 版本号/日期）
    // 安全：受限放行（见 FileSystem.isRetiredGlobalPackage），只认包目录本身；
    // 风险级 review —— 命名可能出自人工重命名，需用户确认后再清
    private static func scanD15RetiredNodeModules() -> [CleanItem] {
        var items: [CleanItem] = []
        for root in CleanupRules.globalNodeModulesRoots {
            guard FileSystem.isDir(root) else { continue }
            for pkg in FileSystem.subdirs(of: root) {
                // 作用域包（@scope/name）需再下钻一层
                let candidates = (pkg as NSString).lastPathComponent.hasPrefix("@")
                    ? FileSystem.subdirs(of: pkg) : [pkg]
                for cand in candidates {
                    let pkgName = (cand as NSString).lastPathComponent
                    guard CleanupRules.isRetiredPackageName(pkgName),
                          FileSystem.isSafeToClean(cand) else { continue }
                    let size = FileSystem.size(at: cand)
                    if size > 0 {
                        items.append(CleanItem(
                            name: pkgName, path: cand,
                            size: size, rule: "D15", category: .devResidue,
                            note: "疑似废弃版本副本（命名含 old/retired/bak 标记）"))
                    }
                }
            }
        }
        return items
    }

    private static func collectPycache(in dir: String, depth: Int, maxDepth: Int, into items: inout [CleanItem]) {
        guard depth <= maxDepth else { return }
        // subdirs 已不跟随软链（见 FileSystem.subdirs），此处递归因此天然安全
        for child in FileSystem.subdirs(of: dir) {
            let name = (child as NSString).lastPathComponent
            if name == "__pycache__" {
                guard FileSystem.isSafeToClean(child) else { continue }
                let size = FileSystem.size(at: child)
                if size > 0 {
                    items.append(CleanItem(
                        name: name, path: child, size: size, rule: "D11",
                        category: .devResidue, note: "Python 字节码缓存"))
                }
            } else if !name.hasPrefix(".") {
                collectPycache(in: child, depth: depth + 1, maxDepth: maxDepth, into: &items)
            }
        }
    }

    // D16: CocoaPods 缓存与 Specs 镜像
    private static func scanD16CocoaPods() -> [CleanItem] {
        var items: [CleanItem] = []
        let cacheDir = CleanPaths.expand(CleanPaths.cocoapodsCache)
        if FileSystem.isDir(cacheDir), FileSystem.isSafeToClean(cacheDir) {
            let size = FileSystem.size(at: cacheDir)
            if size > 0 {
                items.append(CleanItem(
                    name: "CocoaPods Cache",
                    path: cacheDir, size: size, rule: "D16", category: .devResidue,
                    note: "Pods 下载与 Specs 缓存"))
            }
        }
        let reposDir = CleanPaths.expand(CleanPaths.cocoapodsRepos)
        if FileSystem.isDir(reposDir), FileSystem.isSafeToClean(reposDir) {
            for repo in FileSystem.subdirs(of: reposDir) {
                guard FileSystem.isSafeToClean(repo) else { continue }
                let size = FileSystem.size(at: repo)
                if size > 0 {
                    items.append(CleanItem(
                        name: "CocoaPods Repo (\((repo as NSString).lastPathComponent))",
                        path: repo, size: size, rule: "D16", category: .devResidue,
                        note: "Specs 规格镜像库"))
                }
            }
        }
        return items
    }

    // D17: Docker 构建缓存与运行日志
    private static func scanD17DockerCache() -> [CleanItem] {
        var items: [CleanItem] = []
        let dockerRunning = CleanPaths.runningBundleIDs.contains("com.docker.docker")
            || CleanPaths.runningDisplayNames.contains("docker")
        if !dockerRunning {
            let logDir = CleanPaths.expand(CleanPaths.dockerDataLogs)
            if FileSystem.isDir(logDir), FileSystem.isSafeToClean(logDir) {
                let size = FileSystem.size(at: logDir)
                if size > 0 {
                    items.append(CleanItem(
                        name: "Docker 运行日志",
                        path: logDir, size: size, rule: "D17", category: .devResidue,
                        note: "Docker Desktop 守护进程日志"))
                }
            }
        }
        let buildxDir = CleanPaths.expand(CleanPaths.dockerBuildxCache)
        if FileSystem.isDir(buildxDir), FileSystem.isSafeToClean(buildxDir) {
            let size = FileSystem.size(at: buildxDir)
            if size > 0 {
                items.append(CleanItem(
                    name: "Docker Buildx 缓存",
                    path: buildxDir, size: size, rule: "D17", category: .devResidue,
                    note: "容器构建缓存"))
            }
        }
        return items
    }

    // D18: Cargo Git 检出与索引仓库
    private static func scanD18CargoGit() -> [CleanItem] {
        var items: [CleanItem] = []
        let gitDirs: [(String, String)] = [
            (CleanPaths.cargoGitCheckouts, "Cargo Git 源码检出"),
            (CleanPaths.cargoGitDb, "Cargo Git 索引数据库"),
        ]
        for (p, note) in gitDirs {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, rule: "D18", category: .devResidue,
                    note: note))
            }
        }
        return items
    }

    // D19: Gradle 守护进程日志与历史 Wrapper
    private static func scanD19GradleDaemonAndWrapper() -> [CleanItem] {
        var items: [CleanItem] = []
        let daemonDir = CleanPaths.expand(CleanPaths.gradleDaemon)
        if FileSystem.isDir(daemonDir), FileSystem.isSafeToClean(daemonDir) {
            var logPaths: [String] = []
            var totalSize: Int64 = 0
            for sub in FileSystem.subdirs(of: daemonDir) {
                for file in FileSystem.children(of: sub) {
                    if file.hasSuffix(".log") || file.hasSuffix(".out") {
                        let full = (sub as NSString).appendingPathComponent(file)
                        guard FileSystem.isSafeToClean(full) else { continue }
                        let sz = FileSystem.size(at: full)
                        if sz > 0 {
                            logPaths.append(full)
                            totalSize += sz
                        }
                    }
                }
            }
            if !logPaths.isEmpty {
                items.append(CleanItem(
                    name: "Gradle 历史守护进程日志 (\(logPaths.count) 个)",
                    path: daemonDir, paths: logPaths, size: totalSize, rule: "D19",
                    category: .devResidue, note: "Gradle daemon 运行日志与堆栈"))
            }
        }
        let wrapperDir = CleanPaths.expand(CleanPaths.gradleWrapperDists)
        if FileSystem.isDir(wrapperDir), FileSystem.isSafeToClean(wrapperDir) {
            for dist in FileSystem.subdirs(of: wrapperDir) {
                guard FileSystem.isSafeToClean(dist) else { continue }
                let sz = FileSystem.size(at: dist)
                if sz > 0 {
                    items.append(CleanItem(
                        name: "Gradle Wrapper (\((dist as NSString).lastPathComponent))",
                        path: dist, size: sz, rule: "D19", category: .devResidue,
                        note: "历史下载的 Gradle 发行包"))
                }
            }
        }
        return items
    }

    // D20: JetBrains 历史版本日志与索引缓存
    private static func scanD20JetBrains() -> [CleanItem] {
        var items: [CleanItem] = []
        let roots = [
            CleanPaths.expand(CleanPaths.jetbrainsCaches),
            CleanPaths.expand(CleanPaths.jetbrainsLogs)
        ]
        var seen = Set<String>()
        for root in roots {
            guard FileSystem.isDir(root) else { continue }
            for dir in FileSystem.subdirs(of: root) {
                guard !seen.contains(dir), FileSystem.isSafeToClean(dir) else { continue }
                seen.insert(dir)
                let name = (dir as NSString).lastPathComponent
                let check = CleanPaths.isJetBrainsAppRunning(directoryName: name)
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    let mtime = FileSystem.modificationDate(dir)
                    let usage = FileSystem.usage(of: dir)
                    items.append(CleanItem(
                        name: "JetBrains \(name)",
                        path: dir,
                        size: size,
                        rule: "D20",
                        category: .devResidue,
                        note: "JetBrains 历史版本索引与运行日志",
                        modificationDate: mtime,
                        use: UseState(
                            ownerIsRunning: check.isRunning,
                            ownerName: check.appName,
                            lastUsed: mtime ?? usage.lastUsed,
                            level: usage.level,
                            observedAt: Date()
                        )
                    ))
                }
            }
        }
        return items
    }

    // D21: Xcode iOS/watchOS/tvOS DeviceSupport 旧设备调试符号（>60 天未修改）
    private static func scanD21XcodeDeviceSupport(xcodeRunning: Bool) -> [CleanItem] {
        var items: [CleanItem] = []
        let cutoff = Date().addingTimeInterval(-60 * 86400)
        for rootPattern in CleanPaths.xcodeDeviceSupportRoots {
            let root = CleanPaths.expand(rootPattern)
            guard FileSystem.isDir(root) else { continue }
            for dir in FileSystem.subdirs(of: root) {
                guard FileSystem.isSafeToClean(dir) else { continue }
                guard let mdate = FileSystem.modificationDate(dir), mdate < cutoff else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    let name = (dir as NSString).lastPathComponent
                    let usage = FileSystem.usage(of: dir)
                    items.append(CleanItem(
                        name: "DeviceSupport \(name)",
                        path: dir,
                        size: size,
                        rule: "D21",
                        category: .devResidue,
                        note: "过时设备调试符号 (>60 天)",
                        modificationDate: mdate,
                        use: UseState(
                            ownerIsRunning: xcodeRunning,
                            ownerName: "Xcode",
                            lastUsed: mdate,
                            level: usage.level,
                            observedAt: Date()
                        )
                    ))
                }
            }
        }
        return items
    }

    // D22: Xcode SwiftUI Previews 画布与模拟器预览缓存
    private static func scanD22XcodePreviews(xcodeRunning: Bool) -> [CleanItem] {
        var items: [CleanItem] = []
        let previewsRoot = CleanPaths.expand(CleanPaths.xcodePreviews)
        if FileSystem.isDir(previewsRoot), FileSystem.isSafeToClean(previewsRoot) {
            for dir in FileSystem.subdirs(of: previewsRoot) {
                guard FileSystem.isSafeToClean(dir) else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    let name = (dir as NSString).lastPathComponent
                    let mdate = FileSystem.modificationDate(dir)
                    let usage = FileSystem.usage(of: dir)
                    items.append(CleanItem(
                        name: "SwiftUI Preview (\(name))",
                        path: dir,
                        size: size,
                        rule: "D22",
                        category: .devResidue,
                        note: "Xcode SwiftUI 预览与临时模拟器缓存",
                        modificationDate: mdate,
                        use: UseState(
                            ownerIsRunning: xcodeRunning,
                            ownerName: "Xcode",
                            lastUsed: mdate ?? usage.lastUsed,
                            level: usage.level,
                            observedAt: Date()
                        )
                    ))
                }
            }
        }
        return items
    }

    // D23: Docker 桌面虚拟机磁盘镜像与未用卷
    private static func scanD23DockerVm() -> [CleanItem] {
        var items: [CleanItem] = []
        let dockerRunning = CleanPaths.runningBundleIDs.contains("com.docker.docker")
            || CleanPaths.runningDisplayNames.contains("docker")
        let vmDir = CleanPaths.expand(CleanPaths.dockerVmData)
        if FileSystem.isDir(vmDir) {
            let candidates = [
                (vmDir as NSString).appendingPathComponent("Docker.raw"),
                (vmDir as NSString).appendingPathComponent("Docker.qcow2")
            ]
            for file in candidates {
                guard FileManager.default.fileExists(atPath: file), FileSystem.isSafeToClean(file) else { continue }
                let size = FileSystem.size(at: file)
                if size > 0 {
                    let mdate = FileSystem.modificationDate(file)
                    let usage = FileSystem.usage(of: file)
                    items.append(CleanItem(
                        name: (file as NSString).lastPathComponent,
                        path: file,
                        size: size,
                        rule: "D23",
                        category: .devResidue,
                        note: "Docker Desktop 虚拟磁盘文件（包含本地镜像与容器）",
                        modificationDate: mdate,
                        use: UseState(
                            ownerIsRunning: dockerRunning,
                            ownerName: "Docker",
                            lastUsed: mdate ?? usage.lastUsed,
                            level: usage.level,
                            observedAt: Date()
                        )
                    ))
                }
            }
        }
        return items
    }

    // MARK: - 4. App 残留 A1–A4

    private static func scanAppResidue() -> [CleanItem] {
        // MED-1：扫描前刷新已安装 App 缓存（运行期新装 App 不再被误判残留）。
        // 拿到的是一份**局部快照**，本次扫描全程读它，不再触碰静态存储 —— 无锁、无竞争。
        let snapshot = refreshedInstalledAppSnapshot()
        let installedApps = snapshot.apps
        let installedBundlePrefixes = snapshot.prefixes
        guard snapshot.trustworthy else { return [] }

        var items: [CleanItem] = []
        items += scanA1AppSupportResidue(installedApps: installedApps,
                                         installedBundlePrefixes: installedBundlePrefixes)
        items += scanA2OrphanPreferences(installedApps: installedApps,
                                         installedBundlePrefixes: installedBundlePrefixes)
        items += scanA3DanglingLaunchAgents()
        items += scanA4SavedApplicationState(installedApps: installedApps,
                                             installedBundlePrefixes: installedBundlePrefixes)
        items += scanA5ByHostPreferences(installedApps: installedApps,
                                         installedBundlePrefixes: installedBundlePrefixes)

        return items.sorted { $0.size > $1.size }
    }

    // A1: Application Support 中已卸载 App 的目录
    // 修复：①别名双向匹配 ②180 天活跃度门槛（在用数据不列）③共享框架目录排除
    // 注：早期版本这里还有一条"④运行中 app 匹配跳过"的注释并取过一个 runningNames 集合，
    // 但从未被使用——下面的 installedApps 判定已经覆盖它（能运行起来的 app 必然已安装）。
    // 死变量已删除，注释同步修正。
    private static func scanA1AppSupportResidue(installedApps: Set<String>,
                                                installedBundlePrefixes: Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let residueCutoff = Date().addingTimeInterval(-180 * 86400)
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.appSupport)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            let name = (dir as NSString).lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("com.apple") { continue }
            let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
            // 共享框架目录：无法确定归属，直接跳过（Electron/CEF 等可能被多个 app 使用）
            if sharedFrameworkDirs.contains(normalized) { continue }
            // 活跃度：180 天内有更新 → 在用数据，不列为残留（与 A2 同门槛）
            if let mdate = FileSystem.modificationDate(dir), mdate > residueCutoff { continue }
            // 兼容 bundle-id 形式目录名（com.qoder.app.stable → 各段与 app 名比对）
            let segments = normalized.split(separator: ".")
            let segmentMatch = segments.contains { seg in
                installedApps.contains { $0.contains(seg) || (seg.count >= 6 && seg.contains($0)) }
            }
            // bundle id 前缀匹配（com.tencent.imamac → com.tencent ∈ 已装前缀）
            let prefixMatch = segments.count >= 2 && installedBundlePrefixes.contains("\(segments[0]).\(segments[1])")
            // 别名匹配（修复：双向——normalized 命中任一 key 或任一别名值，且对应 app 已装）
            let aliasMatch = nameAliases.contains { (key, aliases) in
                let hit = normalized == key || aliases.contains(normalized)
                    || normalized.contains(key) || aliases.contains { normalized.contains($0) }
                guard hit else { return false }
                // 该别名对应 app 是否已装：key 或任一别名命中 installedApps 即视为在用
                let names = aliases.union([key])
                return installedApps.contains { app in
                    names.contains { app.contains($0) || $0.contains(app) }
                }
            }
            // 与已安装 App 名双向子串匹配（"Google" ⊂ "Google Chrome" 视为已安装，
            // 宁可漏报也不误删活跃应用数据；反向匹配要求名字较长避免 "code" 类短名误伤）
            let stillInstalled = segmentMatch || prefixMatch || aliasMatch || installedApps.contains { app in
                app.contains(normalized) || (app.count >= 6 && normalized.contains(app))
            }
            if stillInstalled { continue }
            let size = FileSystem.size(at: dir)
            if size > 10 * 1024 * 1024 { // 仅 >10MB 残留值得列出
                items.append(CleanItem(
                    name: name, path: dir, size: size, rule: "A1",
                    category: .appResidue, note: "疑似已卸载 App 的残留（180 天未更新）"))
            }
        }
        return items
    }

    // A2: Preferences 中孤立 plist（排除系统 bundle、仍安装的 App 与通用框架，> 180 天）
    // 修复：单段名（系统守护进程）、通用框架 vendor 前缀均不列为可删
    private static func scanA2OrphanPreferences(installedApps: Set<String>,
                                                installedBundlePrefixes: Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let systemBundles = ["com.apple", "com.google", "com.microsoft", "com.adobe", "com.oracle",
                             "org.chromium", "com.jetbrains", "com.tencent", "com.alibaba", "com.bytedance"]

        let cutoff = Date().addingTimeInterval(-180 * 86400)
        let sharedVendors = ["jetbrains", "qt", "dotnet", "electron", "google", "microsoft",
                             "adobe", "oracle", "tencent", "alibaba", "bytedance",
                             "qtproject", "sqlite", "gnu", "freedesktop"]
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.preferences), keepHidden: false) {
            guard child.hasSuffix(".plist"), FileSystem.isSafeToClean(child) else { continue }
            let bundle = (child as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
            if systemBundles.contains(where: { bundle.hasPrefix($0) }) { continue }
            // 单段名（sharedfilelistd/icloudmailagent/nsurlsessiond 等系统守护进程偏好）
            if !bundle.contains(".") { continue }
            // 通用框架 vendor 前缀（JetBrains/Qt/.NET 等可能仍在用）；
            // 先剥离 com./org. 等反域名前缀再匹配（com.qtproject → qtproject）
            let stripped = bundle.lowercased()
                .replacingOccurrences(of: "^com\\.", with: "", options: .regularExpression)
                .replacingOccurrences(of: "^org\\.", with: "", options: .regularExpression)
            if sharedVendors.contains(where: { stripped.hasPrefix($0) || stripped.contains(".\($0)") }) { continue }
            // N6：App 仍安装（bundle 前缀命中已装前缀，或名称命中已装 App）→ 不列为可删
            let segments = bundle.lowercased().split(separator: ".")
            let prefixStillInstalled = segments.count >= 2
                && installedBundlePrefixes.contains("\(segments[0]).\(segments[1])")
            let nameStillInstalled = installedApps.contains { app in
                app.contains(bundle.lowercased()) || bundle.lowercased().contains(app)
            }
            if prefixStillInstalled || nameStillInstalled { continue }
            guard let mdate = FileSystem.modificationDate(child), mdate < cutoff else { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                items.append(CleanItem(
                    name: bundle, path: child, size: size, rule: "A2",
                    category: .appResidue, note: "超过 180 天未更新的偏好设置"))
            }
        }
        return items
    }

    // A3: LaunchAgents 指向不存在的程序
    //
    // 编号说明：这一条原本登记为 A4，而原 A3（"已卸载应用的缓存"）是一条**幽灵规则**——
    // 登记在册却从未实现，且目标集合被 C1 全量覆盖，实现出来只会造成跨分类重复计字节。
    // v1.2 删掉了那条幽灵规则并把 A4 顺延为 A3，以保持同分类编号连续
    // （`Selftest` 有"编号连续无缺号"用例把关）。
    private static func scanA3DanglingLaunchAgents() -> [CleanItem] {
        var items: [CleanItem] = []
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.launchAgents), keepHidden: false) {
            guard child.hasSuffix(".plist"), FileSystem.isSafeToClean(child) else { continue }
            if let dict = NSDictionary(contentsOfFile: child),
               let args = dict["ProgramArguments"] as? [String] {
                for arg in args where arg.contains("/Applications/") {
                    if !FileManager.default.fileExists(atPath: arg) {
                        let size = FileSystem.size(at: child)
                        items.append(CleanItem(
                            name: (child as NSString).lastPathComponent,
                            path: child, size: size, rule: "A3",
                            category: .appResidue,
                            note: "启动代理指向已卸载 App：\(arg)"))
                        break
                    }
                }
            }
        }
        return items
    }

    // A4: Saved Application State 中已卸载应用的窗口状态
    private static func scanA4SavedApplicationState(installedApps: Set<String>,
                                                    installedBundlePrefixes: Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let stateRoot = CleanPaths.expand(CleanPaths.savedApplicationState)
        guard FileSystem.isDir(stateRoot) else { return items }
        let systemBundles = ["com.apple", "com.google", "com.microsoft", "com.adobe", "com.oracle",
                             "org.chromium", "com.jetbrains", "com.tencent", "com.alibaba", "com.bytedance"]
        for child in FileSystem.children(of: stateRoot) {
            guard child.hasSuffix(".savedState"), FileSystem.isSafeToClean(child) else { continue }
            let bundle = (child as NSString).lastPathComponent.replacingOccurrences(of: ".savedState", with: "")
            if systemBundles.contains(where: { bundle.hasPrefix($0) }) { continue }
            if !bundle.contains(".") { continue }
            let segments = bundle.lowercased().split(separator: ".")
            let prefixStillInstalled = segments.count >= 2
                && installedBundlePrefixes.contains("\(segments[0]).\(segments[1])")
            let nameStillInstalled = installedApps.contains { app in
                app.contains(bundle.lowercased()) || bundle.lowercased().contains(app)
            }
            if prefixStillInstalled || nameStillInstalled { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                let mdate = FileSystem.modificationDate(child)
                items.append(CleanItem(
                    name: "窗口状态 (\(bundle))",
                    path: child,
                    size: size,
                    rule: "A4",
                    category: .appResidue,
                    note: "已卸载应用的窗口恢复状态",
                    modificationDate: mdate
                ))
            }
        }
        return items
    }

    // A5: Preferences/ByHost 中孤立的硬件绑定偏好设置
    private static func scanA5ByHostPreferences(installedApps: Set<String>,
                                                installedBundlePrefixes: Set<String>) -> [CleanItem] {
        var items: [CleanItem] = []
        let byHostRoot = CleanPaths.expand(CleanPaths.preferencesByHost)
        guard FileSystem.isDir(byHostRoot) else { return items }
        let systemBundles = ["com.apple", "com.google", "com.microsoft", "com.adobe", "com.oracle",
                             "org.chromium", "com.jetbrains", "com.tencent", "com.alibaba", "com.bytedance"]
        for child in FileSystem.children(of: byHostRoot) {
            guard child.hasSuffix(".plist"), FileSystem.isSafeToClean(child) else { continue }
            let filename = (child as NSString).lastPathComponent
            guard let bundle = CleanPaths.extractBundleFromByHostFilename(filename) else { continue }
            if systemBundles.contains(where: { bundle.hasPrefix($0) }) { continue }
            if !bundle.contains(".") { continue }
            let segments = bundle.lowercased().split(separator: ".")
            let prefixStillInstalled = segments.count >= 2
                && installedBundlePrefixes.contains("\(segments[0]).\(segments[1])")
            let nameStillInstalled = installedApps.contains { app in
                app.contains(bundle.lowercased()) || bundle.lowercased().contains(app)
            }
            if prefixStillInstalled || nameStillInstalled { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                let mdate = FileSystem.modificationDate(child)
                items.append(CleanItem(
                    name: "ByHost 偏好 (\(bundle))",
                    path: child,
                    size: size,
                    rule: "A5",
                    category: .appResidue,
                    note: "已卸载应用的硬件绑定偏好碎片",
                    modificationDate: mdate
                ))
            }
        }
        return items
    }

    // MARK: - 5. 大文件与垃圾箱 T1–T5

    private static func scanLargeFiles() -> [CleanItem] {
        var items: [CleanItem] = []
        var seen = Set<String>()   // N1：跨 T2/T3 同路径去重
        let day: TimeInterval = 86400

        func add(_ item: CleanItem) {
            guard !seen.contains(item.path) else { return }
            seen.insert(item.path)
            items.append(item)
        }

        // T1: 废纸篓（清理 = 彻底删除）
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.trash)) {
            let size = FileSystem.size(at: child)
            if size > 0 {
                add(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, rule: "T1", category: .largeFiles,
                    note: "废纸篓内容（将彻底删除）", permanentDelete: true))
            }
        }

        // T2: Downloads 中 >500MB 或 >180 天未访问
        let downloads = CleanPaths.expand(CleanPaths.downloads)
        for child in FileSystem.children(of: downloads) {
            let size = FileSystem.size(at: child)
            let old = (FileSystem.accessDate(child) ?? .distantPast) < Date().addingTimeInterval(-180 * day)
            if size > 500 * 1024 * 1024 || (old && size > 0) {
                add(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, rule: "T2", category: .largeFiles,
                    note: size > 500 * 1024 * 1024 ? "超过 500MB" : "超过 180 天未访问"))
            }
        }

        // T3: 大文件扫描（>1GB，深度 ≤ 2；与 T2 共享 seen，Downloads 顶层不再重复）
        for root in CleanPaths.bigFileRoots {
            let rootPath = CleanPaths.expand(root)
            guard FileSystem.isRealDir(rootPath) else { continue }
            scanBigFiles(in: rootPath, depth: 0, maxDepth: 2, into: &items, seen: &seen)
        }

        // T4: 未使用模拟器（>90 天；N12：CoreSimulator 运行中跳过，避免删活跃设备）
        let cutoff = Date().addingTimeInterval(-90 * day)
        if !CleanPaths.runningBundleIDs.contains("com.apple.iphonesimulator") {
            for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.simulatorDevices)) {
                guard FileSystem.isSafeToClean(dir) else { continue }
                guard let mdate = FileSystem.modificationDate(dir), mdate < cutoff else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (dir as NSString).lastPathComponent,
                        path: dir, size: size, rule: "T4", category: .largeFiles,
                        note: "超过 90 天未使用的模拟器"))
                }
            }
        }

        // T5: 旧 iOS 设备备份（>180 天，尊重数据安全 → review）
        // 结构：MobileSync/Backup/<设备UDID>/，逐 UDID 目录判断
        let backupRoot = (CleanPaths.expand(CleanPaths.mobileSync) as NSString)
            .appendingPathComponent("Backup")
        let backupCutoff = Date().addingTimeInterval(-180 * day)
        for dir in FileSystem.subdirs(of: backupRoot) {
            guard let mdate = FileSystem.modificationDate(dir), mdate < backupCutoff else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, rule: "T5",
                    category: .largeFiles,
                    note: "超过 180 天未更新的设备备份"))
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    private static func scanBigFiles(in dir: String, depth: Int, maxDepth: Int,
                                     into items: inout [CleanItem], seen: inout Set<String>) {
        guard depth <= maxDepth else { return }
        for child in FileSystem.children(of: dir) {
            // isRealDir 而非 isDir：大文件扫描是递归的，一个指向别处的软链就能
            // 让"~/Downloads 里的大文件"实际落在任意路径上，而列表里显示的仍是家目录内的路径。
            if FileSystem.isRealDir(child) {
                let name = (child as NSString).lastPathComponent
                if !name.hasPrefix(".") {
                    scanBigFiles(in: child, depth: depth + 1, maxDepth: maxDepth, into: &items, seen: &seen)
                }
            } else {
                let size = FileSystem.size(at: child)
                if size > 1024 * 1024 * 1024, !seen.contains(child) {
                    seen.insert(child)
                    items.append(CleanItem(
                        name: (child as NSString).lastPathComponent,
                        path: child, size: size, rule: "T3", category: .largeFiles,
                        note: "超过 1GB 的大文件"))
                }
            }
        }
    }

    // MARK: - 6. 浏览器与系统数据 B1–B4

    private static func scanBrowserAndSystem() -> [CleanItem] {
        var items: [CleanItem] = []

        // B1/B3: Safari 站点数据与容器缓存（Safari 未运行）
        //
        // 注意 B1（LocalStorage / WebsiteData）本质是**用户的站点数据**——删掉会让部分网站
        // 需要重新登录、甚至丢失本地草稿，所以它不是"缓存"，规则表里标为 userData（→ 需确认）。
        if !CleanPaths.runningBundleIDs.contains("com.apple.Safari") {
            for (p, note, ruleID) in [(CleanPaths.safariLocalStorage, "Safari LocalStorage", "B1"),
                                      (CleanPaths.safariWebsiteData, "Safari 站点数据", "B1"),
                                      (CleanPaths.safariContainerCaches, "Safari 容器缓存", "B3"),
                                      (CleanPaths.safariContainerStorages, "Safari WebKit 站点数据", "B1")] {
                let dir = CleanPaths.expand(p)
                guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (dir as NSString).lastPathComponent,
                        path: dir, size: size, rule: ruleID,
                        category: .browserAndSystem, note: note))
                }
            }
        }

        // B2: Chromium 系浏览器缓存（对应浏览器未运行）
        for (appName, supportDir) in CleanPaths.chromiumCaches {
            let bundleIDs: [String] = {
                switch appName {
                case "Google Chrome": return ["com.google.Chrome"]
                case "Microsoft Edge": return ["com.microsoft.edgemac"]
                case "Brave Browser": return ["com.brave.Browser"]
                case "Opera": return ["com.operasoftware.Opera"]
                case "Vivaldi": return ["com.vivaldi.Vivaldi"]
                default: return []
                }
            }()
            if bundleIDs.contains(where: { CleanPaths.runningBundleIDs.contains($0) }) { continue }
            let base = CleanPaths.expand(supportDir)
            guard FileSystem.isDir(base) else { continue }
            for profile in FileSystem.subdirs(of: base) {
                let pname = (profile as NSString).lastPathComponent
                guard pname == "Default" || pname.hasPrefix("Profile ") else { continue }
                for cacheSub in ["Cache", "Code Cache"] {
                    let cacheDir = (profile as NSString).appendingPathComponent(cacheSub)
                    guard FileSystem.isDir(cacheDir), FileSystem.isSafeToClean(cacheDir) else { continue }
                    let size = FileSystem.size(at: cacheDir)
                    if size > 0 {
                        items.append(CleanItem(
                            name: "\(appName) \(pname) \(cacheSub)",
                            path: cacheDir, size: size, rule: "B2",
                            category: .browserAndSystem,
                            note: "\(appName) 缓存（浏览器未运行时）"))
                    }
                }
            }
        }

        // B4/B5: Chromium 宿主（浏览器与 Electron/CEF 应用）在 Application Support 下的组件目录。
        //
        // 历史缺陷（本次修复的重点）：这两类东西原本合在一条规则里、一律标 safe。但
        // component_crx_cache 是**下载缓存**（删了重下，无感），而 WidevineCdm（DRM 播放）、
        // WasmTtsEngine（语音合成）、SODALanguagePacks（语言包）是**按需下载的功能组件**——
        // 删掉不是"缓存被重建"，而是"该功能直接不可用，直到应用重新下载完"。
        // 实测中它们被标成"安全"，用户照做后 DRM 视频就播不了。现按本质拆成两条规则。
        let appSupport = CleanPaths.expand(CleanPaths.appSupport)
        for appDir in FileSystem.subdirs(of: appSupport) {
            let appName = (appDir as NSString).lastPathComponent

            for (names, ruleID, note) in [
                (CleanupRules.chromiumDownloadCaches, "B4", "Chromium 组件下载缓存"),
                (CleanupRules.chromiumFunctionalComponents, "B5", "Chromium 按需下载的功能组件"),
            ] {
                for ccName in names.sorted() {
                    let ccDir = (appDir as NSString).appendingPathComponent(ccName)
                    guard FileSystem.isDir(ccDir), FileSystem.isSafeToClean(ccDir) else { continue }
                    let size = FileSystem.size(at: ccDir)
                    if size > 0 {
                        items.append(CleanItem(
                            name: "\(appName) \(ccName)", path: ccDir, size: size,
                            rule: ruleID, category: .browserAndSystem, note: note))
                    }
                }
            }
        }

        return items.sorted { $0.size > $1.size }
    }
}
