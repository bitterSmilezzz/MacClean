import Foundation
import SwiftUI
import AppKit

// MARK: - 插件与系统扩展类型

enum PluginExtensionKind: String, Codable, CaseIterable, Identifiable {
    case quickLook = "QuickLook 快速查看"
    case spotlight = "Spotlight 导入器"
    case services = "服务菜单扩展"
    case contextualMenu = "上下文菜单插件"
    case internetPlugin = "网页浏览器插件"
    case screenSaver = "屏幕保护程序"
    case inputMethod = "输入法扩展"
    case colorPicker = "调色板组件"
    case other = "其他系统扩展"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .quickLook: return "QuickLook"
        case .spotlight: return "Spotlight"
        case .services: return "服务菜单"
        case .contextualMenu: return "右键菜单"
        case .internetPlugin: return "网页插件"
        case .screenSaver: return "屏保"
        case .inputMethod: return "输入法"
        case .colorPicker: return "调色板"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .quickLook: return "eye.circle"
        case .spotlight: return "magnifyingglass.circle"
        case .services: return "gearshape.2"
        case .contextualMenu: return "contextualmenu.and.cursor"
        case .internetPlugin: return "safari"
        case .screenSaver: return "display"
        case .inputMethod: return "keyboard"
        case .colorPicker: return "paintpalette"
        case .other: return "puzzlepiece.extension"
        }
    }
}

// MARK: - 插件健康状态

enum PluginExtensionStatus: String, Codable, CaseIterable, Identifiable {
    case orphan = "宿主已卸载"
    case broken = "扩展已损坏"
    case installed = "宿主正常在用"
    case system = "系统官方组件"
    /// 证据不足：归属应用清单读不到、无 bundle id、或目标可能是用户自己的创作物。
    /// 「读不到」≠「可以删」——本状态**永不**给出可删判据。
    case needsReview = "需确认（证据不足）"

    var id: String { rawValue }

    var badgeColor: Color {
        switch self {
        case .orphan: return .red
        case .broken: return .orange
        case .installed: return .secondary
        case .system: return .blue
        case .needsReview: return .gray
        }
    }

    var icon: String {
        switch self {
        case .orphan: return "xmark.bin"
        case .broken: return "exclamationmark.triangle"
        case .installed: return "checkmark.shield"
        case .system: return "apple.logo"
        case .needsReview: return "questionmark.shield"
        }
    }

    /// 该状态是否构成删除的正向判据。用户创作物由 `PluginExtensionItem` 再拦一层。
    var providesDeletionVerdict: Bool { self == .orphan || self == .broken }
}

// MARK: - 插件与系统扩展模型

struct PluginExtensionItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let bundleID: String?
    let version: String?
    let kind: PluginExtensionKind
    let status: PluginExtensionStatus
    let hostAppName: String?
    let isUserDomain: Bool
    var isSelected: Bool
    /// 用户自己的创作物（Automator 服务 / 用户 Services 下的 workflow 等）。
    /// 它的宿主是 macOS 本身，**永不**判孤儿、**永不**判可删（v1.73.0 判据修复）。
    let isUserAuthoredContent: Bool
    /// 研判依据，UI 如实展示
    let note: String?

    /// 本模块的**可删判据**（不是"已受保护"的意思）。
    ///
    /// 旧名叫 `isSafeToClean`，与 `FileSystem.isSafeToClean` 同名异义：它只是
    /// `status == .orphan || .broken` 的一句结论，既没查软链跳板、也没查治理域与
    /// 真实删除权限，却让用户误以为"能勾就代表已被保护网验过"。现在改名，
    /// 并且真正的放行判定只发生在 `ResidueDeletionGate` 里。
    var isDeletableVerdict: Bool {
        !isUserAuthoredContent && status.providesDeletionVerdict
    }

    @available(*, deprecated, renamed: "isDeletableVerdict")
    var isSafeToClean: Bool { isDeletableVerdict }

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        size: Int64,
        bundleID: String?,
        version: String?,
        kind: PluginExtensionKind,
        status: PluginExtensionStatus,
        hostAppName: String?,
        isUserDomain: Bool,
        isSelected: Bool = false,
        isUserAuthoredContent: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.bundleID = bundleID
        self.version = version
        self.kind = kind
        self.status = status
        self.hostAppName = hostAppName
        self.isUserDomain = isUserDomain
        self.isSelected = isSelected
        self.isUserAuthoredContent = isUserAuthoredContent
        self.note = note
    }
}

