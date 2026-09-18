import Foundation
import AppKit

/// 孤儿残留排查引擎（借鉴 PureMac / Pearcleaner 逆向反查思路）
enum OrphanScanner {

    // MARK: - 已安装与系统 App 数据库

    struct InstalledDatabase {
        let bundleIDs: Set<String>
        let bundlePrefixes: Set<String>
        let normalizedNames: Set<String>
        let executableNames: Set<String>
        let runningBundleIDs: Set<String>

        init(
            bundleIDs: Set<String>,
            bundlePrefixes: Set<String>,
            normalizedNames: Set<String>,
            executableNames: Set<String>,
            runningBundleIDs: Set<String>
        ) {
            self.bundleIDs = bundleIDs
            self.bundlePrefixes = bundlePrefixes
            self.normalizedNames = normalizedNames
            self.executableNames = executableNames
            self.runningBundleIDs = runningBundleIDs
        }

        static func build() -> InstalledDatabase {
            var bIDs = Set<String>()
            var bPrefixes = Set<String>()
            var names = Set<String>()
            var execs = Set<String>()

            let roots = [
                "/Applications",
                "~/Applications",
                "/System/Applications",
                "/System/Library/CoreServices/Applications"
            ]

            for root in roots {
                let expanded = CleanPaths.expand(root)
                guard FileManager.default.fileExists(atPath: expanded) else { continue }
                collectApps(in: expanded, bIDs: &bIDs, bPrefixes: &bPrefixes, names: &names, execs: &execs)
            }

            // 运行中的进程
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
            for r in running {
                bIDs.insert(r)
                let parts = r.split(separator: ".")
                if parts.count >= 2 {
                    bPrefixes.insert("\(parts[0]).\(parts[1])")
                }
            }

            return InstalledDatabase(
                bundleIDs: bIDs,
                bundlePrefixes: bPrefixes,
                normalizedNames: names,
                executableNames: execs,
                runningBundleIDs: running
            )
        }

        private static func collectApps(
            in dir: String,
            bIDs: inout Set<String>,
            bPrefixes: inout Set<String>,
            names: inout Set<String>,
            execs: inout Set<String>
        ) {
            for child in FileSystem.children(of: dir) {
                if child.hasSuffix(".app") {
                    let appName = (child as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                    names.insert(normalize(appName))

                    let plistPath = (child as NSString).appendingPathComponent("Contents/Info.plist")
                    if let dict = NSDictionary(contentsOfFile: plistPath) {
                        if let bid = dict["CFBundleIdentifier"] as? String {
                            let lower = bid.lowercased()
                            bIDs.insert(lower)
                            let parts = lower.split(separator: ".")
                            if parts.count >= 2 {
                                bPrefixes.insert("\(parts[0]).\(parts[1])")
                            }
                        }
                        if let cfName = dict["CFBundleName"] as? String {
                            names.insert(normalize(cfName))
                        }
                        if let cfDisplay = dict["CFBundleDisplayName"] as? String {
                            names.insert(normalize(cfDisplay))
                        }
                        if let exec = dict["CFBundleExecutable"] as? String {
                            execs.insert(exec.lowercased())
                        }
                    }
                }
            }
        }
    }

    // MARK: - 保护白名单与判定

    private static let systemBundlePrefixes: Set<String> = [
        "com.apple.", "group.com.apple.", "apple.", "system.",
        "com.google.chrome.helper", "com.microsoft.autoupdate"
    ]

    private static let protectedSingleSegments: Set<String> = [
        "sharedfilelistd", "containermanagerd", "nsurlsessiond", "cfnetwork",
        "quicklook", "coreduet", "powerlog", "launchd", "bluetoothd", "trustd",
        "securityd", "secd", "tccd", "calaccessd", "cloudd", "identityservicesd"
    ]

    private static let sharedVendorTokens: Set<String> = [
        "jetbrains", "qt", "electron", "dotnet", "google", "microsoft",
        "adobe", "oracle", "tencent", "alibaba", "bytedance", "baidu",
        "python", "node", "homebrew", "cargo", "rust", "golang", "docker"
    ]

