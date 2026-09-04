import Foundation
import AppKit

/// 扫描引擎：严格按 CLEANUP-RULES.md 的 6 类规则执行只读扫描
final class Scanner {

    /// 已安装 App 名集合（去 .app 后缀、小写、去空格），用于 A1/A2 残留判断
    /// 来源：应用目录 + 当前运行中的应用名 + bundle id 前缀 + 中英文别名
    /// MED-1：改为可变缓存，A 类扫描前 refreshInstalledApps() 刷新，避免运行期新装 App 被误判残留
    private static var installedApps: Set<String> = Scanner.buildInstalledApps()

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
    private static var installedBundlePrefixes: Set<String> = Scanner.buildInstalledBundlePrefixes()

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
    private static func refreshInstalledApps() {
        installedApps = buildInstalledApps()
        installedBundlePrefixes = buildInstalledBundlePrefixes()
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
        // 使用频率标注（用户诉求）：逐项检测"最近使用时间 + 使用频率"，供 UI 判断值不值得删
        return items.map { annotateUsage($0) }
    }

    /// 标注最近使用时间与使用频率（对主路径检测；聚合项主路径为父目录，抽样反映整体活跃度）
    private static func annotateUsage(_ item: CleanItem) -> CleanItem {
        let info = FileSystem.usage(of: item.path)
        var copy = item
        copy.lastUsed = info.lastUsed
        copy.usage = info.level
        return copy
    }

    // MARK: - 1. 用户缓存 C1–C6

