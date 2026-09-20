import Foundation

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

    public var id: String { rawValue }

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

    public init(
        id: String,
        name: String,
        path: String,
        kind: SpotlightStoreKind,
        status: SpotlightIndexStatus,
        size: Int64,
        fileCount: Int = 1,
        modificationDate: Date,
        isSelected: Bool = false
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
    }
}

// MARK: - Spotlight 治理全景概览

public struct SpotlightSummary: Equatable {
    public var items: [SpotlightStoreItem]
    public var totalSize: Int64
    public var orphanCount: Int
    public var orphanSize: Int64
    public var activeCount: Int

    public init(
        items: [SpotlightStoreItem] = [],
        totalSize: Int64 = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        activeCount: Int = 0
    ) {
        self.items = items
        self.totalSize = totalSize
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.activeCount = activeCount
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
