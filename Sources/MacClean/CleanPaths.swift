import Foundation
import AppKit

/// 固化路径规则（与 docs/CLEANUP-RULES.md 一一对应，v1.1）
/// 规则登记与元数据见 `CleanupRules`；本文件只负责路径常量。
enum CleanPaths {
    // MARK: G6 硬排除白名单
    static let hardExclude: [String] = [
        "~/Library/Mail",
        "~/Library/Keychains",
        "~/Library/Accounts",
        "~/Library/Messages",
        "~/Library/Safari/Bookmarks.plist",
        "~/Library/Safari/History.db",
        "~/.ssh",
        "~/.gnupg",
        // v1.1 新增：应用共享容器与云端同步目录（内含用户数据，非缓存）
        "~/Library/Group Containers",   // 壁纸/聊天库等跨应用共享数据（如 group.com.waifux.app）
        "~/Library/Mobile Documents",   // iCloud Drive 本地副本
        "~/Library/CloudStorage",       // Google Drive / OneDrive / 坚果云等云盘挂载
        // v1.72 补：照片图库原先只在 `tccProtected` 里，那是"读得到吗"的判据，
        // **不构成删除拦截**——一旦授予完全磁盘访问权限，库内真实文件就能通过主目录护栏
        // 被判为可清理。图库是自管理容器，删进去任何一项都是损毁整个照片库，
        // 因此必须同时进 G6（tccProtected 管可读性，hardExclude 管可删性）。
        "~/Pictures/Photos Library.photoslibrary",
    ]

    // MARK: G8 系统级硬保护（文档第 7 章）
    /// 即使将来放宽 `allowedRoots` 也绝不触碰的路径。
    /// 判据：SIP `restricted` 标志 / `SF_NOUNLINK`(sunlnk) 标志 / 系统运行必需。
    /// 这些目标 `sudo` 同样无解或会破坏系统，工具不应把它们列为可清理项——
    /// 避免用户白费力气（已实测：`/Library/Updates` 受 SIP 保护，且系统会自行回收）。
    static let systemProtected: [String] = [
        "/System",
        "/System/Volumes",
        "/Library/Updates",             // restricted + com.apple.rootless（Software Update 元数据，系统自行回收）
        "/private/var/vm",              // sleepimage + swapfile：休眠与内存必需
        "/private/var/db",              // 系统数据库（uuidtext / receipts / powerlog）
        "/private/var/folders/zz",      // 系统守护进程临时目录（sunlnk 无法清除）
    ]

    // MARK: G9 TCC 保护（文档第 7.2 节）
    /// 需要「完全磁盘访问权限」才能读取的路径。
    /// **重要**：无权限时读取返回 `Operation not permitted`，若用
    /// `ls … 2>/dev/null | wc -l` 之类写法会得到 `0`，被误判为「空目录」。
    /// 必须用 `FileSystem.hasFullDiskAccess()` 判断权限、
    /// `FileSystem.isPermissionDenied(_:)` 区分「读不到」与「真的空」。
    static let tccProtected: [String] = [
        "~/.Trash",
        "~/Pictures/Photos Library.photoslibrary",
        "~/Library/Caches/CloudKit",
        "~/Library/Daemon Containers",
    ]

    // MARK: 1. 用户缓存 C1–C6
    static let userCaches = "~/Library/Caches"
    static let xcodeCache = "~/Library/Caches/com.apple.dt.Xcode"
    static let pipCache = "~/Library/Caches/pip"
    static let pipCacheAlt = "~/.cache/pip"
    static let homebrewCache = "~/Library/Caches/Homebrew"
    static let browserCacheDirs = [
        "~/Library/Caches/com.apple.Safari",
        "~/Library/Caches/com.google.Chrome",
        "~/Library/Caches/com.microsoft.Edge",
        "~/Library/Caches/com.brave.Browser",
        "~/Library/Caches/com.operasoftware.Opera",
        "~/Library/Caches/com.vivaldi.Vivaldi",
    ]
    static let containersCaches = "~/Library/Containers"

    // MARK: 2. 日志与临时文件 L1–L8
    static let logs = "~/Library/Logs"
    static let diagnosticReports = "~/Library/Logs/DiagnosticReports"
    static let diagnosticReportsRetired = "~/Library/Logs/DiagnosticReports/Retired"
    static let crashReporter = "~/Library/Application Support/CrashReporter"
    static let tmp = "/private/tmp"
    static let varTmp = "/private/var/tmp"
    static let temporaryItems = "~/Library/TemporaryItems"

