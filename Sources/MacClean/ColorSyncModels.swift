import Foundation

// MARK: - ColorSync 色彩配置文件类型枚举 (v1.68.0，v1.72.0 判据修复)

public enum ICCProfileKind: String, Codable, CaseIterable, Identifiable {
    case displayProfile = "外接显示器色彩配置"
    case printerProfile = "打印机色彩配置"
    case customProfile = "用户自定义校准配置"
    case colorSyncCache = "ColorSync 缓存数据"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .displayProfile: return "display.2"
        case .printerProfile: return "printer.fill"
        case .customProfile: return "slider.horizontal.3"
        case .colorSyncCache: return "archivebox.fill"
        }
    }
}

// MARK: - 色彩配置文件健康状态

// v1.72.0 的两个新状态：
// · `recentlyActive`：30 天内写过 → 一律视为在用（旧实现完全没有这条，
//   昨天刚校准的配置今天就被列成"残留"默认勾选）。
// · `needsConfirmation`：接驳显示器列表为空/读不到、偏好记录解析失败等
//   **证据缺失**场景。旧实现在这些情况下反过来判 `.disconnectedOrphan` 并默认可删。
public enum ICCProfileStatus: String, Codable, CaseIterable, Identifiable {
    case activeConnected = "当前连接显示器 (受保护)"
    case disconnectedOrphan = "已断开外接显示器残留 (建议清理)"
    case corrupted = "损坏或零字节配置 (建议清理)"
    case systemProtected = "Apple 系统核心配置 (受保护)"
    case recentlyActive = "近期有写入 (视为在用)"
    case needsConfirmation = "证据不足 (需人工确认)"

    public var id: String { rawValue }

    public var isOrphanOrCorrupted: Bool {
        self == .disconnectedOrphan || self == .corrupted
    }

    /// 有明确在用/受保护证据
    public var isInUseOrProtected: Bool {
        self == .activeConnected || self == .systemProtected || self == .recentlyActive
    }
}

// MARK: - 在用证据（接驳显示器 + ColorSync 偏好）

/// 一台**当前接驳**的显示器。
///
/// `uuid` 是 `CGDisplayCreateUUIDFromDisplayID(displayID)` 的结果。macOS 为每台
/// 显示器生成的 profile 文件名就是 `<显示名>-<UUID>.icc`
/// （本机实测：`Color LCD-37D8832A-2D66-02CA-B9F7-8F30A301B230.icc` 对应内建屏），
/// 所以 UUID 是"这个 profile 属于哪台屏"的最硬证据，比名字模糊匹配可靠得多。
public struct ConnectedDisplay: Equatable {
    public let name: String
    public let uuid: String

    public init(name: String, uuid: String) {
        self.name = name
        self.uuid = uuid
    }
}

/// 「这台机器当前哪些色彩配置真在用」的证据 + 可信度。
public struct ColorSyncEvidence: Equatable {
    /// 当前接驳的显示器
    public let displays: [ConnectedDisplay]
    /// 显示器枚举是否可信（`NSScreen.screens` 为空表示无头/不可读 → 不得判孤儿）
    public let displaysReadable: Bool
    /// 用户/系统 ColorSync 偏好里指向 profile 的路径（含 Display P3 之类的引用）
    public let referencedProfilePaths: Set<String>
    /// 偏好文件是否都读到了（存在但读不到 → false）
    public let preferenceReadable: Bool
    /// 读到了哪些偏好源
    public let preferenceSources: [String]
    /// 读不到的源（卡片点名给用户）
    public let unreadableSources: [String]
    /// 「现在」——30 天内修改判据的基准时刻（注入它自检才能覆盖冷热两个分支）
    public let now: Date

    public init(displays: [ConnectedDisplay], displaysReadable: Bool,
                referencedProfilePaths: Set<String>, preferenceReadable: Bool,
                preferenceSources: [String] = [], unreadableSources: [String] = [],
                now: Date = Date()) {
        self.displays = displays
        self.displaysReadable = displaysReadable
        self.referencedProfilePaths = referencedProfilePaths
        self.preferenceReadable = preferenceReadable
        self.preferenceSources = preferenceSources
        self.unreadableSources = unreadableSources
        self.now = now
    }

    /// 两条在用证据都可信，才允许得出"断开残留"的结论
    public var isInUseEvidenceTrustworthy: Bool { displaysReadable && preferenceReadable }

    public static let unreadable = ColorSyncEvidence(
        displays: [], displaysReadable: false, referencedProfilePaths: [],
        preferenceReadable: false, unreadableSources: ["NSScreen", "ColorSync Preferences"],
        now: Date())
}

// MARK: - 色彩配置文件条目数据模型

public struct ICCProfileItem: Identifiable, Equatable, Hashable {
    public let id: String                     // 绝对路径
    public let name: String                   // 显示名称
    public let path: String                   // 绝对路径
    public let kind: ICCProfileKind           // 分类
    public let status: ICCProfileStatus       // 状态
    public let size: Int64                    // 大小
    public let modificationDate: Date         // 修改时间
    /// 判定依据 / 降级原因（中文，卡片如实展示）
    public let evidenceNote: String?
    /// 归属治理域 id（nil = 主目录内，走主目录护栏）
    public let domainID: String?
    public var isSelected: Bool               // 是否选中清理

    public init(
        id: String,
        name: String,
        path: String,
        kind: ICCProfileKind,
        status: ICCProfileStatus,
        size: Int64,
        modificationDate: Date,
        evidenceNote: String? = nil,
        domainID: String? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.status = status
        self.size = size
        self.modificationDate = modificationDate
        self.evidenceNote = evidenceNote
        self.domainID = domainID
        self.isSelected = isSelected
    }
}

// MARK: - ColorSync 治理全景概览

public struct ColorSyncSummary: Equatable {
    public var items: [ICCProfileItem]
    public var totalSize: Int64
    public var orphanCount: Int
    public var orphanSize: Int64
    public var activeCount: Int
    /// 在用证据（接驳显示器 + 偏好）是否可信
    public var evidenceTrustworthy: Bool
    /// 因证据不足而降级的条目数
    public var needsConfirmationCount: Int
    /// 读不到的证据源
    public var unreadableSources: [String]

    public init(
        items: [ICCProfileItem] = [],
        totalSize: Int64 = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        activeCount: Int = 0,
        evidenceTrustworthy: Bool = true,
        needsConfirmationCount: Int = 0,
        unreadableSources: [String] = []
    ) {
        self.items = items
        self.totalSize = totalSize
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.activeCount = activeCount
        self.evidenceTrustworthy = evidenceTrustworthy
        self.needsConfirmationCount = needsConfirmationCount
        self.unreadableSources = unreadableSources
    }

    /// 已选中的释放潜力
    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    /// 已选中的条目数
    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }
}
