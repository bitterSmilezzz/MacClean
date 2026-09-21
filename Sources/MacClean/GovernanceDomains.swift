import Foundation
import Darwin

// MARK: - 治理域与统一删除判定（v1.72.0 安全收敛）
//
// 背景：`FileSystem.isSafeToClean` 的常规放行只覆盖主目录与临时目录
// （`allowedRoots = [home, /tmp, /var/tmp]`）。而 v1.53 起的十余个治理模块扫的是
// `/Library/Fonts`、`/Library/ColorSync/Profiles`、`/Library/Audio/Plug-Ins/HAL`
// 这类**主目录之外**的位置，于是各模块自造了 `path.hasPrefix("/System")` 式字符串护栏。
//
// 那套自造护栏有三个问题：
// ① 字符串护栏可被软链逃逸绕过——`FileSystem.swift` 顶部已用自检证明过一次；
// ② 用户自定义白名单（WhitelistManager）与 G6 硬排除对这些模块**完全失效**；
// ③ 各模块护栏松紧不一，同一份残留在 A 模块判"在用"、在 B 模块判"孤儿"。
//
// 现在改为：凡是要删主目录之外的东西，调用方必须先声明**治理域**，
// 由 `FileSystem.governanceVerdict(_:domain:)` 做唯一判定。
// 每个治理域登记的是"这个模块被授权在哪个精确根下操作"，且**永不授权删根本身**。

/// 一个治理模块被授权操作的精确系统位置。
struct GovernanceDomain: Equatable, Hashable {
    /// 稳定标识，出现在自检断言与文档里
    let id: String
    /// 被授权操作的确切根路径（绝对路径，`~` 已展开）
    let root: String
    /// 目标必须位于 root 之下**至少这么多层**。
    /// 1 = 只允许 root 的直接子项（禁删 root 本身）；
    /// 更大值用于"根目录下一层仍是聚合目录"的位置。
    let minDepthBelowRoot: Int
    /// 一句话说明为什么授权，供 UI 与文档引用
    let note: String
    /// 非 nil 时，root 之下的**第一层目录名**必须在此名单内。
    /// 用于 root 本身混有用户数据的位置（如 `/Volumes` 下既有 `.Spotlight-V100`
    /// 也有用户可见卷内容），把授权精确钉在少数几个条目上。
    let allowedEntryNames: Set<String>?

    init(id: String, root: String, minDepthBelowRoot: Int, note: String,
         allowedEntryNames: Set<String>? = nil) {
        self.id = id
        self.root = root
        self.minDepthBelowRoot = minDepthBelowRoot
        self.note = note
        self.allowedEntryNames = allowedEntryNames
    }

    var normalizedRoot: String { FileSystem.normalizePath(root) }

    /// 该域内目标所需的最小绝对深度（用于错误信息）
    var requiredDepth: Int {
        normalizedRoot.split(separator: "/").count + minDepthBelowRoot
    }

