import Foundation
import AppKit

// MARK: - 已安装 App（供卸载器）

struct InstalledApp: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let bundleID: String?
    let size: Int64

    var isSystemApp: Bool { bundleID?.hasPrefix("com.apple.") == true }
    /// MED-2（终检）：实时查询运行态，不依赖进程启动时的静态快照
    var isRunning: Bool {
        guard let bundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

// MARK: - 关联残留文件类型细分

enum RelatedFileKind: String, CaseIterable, Identifiable, Codable {
    case appSupport = "应用支持数据"
    case preferences = "偏好设置"
    case caches = "缓存数据"
    case containers = "沙盒容器"
    case groupContainers = "共享组容器"
    case webKitAndCookies = "WebKit 与 Cookie"
    case crashReports = "崩溃诊断报告"
    case savedState = "状态与恢复"
    case appScripts = "应用脚本"
    case launchAgents = "自启守护项"
    case httpStorages = "网络数据"
    case other = "其他关联"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appSupport: return "folder.badge.gearshape"
        case .preferences: return "gearshape"
        case .caches: return "archivebox"
        case .containers: return "shippingbox"
        case .groupContainers: return "person.2.badge.gearshape"
        case .webKitAndCookies: return "safari"
        case .crashReports: return "exclamationmark.bubble"
        case .savedState: return "clock.arrow.circlepath"
        case .appScripts: return "applescript"
        case .launchAgents: return "bolt"
        case .httpStorages: return "network"
        case .other: return "doc"
        }
    }
}

// MARK: - 关联文件（App 卸载器扫描结果）

struct RelatedFile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let kind: String   // 所属类别文字描述，保持兼容
    let fileKind: RelatedFileKind
    var isSelected: Bool = false

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        size: Int64,
        kind: String,
        fileKind: RelatedFileKind? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.kind = kind
        self.fileKind = fileKind ?? Self.inferFileKind(from: kind)
        self.isSelected = isSelected
    }

    private static func inferFileKind(from kind: String) -> RelatedFileKind {
        switch kind {
        case "Application Support": return .appSupport
        case "Preferences": return .preferences
        case "Caches": return .caches
        case "Containers": return .containers
        case "Group Containers": return .groupContainers
        case "WebKit", "WebKit 与 Cookie": return .webKitAndCookies
        case "Logs", "崩溃诊断报告": return .crashReports
        case "Saved State", "状态与恢复": return .savedState
        case "Application Scripts", "应用脚本": return .appScripts
        case "LaunchAgents", "自启守护项": return .launchAgents
        case "HTTPStorages", "网络数据": return .httpStorages
        default: return .other
        }
    }
}

// MARK: - 卸载器状态

final class UninstallerState: ObservableObject {
    public enum UninstallerTab: String, CaseIterable, Identifiable {
        case apps = "已安装应用"
        case orphans = "孤儿残留排查"
        case preferences = "偏好碎片反查"
        case extensions = "插件与扩展治理"
        case localization = "多语言瘦身"
        case loginItems = "自启死链排查"
        public var id: String { rawValue }
    }

    @Published var currentTab: UninstallerTab = .apps

    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var related: [RelatedFile] = []
    @Published var isScanning = false
    @Published var lastSummary: String?
    @Published var isUninstalling = false

    // MARK: - 孤儿残留状态
    @Published var orphanApps: [OrphanApp] = []
    @Published var selectedOrphanApp: OrphanApp?
    @Published var isScanningOrphans = false
    @Published var lastOrphanSummary: String?
    @Published var isCleaningOrphans = false

    // MARK: - 偏好碎片反查状态 (v1.53.0)
    @Published var preferenceItems: [OrphanPreferenceItem] = []
    @Published var isScanningPreferences = false
    @Published var lastPreferenceSummary: String?
    @Published var isCleaningPreferences = false

    // MARK: - 插件与扩展治理状态 (v1.55.0)
    @Published var pluginItems: [PluginExtensionItem] = []
    @Published var isScanningPlugins = false
    @Published var lastPluginSummary: String?
    @Published var isCleaningPlugins = false

    // MARK: - 多语言瘦身状态 (v1.60.0)
    @Published var localizationBundles: [AppLocalizationBundle] = []
    @Published var selectedLocalizationBundle: AppLocalizationBundle?
    @Published var isScanningLocalization = false
    @Published var lastLocalizationSummary: String?
    @Published var isCleaningLocalization = false

