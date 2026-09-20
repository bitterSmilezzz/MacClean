import Foundation
import CoreText

// MARK: - 字体文件状态与格式

public enum FontItemStatus: String, Codable, CaseIterable {
    case valid = "正常"
    case duplicate = "重复副本"
    case corrupted = "已损坏/无法解析"
    case orphan = "未注册孤儿"
}

public enum FontFormat: String, Codable, CaseIterable {
    case ttf = "TrueType (TTF)"
    case otf = "OpenType (OTF)"
    case ttc = "TrueType Collection (TTC)"
    case dfont = "Datafork Font (DFont)"
    case woff = "Web Open Font (WOFF)"
    case woff2 = "Web Open Font 2 (WOFF2)"
    case other = "其他字体"

    public static func from(path: String) -> FontFormat {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "ttf": return .ttf
        case "otf": return .otf
        case "ttc": return .ttc
        case "dfont": return .dfont
        case "woff": return .woff
        case "woff2": return .woff2
        default: return .other
        }
    }
}

// MARK: - 字体条目模型

public struct FontItem: Identifiable, Equatable, Hashable {
    public let id: String                 // 文件绝对路径
    public let fileName: String           // 文件名
    public let path: String               // 路径
    public let size: Int64                // 文件大小
    public let format: FontFormat         // 字体格式
    public let familyName: String?        // 字体家族名称（如 PingFang SC）
    public let postscriptName: String?    // PostScript 名称
    public let status: FontItemStatus     // 健康与状态
    public let isSystemProtected: Bool    // 是否为系统受保护字体
    public var isSelected: Bool           // 是否勾选清理

    public init(
        id: String,
        fileName: String,
        path: String,
        size: Int64,
        format: FontFormat,
        familyName: String?,
        postscriptName: String?,
        status: FontItemStatus,
        isSystemProtected: Bool,
        isSelected: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.path = path
        self.size = size
        self.format = format
        self.familyName = familyName
        self.postscriptName = postscriptName
        self.status = status
        self.isSystemProtected = isSystemProtected
        self.isSelected = isSelected
    }
}

// MARK: - 字体缓存条目模型

public struct FontCacheItem: Identifiable, Equatable {
    public let id: String                 // 缓存目录或文件绝对路径
    public let name: String               // 缓存名称
    public let path: String               // 路径
    public let size: Int64                // 缓存字节数
    public let note: String               // 说明
    public var isSelected: Bool           // 是否勾选

    public init(
        id: String,
        name: String,
        path: String,
        size: Int64,
        note: String,
        isSelected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.note = note
        self.isSelected = isSelected
    }
}

// MARK: - 字体治理全景报告

public struct FontInspectionReport: Equatable {
    public var userFonts: [FontItem]
    public var cacheItems: [FontCacheItem]
    public var totalFontSize: Int64
    public var totalCacheSize: Int64

    public init(
        userFonts: [FontItem] = [],
        cacheItems: [FontCacheItem] = [],
        totalFontSize: Int64 = 0,
        totalCacheSize: Int64 = 0
    ) {
        self.userFonts = userFonts
        self.cacheItems = cacheItems
        self.totalFontSize = totalFontSize
        self.totalCacheSize = totalCacheSize
    }

    /// 损坏字体列表
    public var corruptedFonts: [FontItem] {
        userFonts.filter { $0.status == .corrupted }
    }

    /// 重复字体列表
    public var duplicateFonts: [FontItem] {
        userFonts.filter { $0.status == .duplicate }
    }

    /// 可清理字体释放潜力（损坏 + 重复勾选项）
    public var reclaimableFontSize: Int64 {
        userFonts
            .filter { !$0.isSystemProtected && $0.isSelected && ($0.status == .corrupted || $0.status == .duplicate) }
            .reduce(0) { $0 + $1.size }
    }

    /// 可清理缓存释放潜力
    public var reclaimableCacheSize: Int64 {
        cacheItems.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    /// 总可释放空间
    public var totalReclaimableSize: Int64 {
        reclaimableFontSize + reclaimableCacheSize
    }
}