    static func == (lhs: GovernanceDomain, rhs: GovernanceDomain) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension GovernanceDomain {

    // MARK: 全局字体（`/Library/Fonts` 实测 `drwxrwxr-t root:admin`，
    // admin 组可写，故本工具**真的**能删——这是必须走网关的最典型位置）
    static let fontsGlobal = GovernanceDomain(
        id: "fonts.global", root: "/Library/Fonts", minDepthBelowRoot: 1,
        note: "全局字体目录：admin 组可写，仅授权删除单个字体文件")

    // MARK: 打印机驱动与 PPD
    static let printersGlobal = GovernanceDomain(
        id: "printers.global", root: "/Library/Printers", minDepthBelowRoot: 1,
        note: "第三方打印机驱动包：仅授权删除厂商子目录")
    static let ppdResources = GovernanceDomain(
        id: "printers.ppdResources", root: "/Library/Printers/PPDs/Contents/Resources",
        minDepthBelowRoot: 1,
        note: "PPD 描述文件库：仅授权删除单个 PPD 文件或语言子目录，禁删整棵资源树")

    // MARK: 色彩描述文件
    static let colorSyncProfiles = GovernanceDomain(
        id: "colorsync.profiles", root: "/Library/ColorSync/Profiles", minDepthBelowRoot: 1,
        note: "全局 ICC 描述文件：仅授权删除单个 .icc/.icprof")

    // MARK: 音频 HAL / AU 插件
    static let audioHAL = GovernanceDomain(
        id: "audio.hal", root: "/Library/Audio/Plug-Ins/HAL", minDepthBelowRoot: 1,
        note: "CoreAudio 硬件抽象层驱动目录")
    static let audioComponents = GovernanceDomain(
        id: "audio.components", root: "/Library/Audio/Plug-Ins/Components", minDepthBelowRoot: 1,
        note: "Audio Unit 插件目录")

    // MARK: 系统级扩展（v1.55 插件治理）
    static let quickLookGlobal = GovernanceDomain(
        id: "extensions.quickLook", root: "/Library/QuickLook", minDepthBelowRoot: 1,
        note: "全局 QuickLook 生成器")
    static let spotlightImportersGlobal = GovernanceDomain(
        id: "extensions.spotlight", root: "/Library/Spotlight", minDepthBelowRoot: 1,
        note: "全局 Spotlight 元数据导入器")
    static let internetPlugInsGlobal = GovernanceDomain(
        id: "extensions.internetPlugIns", root: "/Library/Internet Plug-Ins", minDepthBelowRoot: 1,
        note: "浏览器网页插件")
    static let contextualMenuGlobal = GovernanceDomain(
        id: "extensions.contextualMenu", root: "/Library/Contextual Menu Items", minDepthBelowRoot: 1,
        note: "右键上下文菜单扩展")
    static let screenSaversGlobal = GovernanceDomain(
        id: "extensions.screenSavers", root: "/Library/Screen Savers", minDepthBelowRoot: 1,
        note: "屏保组件")
    static let inputMethodsGlobal = GovernanceDomain(
        id: "extensions.inputMethods", root: "/Library/Input Methods", minDepthBelowRoot: 1,
        note: "输入法与调色板组件")
    static let colorPickersGlobal = GovernanceDomain(
        id: "extensions.colorPickers", root: "/Library/ColorPickers", minDepthBelowRoot: 1,
        note: "颜色选取器组件")

    // MARK: 自启项（/Library 层由 root 管理，实际删除会因权限被拒；仍登记以便统一裁决）
    static let launchAgentsGlobal = GovernanceDomain(
        id: "launchagents.global", root: "/Library/LaunchAgents", minDepthBelowRoot: 1,
        note: "全局用户自启代理")
    static let launchDaemonsGlobal = GovernanceDomain(
        id: "launchdaemons.global", root: "/Library/LaunchDaemons", minDepthBelowRoot: 1,
        note: "系统守护进程定义：本工具不提权，越权请求一律拒绝")

    // MARK: 诊断报告
    static let diagnosticReportsGlobal = GovernanceDomain(
        id: "diagnostics.globalReports", root: "/Library/Logs/DiagnosticReports",
        minDepthBelowRoot: 1, note: "系统级崩溃与诊断报告")

    // MARK: 全局缓存
    static let systemCachesGlobal = GovernanceDomain(
        id: "caches.global", root: "/Library/Caches", minDepthBelowRoot: 1,
        note: "系统级缓存目录：仅授权删除具体归属子项")

    // MARK: App 包内的可瘦身资源（v1.60 本地化瘦身）
    /// 深度 4 = `<App>.app/Contents/Resources/<xx.lproj>`。
    /// 这样授权只覆盖包内资源，永远删不到 `/Applications/Foo.app` 本身。
    static let appLocalizedResources = GovernanceDomain(
        id: "app.localizedResources", root: "/Applications", minDepthBelowRoot: 4,
        note: "已安装 App 包内的多语言资源：层级过浅一律拒绝，避免连应用本体一起删")

    // MARK: 卷宗上的 Spotlight 索引
    /// `/Volumes` 下混有用户可见卷内容，故用入口名单把授权钉死在 `.Spotlight-V100`。
    static let volumeSpotlightIndex = GovernanceDomain(
        id: "spotlight.volumeIndex", root: "/Volumes", minDepthBelowRoot: 2,
        note: "外接/其他卷宗上的 Spotlight 索引（重建即可恢复）",
        allowedEntryNames: [".Spotlight-V100"])

    /// 全部已登记治理域。新增治理模块必须在此登记，否则网关一律拒绝。
    static let all: [GovernanceDomain] = [
        fontsGlobal, printersGlobal, ppdResources, colorSyncProfiles,
        audioHAL, audioComponents,
        quickLookGlobal, spotlightImportersGlobal, internetPlugInsGlobal,
        contextualMenuGlobal, screenSaversGlobal, inputMethodsGlobal, colorPickersGlobal,
        launchAgentsGlobal, launchDaemonsGlobal, diagnosticReportsGlobal,
        systemCachesGlobal, appLocalizedResources, volumeSpotlightIndex,
    ]

    /// 域 id → 域（自检与文档用于穷举）
    static let byID: [String: GovernanceDomain] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })
}