    func loadLocalization() {
        isScanningLocalization = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bundles = AppLocalizationScanner.scan()
            DispatchQueue.main.async {
                self?.localizationBundles = bundles
                self?.isScanningLocalization = false
                if self?.selectedLocalizationBundle == nil || !bundles.contains(where: { $0.id == self?.selectedLocalizationBundle?.id }) {
                    self?.selectedLocalizationBundle = bundles.first
                }
            }
        }
    }

    func selectLocalizationBundle(_ bundle: AppLocalizationBundle?) {
        selectedLocalizationBundle = bundle
    }

    func toggleLocalizationPack(bundleID: String, packID: String, on: Bool) {
        guard let bIdx = localizationBundles.firstIndex(where: { $0.id == bundleID }) else { return }
        var bundles = localizationBundles
        if let pIdx = bundles[bIdx].languagePacks.firstIndex(where: { $0.id == packID }) {
            if !bundles[bIdx].languagePacks[pIdx].isProtected {
                bundles[bIdx].languagePacks[pIdx].isSelected = on
            }
        }
        localizationBundles = bundles
        if selectedLocalizationBundle?.id == bundleID {
            selectedLocalizationBundle = bundles[bIdx]
        }
    }

    func setAllLocalizationPacksSelected(bundleID: String, on: Bool) {
        guard let bIdx = localizationBundles.firstIndex(where: { $0.id == bundleID }) else { return }
        var bundles = localizationBundles
        bundles[bIdx].languagePacks = bundles[bIdx].languagePacks.map { pack in
            var copy = pack
            if !copy.isProtected {
                copy.isSelected = on
            }
            return copy
        }
        localizationBundles = bundles
        if selectedLocalizationBundle?.id == bundleID {
            selectedLocalizationBundle = bundles[bIdx]
        }
    }

    func cleanSelectedLocalization(bundle: AppLocalizationBundle, permanently: Bool = false) -> Bool {
        guard !isCleaningLocalization else { return false }
        let selectedIDs = Set(bundle.languagePacks.filter { !$0.isProtected && $0.isSelected }.map(\.id))
        guard !selectedIDs.isEmpty else { return false }

        isCleaningLocalization = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = AppLocalizationScanner.cleanOutcome(bundle: bundle, selectedItemIDs: selectedIDs,
                                                          permanently: permanently)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCleaningLocalization = false
                let mode = permanently ? "彻底清除" : "移入废纸篓"
                // 摘要必须带上被拦数：网关会因为签名密封风险、语言保护、越权等原因
                // 拒绝其中若干项，只播报"已安全清理 N 个"等于让用户以为剩下的也处理了。
                var summary = "【\(bundle.appName)】已\(mode) \(res.cleanedCount) 个外语包，释放 \(res.freedBytes.byteStringCN)"
                if !res.needsPrivilege.isEmpty {
                    summary += "；\(res.needsPrivilege.count) 项无删除权限（该 App 由 root 管理）"
                }
                let blocked = res.rejected.count - res.needsPrivilege.count
                if blocked > 0 {
                    summary += "；\(blocked) 项被安全护栏拦下（母语/系统语言/受保护资源）"
                }
                if res.cleanedCount == 0 {
                    summary = "【\(bundle.appName)】没有可清理项：\(res.summary)"
                }
                self.lastLocalizationSummary = summary
                if let updated = AppLocalizationScanner.inspectAppBundle(at: bundle.appPath), updated.removablePackCount > 0 {
                    if let idx = self.localizationBundles.firstIndex(where: { $0.id == bundle.id }) {
                        self.localizationBundles[idx] = updated
                        if self.selectedLocalizationBundle?.id == bundle.id {
                            self.selectedLocalizationBundle = updated
                        }
                    }
                } else {
                    self.localizationBundles.removeAll { $0.id == bundle.id }
                    if self.selectedLocalizationBundle?.id == bundle.id {
                        self.selectedLocalizationBundle = self.localizationBundles.first
                    }
                }
            }
        }
        return true
    }

    func loadApps() {
        // 三巡：置 isScanning 避免首次进入闪现"未发现可卸载 App"空态
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = UninstallerScanner.scanApps()
            DispatchQueue.main.async {
                self?.apps = apps
                self?.isScanning = false
            }
        }
    }

    func select(_ app: InstalledApp?) {
        selectedApp = app
        related = []
        lastSummary = nil
        guard let app, !app.isRunning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = UninstallerScanner.relatedFiles(for: app)
            DispatchQueue.main.async {
                self?.related = files
                self?.isScanning = false
            }
        }
    }

    var selectedFiles: [RelatedFile] { related.filter { $0.isSelected } }
    var selectedCount: Int { selectedFiles.count }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
    var allSelected: Bool { !related.isEmpty && related.allSatisfy { $0.isSelected } }

    func toggle(_ fileID: UUID, _ on: Bool) {
        guard let idx = related.firstIndex(where: { $0.id == fileID }) else { return }
        var new = related
        new[idx].isSelected = on
        related = new   // 整体赋值触发 @Published
    }

    func setAllSelected(_ on: Bool) {
        related = related.map { var f = $0; f.isSelected = on; return f }
    }

    /// 卸载勾选的关联文件（默认移入废纸篓；已在废纸篓语义的项强制删除由 Cleaner 处理）
    func uninstallSelected(permanently: Bool) -> Bool {
        let files = selectedFiles
        guard !files.isEmpty, !isUninstalling else { return false }
        isUninstalling = true
        // 走 A1 规则编号（本质 = 已卸载 App 的残留 → 需确认）。
        // 注意：卸载器这里的"选择"是用户先明确点了要卸载某个 App 才产生的，
        // 与分类扫描里"一键全选"的风险性质不同，因此不套用 selectAllSafe 的限制。
        let items = files.map {
            CleanItem(name: $0.name, path: $0.path, size: $0.size, rule: "A1",
                      category: .appResidue, note: "\($0.kind) · App 卸载残留")
        }
        // L5（数据层审查）：避免主线程同步执行大目录 trashItem 阻塞 UI——后台执行 + 主线程回写
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Cleaner.clean(items, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self else { return }
                let failed = result.failedPaths
                let done = Set(files.map(\.id))
                // #1（二轮）：filter 保留快照外新勾选项（卸载期间用户勾选的新文件不被误移）
                self.related = self.related.map { f in
                    guard f.isSelected, done.contains(f.id) else { return f }
                    if failed.contains(f.path) {
                        var copy = f
                        copy.isSelected = false
                        return copy
                    }
                    return f
                }.filter { !$0.isSelected || !done.contains($0.id) }
                self.isUninstalling = false
                // 刚卸载掉的 App 必须立刻从"已安装清单"里消失。
                // `AppInventory` 有 60 s TTL，不主动失效的话：卸载后马上转去查孤儿残留，
                // 它的 Caches/Containers/偏好仍被判"宿主还在"，一个都列不出来。
                if result.succeeded > 0 { AppInventory.invalidate() }
                var parts = ["已卸载 \(result.succeeded) 项，释放 \(result.releasedBytes.byteStringCN)"]
                if !result.failures.isEmpty { parts.append("\(result.failures.count) 项失败") }
                self.lastSummary = parts.joined(separator: "，")
            }
        }
        return true
    }

    // MARK: - 孤儿残留排查逻辑

    func loadOrphans() {
        isScanningOrphans = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let orphans = OrphanScanner.scan()
            DispatchQueue.main.async {
                self?.orphanApps = orphans
                self?.isScanningOrphans = false
                if self?.selectedOrphanApp == nil || !orphans.contains(where: { $0.id == self?.selectedOrphanApp?.id }) {
                    self?.selectedOrphanApp = orphans.first
                }
            }
        }
    }

    func selectOrphanApp(_ app: OrphanApp?) {
        selectedOrphanApp = app
    }

    func toggleOrphanItem(appID: UUID, itemID: UUID, on: Bool) {
        guard let appIdx = orphanApps.firstIndex(where: { $0.id == appID }) else { return }
        var apps = orphanApps
        if let itemIdx = apps[appIdx].items.firstIndex(where: { $0.id == itemID }) {
            apps[appIdx].items[itemIdx].isSelected = on
            apps[appIdx].isSelected = apps[appIdx].items.allSatisfy(\.isSelected)
        }
        orphanApps = apps
        if selectedOrphanApp?.id == appID {
            selectedOrphanApp = apps[appIdx]
        }
    }

    func toggleOrphanApp(appID: UUID, on: Bool) {
        guard let appIdx = orphanApps.firstIndex(where: { $0.id == appID }) else { return }
        var apps = orphanApps
        apps[appIdx].isSelected = on
        apps[appIdx].items = apps[appIdx].items.map { var i = $0; i.isSelected = on; return i }
        orphanApps = apps
        if selectedOrphanApp?.id == appID {
            selectedOrphanApp = apps[appIdx]
        }
    }

    func setAllOrphansSelected(_ on: Bool) {
        orphanApps = orphanApps.map { var a = $0; a.isSelected = on; a.items = a.items.map { var i = $0; i.isSelected = on; return i }; return a }
        if let sel = selectedOrphanApp, let updated = orphanApps.first(where: { $0.id == sel.id }) {
            selectedOrphanApp = updated
        }
    }

    var selectedOrphanItems: [OrphanItem] {
        orphanApps.flatMap { $0.items.filter(\.isSelected) }
    }

    var selectedOrphanSize: Int64 {
        selectedOrphanItems.reduce(0) { $0 + $1.size }
    }

    var selectedOrphanCount: Int {
        selectedOrphanItems.count
    }

    var allOrphansSelected: Bool {
        !orphanApps.isEmpty && orphanApps.allSatisfy { $0.allSelected }
    }

    /// 清理选中的孤儿残留（默认移入废纸篓）
    func cleanSelectedOrphans(permanently: Bool) -> Bool {
        let itemsToClean = selectedOrphanItems
        guard !itemsToClean.isEmpty, !isCleaningOrphans else { return false }
        isCleaningOrphans = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OrphanScanner.clean(items: itemsToClean, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self else { return }
                let doneIDs = Set(itemsToClean.map(\.id))
                let failedPaths = result.failedPaths

                var updatedApps: [OrphanApp] = []
                for var app in self.orphanApps {
                    app.items.removeAll { item in
                        doneIDs.contains(item.id) && !failedPaths.contains(item.path)
                    }
                    if !app.items.isEmpty {
                        app.isSelected = app.items.allSatisfy(\.isSelected)
                        updatedApps.append(app)
                    }
                }
                self.orphanApps = updatedApps
                if let current = self.selectedOrphanApp {
                    self.selectedOrphanApp = updatedApps.first(where: { $0.id == current.id }) ?? updatedApps.first
                } else {
                    self.selectedOrphanApp = updatedApps.first
                }
                self.isCleaningOrphans = false
                var parts = ["已清理 \(result.succeeded) 项孤儿残留，释放 \(result.releasedBytes.byteStringCN)"]
                if !result.failures.isEmpty { parts.append("\(result.failures.count) 项失败") }
                self.lastOrphanSummary = parts.joined(separator: "，")
            }
        }
        return true
    }

    // MARK: - 偏好碎片反查逻辑 (v1.53.0)

    func loadPreferences() {
        isScanningPreferences = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = PreferenceResidueInspector.shared.scanOrphanPreferences()
            DispatchQueue.main.async {
                self?.preferenceItems = items
                self?.isScanningPreferences = false
            }
        }
    }

    func togglePreferenceItem(id: UUID, on: Bool) {
        if let idx = preferenceItems.firstIndex(where: { $0.id == id }) {
            preferenceItems[idx].isSelected = on
        }
    }

    func setAllPreferencesSelected(_ on: Bool) {
        preferenceItems = preferenceItems.map {
            var item = $0
            item.isSelected = on
            return item
        }
    }

    var selectedPreferencesCount: Int {
        preferenceItems.filter(\.isSelected).count
    }

    var selectedPreferencesSize: Int64 {
        preferenceItems.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var allPreferencesSelected: Bool {
        !preferenceItems.isEmpty && preferenceItems.allSatisfy(\.isSelected)
    }

    func cleanSelectedPreferences(toTrash: Bool = true) -> Bool {
        let targets = preferenceItems.filter(\.isSelected)
        guard !targets.isEmpty, !isCleaningPreferences else { return false }
        isCleaningPreferences = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = PreferenceResidueInspector.shared.cleanPreferences(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaningPreferences = false
                let action = toTrash ? "移入废纸篓" : "彻底清除"
                self.lastPreferenceSummary = "已安全\(action) \(res.successCount) 个已卸载偏好碎片，释放 \(res.freedBytes.byteStringCN)"
                self.loadPreferences()
            }
        }
        return true
    }

    // MARK: - 插件与扩展治理操作逻辑 (v1.55.0)

    func loadPlugins() {
        isScanningPlugins = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = PluginExtensionInspector.shared.scan()
            DispatchQueue.main.async {
                self?.pluginItems = items
                self?.isScanningPlugins = false
            }
        }
    }

    func togglePluginItem(id: UUID, on: Bool) {
        guard let idx = pluginItems.firstIndex(where: { $0.id == id }) else { return }
        var list = pluginItems
        list[idx].isSelected = on
        pluginItems = list
    }

    func setAllPluginsSelected(_ on: Bool, safeOnly: Bool = true) {
        pluginItems = pluginItems.map { item in
            var copy = item
            if safeOnly {
                if item.isSafeToClean {
                    copy.isSelected = on
                } else {
                    copy.isSelected = false
                }
            } else {
                if item.status != .system {
                    copy.isSelected = on
                }
            }
            return copy
        }
    }

    var selectedPluginItems: [PluginExtensionItem] {
        pluginItems.filter { $0.isSelected }
    }

    var selectedPluginCount: Int {
        selectedPluginItems.count
    }

    var selectedPluginSize: Int64 {
        selectedPluginItems.reduce(0) { $0 + $1.size }
    }

    var allPluginsSelected: Bool {
        let safeItems = pluginItems.filter { $0.isSafeToClean }
        return !safeItems.isEmpty && safeItems.allSatisfy { $0.isSelected }
    }

    func cleanSelectedPlugins(permanently: Bool) -> Bool {
        let items = selectedPluginItems
        guard !items.isEmpty, !isCleaningPlugins else { return false }
        isCleaningPlugins = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let res = PluginExtensionInspector.shared.clean(items: items, permanently: permanently)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCleaningPlugins = false
                let action = permanently ? "彻底删除" : "移入废纸篓"
                var summary = "已安全\(action) \(res.succeeded) 项扩展残留，释放 \(res.releasedBytes.byteStringCN)"
                if res.hadQuickLook {
                    summary += "（已自动刷新 QuickLook 缓存）"
                }
                self.lastPluginSummary = summary
                self.loadPlugins()
            }
        }
        return true
    }
}