    // MARK: 3. 开发残留 D1–D11
    static let derivedData = "~/Library/Developer/Xcode/DerivedData"
    static let archives = "~/Library/Developer/Xcode/Archives"
    static let simulatorCaches = "~/Library/Developer/CoreSimulator/Caches"
    static let simulatorDevices = "~/Library/Developer/CoreSimulator/Devices"
    static let npmCache = "~/.npm/_cacache"
    static let yarnCache = "~/.yarn/cache"
    static let pnpmStore = "~/.pnpm-store"
    static let gradleCaches = "~/.gradle/caches"
    static let m2Repository = "~/.m2/repository"
    static let cargoRegistry = "~/.cargo/registry"
    static let swiftpmCache = "~/Library/Caches/org.swift.swiftpm"
    static let cocoapodsCache = "~/Library/Caches/CocoaPods"
    static let cocoapodsRepos = "~/.cocoapods/repos"
    static let dockerBuildxCache = "~/.docker/buildx/cache"
    static let dockerDataLogs = "~/Library/Containers/com.docker.docker/Data/log"
    static let cargoGitCheckouts = "~/.cargo/git/checkouts"
    static let cargoGitDb = "~/.cargo/git/db"
    static let gradleDaemon = "~/.gradle/daemon"
    static let gradleWrapperDists = "~/.gradle/wrapper/dists"
    // v1.43.0 新增：D20–D23 专业开发工具与容器深度清理
    static let jetbrainsLogs = "~/Library/Logs/JetBrains"
    static let jetbrainsCaches = "~/Library/Caches/JetBrains"
    static let xcodeDeviceSupportRoots = [
        "~/Library/Developer/Xcode/iOS DeviceSupport",
        "~/Library/Developer/Xcode/watchOS DeviceSupport",
        "~/Library/Developer/Xcode/tvOS DeviceSupport",
    ]
    static let xcodePreviews = "~/Library/Developer/Xcode/UserData/Previews"
    static let dockerVmData = "~/Library/Containers/com.docker.docker/Data/vms/0/data"
    static let codeRoots = ["~/workspace", "~/projects", "~/dev", "~/code"]

    // MARK: 4. App 残留 A1–A5
    static let appSupport = "~/Library/Application Support"
    static let preferences = "~/Library/Preferences"
    static let preferencesByHost = "~/Library/Preferences/ByHost"
    static let savedApplicationState = "~/Library/Saved Application State"
    static let launchAgents = "~/Library/LaunchAgents"
    static let appDirs = ["/Applications", "~/Applications", "/System/Applications",
                          "/Library/Input Methods", "~/Library/Input Methods"]

    // MARK: 5. 大文件与垃圾箱 T1–T4
    static let trash = "~/.Trash"
    static let downloads = "~/Downloads"
    static let bigFileRoots = ["~/Downloads", "~/Documents", "~/Desktop", "~/Movies"]
    static let mobileSync = "~/Library/Application Support/MobileSync"
    static let homebrewCellar = "/opt/homebrew/Cellar"   // Apple Silicon
    static let homebrewCellarIntel = "/usr/local/Cellar"  // Intel

    // MARK: 6. 浏览器与系统数据 B1–B3
    static let safariLocalStorage = "~/Library/Safari/LocalStorage"
    static let safariWebsiteData = "~/Library/Safari/WebsiteData"
    static let safariContainerCaches = "~/Library/Containers/com.apple.Safari/Data/Library/Caches"
    static let safariContainerStorages = "~/Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData"
    static let chromiumCaches = [
        ("Google Chrome", "~/Library/Application Support/Google/Chrome"),
        ("Microsoft Edge", "~/Library/Application Support/Microsoft Edge"),
        ("Brave Browser", "~/Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Opera", "~/Library/Application Support/com.operasoftware.Opera"),
        ("Vivaldi", "~/Library/Application Support/Vivaldi"),
    ]

