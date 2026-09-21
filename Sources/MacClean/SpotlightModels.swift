import Foundation

// MARK: - 治理模块共用：证据源读取问题（v1.73.0 安全加固）
//
// 为什么放在这里、为什么要新造一个类型：
// `Models.swift` 里已经有一个同义的 `ScanIssue`，但它是 **internal**，而本批次五个治理模块
// （Spotlight / 多语言瘦身 / 诊断报告 / 底层存储 / 启动项）对外都是 `public` API，
// public 结构体不能持有 internal 存储属性。改 `Models.swift` 不在本轮授权范围内，
// 因此在此登记一个公开版本，供五个模块共用。
//
// 它存在的唯一目的：**把"读不到"变成一条显式记录**。
// 这些扫描器原先清一色 `try?` + `continue`，于是
// 「权限不足读不到」与「这里真的没有东西」在结果上完全一样 —— 都是 0 项，
// 而 0 项在 UI 上被渲染成"系统很干净"。任何一个模块只要产出下列记录，
// 其结论就不再完整，UI 必须显示"结果不完整"而不是"没有异常"。
public struct GovernanceEvidenceIssue: Identifiable, Equatable {
    public enum Kind: String, Equatable {
        /// 权限不足（root 所有 / 缺少「完全磁盘访问权限」）
        case permissionDenied
        /// 其它读取失败（IO 错误、枚举器建不起来）
        case unreadable
        /// 依赖的外部命令在本机不存在
        case toolUnavailable
        /// 外部命令非 0 退出或超时
        case commandFailed
    }

    public let id = UUID()
    public let kind: Kind
    /// 出问题的路径或命令
    public let subject: String
    /// 面向用户的一句话说明
    public let message: String

    public init(kind: Kind, subject: String, message: String) {
        self.kind = kind
        self.subject = subject
        self.message = message
    }

    /// 手工实现：`id` 是每次构造都变随机值，不参与"同一条问题"的判定。
    public static func == (lhs: GovernanceEvidenceIssue, rhs: GovernanceEvidenceIssue) -> Bool {
        lhs.kind == rhs.kind && lhs.subject == rhs.subject && lhs.message == rhs.message
    }

    public var icon: String {
        kind == .permissionDenied ? "lock.fill" : "exclamationmark.triangle.fill"
    }

    /// 统一的一句结论，卡片直接展示（绝不出现"干净/正常"字样）。
    public static func incompleteBanner(_ issues: [GovernanceEvidenceIssue]) -> String {
        let permissionOnly = !issues.isEmpty && issues.allSatisfy { $0.kind == .permissionDenied }
        let head = permissionOnly
            ? "权限不足，\(issues.count) 个位置读不到"
            : "\(issues.count) 个证据源读取失败"
        return "本次结果不完整：\(head)。以下结论仅覆盖读到的部分，不代表系统干净。"
    }
}

// MARK: - Spotlight 存储库类型枚举 (v1.69.0)

public enum SpotlightStoreKind: String, Codable, CaseIterable, Identifiable {
    case coreSpotlightIndex = "CoreSpotlight 应用索引"
    case spotlightCache = "Spotlight 搜索缓存"
    case volumeIndex = "磁盘卷根索引库"
    case importerCache = "导入器元数据缓存"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .coreSpotlightIndex: return "magnifyingglass"
        case .spotlightCache: return "archivebox.fill"
        case .volumeIndex: return "internaldrive.fill"
        case .importerCache: return "puzzlepiece.extension.fill"
        }
    }
}

// MARK: - Spotlight 索引健康状态

public enum SpotlightIndexStatus: String, Codable, CaseIterable, Identifiable {
    case activeHealthy = "活动正常 (受保护)"
    case orphanAppResidue = "已卸载应用索引残留 (建议清理)"
    case bloatedOrCorrupted = "体积膨胀或损坏 (建议重建)"
    case systemProtected = "系统受保护核心 (受保护)"
    /// v1.73.0：判据不足时的**降级态**。
    /// 两种情况会落到这里：① 索引目录读不到（`/Volumes/*/.Spotlight-V100` 多为 root 所有）；
    /// ② 已安装应用清单不完整（`AppInventory.isComplete == false`），
    /// 此时"不在清单里"根本推不出"宿主已卸载"。
    /// 该状态**既不算可清理、也不算在用**，UI 不默选、必须由用户显式确认。
    case needsConfirmation = "证据不足 (需确认)"