    private static func scanUserCaches() -> [CleanItem] {
        var items: [CleanItem] = []
        var seen = Set<String>()

        func add(_ item: CleanItem) {
            guard !seen.contains(item.path) else { return }
            seen.insert(item.path)
            items.append(item)
        }

        // C1: ~/Library/Caches 下所有子目录
        // 运行时跳过：目录名命中运行中 app 的 bundle id **或显示名**（如 "Tabbit Browser" 目录）
        let runningBundleIDs = CleanPaths.runningBundleIDs
        let runningDisplayNames = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
                .map { $0.lowercased().replacingOccurrences(of: " ", with: "") }
        )
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.userCaches)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            // G5: 运行中应用跳过（目录名与 bundle id 或 app 显示名匹配）
            let bundle = (dir as NSString).lastPathComponent
            let normalizedDir = bundle.lowercased().replacingOccurrences(of: " ", with: "")
            if runningBundleIDs.contains(bundle) || runningDisplayNames.contains(normalizedDir) { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                add(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, risk: .safe, category: .userCaches,
                    note: "应用可重建的缓存"))
            }
        }

        // C2/C3: Xcode 与 pip 缓存（未运行才列入，seen 去重；LOW-1：Xcode 缓存需运行时过滤）
        if !CleanPaths.runningBundleIDs.contains("com.apple.dt.Xcode") {
            let xcodeDir = CleanPaths.expand(CleanPaths.xcodeCache)
            if FileSystem.isDir(xcodeDir), FileSystem.isSafeToClean(xcodeDir) {
                let size = FileSystem.size(at: xcodeDir)
                if size > 0 {
                    add(CleanItem(
                        name: (xcodeDir as NSString).lastPathComponent,
                        path: xcodeDir, size: size, risk: .safe, category: .userCaches,
                        note: CleanPaths.xcodeCache))
                }
            }
        }
        for p in [CleanPaths.pipCache, CleanPaths.pipCacheAlt, CleanPaths.homebrewCache] {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                add(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, risk: .safe, category: .userCaches, note: p))
            }
        }

        // C6: 沙盒容器缓存（N3：com.apple.Safari 容器缓存由 B1 分类统一管理，此处排除防跨分类重复）
        let containers = CleanPaths.expand(CleanPaths.containersCaches)
        for container in FileSystem.subdirs(of: containers) {
            let bundle = (container as NSString).lastPathComponent
            if bundle == "com.apple.Safari" { continue }
            if CleanPaths.runningBundleIDs.contains(bundle) { continue }
            let cacheDir = (container as NSString).appendingPathComponent("Data/Library/Caches")
            guard FileSystem.isDir(cacheDir), FileSystem.isSafeToClean(cacheDir) else { continue }
            let size = FileSystem.size(at: cacheDir)
            if size > 0 {
                add(CleanItem(
                    name: "\(bundle) 缓存",
                    path: cacheDir, size: size, risk: .safe, category: .userCaches,
                    note: "沙盒容器缓存"))
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - 2. 日志与临时文件 L1–L4

    private static func scanLogsAndTemp() -> [CleanItem] {
        var items: [CleanItem] = []

        // L1: ~/Library/Logs 顶层项（DiagnosticReports 由 L2 单独列出，此处跳过防重复）
        // MED-3：记录已列出的顶层路径，L5 跳过这些路径内部的轮转文件防字节双计
        let reportsDir = CleanPaths.expand(CleanPaths.diagnosticReports)
        var l1CoveredPaths = Set<String>()
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.logs)) {
            guard FileSystem.isSafeToClean(child), child != reportsDir else { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                items.append(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, risk: .safe, category: .logsAndTemp,
                    note: "日志"))
                l1CoveredPaths.insert(child)
            }
        }

        // L2: 诊断报告（L1 已跳过该目录，这里单独列出更明确的含义）
        // OBS-1（终验）：DiagnosticReports 也加入 covered，L5 不再收集其内部 .gz 防展示双计
        let reports = CleanPaths.expand(CleanPaths.diagnosticReports)
        if FileSystem.isDir(reports) {
            l1CoveredPaths.insert(reports)
            let size = FileSystem.size(at: reports)
            if size > 0 {
                items.append(CleanItem(
                    name: "DiagnosticReports", path: reports, size: size,
                    risk: .safe, category: .logsAndTemp, note: "崩溃与诊断报告"))
            }
        }

        // L3: /private/tmp 与 /private/var/tmp（仅可写项）
        for tmpPath in [CleanPaths.tmp, CleanPaths.varTmp] {
            guard FileManager.default.isWritableFile(atPath: tmpPath) else { continue }
            for child in FileSystem.children(of: tmpPath) {
                guard FileSystem.isSafeToClean(child) else { continue }
                let size = FileSystem.size(at: child)
                if size > 0 {
                    items.append(CleanItem(
                        name: (child as NSString).lastPathComponent,
                        path: child, size: size, risk: .review, category: .logsAndTemp,
                        note: "临时文件（需确认）"))
                }
            }
        }

        // L4: TemporaryItems
        let tempItems = CleanPaths.expand(CleanPaths.temporaryItems)
        if FileSystem.isDir(tempItems) {
            let size = FileSystem.size(at: tempItems)
            if size > 0 {
                items.append(CleanItem(
                    name: "TemporaryItems", path: tempItems, size: size,
                    risk: .safe, category: .logsAndTemp, note: "未完成写入的临时项"))
            }
        }

        // L5: 旋转/压缩旧日志（*.log.N / *.gz，>30 天，仅 Logs 内递归深度 3）
        // MED-3：跳过 L1 已整体列出的顶层目录内部的轮转文件（L1 目录项删除时已包含），防字节双计
        let logRoot = CleanPaths.expand(CleanPaths.logs)
        let rotatedCutoff = Date().addingTimeInterval(-30 * 86400)
        var rotatedTargets: [String] = []
        var rotatedBytes: Int64 = 0
        collectRotatedLogs(in: logRoot, depth: 0, maxDepth: 3, cutoff: rotatedCutoff,
                           coveredByL1: l1CoveredPaths,
                           into: &rotatedTargets, bytes: &rotatedBytes)
        if !rotatedTargets.isEmpty {
            items.append(CleanItem(
                name: "旋转旧日志 (\(rotatedTargets.count) 个文件)",
                path: logRoot, paths: rotatedTargets, size: rotatedBytes,
                risk: .review, category: .logsAndTemp,   // L1: 提级为需确认（批量文件，谨慎）
                note: "超过 30 天的 *.log.N / *.N.log / *.gz 轮转日志"))
        }

        return items.sorted { $0.size > $1.size }
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
            if FileSystem.isDir(child) {
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

    // MARK: - 3. 开发残留 D1–D11

    private static func scanDevResidue() -> [CleanItem] {
        var items: [CleanItem] = []
        let xcodeRunning = CleanPaths.runningBundleIDs.contains("com.apple.dt.Xcode")

        // D1: DerivedData
        if !xcodeRunning {
            for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.derivedData)) {
                guard FileSystem.isSafeToClean(dir) else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (dir as NSString).lastPathComponent,
                        path: dir, size: size, risk: .safe, category: .devResidue,
                        note: "Xcode 构建产物"))
                }
            }
        }

        // D2: Archives 超过 90 天
        let cutoff = Date().addingTimeInterval(-90 * 86400)
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.archives)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            guard let mdate = FileSystem.modificationDate(dir), mdate < cutoff else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, risk: .review, category: .devResidue,
                    note: "超过 90 天的归档"))
            }
        }

        // D3: 模拟器缓存
        let simCaches = CleanPaths.expand(CleanPaths.simulatorCaches)
        if FileSystem.isDir(simCaches), FileSystem.isSafeToClean(simCaches) {
            let size = FileSystem.size(at: simCaches)
            if size > 0 {
                items.append(CleanItem(name: "CoreSimulator Caches", path: simCaches,
                                       size: size, risk: .safe, category: .devResidue,
                                       note: "模拟器缓存"))
            }
        }

        // D4–D10: 包管理器缓存（整目录，safe）
        let pkgDirs: [(String, String)] = [
            (CleanPaths.npmCache, "npm 缓存"),
            (CleanPaths.yarnCache, "yarn 缓存"),
            (CleanPaths.pnpmStore, "pnpm store"),
            (CleanPaths.gradleCaches, "Gradle 缓存"),
            (CleanPaths.cargoRegistry, "Cargo registry"),
            (CleanPaths.swiftpmCache, "SwiftPM 缓存"),
        ]
        for (p, note) in pkgDirs {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                items.append(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, risk: .safe, category: .devResidue, note: note))
            }
        }

        // D8: Maven 失效元数据（只清 *.lastUpdated 与 _remote.repositories）
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
                    path: m2, paths: targets, size: total, risk: .review,
                    category: .devResidue, note: "*.lastUpdated / _remote.repositories"))
            }
        }

        // D11: __pycache__（限定代码目录，深度 ≤ 5）
        for root in CleanPaths.codeRoots {
            let rootPath = CleanPaths.expand(root)
            guard FileSystem.isDir(rootPath) else { continue }
            collectPycache(in: rootPath, depth: 0, maxDepth: 5, into: &items)
        }

        // D12: Homebrew Cellar 旧版本（保留当前链接版本，其余移入候选）
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
                        risk: .review, category: .devResidue,
                        note: "Homebrew 旧版本，当前为 \(current ?? "未知")"))
                }
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    private static func collectPycache(in dir: String, depth: Int, maxDepth: Int, into items: inout [CleanItem]) {
        guard depth <= maxDepth else { return }
        for child in FileSystem.subdirs(of: dir) {
            let name = (child as NSString).lastPathComponent
            if name == "__pycache__" {
                guard FileSystem.isSafeToClean(child) else { continue }
                let size = FileSystem.size(at: child)
                if size > 0 {
                    items.append(CleanItem(
                        name: name, path: child, size: size, risk: .safe,
                        category: .devResidue, note: "Python 字节码缓存"))
                }
            } else if !name.hasPrefix(".") {
                collectPycache(in: child, depth: depth + 1, maxDepth: maxDepth, into: &items)
            }
        }
    }

    // MARK: - 4. App 残留 A1–A4

    private static func scanAppResidue() -> [CleanItem] {
        // MED-1：扫描前刷新已安装 App 缓存（运行期新装 App 不再被误判残留）
        refreshInstalledApps()
        var items: [CleanItem] = []
        let systemBundles = ["com.apple", "com.google", "com.microsoft", "com.adobe", "com.oracle",
                             "org.chromium", "com.jetbrains", "com.tencent", "com.alibaba", "com.bytedance"]

        // A1: Application Support 中已卸载 App 的目录
        // 修复：①别名双向匹配 ②180 天活跃度门槛（在用数据不列）③共享框架目录排除 ④运行中 app 匹配跳过
        let residueCutoff = Date().addingTimeInterval(-180 * 86400)
        let runningNames = Set(CleanPaths.runningBundleIDs)
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
                    name: name, path: dir, size: size, risk: .review,
                    category: .appResidue, note: "疑似已卸载 App 的残留（180 天未更新）"))
            }
        }

        // A2: Preferences 中孤立 plist（排除系统 bundle、仍安装的 App 与通用框架，> 180 天）
        // 修复：单段名（系统守护进程）、通用框架 vendor 前缀均不列为可删
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
                    name: bundle, path: child, size: size, risk: .review,
                    category: .appResidue, note: "超过 180 天未更新的偏好设置"))
            }
        }

        // A4: LaunchAgents 指向不存在的程序
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.launchAgents), keepHidden: false) {
            guard child.hasSuffix(".plist"), FileSystem.isSafeToClean(child) else { continue }
            if let dict = NSDictionary(contentsOfFile: child),
               let args = dict["ProgramArguments"] as? [String] {
                for arg in args where arg.contains("/Applications/") {
                    if !FileManager.default.fileExists(atPath: arg) {
                        let size = FileSystem.size(at: child)
                        items.append(CleanItem(
                            name: (child as NSString).lastPathComponent,
                            path: child, size: size, risk: .danger,
                            category: .appResidue,
                            note: "启动代理指向已卸载 App：\(arg)"))
                        break
                    }
                }
            }
        }

        return items.sorted { $0.size > $1.size }
    }

    // MARK: - 5. 大文件与垃圾箱 T1–T4

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
                    path: child, size: size, risk: .review, category: .largeFiles,
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
                    path: child, size: size, risk: .review, category: .largeFiles,
                    note: size > 500 * 1024 * 1024 ? "超过 500MB" : "超过 180 天未访问"))
            }
        }

        // T3: 大文件扫描（>1GB，深度 ≤ 2；与 T2 共享 seen，Downloads 顶层不再重复）
        for root in CleanPaths.bigFileRoots {
            let rootPath = CleanPaths.expand(root)
            guard FileSystem.isDir(rootPath) else { continue }
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
                        path: dir, size: size, risk: .danger, category: .largeFiles,
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
                    path: dir, size: size, risk: .review,
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
            if FileSystem.isDir(child) {
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
                        path: child, size: size, risk: .review, category: .largeFiles,
                        note: "超过 1GB 的大文件"))
                }
            }
        }
    }

    // MARK: - 6. 浏览器与系统数据 B1–B3

    private static func scanBrowserAndSystem() -> [CleanItem] {
        var items: [CleanItem] = []

        // B1/B3: Safari 站点数据与容器缓存（Safari 未运行）
        if !CleanPaths.runningBundleIDs.contains("com.apple.Safari") {
            for (p, note, risk) in [(CleanPaths.safariLocalStorage, "Safari LocalStorage", RiskLevel.review),
                                    (CleanPaths.safariWebsiteData, "Safari 站点数据", .review),
                                    (CleanPaths.safariContainerCaches, "Safari 容器缓存", .safe),
                                    (CleanPaths.safariContainerStorages, "Safari WebKit 站点数据", .review)] {
                let dir = CleanPaths.expand(p)
                guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
                let size = FileSystem.size(at: dir)
                if size > 0 {
                    items.append(CleanItem(
                        name: (dir as NSString).lastPathComponent,
                        path: dir, size: size, risk: risk, category: .browserAndSystem, note: note))
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
                            path: cacheDir, size: size, risk: .review,
                            category: .browserAndSystem,
                            note: "\(appName) 缓存（浏览器未运行时）"))
                    }
                }
            }
        }

        return items.sorted { $0.size > $1.size }
    }
}