    /// 判定某条目是否属于仍安装在系统中的应用或系统服务（若属于则不是孤儿）
    static func isInstalledOrProtected(identifier: String, db: InstalledDatabase) -> Bool {
        let lower = identifier.lowercased()

        // 1. 系统 bundle 与守护进程硬白名单
        for prefix in systemBundlePrefixes where lower.hasPrefix(prefix) || lower == prefix.dropLast() {
            return true
        }
        if !lower.contains(".") && protectedSingleSegments.contains(lower) {
            return true
        }

        // 2. 精确命中已安装或运行中的 Bundle ID
        if db.bundleIDs.contains(lower) || db.runningBundleIDs.contains(lower) {
            return true
        }

        // 3. 前缀命中（如已安装 com.tencent.xinWeChat，匹配到 com.tencent.xinWeChat.helper）
        let parts = lower.split(separator: ".")
        if parts.count >= 2 {
            let prefix = "\(parts[0]).\(parts[1])"
            if db.bundlePrefixes.contains(prefix) {
                // 进一步检查是否为同主干应用
                if parts.count >= 3 {
                    let mainAppBundle = "\(parts[0]).\(parts[1]).\(parts[2])"
                    if db.bundleIDs.contains(mainAppBundle) {
                        return true
                    }
                }
            }
        }

        // 4. 名称与可执行文件名逆向归一化匹配
        let norm = normalize(lower)
        if norm.count >= 3 {
            for installed in db.normalizedNames {
                if installed == norm || (installed.count >= 4 && (norm.contains(installed) || installed.contains(norm))) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - 深度扫描

    static func scan(db: InstalledDatabase? = nil) -> [OrphanApp] {
        let database = db ?? InstalledDatabase.build()
        let home = NSHomeDirectory()
        var items: [OrphanItem] = []
        var itemCandidates: [UUID: (displayName: String, bundleID: String?)] = [:]

        // 1. 沙盒容器 ~/Library/Containers/*
        scanContainers(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 2. 共享组容器 ~/Library/Group Containers/*
        scanGroupContainers(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 3. 窗口状态 ~/Library/Saved Application State/*.savedState
        scanSavedState(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 4. WebKit 缓存 ~/Library/WebKit/*
        scanWebKit(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 5. 网络存储 ~/Library/HTTPStorages/*
        scanHTTPStorages(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 6. 偏好设置 ~/Library/Preferences/*.plist
        scanPreferences(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 7. 自启代理 ~/Library/LaunchAgents/*.plist
        scanLaunchAgents(home: home, db: database, into: &items, candidates: &itemCandidates)

        // 8. 聚合为 OrphanApp 分组
        return aggregate(items: items, candidates: itemCandidates)
    }

    // MARK: - 分类扫描实现

    private static func scanContainers(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/Containers"
        for child in FileSystem.children(of: root) {
            let dirName = (child as NSString).lastPathComponent
            guard !dirName.hasPrefix(".") else { continue }
            guard !isInstalledOrProtected(identifier: dirName, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let mdate = FileSystem.modificationDate(child)
            let item = OrphanItem(name: dirName, path: child, size: size,
                                  kind: .container, lastModified: mdate)
            items.append(item)
            candidates[item.id] = (deriveDisplayName(dirName), dirName)
        }
    }

    private static func scanGroupContainers(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/Group Containers"
        for child in FileSystem.children(of: root) {
            let dirName = (child as NSString).lastPathComponent
            guard !dirName.hasPrefix(".") else { continue }
            // 绝不碰系统组容器
            if dirName.hasPrefix("group.com.apple.") || dirName.hasPrefix("com.apple.") { continue }
            guard !isInstalledOrProtected(identifier: dirName, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let mdate = FileSystem.modificationDate(child)
            let item = OrphanItem(name: dirName, path: child, size: size,
                                  kind: .groupContainer, lastModified: mdate)
            items.append(item)
            candidates[item.id] = (deriveDisplayName(dirName), dirName)
        }
    }

    private static func scanSavedState(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/Saved Application State"
        for child in FileSystem.children(of: root) where child.hasSuffix(".savedState") {
            let dirName = (child as NSString).lastPathComponent
            let bundle = dirName.replacingOccurrences(of: ".savedState", with: "")
            guard !isInstalledOrProtected(identifier: bundle, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let mdate = FileSystem.modificationDate(child)
            let item = OrphanItem(name: dirName, path: child, size: size,
                                  kind: .savedState, lastModified: mdate)
            items.append(item)
            candidates[item.id] = (deriveDisplayName(bundle), bundle)
        }
    }

    private static func scanWebKit(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/WebKit"
        for child in FileSystem.children(of: root) {
            let dirName = (child as NSString).lastPathComponent
            guard !dirName.hasPrefix(".") else { continue }
            guard !isInstalledOrProtected(identifier: dirName, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let mdate = FileSystem.modificationDate(child)
            let item = OrphanItem(name: dirName, path: child, size: size,
                                  kind: .webkit, lastModified: mdate)
            items.append(item)
            candidates[item.id] = (deriveDisplayName(dirName), dirName)
        }
    }

    private static func scanHTTPStorages(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/HTTPStorages"
        for child in FileSystem.children(of: root) {
            let dirName = (child as NSString).lastPathComponent
            guard !dirName.hasPrefix(".") else { continue }
            guard !isInstalledOrProtected(identifier: dirName, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let mdate = FileSystem.modificationDate(child)
            let item = OrphanItem(name: dirName, path: child, size: size,
                                  kind: .httpStorage, lastModified: mdate)
            items.append(item)
            candidates[item.id] = (deriveDisplayName(dirName), dirName)
        }
    }

    private static func scanPreferences(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/Preferences"
        let cutoff = Date().addingTimeInterval(-30 * 86400) // 偏好设置保留 30 天缓冲期
        for child in FileSystem.children(of: root, keepHidden: false) where child.hasSuffix(".plist") {
            let fileName = (child as NSString).lastPathComponent
            let bundle = fileName.replacingOccurrences(of: ".plist", with: "")
            guard !isInstalledOrProtected(identifier: bundle, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            if let mdate = FileSystem.modificationDate(child), mdate >= cutoff {
                continue
            }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let item = OrphanItem(name: fileName, path: child, size: size,
                                  kind: .preferences, lastModified: FileSystem.modificationDate(child))
            items.append(item)
            candidates[item.id] = (deriveDisplayName(bundle), bundle)
        }
    }

    private static func scanLaunchAgents(
        home: String,
        db: InstalledDatabase,
        into items: inout [OrphanItem],
        candidates: inout [UUID: (displayName: String, bundleID: String?)]
    ) {
        let root = "\(home)/Library/LaunchAgents"
        for child in FileSystem.children(of: root, keepHidden: false) where child.hasSuffix(".plist") {
            guard FileSystem.isSafeToClean(child) else { continue }
            guard let dict = NSDictionary(contentsOfFile: child),
                  let args = dict["ProgramArguments"] as? [String] else { continue }

            for arg in args where arg.contains("/Applications/") {
                if !FileManager.default.fileExists(atPath: arg) {
                    let size = FileSystem.size(at: child)
                    let name = (child as NSString).lastPathComponent
                    let item = OrphanItem(name: name, path: child, size: size,
                                          kind: .launchAgent, lastModified: FileSystem.modificationDate(child))
                    items.append(item)
                    let appName = (arg as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                    candidates[item.id] = (appName, name.replacingOccurrences(of: ".plist", with: ""))
                    break
                }
            }
        }
    }

    // MARK: - 聚合归集

    private static func aggregate(
        items: [OrphanItem],
        candidates: [UUID: (displayName: String, bundleID: String?)]
    ) -> [OrphanApp] {
        var groups: [String: (displayName: String, bundleID: String?, items: [OrphanItem])] = [:]

        for item in items {
            guard let info = candidates[item.id] else { continue }
            let key = info.displayName.lowercased()

            if var existing = groups[key] {
                existing.items.append(item)
                if existing.bundleID == nil, let b = info.bundleID {
                    existing.bundleID = b
                }
                groups[key] = existing
            } else {
                groups[key] = (info.displayName, info.bundleID, [item])
            }
        }

        return groups.values.map { g in
            OrphanApp(
                name: g.displayName,
                bundleID: g.bundleID,
                items: g.items.sorted { $0.size > $1.size },
                isSelected: false
            )
        }.sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: - 辅助工具

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    /// 从 bundleID 或目录名推导人类可读的应用名称
    static func deriveDisplayName(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("group.") { s = String(s.dropFirst(6)) }
        let parts = s.split(separator: ".")
        if parts.count >= 3 {
            // e.g. com.bohemiancoding.sketch3 -> Sketch 3
            let last = String(parts.last!)
            return formatSegment(last)
        } else if let last = parts.last {
            return formatSegment(String(last))
        }
        return raw
    }

    private static func formatSegment(_ segment: String) -> String {
        guard !segment.isEmpty else { return segment }
        // 首字母大写
        return segment.prefix(1).uppercased() + segment.dropFirst()
    }

    /// 清理孤儿文件（转换为 CleanItem 走 Cleaner 安全废纸篓机制）
    static func clean(
        items: [OrphanItem],
        permanently: Bool,
        progress: @escaping (String) -> Void
    ) -> Cleaner.Result {
        let cleanItems = items.map { item in
            CleanItem(
                name: item.name,
                path: item.path,
                size: item.size,
                rule: "A1",
                category: .appResidue,
                note: "孤儿残留（\(item.kind.rawValue)）· 移入废纸篓"
            )
        }
        return Cleaner.clean(cleanItems, permanently: permanently, progress: progress)
    }
}