// MARK: - 判定结果

/// 网关对单个路径的裁决。带 `message` 是为了让 UI 能给出**真实原因**，
/// 而不是笼统一句"清理失败"。
enum GovernanceVerdict: Equatable {
    case allowed
    case rejected(Reason)

    enum Reason: String, Equatable {
        case emptyPath
        case resolvesToRoot
        case systemProtected
        case hardExcluded
        case userWhitelisted
        case blockedByBaseGate
        case symlinkJump
        case outsideDomain
        case tooShallowForDomain
        case missing
        case needsPrivilege
        /// 模块有正向证据表明该条目仍在被使用（如系统注册表里已注册、被设备引用）。
        /// 网关的 `policy` 闭包用它把"业务在用"与"护栏拦下"区分开，UI 才能给不同文案。
        case inUse
        /// 该条目本身不该被删除，但不属于任何一条安全护栏的语义
        /// （例：用户自己创作的内容、无归属可辨的目录）。
        case notDeletable
    }

    var isAllowed: Bool { self == .allowed }

    /// 面向用户的中文说明（卡片直接展示）
    var message: String {
        switch self {
        case .allowed: return "允许操作"
        case .rejected(let r):
            switch r {
            case .emptyPath: return "路径为空"
            case .resolvesToRoot: return "目标解析到了文件系统根，拒绝"
            case .systemProtected: return "受 SIP/系统硬保护（G8），绝不可删"
            case .hardExcluded: return "位于用户数据硬排除清单（G6），绝不可删"
            case .userWhitelisted: return "在你自定义的白名单里，已按你的设置保留"
            case .blockedByBaseGate: return "被基础安全护栏拒绝"
            case .symlinkJump: return "路径经符号链接跳出了授权位置，拒绝"
            case .outsideDomain: return "不在任何已登记的治理域内，拒绝"
            case .tooShallowForDomain: return "层级过浅（可能是整个目录根），拒绝"
            case .missing: return "路径已不存在"
            case .needsPrivilege: return "该位置由 root 管理，MacClean 无删除权限（本工具不做提权）"
            case .inUse: return "系统或设备正在使用，删除会立即影响功能"
            case .notDeletable: return "不属于可清理对象，已保留"
            }
        }
    }
}

extension FileSystem {