// MARK: - 插件与扩展治理检测引擎
//
// v1.73.0 三处修复：
// ① `isSafeToClean` 这个属性名与 `FileSystem.isSafeToClean` 同名异义——它只是
//    `status == .orphan || .broken` 的一句结论，既没查软链跳板也没查治理域，
//    却给用户"能勾就代表已被保护"的错觉。改名 `isDeletableVerdict`，
//    真正的放行判定只发生在 `ResidueDeletionGate` 里。
// ② `~/Library/Services/*.workflow`（Automator 服务）的 `CFBundleExecutable` 常为空、
//    bundle id 也非 `com.apple.`，旧逻辑匹配不上宿主就判 `.orphan`，然后**无任何路径
//    校验**地把它删掉。现在用户创作物一律不判孤儿：只有"归属应用清单命中"这个正向
//    证据才算在用，否则降级 `.needsReview`。
// ③ 判孤儿前必须确认已安装应用清单可信（`AppInventory.isComplete`）；
//    全局 `/Library/*` 扩展根逐个声明治理域，删除全部走网关。

final class PluginExtensionInspector {
    static let shared = PluginExtensionInspector()

    /// `qlmanage` 路径可覆盖：自检据此断言命令与参数，且不会真的刷系统 QuickLook 缓存。
    static var qlmanagePath = "/usr/bin/qlmanage"

    private init() {}

    // MARK: - 扫描目录定义

    struct TargetDirectory {
        let path: String
        let kind: PluginExtensionKind
        let isUserDomain: Bool
        /// 全局位置声明的授权根（治理域）。主目录内的传 nil，由主目录护栏裁决。
        let domain: GovernanceDomain?
        /// 该根之下的内容视为**用户创作物**（如 Automator 服务），永不判孤儿
        let isUserAuthoredRoot: Bool

        init(path: String, kind: PluginExtensionKind, isUserDomain: Bool,
             domain: GovernanceDomain? = nil, isUserAuthoredRoot: Bool = false) {
            self.path = path
            self.kind = kind
            self.isUserDomain = isUserDomain
            self.domain = domain
            self.isUserAuthoredRoot = isUserAuthoredRoot
        }
    }

