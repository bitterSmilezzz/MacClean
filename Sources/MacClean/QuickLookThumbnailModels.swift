import Foundation

// MARK: - QuickLook 快速查看缓存分类枚举

public enum QuickLookCacheKind: String, Codable, CaseIterable, Identifiable {
    case thumbnailDatabase = "系统缩略图数据库"
    case previewExtensionCache = "预览生成扩展缓存"
    case uiServiceCache = "QuickLook UI 服务缓存"
    case userQuickLookCache = "用户级快速查看缓存"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .thumbnailDatabase: return "photo.stack.fill"
        case .previewExtensionCache: return "puzzlepiece.extension.fill"
        case .uiServiceCache: return "macwindow.on.rectangle"
        case .userQuickLookCache: return "eye.fill"
        }
    }
}

// MARK: - QuickLook 缓存条目数据模型

public struct QuickLookCacheItem: Identifiable, Equatable, Hashable {
    public let id: String                     // 目录绝对路径
    public let kind: QuickLookCacheKind       // 缓存分类
    public let title: String                  // 标题
    public let path: String                   // 绝对路径
    public let size: Int64                    // 占用字节
    public let fileCount: Int                 // 内部文件数量
    public var isSelected: Bool               // 是否选中清理

    public init(
        id: String,
        kind: QuickLookCacheKind,
        title: String,
        path: String,
        size: Int64,
        fileCount: Int,
        isSelected: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.size = size
        self.fileCount = fileCount
        self.isSelected = isSelected
    }
}

// MARK: - QuickLook 缩略图缓存概览

public struct QuickLookThumbnailSummary: Equatable {
    public var items: [QuickLookCacheItem]
    public var totalSize: Int64

    public init(
        items: [QuickLookCacheItem] = [],
        totalSize: Int64 = 0
    ) {
        self.items = items
        self.totalSize = totalSize
    }

    /// 已勾选的释放空间
    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    /// 已勾选的条目数
    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }
}
