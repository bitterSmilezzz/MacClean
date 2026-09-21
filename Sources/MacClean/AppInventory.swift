import Foundation
import AppKit

// MARK: - 已安装应用清单（v1.72.0 收敛）
//
// 这件事此前有 6 份实现：`Scanner.buildInstalledApps`、`Scanner.buildInstalledBundlePrefixes`、
// `OrphanScanner.InstalledDatabase.build`、`UninstallerScanner.scanApps`、
// `AudioHALScanner.getInstalledBundleIDs`、`SpotlightScanner.getInstalledBundleIDs`、
// `CLICacheScanner`/`AppLocalizationScanner`/`DiagnosticReportScanner` 又各有变体。
// 打开一次卸载器（列 App → 查孤儿 → 查偏好残留 → 查插件残存）会**重建约 5 次**，
// 每次枚举 4 个 Applications 根并读 200–400 份 `Info.plist`。
//
// 更严重的是正确性：这些实现清一色用 `try?` 读目录，读失败就 `continue`。
// 于是"根目录读不到"会得到一个**空集合**，而下游把"bundle id 不在已安装集合里"
// 当成"宿主已卸载"——读失败被读成了"全机应用都消失了"，所有残存一律默认可删。
// 这正是 README 声称已修的 G13（"读不到"不等于"很干净"）在治理模块里的复发。
//
// 本类型是唯一的清单来源，并额外导出 `isComplete`：任何据此判孤儿的模块都必须在
// 清单不完整时**放弃判孤儿**，把结论降级为"需确认"。

enum AppInventory {

    struct Snapshot: Equatable {
        /// 小写 bundle id
        let bundleIDs: Set<String>
        /// bundle id 前两段（com.tencent / com.bilibili）
        let bundlePrefixes: Set<String>
        /// 归一化后的应用名（含 CFBundleName / CFBundleDisplayName / 目录名）
        let normalizedNames: Set<String>
        /// 小写可执行文件名
        let executableNames: Set<String>
        /// 此刻在跑的 bundle id
        let runningBundleIDs: Set<String>
        /// `.app` 绝对路径
        let appPaths: [String]
        /// 读取失败的根目录。**非空即清单不可信**
        let unreadableRoots: [String]

        /// 清单是否足以支撑"孤儿"结论
        var isComplete: Bool { unreadableRoots.isEmpty && !bundleIDs.isEmpty }

        /// 名字是否命中某个已安装应用（归一化后比对）
        func matchesInstalledName(_ text: String) -> Bool {
            let norm = OrphanScanner.normalize(text)
            guard norm.count >= 3 else { return false }
            for installed in normalizedNames where installed == norm
                || (installed.count >= 4 && (norm.contains(installed) || installed.contains(norm))) {
                return true
            }
            return false
        }

        /// bundle id 是否已安装（含 helper 段回退到主干）
        func contains(bundleID: String) -> Bool {
            let lower = bundleID.lowercased()
            if bundleIDs.contains(lower) || runningBundleIDs.contains(lower) { return true }
            let parts = lower.split(separator: ".")
            guard parts.count >= 3 else { return false }
            return bundleIDs.contains("\(parts[0]).\(parts[1]).\(parts[2])")
        }

        static let empty = Snapshot(bundleIDs: [], bundlePrefixes: [], normalizedNames: [],
                                    executableNames: [], runningBundleIDs: [], appPaths: [],
                                    unreadableRoots: [])
    }

    // MARK: 注入点（自检用）

    /// 覆盖扫描根；nil = 用默认
    static var rootsOverride: [String]?
    /// 覆盖整份清单（自检注入 fixture 时用，避免依赖真实机器上装了哪些 App）
    static var snapshotOverride: Snapshot?

    private static var cached: Snapshot?
    private static var cachedAt: Date?
    private static let lock = NSLock()

