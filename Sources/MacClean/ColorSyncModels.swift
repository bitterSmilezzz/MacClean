import Foundation

// MARK: - ColorSync 色彩配置文件类型枚举

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

public enum ICCProfileStatus: String, Codable, CaseIterable, Identifiable {
    case activeConnected = "当前连接显示器 (受保护)"
    case disconnectedOrphan = "已断开外接显示器残留 (建议清理)"
    case corrupted = "损坏或零字节配置 (建议清理)"
    case systemProtected = "Apple 系统核心配置 (受保护)"

    public var id: String { rawValue }

    public var isOrphanOrCorrupted: Bool {
        self == .disconnectedOrphan || self == .corrupted
    }
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
    public var isSelected: Bool               // 是否选中清理

    public init(
        id: String,
        name: String,
        path: String,
        kind: ICCProfileKind,
        status: ICCProfileStatus,
        size: Int64,
        modificationDate: Date,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.status = status
        self.size = size
        self.modificationDate = modificationDate
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

    public init(
        items: [ICCProfileItem] = [],
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
