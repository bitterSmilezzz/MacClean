import Foundation
import AppKit

/// 扫描引擎：严格按 CLEANUP-RULES.md 的 6 类规则执行只读扫描
final class Scanner {

    /// 已安装 App 名集合（去 .app 后缀、小写、去空格），用于 A1/A2 残留判断
    /// 来源：应用目录 + 当前运行中的应用名 + bundle id 前缀 + 中英文别名
    private static let installedApps: Set<String> = {
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
    }()

    /// 已安装 App 的 bundle id 前缀（前两段，如 com.tencent / com.bilibili）
    private static let installedBundlePrefixes: Set<String> = {
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
    }()

    /// 中英文别名映射（目录名 → 可能的已安装应用名）
    private static let nameAliases: [String: Set<String>] = [
        "bilibili": ["哔哩哔哩", "bilibili"],
        "qianwenime": ["通义输入法", "qianwenime"],
        "imamac": ["wechat", "微信", "qq"],
        "traecn": ["traesolocn", "trae"],
    ]

    private static func normalizeAppName(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        return base
    }

    // MARK: - 入口

    static func scan(_ category: CleanCategory) -> [CleanItem] {
        switch category {
        case .userCaches: return scanUserCaches()
        case .logsAndTemp: return scanLogsAndTemp()
        case .devResidue: return scanDevResidue()
        case .appResidue: return scanAppResidue()
        case .largeFiles: return scanLargeFiles()
        case .browserAndSystem: return scanBrowserAndSystem()
        }
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
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.userCaches)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            // G5: 运行中应用跳过（目录名与 bundle id 匹配）
            let bundle = (dir as NSString).lastPathComponent
            if CleanPaths.runningBundleIDs.contains(bundle) { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                add(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, risk: .safe, category: .userCaches,
                    note: "应用可重建的缓存"))
            }
        }

        // C2/C3: Xcode 与 pip 缓存（未运行才列入，seen 去重）
        for p in [CleanPaths.xcodeCache, CleanPaths.pipCache, CleanPaths.pipCacheAlt, CleanPaths.homebrewCache] {
            let dir = CleanPaths.expand(p)
            guard FileSystem.isDir(dir), FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            if size > 0 {
                add(CleanItem(
                    name: (dir as NSString).lastPathComponent,
                    path: dir, size: size, risk: .safe, category: .userCaches, note: p))
            }
        }

        // C6: 沙盒容器缓存
        let containers = CleanPaths.expand(CleanPaths.containersCaches)
        for container in FileSystem.subdirs(of: containers) {
            let bundle = (container as NSString).lastPathComponent
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

        // L1: ~/Library/Logs 顶层项
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.logs)) {
            guard FileSystem.isSafeToClean(child) else { continue }
            let size = FileSystem.size(at: child)
            if size > 0 {
                items.append(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, risk: .safe, category: .logsAndTemp,
                    note: "日志"))
            }
        }

        // L2: 诊断报告
        let reports = CleanPaths.expand(CleanPaths.diagnosticReports)
        if FileSystem.isDir(reports) {
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

        return items.sorted { $0.size > $1.size }
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
        var items: [CleanItem] = []
        let systemBundles = ["com.apple", "com.google", "com.microsoft", "com.adobe", "com.oracle",
                             "org.chromium", "com.jetbrains", "com.tencent", "com.alibaba", "com.bytedance"]

        // A1: Application Support 中已卸载 App 的目录
        for dir in FileSystem.subdirs(of: CleanPaths.expand(CleanPaths.appSupport)) {
            guard FileSystem.isSafeToClean(dir) else { continue }
            let name = (dir as NSString).lastPathComponent
            if name.hasPrefix(".") || name.hasPrefix("com.apple") { continue }
            let normalized = name.lowercased().replacingOccurrences(of: " ", with: "")
            // 兼容 bundle-id 形式目录名（com.qoder.app.stable → 各段与 app 名比对）
            let segments = normalized.split(separator: ".")
            let segmentMatch = segments.contains { seg in
                installedApps.contains { $0.contains(seg) || (seg.count >= 6 && seg.contains($0)) }
            }
            // bundle id 前缀匹配（com.tencent.imamac → com.tencent ∈ 已装前缀）
            let prefixMatch = segments.count >= 2 && installedBundlePrefixes.contains("\(segments[0]).\(segments[1])")
            // 别名匹配（bilibili ↔ 哔哩哔哩）
            let aliasMatch = nameAliases[normalized].map { aliases in
                aliases.contains { alias in
                    installedApps.contains { $0.contains(normalizeAppName(alias)) }
                }
            } ?? false
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
                    category: .appResidue, note: "疑似已卸载 App 的残留"))
            }
        }

        // A2: Preferences 中孤立 plist（排除系统 bundle，> 180 天）
        let cutoff = Date().addingTimeInterval(-180 * 86400)
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.preferences), keepHidden: false) {
            guard child.hasSuffix(".plist"), FileSystem.isSafeToClean(child) else { continue }
            let bundle = (child as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
            if systemBundles.contains(where: { bundle.hasPrefix($0) }) { continue }
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
        let day: TimeInterval = 86400

        // T1: 废纸篓（清理 = 彻底删除）
        for child in FileSystem.children(of: CleanPaths.expand(CleanPaths.trash)) {
            let size = FileSystem.size(at: child)
            if size > 0 {
                items.append(CleanItem(
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
                items.append(CleanItem(
                    name: (child as NSString).lastPathComponent,
                    path: child, size: size, risk: .review, category: .largeFiles,
                    note: size > 500 * 1024 * 1024 ? "超过 500MB" : "超过 180 天未访问"))
            }
        }

        // T3: 大文件扫描（>1GB，深度 ≤ 2）
        for root in CleanPaths.bigFileRoots {
            let rootPath = CleanPaths.expand(root)
            guard FileSystem.isDir(rootPath) else { continue }
            scanBigFiles(in: rootPath, depth: 0, maxDepth: 2, into: &items)
        }

        // T4: 未使用模拟器（>90 天）
        let cutoff = Date().addingTimeInterval(-90 * day)
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

        return items.sorted { $0.size > $1.size }
    }

    private static func scanBigFiles(in dir: String, depth: Int, maxDepth: Int, into items: inout [CleanItem]) {
        guard depth <= maxDepth else { return }
        for child in FileSystem.children(of: dir) {
            if FileSystem.isDir(child) {
                let name = (child as NSString).lastPathComponent
                if !name.hasPrefix(".") {
                    scanBigFiles(in: child, depth: depth + 1, maxDepth: maxDepth, into: &items)
                }
            } else {
                let size = FileSystem.size(at: child)
                if size > 1024 * 1024 * 1024 {
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
                                    (CleanPaths.safariContainerCaches, "Safari 容器缓存", .safe)] {
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