    /// 主目录之外位置的**唯一**删除判定入口。
    ///
    /// 判定顺序（前四步与 `isSafeToClean` 共享同一套核心护栏，杜绝"两套标准"）：
    /// ① 空路径拒绝；② 末段是软链拒绝；③ 解析真实位置；
    /// ④ G8 系统硬保护 / G6 用户数据硬排除 / 用户自定义白名单；
    /// ⑤ 真实位置必须落在声明的治理域内，且深度足够（不是域根本身）；
    /// ⑥ 当前进程是否真的有权 unlink 该条目（含 sticky 位规则）→ 否则判 `needsPrivilege`。
    ///
    /// 注意 ⑤ 用的是**解析后的真实位置**：`/Library/Fonts/link → /System/Library/Fonts`
    /// 字面上在域内，解析后不在，因此被拒——这正是软链逃逸的封堵点。
    static func governanceVerdict(_ path: String, domain: GovernanceDomain) -> GovernanceVerdict {
        guard !path.isEmpty else { return .rejected(.emptyPath) }
        if isSymlink(path) { return .rejected(.symlinkJump) }

        let real = normalizePath(realPath(path))
        guard real != "/" else { return .rejected(.resolvesToRoot) }
        if let blocked = coreGuardVerdict(real) { return .rejected(blocked) }

        // 必须严格位于授权域之内
        let root = domain.normalizedRoot
        guard real == root || real.hasPrefix(root + "/") else {
            return .rejected(.outsideDomain)
        }
        let depthBelowRoot = real.dropFirst(root.count).split(separator: "/").count
        guard depthBelowRoot >= domain.minDepthBelowRoot else {
            return .rejected(.tooShallowForDomain)
        }
        // 入口名单：root 之下第一层必须是登记过的条目
        if let allowed = domain.allowedEntryNames {
            let firstSegment = real.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
            guard let first = firstSegment, allowed.contains(first) else {
                return .rejected(.outsideDomain)
            }
        }

        guard exists(real) else { return .rejected(.missing) }
        guard canUnlink(real) else { return .rejected(.needsPrivilege) }
        return .allowed
    }

    /// 主目录内的常规判定：沿用 `isSafeToClean`，但把"为什么不行"细分出来。
    static func governanceVerdictWithinHome(_ path: String) -> GovernanceVerdict {
        guard !path.isEmpty else { return .rejected(.emptyPath) }
        if isSymlink(path) { return .rejected(.symlinkJump) }
        let real = normalizePath(realPath(path))
        guard real != "/" else { return .rejected(.resolvesToRoot) }
        if let blocked = coreGuardVerdict(real) { return .rejected(blocked) }
        guard isSafeToClean(real) else { return .rejected(.blockedByBaseGate) }
        guard exists(real) else { return .rejected(.missing) }
        return .allowed
    }

    /// 核心护栏：G8 系统硬保护 → G6 用户数据硬排除 → 用户自定义白名单。
    /// `isSafeToClean` 与本文件的域判定共用它，保证"同一份路径在两处结论一致"。
    /// 入参必须是 `normalizePath` 之后的真实位置。
    static func coreGuardVerdict(_ normalizedRealPath: String) -> GovernanceVerdict.Reason? {
        if isSystemProtected(normalizedRealPath) { return .systemProtected }
        for ex in CleanPaths.hardExclude {
            let p = normalizePath(ex)
            if normalizedRealPath == p || normalizedRealPath.hasPrefix(p + "/") { return .hardExcluded }
        }
        if WhitelistManager.shared.isWhitelisted(path: normalizedRealPath)
            || WhitelistManager.shared.isExtensionWhitelisted(path: normalizedRealPath) {
            return .userWhitelisted
        }
        return nil
    }

    /// 当前进程是否真的有权删除该条目。
    ///
    /// 内核规则：删除条目需要**父目录**的写权限；若父目录带 sticky 位（`S_ISVTX`），
    /// 还只有**文件属主**、**目录属主**或 root 能删。
    ///
    /// 这里此前写成了 `tst.st_uid == pst.st_uid`（文件属主 == 目录属主）——那是**别人的**
    /// 两个 uid 在比较，跟"我是谁"无关，于是 root 拥有的字体文件落在
    /// `drwxrwxr-t root:admin` 的 `/Library/Fonts` 里会被判成"能删"，
    /// 实际 unlink 必然 `Operation not permitted`。判据必须落到 euid 上。
    static func canUnlink(_ path: String) -> Bool {
        let euid = geteuid()
        if euid == 0 { return true }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return false }
        if access(parent, W_OK) != 0 { return false }

        var pst = stat()
        guard stat(parent, &pst) == 0 else { return false }
        guard (pst.st_mode & S_ISVTX) != 0 else { return true }

        var tst = stat()
        guard lstat(path, &tst) == 0 else { return true }   // 不存在交由 .missing 判定
        return tst.st_uid == euid || pst.st_uid == euid
    }
}