    /// 获取默认系统与用户级扫描目录
    static func defaultDirectories() -> [TargetDirectory] {
        var dirs: [TargetDirectory] = []

        // 用户层目录 (~/Library/...)
        let userLib = ("~/Library" as NSString).expandingTildeInPath
        dirs.append(TargetDirectory(path: "\(userLib)/QuickLook", kind: .quickLook, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Spotlight", kind: .spotlight, isUserDomain: true))
        // 用户 Services：Automator/快捷操作创作物，宿主是系统本身
        dirs.append(TargetDirectory(path: "\(userLib)/Services", kind: .services,
                                    isUserDomain: true, isUserAuthoredRoot: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Contextual Menu Items", kind: .contextualMenu, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Internet Plug-Ins", kind: .internetPlugin, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Screen Savers", kind: .screenSaver, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Input Methods", kind: .inputMethod, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/ColorPickers", kind: .colorPicker, isUserDomain: true))

        // 全局系统目录 (/Library/...)：逐个声明治理域，未登记的位置网关一律拒绝
        dirs.append(TargetDirectory(path: "/Library/QuickLook", kind: .quickLook,
                                    isUserDomain: false, domain: .quickLookGlobal))
        dirs.append(TargetDirectory(path: "/Library/Spotlight", kind: .spotlight,
                                    isUserDomain: false, domain: .spotlightImportersGlobal))
        dirs.append(TargetDirectory(path: "/Library/Contextual Menu Items", kind: .contextualMenu,
                                    isUserDomain: false, domain: .contextualMenuGlobal))
        dirs.append(TargetDirectory(path: "/Library/Internet Plug-Ins", kind: .internetPlugin,
                                    isUserDomain: false, domain: .internetPlugInsGlobal))
        dirs.append(TargetDirectory(path: "/Library/Screen Savers", kind: .screenSaver,
                                    isUserDomain: false, domain: .screenSaversGlobal))
        dirs.append(TargetDirectory(path: "/Library/Input Methods", kind: .inputMethod,
                                    isUserDomain: false, domain: .inputMethodsGlobal))
        dirs.append(TargetDirectory(path: "/Library/ColorPickers", kind: .colorPicker,
                                    isUserDomain: false, domain: .colorPickersGlobal))

        return dirs
    }

    /// 全局扩展根 → 已登记治理域；主目录内的返回 nil（走主目录护栏）。
    /// 既不在主目录、也不在任何登记域下的位置同样返回 nil，由基础护栏拦下。
    static func governanceDomain(forPath path: String) -> GovernanceDomain? {
        GovernanceDomain.domain(forPath: path)
    }

    /// 用户创作物判定：用户域 Services 根之下，或任意 `.workflow`（Automator 导出物）。
    static func isUserAuthoredContent(path: String, kind: PluginExtensionKind,
                                      isUserDomain: Bool, inUserAuthoredRoot: Bool = false) -> Bool {
        let normalized = FileSystem.normalizePath(path)
        let ext = (normalized as NSString).pathExtension.lowercased()
        if ext == "workflow" || ext == "shortcut" { return true }
        guard isUserDomain else { return false }
        if inUserAuthoredRoot { return true }
        let userServices = FileSystem.normalizePath(
            ("~/Library/Services" as NSString).expandingTildeInPath)
        return kind == .services && normalized.hasPrefix(userServices + "/")
    }

    // MARK: - 扫描与解析主流程

    /// 全量扫描扩展项。
    ///
    /// - Parameter installedApps: 显式宿主清单（卸载器等调用方复用）。nil 时**只**信
    ///   `AppInventory`，并在清单不完整时放弃产出孤儿结论。
    func scan(
        directories: [TargetDirectory] = defaultDirectories(),
        installedApps: [InstalledApp]? = nil
    ) -> [PluginExtensionItem] {
        let fm = FileManager.default
        let apps = installedApps ?? []
        let inventory = AppInventory.current()
        var items: [PluginExtensionItem] = []

        for target in directories {
            guard fm.fileExists(atPath: target.path) else { continue }
            // 读不到目录内容 → 这一根下什么都不列（而不是"里面的东西都能删"）
            guard let contents = try? fm.contentsOfDirectory(atPath: target.path) else { continue }

            for filename in contents.sorted() {
                if filename.hasPrefix(".") { continue }

                let fullPath = (target.path as NSString).appendingPathComponent(filename)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }
                // 软链不列：删它不释放空间，且它是跳出授权位置的经典入口
                if FileSystem.isSymlink(fullPath) { continue }

                let itemSize: Int64 = FileSystem.size(at: fullPath)
                let parsed = parseBundleMetadata(path: fullPath, defaultName: filename, kind: target.kind)

                let (status, hostApp, note) = evaluateStatus(
                    bundleID: parsed.bundleID,
                    appName: parsed.name,
                    executableExists: parsed.executableExists,
                    hasInfoPlist: parsed.hasInfoPlist,
                    fullPath: fullPath,
                    kind: target.kind,
                    isUserDomain: target.isUserDomain,
                    inUserAuthoredRoot: target.isUserAuthoredRoot,
                    installedApps: apps,
                    inventory: inventory)

                items.append(PluginExtensionItem(
                    name: parsed.name,
                    path: fullPath,
                    size: itemSize,
                    bundleID: parsed.bundleID,
                    version: parsed.version,
                    kind: target.kind,
                    status: status,
                    hostAppName: hostApp,
                    isUserDomain: target.isUserDomain,
                    isSelected: false,
                    isUserAuthoredContent: Self.isUserAuthoredContent(
                        path: fullPath, kind: target.kind, isUserDomain: target.isUserDomain,
                        inUserAuthoredRoot: target.isUserAuthoredRoot),
                    note: note))
            }
        }

        // 排序：可删判据优先，其次按体积降序
        return items.sorted { a, b in
            if a.isDeletableVerdict != b.isDeletableVerdict {
                return a.isDeletableVerdict && !b.isDeletableVerdict
            }
            return a.size > b.size
        }
    }

    // MARK: - Bundle 元数据解析

    struct ParsedMetadata {
        let name: String
        let bundleID: String?
        let version: String?
        let executableExists: Bool
        /// Info.plist 是否真的读到了。读不到时 `executableExists` 只是占位真值，
        /// **不能**据此判损坏。
        let hasInfoPlist: Bool
    }

    func parseBundleMetadata(path: String, defaultName: String, kind: PluginExtensionKind) -> ParsedMetadata {
        let fm = FileManager.default
        var plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        if !fm.fileExists(atPath: plistPath) {
            let altPlist = (path as NSString).appendingPathComponent("Info.plist")
            if fm.fileExists(atPath: altPlist) {
                plistPath = altPlist
            }
        }

        guard fm.fileExists(atPath: plistPath),
              let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            // 非标准 Bundle 或无 Info.plist：证据缺失，而不是"没有宿主"
            let cleanName = stripExtension(from: defaultName)
            return ParsedMetadata(name: cleanName, bundleID: nil, version: nil,
                                  executableExists: true, hasInfoPlist: false)
        }

        let bundleID = dict["CFBundleIdentifier"] as? String
        let displayName = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? stripExtension(from: defaultName)

        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)

        var execExists = true
        if let execName = dict["CFBundleExecutable"] as? String, !execName.isEmpty {
            let execPath1 = (path as NSString).appendingPathComponent("Contents/MacOS/\(execName)")
            let execPath2 = (path as NSString).appendingPathComponent(execName)
            if !fm.fileExists(atPath: execPath1) && !fm.fileExists(atPath: execPath2) {
                execExists = false
            }
        }

        return ParsedMetadata(
            name: displayName,
            bundleID: bundleID,
            version: version,
            executableExists: execExists,
            hasInfoPlist: true)
    }

    // MARK: - 状态研判

    func evaluateStatus(
        bundleID: String?,
        appName: String,
        executableExists: Bool,
        hasInfoPlist: Bool = true,
        fullPath: String,
        kind: PluginExtensionKind = .other,
        isUserDomain: Bool = false,
        inUserAuthoredRoot: Bool = false,
        installedApps: [InstalledApp],
        inventory: AppInventory.Snapshot = AppInventory.current()
    ) -> (status: PluginExtensionStatus, host: String?, note: String?) {
        // 1. Apple 官方系统组件：最先判，且不受"二进制丢失"影响
        if let bundleID, bundleID.lowercased().hasPrefix("com.apple.") {
            return (.system, "macOS 系统内置", "bundle id 属 com.apple.*")
        }
        let real = FileSystem.normalizePath(FileSystem.realPath(fullPath))
        if FileSystem.isSystemProtected(real) {
            return (.system, "macOS 系统内置", "位于 G8 系统硬保护位置")
        }

        // 2. 用户创作物：宿主是系统本身，只有清单命中才算在用，否则"需确认"
        let userAuthored = Self.isUserAuthoredContent(
            path: fullPath, kind: kind, isUserDomain: isUserDomain,
            inUserAuthoredRoot: inUserAuthoredRoot)
        if userAuthored {
            if let host = matchHost(bundleID: bundleID, appName: appName, fullPath: fullPath,
                                    installedApps: installedApps, inventory: inventory) {
                return (.installed, host, "用户创作物，且归属应用清单命中")
            }
            return (.needsReview, nil,
                    "你在 Automator/快捷指令里创建的扩展，宿主是 macOS 本身；"
                    + "无归属应用命中不能判孤儿——已按「读不到 ≠ 可以删」保留")
        }

        // 3. 二进制丢失：只有在真的读到 Info.plist 的前提下才算"损坏"
        if !executableExists {
            guard hasInfoPlist else {
                return (.needsReview, nil, "读不到 Info.plist，无法判定是否损坏")
            }
            return (.broken, nil, "CFBundleExecutable 指向的二进制不存在或已是死链")
        }
        guard hasInfoPlist else {
            return (.needsReview, nil, "非标准 Bundle 且无 Info.plist，无法确认归属")
        }

        // 4. 正向证据：命中已安装应用即算在用
        if let host = matchHost(bundleID: bundleID, appName: appName, fullPath: fullPath,
                                installedApps: installedApps, inventory: inventory) {
            return (.installed, host, nil)
        }

        // 5. 没有任何命中：清单不可信时**绝不**判孤儿
        if installedApps.isEmpty && !inventory.isComplete {
            return (.needsReview, nil,
                    "已安装应用清单不完整（\(inventory.unreadableRoots.joined(separator: "、"))"
                    + " 读不到），不能据「不在清单里」判孤儿")
        }
        guard let bundleID, !bundleID.isEmpty else {
            return (.needsReview, nil, "扩展没有 bundle id 与归属特征，无法确认宿主")
        }
        let derivedHost = PreferenceResidueInspector.deriveDisplayName(from: bundleID)
        return (.orphan, derivedHost, "宿主应用未在已安装清单中")
    }

    /// 归属应用正向匹配：显式清单 + `AppInventory` 双路。命中返回宿主名，未命中返回 nil。
    private func matchHost(bundleID: String?, appName: String, fullPath: String,
                           installedApps: [InstalledApp],
                           inventory: AppInventory.Snapshot) -> String? {
        if let bundleID, !bundleID.isEmpty {
            let lowerBundle = bundleID.lowercased()
            for app in installedApps {
                guard let appBundle = app.bundleID?.lowercased(), !appBundle.isEmpty else { continue }
                if lowerBundle == appBundle || lowerBundle.hasPrefix(appBundle + ".")
                    || appBundle.hasPrefix(lowerBundle + ".") {
                    return app.name
                }
            }
            let stem = stemOfBundle(lowerBundle)
            for app in installedApps {
                let appNameNorm = normalizeName(app.name)
                if !stem.isEmpty && (appNameNorm.contains(stem) || stem.contains(appNameNorm)) {
                    return app.name
                }
            }
            if inventory.contains(bundleID: lowerBundle) { return "已安装应用（清单命中）" }
        }

        let itemBase = normalizeName(stripExtension(from: (fullPath as NSString).lastPathComponent))
        for app in installedApps {
            let appNameNorm = normalizeName(app.name)
            if !itemBase.isEmpty && (appNameNorm == itemBase || appNameNorm.hasPrefix(itemBase)
                                        || itemBase.hasPrefix(appNameNorm)) {
                return app.name
            }
        }
        if inventory.matchesInstalledName(appName) || inventory.matchesInstalledName(itemBase) {
            return "已安装应用（名称命中）"
        }
        if !itemBase.isEmpty, inventory.executableNames.contains(itemBase) {
            return "已安装应用（可执行名命中）"
        }
        return nil
    }

    // MARK: - 清理与安全执行

    struct CleanResult {
        let succeeded: Int
        let failed: Int
        let releasedBytes: Int64
        /// 清理过 QuickLook 插件**且**缓存刷新成功（旧代码只看"清理过"就宣称已刷新）
        let hadQuickLook: Bool
        let attemptedQuickLookReset: Bool
        let outcome: ResidueDeletionGate.Outcome

        init(succeeded: Int, failed: Int, releasedBytes: Int64, hadQuickLook: Bool,
             attemptedQuickLookReset: Bool = false,
             outcome: ResidueDeletionGate.Outcome = ResidueDeletionGate.Outcome()) {
            self.succeeded = succeeded
            self.failed = failed
            self.releasedBytes = releasedBytes
            self.hadQuickLook = hadQuickLook
            self.attemptedQuickLookReset = attemptedQuickLookReset
            self.outcome = outcome
        }

        var rejected: [ResidueDeletionGate.Rejection] { outcome.rejected }
        var needsPrivilegeCount: Int { outcome.needsPrivilege.count }
        var summary: String { outcome.summary }
    }

    /// 清理所选扩展：判据只作为**候选来源**，放行与否由统一网关逐项裁决。
    func clean(
        items: [PluginExtensionItem],
        permanently: Bool,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "系统扩展残留治理"),
        onProgress: @escaping (String) -> Void = { _ in }
    ) -> CleanResult {
        guard !items.isEmpty else {
            return CleanResult(succeeded: 0, failed: 0, releasedBytes: 0, hadQuickLook: false)
        }
        var outcome = ResidueDeletionGate.Outcome()
        var candidates: [ResidueDeletionGate.Candidate] = []
        var deletableItems: [PluginExtensionItem] = []

        for item in items {
            onProgress("正在提交 \(item.name)…")
            if let blocked = blockVerdict(for: item) {
                outcome.rejected.append(.make(name: item.name, path: item.path,
                                              reason: blocked.reason, message: blocked.message))
                continue
            }
            candidates.append(.init(item.name, path: item.path,
                                    domain: targetDomain(for: item)))
            deletableItems.append(item)
        }

        // 合并逻辑只在 `Outcome.merge` 里有一份实现
        outcome.merge(ResidueDeletionGate.execute(candidates, toTrash: !permanently, journal: journal))

        // QuickLook 生成器被动过 → 刷新缓存，并**如实**记下是否成功
        let cleanedQLPaths = Set(outcome.cleanedPaths)
        let touchedQuickLook = deletableItems.contains { item in
            item.kind == .quickLook && cleanedQLPaths.contains(FileSystem.normalizePath(FileSystem.realPath(item.path)))
        }
        var resetOK = false
        if touchedQuickLook {
            if SafeProcess.isAvailable(Self.qlmanagePath) {
                resetOK = resetQuickLookCache()
            }
        }

        return CleanResult(
            succeeded: outcome.cleanedCount,
            failed: outcome.errorCount,
            releasedBytes: outcome.freedBytes,
            hadQuickLook: touchedQuickLook && resetOK,
            attemptedQuickLookReset: touchedQuickLook,
            outcome: outcome)
    }