    // MARK: 运行中应用排除（G5）
    //
    // OBS-2（终验）：运行态必须**近实时**——进程级永久快照会让"刚启动的 Xcode /
    // 模拟器 / 浏览器"的缓存被误判成可清理。但"近实时"不等于"每个清理项都重新枚举一次"：
    // `ownerApp(of:)` 对每一项都要查归属，原先 `runningBundleIDs` 与
    // `runningAppNamesByBundleID` 各自直接调 `NSWorkspace.shared.runningApplications`，
    // 本机一次 `--scan` 的 1260 个日志项就是 2500+ 次枚举，该分类实测 4.5 s
    // （占整轮扫描近一半）。
    //
    // 现在四个视图共用一份 5 秒 TTL 快照。新鲜度与 `runningAppAliases` 原本就在用的
    // 一致——`ownerApp` 是"bundle id 命中 **或** 别名命中"，别名侧本来就是 5 秒窗口，
    // 所以这次合并**没有放宽**"刚启动的 App 要能被看见"这条保证。
    struct RunningSnapshot {
        let bundleIDs: Set<String>
        let displayNames: Set<String>
        let aliases: Set<String>
        let namesByBundleID: [String: String]
        let takenAt: Date
    }

    private static var cachedRunning: RunningSnapshot?
    /// 缓存必须加锁：`scanAll` 会把 6 个分类**并发**丢进全局队列，每个分类的每一项
    /// 都会调 `ownerApp(of:)` → 这里。无锁读写一个含 Set/Dict 的结构是实打实的数据竞争。
    private static let runningLock = NSLock()
    private static let runningTTL: TimeInterval = 5

    /// bundle id 保持**原样**（不 lowercase、不归一化）：调用方拿 plist 里的标识符直接查表。
    static var runningBundleIDs: Set<String> { runningSnapshot.bundleIDs }
    /// 运行中 App 的显示名（归一化：小写、去空格）。
    static var runningDisplayNames: Set<String> { runningSnapshot.displayNames }
    /// 运行中 App 的全部可识别名（归一化）。
    ///
    /// 为什么需要一整组而不是一个名字——实测案例：
    /// `/Applications/Tabbit Browser.app` 的 `CFBundleName` 是英文 `Tabbit Browser`，
    /// 数据目录因此叫 `~/Library/Application Support/Tabbit Browser/`；
    /// 但 `NSRunningApplication.localizedName` 返回的是**本地化名**「Tabbit浏览器」。
    /// 只比对 localizedName 就会漏判，于是"浏览器正在运行、并正在写这个目录"的缓存
    /// 被判成"没在用"→ 标成可清理。这正是必须修掉的那类"看起来安全其实在用"。
    ///
    /// 采集来源：bundle id、localizedName、CFBundleName、CFBundleExecutable、.app 目录名。
    static var runningAppAliases: Set<String> { runningSnapshot.aliases }
    /// bundle id → 显示名（用于给用户看"是哪个 App 在用"）
    static var runningAppNamesByBundleID: [String: String] { runningSnapshot.namesByBundleID }

    static var runningSnapshot: RunningSnapshot {
        runningLock.lock()
        if let c = cachedRunning, Date().timeIntervalSince(c.takenAt) < runningTTL {
            runningLock.unlock()
            return c
        }
        runningLock.unlock()

        let built = computeRunningSnapshot()

        runningLock.lock()
        cachedRunning = built
        runningLock.unlock()
        return built
    }

    /// 强制丢弃运行态快照。清理动作结束后、或界面要求"立刻反映最新状态"时调用，
    /// 免得用户刚退出的 App 在 5 秒窗口内仍被当成在用而挡住本该出现的结论。
    static func invalidateRunningSnapshot() {
        runningLock.lock()
        cachedRunning = nil
        runningLock.unlock()
    }

