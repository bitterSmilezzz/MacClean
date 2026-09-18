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

    // MARK: 2. 日志与临时文件 L1–L4
    static let logs = "~/Library/Logs"
    static let diagnosticReports = "~/Library/Logs/DiagnosticReports"
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
    static let codeRoots = ["~/workspace", "~/projects", "~/dev", "~/code"]

    // MARK: 4. App 残留 A1–A4
    static let appSupport = "~/Library/Application Support"
    static let preferences = "~/Library/Preferences"
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
    // OBS-2（终验）：改实时计算——每次访问取当前运行态，避免进程级静态快照过期
    // 导致运行中新启动的 Xcode/模拟器/浏览器缓存被列出
    static var runningBundleIDs: Set<String> {
        let apps = NSWorkspace.shared.runningApplications
        return Set(apps.compactMap { $0.bundleIdentifier })
    }

    /// 运行中 App 的显示名（归一化：小写、去空格）。
    static var runningDisplayNames: Set<String> {
        let apps = NSWorkspace.shared.runningApplications
        return Set(apps.compactMap { $0.localizedName }.map { normalize($0) })
    }

    /// 运行中 App 的**全部可识别名**（归一化）。
    ///
    /// 为什么需要一整组而不是一个名字——实测案例：
    /// `/Applications/Tabbit Browser.app` 的 `CFBundleName` 是英文 `Tabbit Browser`，
    /// 数据目录因此叫 `~/Library/Application Support/Tabbit Browser/`；
    /// 但 `NSRunningApplication.localizedName` 返回的是**本地化名**「Tabbit浏览器」。
    /// 只比对 localizedName 就会漏判，于是"浏览器正在运行、并正在写这个目录"的缓存
    /// 被判成"没在用"→ 标成可清理。这正是必须修掉的那类"看起来安全其实在用"。
    ///
    /// 采集来源：bundle id、localizedName、CFBundleName、CFBundleExecutable、.app 目录名。
    /// 结果缓存 5 秒：`ownerApp(of:)` 会逐项调用（50+ 项），不能每次都去读 Info.plist。
    private static var cachedAliases: (set: Set<String>, at: Date)?
    private static let aliasesTTL: TimeInterval = 5
    /// 缓存必须加锁：`scanAll` 会把 6 个分类**并发**丢进全局队列，每个分类的每一项
    /// 都会调 `ownerApp(of:)` → 这里。无锁读写一个 (Set, Date) 元组是实打实的数据竞争
    /// （元组不是单字，可能读到撕裂的值）。
    private static let aliasesLock = NSLock()

    static var runningAppAliases: Set<String> {
        aliasesLock.lock()
        if let c = cachedAliases, Date().timeIntervalSince(c.at) < aliasesTTL {
            let set = c.set
            aliasesLock.unlock()
            return set
        }
        aliasesLock.unlock()

        let names = computeRunningAppAliases()

        aliasesLock.lock()
        cachedAliases = (names, Date())
        aliasesLock.unlock()
        return names
    }

    /// 真正去读运行中 App 的信息。**在锁外执行**：读 Info.plist 是 I/O，
    /// 放在锁里会让并发扫描互相排队。最坏情况是几个线程各算一遍，无副作用。
    private static func computeRunningAppAliases() -> Set<String> {
        var names = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier { names.insert(normalize(bid)) }
            if let n = app.localizedName { names.insert(normalize(n)) }
            if let url = app.bundleURL {
                let dir = url.deletingPathExtension().lastPathComponent
                if !dir.isEmpty { names.insert(normalize(dir)) }
                let plist = url.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: plist) {
                    for key in ["CFBundleName", "CFBundleExecutable", "CFBundleDisplayName"] {
                        if let v = dict[key] as? String, !v.isEmpty { names.insert(normalize(v)) }
                    }
                }
            }
        }
        names.remove("")
        return names
    }

    /// bundle id → 显示名（用于给用户看"是哪个 App 在用"）
    static var runningAppNamesByBundleID: [String: String] {
        var map: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, let name = app.localizedName else { continue }
            map[bid] = name
        }
        return map
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

    /// 展开 ~ 前缀
    static func expand(_ p: String) -> String {
        p.replacingOccurrences(of: "~", with: NSHomeDirectory())
    }
}