    /// 模块级判据：返回「拒绝原因 + 中文说明」，nil 表示可以进网关。
    ///
    /// 不再一律借 `.systemProtected`：官方组件/用户创作物/证据不足属"不是可清理对象"
    /// （`.notDeletable`），宿主仍在安装清单里属"在用"（`.inUse`）。
    func blockVerdict(for item: PluginExtensionItem) -> (reason: GovernanceVerdict.Reason, message: String)? {
        if item.status == .system { return (.notDeletable, "macOS 官方组件，绝不清理") }
        if item.isUserAuthoredContent {
            return (.notDeletable, "这是你自己创建的扩展（Automator 服务/快捷指令），宿主是系统本身，不清理")
        }
        switch item.status {
        case .orphan, .broken:
            return nil
        case .installed:
            return (.inUse, "宿主应用仍在已安装清单里，不是残留")
        case .system:
            return (.notDeletable, "macOS 官方组件，绝不清理")
        case .needsReview:
            return (.notDeletable, "证据不足（\(item.note ?? "无法确认宿主")），需你手动确认")
        }
    }

    /// 该条目的治理域：扫描根声明优先，其次按路径推断；主目录内的为 nil。
    private func targetDomain(for item: PluginExtensionItem) -> GovernanceDomain? {
        Self.governanceDomain(forPath: item.path)
    }

    /// 重置 QuickLook 守护进程缓存。返回值即"是否真的成功"，UI 不得越过它宣称已刷新。
    @discardableResult
    func resetQuickLookCache() -> Bool {
        let path = Self.qlmanagePath
        guard SafeProcess.isAvailable(path) else { return false }
        let regenerate = SafeProcess.run(path, ["-r"], timeout: 10)?.succeeded == true
        let flushCache = SafeProcess.run(path, ["-r", "cache"], timeout: 10)?.succeeded == true
        return regenerate && flushCache
    }

    // MARK: - 辅助方法

    private func stripExtension(from string: String) -> String {
        return (string as NSString).deletingPathExtension
    }

    private func stemOfBundle(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        if parts.count >= 2 {
            return String(parts[1]).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        }
        return ""
    }

    private func normalizeName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".app", with: "")
    }
}