    /// 默认扫描根：`CleanPaths.appDirs` 再补上系统内置 App 的落点，
    /// 与原先 `OrphanScanner.InstalledDatabase.build` 的根集合取并集，避免收敛后漏判。
    static var defaultRoots: [String] {
        CleanPaths.appDirs + ["/System/Library/CoreServices/Applications"]
    }

    /// 当前清单（命中缓存则零 I/O）。`ttl` 控制多久重新扫一次盘。
    static func current(ttl: TimeInterval = 60, forceRefresh: Bool = false) -> Snapshot {
        if let override = snapshotOverride { return override }
        lock.lock()
        if !forceRefresh, let cached, let at = cachedAt, Date().timeIntervalSince(at) < ttl {
            lock.unlock()
            return cached
        }
        let roots = rootsOverride ?? defaultRoots
        lock.unlock()

        // **建清单时不持锁**：它要枚举 4 个 Applications 根并读几百份 `Info.plist`
        // （实测 13.6 ms）。`Scanner.scanAllCategories` 用 `concurrentPerform` 并发跑 6 个
        // 分类，持锁会把并行扫描退化成"排队等锁"，缓存反而成了新的串行点。
        // 两个线程同时构建只是多做一次 I/O，结果一致（后写覆盖先写）。
        let built = build(roots: roots)

        lock.lock()
        cached = built
        cachedAt = Date()
        lock.unlock()
        return built
    }

    /// 安装/卸载了应用、或治理模块需要绝对新鲜时调用。
    static func invalidate() {
        lock.lock()
        cached = nil
        cachedAt = nil
        lock.unlock()
    }

    private static func build(roots: [String]) -> Snapshot {
        var bIDs = Set<String>()
        var bPrefixes = Set<String>()
        var names = Set<String>()
        var execs = Set<String>()
        var paths = [String]()
        var unreadable = [String]()

        for root in roots {
            let expanded = CleanPaths.expand(root)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                continue   // 根本就不存在（如未装第三方输入法）→ 不算读失败
            }
            do {
                let children = try FileManager.default.contentsOfDirectory(atPath: expanded)
                for child in children where child.hasSuffix(".app") {
                    let appPath = (expanded as NSString).appendingPathComponent(child)
                    paths.append(appPath)
                    ingest(appPath: appPath, child: child,
                          bIDs: &bIDs, bPrefixes: &bPrefixes, names: &names, execs: &execs)
                }
            } catch {
                unreadable.append(expanded)
            }
        }

        // 运行中的 App 一定算"已安装"（G5）
        var running = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                let lower = bid.lowercased()
                running.insert(lower)
                bIDs.insert(lower)
                let parts = lower.split(separator: ".")
                if parts.count >= 2 { bPrefixes.insert("\(parts[0]).\(parts[1])") }
            }
            if let name = app.localizedName { names.insert(OrphanScanner.normalize(name)) }
        }

        return Snapshot(bundleIDs: bIDs, bundlePrefixes: bPrefixes, normalizedNames: names,
                        executableNames: execs, runningBundleIDs: running, appPaths: paths,
                        unreadableRoots: unreadable)
    }

    private static func ingest(appPath: String, child: String,
                               bIDs: inout Set<String>, bPrefixes: inout Set<String>,
                               names: inout Set<String>, execs: inout Set<String>) {
        names.insert(OrphanScanner.normalize(child.replacingOccurrences(of: ".app", with: "")))
        guard let dict = NSDictionary(contentsOfFile: (appPath as NSString)
            .appendingPathComponent("Contents/Info.plist")) else { return }
        if let bid = dict["CFBundleIdentifier"] as? String {
            let lower = bid.lowercased()
            bIDs.insert(lower)
            let parts = lower.split(separator: ".")
            if parts.count >= 2 { bPrefixes.insert("\(parts[0]).\(parts[1])") }
        }
        for key in ["CFBundleName", "CFBundleDisplayName"] {
            if let v = dict[key] as? String { names.insert(OrphanScanner.normalize(v)) }
        }
        if let exec = dict["CFBundleExecutable"] as? String { execs.insert(exec.lowercased()) }
    }
}
