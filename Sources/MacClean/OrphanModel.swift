import Foundation

/// 孤儿残留组件类型
public enum OrphanKind: String, CaseIterable, Identifiable, Codable {
    case container = "沙盒容器"
    case groupContainer = "组容器"
    case appSupport = "应用支持"
    case preferences = "偏好设置"
    case savedState = "窗口状态"
    case webkit = "WebKit 缓存"
    case httpStorage = "网络存储"
    case launchAgent = "自启配置"
    case logs = "运行日志"
    case other = "其他残留"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .container: return "shippingbox"
        case .groupContainer: return "folder.badge.gearshape"
        case .appSupport: return "folder"
        case .preferences: return "slider.horizontal.3"
        case .savedState: return "macwindow"
        case .webkit: return "globe"
        case .httpStorage: return "server.rack"
        case .launchAgent: return "bolt"
        case .logs: return "doc.text"
        case .other: return "doc"
        }
    }
}

/// 单个孤儿残留文件或目录
public struct OrphanItem: Identifiable, Equatable, Hashable {
    public let id: UUID
    public let name: String
    public let path: String
    public let size: Int64
    public let kind: OrphanKind
    public let lastModified: Date?
    public var isSelected: Bool

    public init(id: UUID = UUID(), name: String, path: String, size: Int64, kind: OrphanKind, lastModified: Date? = nil, isSelected: Bool = false) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.kind = kind
        self.lastModified = lastModified
        self.isSelected = isSelected
    }
}

/// 聚合的孤儿应用实体（将同一已卸载 App 散落在不同系统目录下的残留归集为一组）
public struct OrphanApp: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let bundleID: String?
    public var items: [OrphanItem]
    public var isSelected: Bool

    public init(id: UUID = UUID(), name: String, bundleID: String? = nil, items: [OrphanItem] = [], isSelected: Bool = false) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.items = items
        self.isSelected = isSelected
    }

    public var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }

    public var allSelected: Bool {
        !items.isEmpty && items.allSatisfy(\.isSelected)
    }
}