    public var id: String { rawValue }

    /// 只有**确证**的孤儿/损坏项才是可删候选；`needsConfirmation` 明确不在其中。
    public var isOrphanOrCorrupted: Bool {
        self == .orphanAppResidue || self == .bloatedOrCorrupted
    }
}

// MARK: - Spotlight 存储库条目数据模型

public struct SpotlightStoreItem: Identifiable, Equatable, Hashable {
    public let id: String                     // 绝对路径
    public let name: String                   // 显示名称
    public let path: String                   // 绝对路径
    public let kind: SpotlightStoreKind       // 分类
    public let status: SpotlightIndexStatus   // 状态
    public let size: Int64                    // 占用字节
    public let fileCount: Int                 // 包含文件数
    public let modificationDate: Date         // 修改时间
    public var isSelected: Bool               // 是否勾选清理
    /// v1.73.0：该卷是否被用户**显式勾选**去执行 `mdutil -E`。
    /// 默认恒为 false —— 重建索引是有后果的操作，绝不允许"顺手全卷重建"。
    public var isSelectedForRebuild: Bool
    /// 不可读原因（`status == .needsConfirmation` 时给用户的中文说明）
    public let note: String?

    public init(
        id: String,
        name: String,
        path: String,
        kind: SpotlightStoreKind,
        status: SpotlightIndexStatus,
        size: Int64,
        fileCount: Int = 1,
        modificationDate: Date,
        isSelected: Bool = false,
        isSelectedForRebuild: Bool = false,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.status = status
        self.size = size
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.isSelected = isSelected
        self.isSelectedForRebuild = isSelectedForRebuild
        self.note = note
    }

    /// 该条目走的治理域：`/Volumes/*/.Spotlight-V100` 用跨卷域，
    /// 其余（主目录内的 CoreSpotlight / 搜索缓存）走主目录护栏。
    /// root 匹配由注册表的统一解析器负责（含运行时登记的动态域）。
    /// internal：`GovernanceDomain` 是内部类型，不能出现在 public 签名的属性上。
    var governanceDomain: GovernanceDomain? {
        guard kind == .volumeIndex else { return nil }
        return GovernanceDomain.domain(forPath: path)
    }
}

// MARK: - Spotlight 治理全景概览

public struct SpotlightSummary: Equatable {
    public var items: [SpotlightStoreItem]
    public var totalSize: Int64
    public var orphanCount: Int
    public var orphanSize: Int64
    public var activeCount: Int
    /// v1.73.0：非空即代表**结果不完整**，UI 必须显式说明而不是报"没有残留"。
    public var issues: [GovernanceEvidenceIssue]
    /// 因证据不足而降级为"需确认"的条目数
    public var needsConfirmationCount: Int

    public init(
        items: [SpotlightStoreItem] = [],
        totalSize: Int64 = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        activeCount: Int = 0,
        issues: [GovernanceEvidenceIssue] = [],
        needsConfirmationCount: Int = 0
    ) {
        self.items = items
        self.totalSize = totalSize
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.activeCount = activeCount
        self.issues = issues
        self.needsConfirmationCount = needsConfirmationCount
    }

    /// 已选中的释放潜力
    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    /// 已选中的条目数
    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    /// 本次扫描的结论是否完整可信
    public var isResultComplete: Bool { issues.isEmpty }

    /// 用户可见的不完整提示；完整时返回 nil
    public var incompletenessBanner: String? {
        issues.isEmpty ? nil : GovernanceEvidenceIssue.incompleteBanner(issues)
    }

    /// 被用户显式勾选去重建索引的卷（`mdutil -E` 的唯一合法作用范围）
    public var volumesSelectedForRebuild: [SpotlightStoreItem] {
        items.filter { $0.kind == .volumeIndex && $0.isSelectedForRebuild }
    }
}
