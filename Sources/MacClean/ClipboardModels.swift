import Foundation
import AppKit

// MARK: - 剪贴板内容类型定义

public enum PasteboardDataType: String, Codable, CaseIterable, Identifiable {
    case text = "纯文本"
    case rtf = "富文本"
    case image = "图像位图"
    case fileURL = "文件引用"
    case sensitiveCredential = "⚠️ 敏感凭据/密钥"
    case binary = "复合二进制"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .text: return "text.alignleft"
        case .rtf: return "doc.richtext"
        case .image: return "photo.fill"
        case .fileURL: return "doc.on.doc.fill"
        case .sensitiveCredential: return "key.fill"
        case .binary: return "shippingbox.fill"
        }
    }
}

// MARK: - 剪贴板条目概要

public struct PasteboardItemSummary: Identifiable, Equatable {
    public let id: String                 // 类型标识，如 public.tiff
    public let typeName: String           // UTType 标识字符串
    public let dataType: PasteboardDataType // 分类类型
    public let size: Int64                // 数据大小（字节）
    public let preview: String            // 内容摘要预览（脱敏）
    public let isLarge: Bool              // 是否为大对象 (>5MB)
    public let isSensitive: Bool          // 是否为疑似敏感信息

    public init(
        id: String,
        typeName: String,
        dataType: PasteboardDataType,
        size: Int64,
        preview: String,
        isLarge: Bool = false,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.typeName = typeName
        self.dataType = dataType
        self.size = size
        self.preview = preview
        self.isLarge = isLarge
        self.isSensitive = isSensitive
    }
}

// MARK: - 剪贴板临时缓存文件项

public struct ClipboardCacheItem: Identifiable, Equatable {
    public let id: String                 // 缓存路径
    public let name: String               // 缓存名
    public let path: String               // 路径
    public let size: Int64                // 大小
    public let note: String               // 描述

    public init(
        id: String,
        name: String,
        path: String,
        size: Int64,
        note: String
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.note = note
    }
}

// MARK: - 剪贴板治理全景报告

public struct ClipboardReport: Equatable {
    public var items: [PasteboardItemSummary]
    public var cacheItems: [ClipboardCacheItem]
    public var totalMemorySize: Int64
    public var totalCacheSize: Int64
    public var hasSensitiveData: Bool
    public var changeCount: Int

    public init(
        items: [PasteboardItemSummary] = [],
        cacheItems: [ClipboardCacheItem] = [],
        totalMemorySize: Int64 = 0,
        totalCacheSize: Int64 = 0,
        hasSensitiveData: Bool = false,
        changeCount: Int = 0
    ) {
        self.items = items
        self.cacheItems = cacheItems
        self.totalMemorySize = totalMemorySize
        self.totalCacheSize = totalCacheSize
        self.hasSensitiveData = hasSensitiveData
        self.changeCount = changeCount
    }

    /// 总可释放占用（内存 + 磁盘缓存）
    public var totalReclaimableSize: Int64 {
        totalMemorySize + totalCacheSize
    }

    /// 是否为空
    public var isEmpty: Bool {
        items.isEmpty && cacheItems.isEmpty
    }
}