    /// 真正去读运行中 App 的信息。**在锁外执行**：读 Info.plist 是 I/O，
    /// 放在锁里会让并发扫描互相排队。最坏情况是几个线程各算一遍，无副作用。
    private static func computeRunningSnapshot() -> RunningSnapshot {
        var bids = Set<String>()
        var display = Set<String>()
        var aliases = Set<String>()
        var map: [String: String] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let bid = app.bundleIdentifier
            let shown = app.localizedName
            if let bid { bids.insert(bid) }
            if let bid, let shown { map[bid] = shown }
            if let shown {
                display.insert(normalize(shown))
                aliases.insert(normalize(shown))
            }
            if let bid { aliases.insert(normalize(bid)) }
            if let url = app.bundleURL {
                let dir = url.deletingPathExtension().lastPathComponent
                if !dir.isEmpty { aliases.insert(normalize(dir)) }
                let plist = url.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: plist) {
                    for key in ["CFBundleName", "CFBundleExecutable", "CFBundleDisplayName"] {
                        if let v = dict[key] as? String, !v.isEmpty { aliases.insert(normalize(v)) }
                    }
                }
            }
        }
        aliases.remove("")
        return RunningSnapshot(bundleIDs: bids, displayNames: display, aliases: aliases,
                               namesByBundleID: map, takenAt: Date())
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 归属判定：这个路径属于哪个 App？

    /// 从路径里解析出"所属 App"，并判断它此刻是否在运行。
    ///
    /// 历史缺陷：这段逻辑原本散落在各个扫描器里各写一遍——C1 只比对 bundle id 与显示名，
    /// B4 完全不查，于是同一个 App 的组件在 C1 会被跳过、在 B4 却会被列出来标成"安全"。
    /// 现在收敛成唯一入口，所有扫描器一律走这里。
    ///
    /// 支持的数据根目录形态：
    /// - `~/Library/Caches/<owner>/…`
    /// - `~/Library/Application Support/<owner>/…`
    /// - `~/Library/Containers/<bundle-id>/…`
    /// - `~/Library/Group Containers/<group-id>/…`
    /// - `~/Library/Preferences/<bundle-id>.plist`
    /// - `~/Library/Logs/<owner>/…`
    /// - `~/Library/Saved Application State/<bundle-id>.savedState`
    static func ownerApp(of path: String) -> (identifier: String, isRunning: Bool, displayName: String?)? {
        let expanded = expand(path)
        let roots: [String] = [
            expand(containersCaches),                 // ~/Library/Containers
            expand("~/Library/Group Containers"),
            expand(appSupport),                       // ~/Library/Application Support
            expand("~/Library/Caches"),
            expand(logs),                             // ~/Library/Logs
            expand("~/Library/Preferences"),
            expand("~/Library/Saved Application State"),
        ]

        for root in roots where expanded.hasPrefix(root + "/") {
            let rest = String(expanded.dropFirst(root.count + 1))
            guard let first = rest.split(separator: "/").first.map(String.init) else { continue }
            // 去掉 .plist / .savedState 之类后缀，还原成标识符
            let identifier = first
                .replacingOccurrences(of: ".savedState", with: "")
                .replacingOccurrences(of: ".plist", with: "")
            guard !identifier.isEmpty, !identifier.hasPrefix(".") else { continue }

            let normalized = normalize(identifier)
            let byBundleID = runningBundleIDs.contains(identifier)
            // 别名集合覆盖了 CFBundleName 等非本地化名——只比对 bundle id / localizedName
            // 会漏掉"目录名用英文、App 显示中文"这一大类（见 runningAppAliases 的说明）。
            let byAlias = runningAppAliases.contains(normalized)
            let isRunning = byBundleID || byAlias
            let displayName = runningAppNamesByBundleID[identifier]
                ?? (isRunning ? identifier : nil)
            return (identifier, isRunning, displayName)
        }
        return nil
    }

    /// 便捷版：只关心"在不在跑"。
    static func ownerIsRunning(_ path: String) -> Bool {
        ownerApp(of: path)?.isRunning ?? false
    }

    /// 判断指定 JetBrains 目录名（如 IntelliJIdea2023.2 / PyCharm2024.1 / GoLand2023.1）对应的 IDE 是否正在运行
    static func isJetBrainsAppRunning(directoryName: String) -> (isRunning: Bool, appName: String) {
        let lower = directoryName.lowercased()
        let productMap: [(keyword: String, bundleID: String, alias: String, displayName: String)] = [
            ("intellij", "com.jetbrains.intellij", "idea", "IntelliJ IDEA"),
            ("idea", "com.jetbrains.intellij", "idea", "IntelliJ IDEA"),
            ("pycharm", "com.jetbrains.pycharm", "pycharm", "PyCharm"),
            ("goland", "com.jetbrains.goland", "goland", "GoLand"),
            ("webstorm", "com.jetbrains.webstorm", "webstorm", "WebStorm"),
            ("clion", "com.jetbrains.clion", "clion", "CLion"),
            ("rider", "com.jetbrains.rider", "rider", "Rider"),
            ("datagrip", "com.jetbrains.datagrip", "datagrip", "DataGrip"),
            ("rubymine", "com.jetbrains.rubymine", "rubymine", "RubyMine"),
            ("phpstorm", "com.jetbrains.phpstorm", "phpstorm", "PhpStorm"),
            ("rustrover", "com.jetbrains.rustrover", "rustrover", "RustRover"),
            ("fleet", "com.jetbrains.fleet", "fleet", "Fleet"),
            ("androidstudio", "com.google.android.studio", "studio", "Android Studio"),
            ("studio", "com.google.android.studio", "studio", "Android Studio"),
        ]
        for item in productMap {
            if lower.contains(item.keyword) {
                let running = runningBundleIDs.contains(item.bundleID)
                    || runningAppAliases.contains(item.alias)
                    || runningDisplayNames.contains(normalize(item.displayName))
                return (running, item.displayName)
            }
        }
        let anyJetBrainsRunning = runningBundleIDs.contains(where: { $0.lowercased().contains("jetbrains") })
            || runningDisplayNames.contains(where: { $0.lowercased().contains("jetbrains") || $0.lowercased().contains("idea") })
        return (anyJetBrainsRunning, "JetBrains IDE")
    }

    /// 从 ByHost plist 文件名（如 com.example.app.A1B2C3D4-E5F6-7890-ABCD-EF1234567890.plist）中剥离硬件 UUID，提取原生 bundle 标识符
    static func extractBundleFromByHostFilename(_ filename: String) -> String? {
        guard filename.hasSuffix(".plist") else { return nil }
        let base = String(filename.dropLast(".plist".count))
        // 匹配末尾形如 .[0-9A-Fa-f-]{32,} 的 UUID 段
        let pattern = #"\.([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}|[0-9A-Fa-f]{32})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(base.startIndex..<base.endIndex, in: base)
        guard let match = regex.firstMatch(in: base, options: [], range: range) else {
            return nil
        }
        guard let matchRange = Range(match.range, in: base) else { return nil }
        let stripped = String(base[..<matchRange.lowerBound])
        return stripped.isEmpty ? nil : stripped
    }

    // MARK: - v1.1 新增规则的路径（文档 §1.7 / §2.6 / §3.13–3.15 / §6.4）

    /// 用户级临时目录（`$TMPDIR`，形如 `/private/var/folders/xx/xxx/T`）
    /// 用途：L6 ShipIt 更新残留、D14 Node 编译缓存
    /// **安全约束**：绝不放行整个 `$TMPDIR` —— 实测其中混有正在运行的构建与工具活跃产物
    /// （例如 `/private/tmp` 里 3.1G 全是当日 agent 工作流产物，并非垃圾），
    /// 因此只按 `FileSystem.isKnownTempResidue(_:)` 的精确模式放行。
    static var userTempDir: String {
        NSTemporaryDirectory()
    }

    /// `$TMPDIR` 的同级 `C` 目录（D13 Clang 模块缓存所在）
    static var userCacheDir: String {
        (userTempDir as NSString).deletingLastPathComponent
    }

    /// D13：Clang 模块缓存完整路径
    static var clangModuleCache: String {
        (userCacheDir as NSString).appendingPathComponent(CleanupRules.clangCacheRelativePath)
    }

    /// D14：Node 编译缓存完整路径
    static var nodeCompileCache: String {
        (userTempDir as NSString).appendingPathComponent(CleanupRules.nodeCompileCacheName)
    }

    /// D15：全局 node_modules 扫描根（源自 CleanupRules，便于统一维护）
    static var globalNodeModulesRoots: [String] { CleanupRules.globalNodeModulesRoots }

    /// 展开 `~` 前缀（**只认前缀**）。
    ///
    /// 原先是无条件 `replacingOccurrences(of: "~", ...)`，两个问题：
    /// ① 会把路径**中间**的 `~` 也换成主目录——`/tmp/x~/y` 变成 `/tmp/x/Users/me/y`，
    ///    于是一个真实存在的垃圾路径，被拿去和 G6/G8/白名单比对的却是另一个不存在的路径；
    /// ② 绝大多数传入的路径本来就是绝对路径（扫描器给的都来自 `expandingTildeInPath`
    ///    或 `FileSystem.children`），却仍要付一次全串搜索替换 + 一次 `NSHomeDirectory()`。
    /// 而本函数在护栏里每条候选路径要被调 30 多次（`normalizePath` 的每一步），
    /// 是 `isSafeToClean` 单次开销 166 µs 的主要来源。
    static func expand(_ p: String) -> String {
        guard p.hasPrefix("~") else { return p }
        let home = NSHomeDirectory()
        if p == "~" { return home }
        guard p.hasPrefix("~/") else { return p }   // `~foo` 这类用户主目录写法不支持，原样返回
        return home + p.dropFirst(1)
    }
}