// MARK: - 卸载器扫描（借鉴 PureMac 匹配思路的深度实现）

enum UninstallerScanner {

    /// 扫描已安装 App（排除系统 App；含 /Applications、~/Applications）
    static func scanApps() -> [InstalledApp] {
        var paths: [String] = []
        for dir in ["/Applications", "~/Applications"] {
            paths += FileSystem.children(of: CleanPaths.expand(dir)).filter { $0.hasSuffix(".app") }
        }

        // 每个 `.app` 的体积都是一次全量递归。原先串行算，本机 28 个第三方 App 实测
        // **2013 ms**——打开卸载器就卡在那里。各 App 之间互不依赖，改成并行；
        // `FileSystem` 的测量缓存本身是加锁的，可以并发调用。
        var results = [InstalledApp?](repeating: nil, count: paths.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
            let child = paths[i]
            let name = (child as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            let plist = (child as NSString).appendingPathComponent("Contents/Info.plist")
            let bundleID = (NSDictionary(contentsOfFile: plist)?["CFBundleIdentifier"] as? String)
            let app = InstalledApp(name: name, path: child, bundleID: bundleID,
                                   size: FileSystem.size(at: child))
            guard !app.isSystemApp else { return }
            lock.lock()
            results[i] = app
            lock.unlock()
        }
        return results.compactMap { $0 }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// 查找某 App 的全部关联文件（全维度 12 级深度匹配：Bundle ID + App 名称 + 厂商子目录 + 隐蔽系统存储）
    static func relatedFiles(for app: InstalledApp, home: String = NSHomeDirectory()) -> [RelatedFile] {
        let bundle = app.bundleID
        let normName = normalize(app.name)
        var results: [RelatedFile] = []
        var seen = Set<String>()

        func add(_ path: String, kind: String, fileKind: RelatedFileKind? = nil) {
            let expanded = CleanPaths.expand(path)
            guard FileManager.default.fileExists(atPath: expanded),
                  FileSystem.isSafeToClean(expanded),
                  !seen.contains(expanded) else { return }
            seen.insert(expanded)
            let size = FileSystem.size(at: expanded)
            if size > 0 {
                results.append(RelatedFile(
                    name: (expanded as NSString).lastPathComponent,
                    path: expanded,
                    size: size,
                    kind: kind,
                    fileKind: fileKind
                ))
            }
        }

        // 1) Preferences & ByHost：偏好设置与硬件主机级偏好
        if let bundle {
            // 标准 Preferences
            for child in FileSystem.children(of: "\(home)/Library/Preferences", keepHidden: false)
            where child.hasSuffix(".plist") {
                let file = (child as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
                if file == bundle || file.hasPrefix(bundle + ".") {
                    add(child, kind: "Preferences", fileKind: .preferences)
                }
            }
            // ByHost 机器硬件级偏好设置 (~/Library/Preferences/ByHost/<bundleID>.<UUID>.plist)
            for child in FileSystem.children(of: "\(home)/Library/Preferences/ByHost", keepHidden: false)
            where child.hasSuffix(".plist") {
                let file = (child as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
                if file.contains(bundle) {
                    add(child, kind: "Preferences", fileKind: .preferences)
                }
            }
        }
        // App 专属名称的 plist（某些轻量或非反向域名 App 直接以 AppName.plist 存储）
        for child in FileSystem.children(of: "\(home)/Library/Preferences", keepHidden: false)
        where child.hasSuffix(".plist") {
            let file = (child as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
            if normalize(file) == normName && normName.count >= 3 {
                add(child, kind: "Preferences", fileKind: .preferences)
            }
        }

        // 2) WebKit 独立本地存储、Cookie 与 LocalStorage
        if let bundle {
            for child in [
                "\(home)/Library/WebKit/\(bundle)",
                "\(home)/Library/Cookies/\(bundle).binarycookies",
                "\(home)/Library/Cookies/\(bundle)",
            ] {
                add(child, kind: "WebKit 与 Cookie", fileKind: .webKitAndCookies)
            }
            for child in FileSystem.children(of: "\(home)/Library/Safari/LocalStorage", keepHidden: false) {
                let name = (child as NSString).lastPathComponent
                if name.contains(bundle) {
                    add(child, kind: "WebKit 与 Cookie", fileKind: .webKitAndCookies)
                }
            }
        }
        if normName.count >= 3 {
            add("\(home)/Library/WebKit/\(app.name)", kind: "WebKit 与 Cookie", fileKind: .webKitAndCookies)
        }

        // 3) CrashReporter 与 DiagnosticReports（崩溃诊断与转储报告）
        let diagReportsDir = "\(home)/Library/Logs/DiagnosticReports"
        for child in FileSystem.children(of: diagReportsDir, keepHidden: false) {
            let name = (child as NSString).lastPathComponent
            let lowerName = name.lowercased()
            let matchesApp = normName.count >= 3 && (lowerName.hasPrefix(normName + "_") || lowerName.hasPrefix(normName + "."))
            let matchesBundle = bundle != nil && (lowerName.hasPrefix(bundle!.lowercased() + "_") || lowerName.hasPrefix(bundle!.lowercased() + "."))
            if matchesApp || matchesBundle {
                add(child, kind: "崩溃诊断报告", fileKind: .crashReports)
            }
        }
        if normName.count >= 3 {
            add("\(home)/Library/Logs/CrashReporter/\(app.name)", kind: "崩溃诊断报告", fileKind: .crashReports)
        }
        if let bundle {
            add("\(home)/Library/Logs/CrashReporter/\(bundle)", kind: "崩溃诊断报告", fileKind: .crashReports)
        }

        // 4) Caches / Containers / HTTPStorages / Saved State / Application Scripts：bundle id 强匹配
        if let bundle {
            for (root, kind, fKind) in [
                ("\(home)/Library/Caches", "Caches", RelatedFileKind.caches),
                ("\(home)/Library/Containers", "Containers", RelatedFileKind.containers),
                ("\(home)/Library/HTTPStorages", "HTTPStorages", RelatedFileKind.httpStorages),
                ("\(home)/Library/Saved Application State", "Saved State", RelatedFileKind.savedState),
                ("\(home)/Library/Application Scripts", "Application Scripts", RelatedFileKind.appScripts),
            ] {
                for child in FileSystem.children(of: root) {
                    let name = (child as NSString).lastPathComponent
                    if name == bundle || name.hasPrefix(bundle + ".") || name == "\(bundle).savedState" {
                        add(child, kind: kind, fileKind: fKind)
                    }
                }
            }
        }

        // 5) Autosave Information（自动保存文档与恢复数据）
        let autosaveDir = "\(home)/Library/Autosave Information"
        for child in FileSystem.children(of: autosaveDir, keepHidden: false) {
            let name = (child as NSString).lastPathComponent
            let matchesApp = normName.count >= 3 && normalize(name).contains(normName)
            let matchesBundle = bundle != nil && name.contains(bundle!)
            if matchesApp || matchesBundle {
                add(child, kind: "Saved State", fileKind: .savedState)
            }
        }

        // 6) Application Support / Logs / Group Containers：名称匹配与多级厂商子目录匹配
        for (root, kind, fKind) in [
            ("\(home)/Library/Application Support", "Application Support", RelatedFileKind.appSupport),
            ("\(home)/Library/Logs", "Logs", RelatedFileKind.crashReports),
            ("\(home)/Library/Group Containers", "Group Containers", RelatedFileKind.groupContainers),
        ] {
            for child in FileSystem.children(of: root) {
                let dirName = (child as NSString).lastPathComponent
                if dirName.hasPrefix(".") { continue }
                // iCloud 系统组容器（Notes/Calendar 等）不与任何第三方 App 卸载关联
                if kind == "Group Containers", dirName.hasPrefix("group.com.apple.") { continue }
                let norm = normalize(dirName)
                guard norm.count >= 3 else { continue }

                // 核心：app 名 == 目录名；或目录名包含完整 app 名（含分隔符边界）
                if norm == normName || (norm.count > normName.count && norm.contains(normName)) {
                    add(child, kind: kind, fileKind: fKind)
                } else if let bundle, (dirName == bundle || dirName.hasPrefix(bundle + ".")) {
                    add(child, kind: kind, fileKind: fKind)
                }

                // 针对 Application Support 中的厂商子目录（如 Google/Chrome、Microsoft/Teams、Adobe/After Effects）
                // 仅扫描子目录，严禁把母厂商目录作为整体添加（严格遵循 N5 规则）
                if kind == "Application Support" && norm != normName {
                    for subChild in FileSystem.children(of: child) {
                        let subDirName = (subChild as NSString).lastPathComponent
                        let subNorm = normalize(subDirName)
                        guard subNorm.count >= 3 else { continue }
                        let matchesNorm = subNorm == normName || (subNorm.count > normName.count && subNorm.contains(normName))
                        let matchesVendorCombo = (norm + subNorm == normName) || (normName.hasPrefix(norm) && normName.hasSuffix(subNorm))
                        var matchesBundle = false
                        if let bundle {
                            let lowerBundle = bundle.lowercased()
                            matchesBundle = subDirName == bundle ||
                                            subDirName.hasPrefix(bundle + ".") ||
                                            lowerBundle.hasSuffix("." + subNorm) ||
                                            lowerBundle.hasSuffix("." + subDirName.lowercased())
                        }
                        if matchesNorm || matchesVendorCombo || matchesBundle {
                            add(subChild, kind: kind, fileKind: fKind)
                        }
                    }
                }
            }
        }

        // 7) LaunchAgents：ProgramArguments 指向该 App 或文件名直配
        for child in FileSystem.children(of: "\(home)/Library/LaunchAgents", keepHidden: false)
        where child.hasSuffix(".plist") {
            let fileName = (child as NSString).lastPathComponent
            var matched = false

            // a. 文件名包含 Bundle ID
            if let bundle, (fileName == "\(bundle).plist" || fileName.hasPrefix("\(bundle).")) {
                matched = true
            }
            // b. 文件名包含 App 规范名
            if !matched && normName.count >= 4 && normalize(fileName).contains(normName) {
                matched = true
            }
            // c. 内容 ProgramArguments 指向该 App 路径
            if !matched, let dict = NSDictionary(contentsOfFile: child),
               let args = dict["ProgramArguments"] as? [String],
               args.contains(where: { $0 == app.path || $0.hasPrefix(app.path + "/") }) {
                matched = true
            }

            if matched {
                add(child, kind: "LaunchAgents", fileKind: .launchAgents)
            }
        }

        return results.sorted { $0.size > $1.size }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }
}
