import Foundation

// MARK: - 下载项类型定义

public enum DownloadItemKind: String, Codable, CaseIterable, Identifiable {
    case installer = "💿 安装镜像/包"
    case archive = "📦 压缩包"
    case media = "🎬 音频/视频"
    case document = "📄 文档与表格"
    case other = "📁 其他文件"

    public var id: String { rawValue }

    public static func from(path: String) -> DownloadItemKind {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "dmg", "pkg", "iso", "xip", "app":
            return .installer
        case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz":
            return .archive
        case "mp4", "mov", "mkv", "avi", "wmv", "mp3", "wav", "flac", "aac", "m4a":
            return .media
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "pages", "numbers", "key":
            return .document
        default:
            return .other
        }
    }

    public var icon: String {
        switch self {
        case .installer: return "externaldrive.fill.badge.plus"
        case .archive: return "archivebox.fill"
        case .media: return "play.rectangle.fill"
        case .document: return "doc.text.fill"
        case .other: return "doc.fill"
        }
    }
}

// MARK: - 下载条目数据模型

public struct DownloadItem: Identifiable, Equatable, Hashable {
    public let id: String                 // 文件绝对路径
    public let fileName: String           // 文件名
    public let path: String               // 路径
    public let size: Int64                // 文件大小
    public let kind: DownloadItemKind     // 类型
    public let modificationDate: Date     // 修改时间
    public let ageDays: Int               // 闲置天数
    public var isSelected: Bool           // 是否勾选清理/整理

    public init(
        id: String,
        fileName: String,
        path: String,
        size: Int64,
        kind: DownloadItemKind,
        modificationDate: Date,
        ageDays: Int,
        isSelected: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.path = path
        self.size = size
        self.kind = kind
        self.modificationDate = modificationDate
        self.ageDays = ageDays
        self.isSelected = isSelected
    }

    /// 是否为高推荐清理项（安装包且超过 7 天，或者任何超过 60 天的压缩包）
    public var isHighlyRecommendedToClean: Bool {
        if kind == .installer && ageDays >= 7 { return true }
        if kind == .archive && ageDays >= 30 { return true }
        if ageDays >= 90 { return true }
        return false
    }
}

// MARK: - 下载目录治理全景概要

public struct DownloadsSummary: Equatable {
    public var items: [DownloadItem]
    public var totalSize: Int64
    public var installerSize: Int64
    public var installerCount: Int
    public var archiveSize: Int64
    public var archiveCount: Int
    public var staleSize: Int64           // 超过 30 天的文件大小
    public var staleCount: Int            // 超过 30 天的文件数量

    public init(
        items: [DownloadItem] = [],
        totalSize: Int64 = 0,
        installerSize: Int64 = 0,
        installerCount: Int = 0,
        archiveSize: Int64 = 0,
        archiveCount: Int = 0,
        staleSize: Int64 = 0,
        staleCount: Int = 0
    ) {
        self.items = items
        self.totalSize = totalSize
        self.installerSize = installerSize
        self.installerCount = installerCount
        self.archiveSize = archiveSize
        self.archiveCount = archiveCount
        self.staleSize = staleSize
        self.staleCount = staleCount
    }

    /// 已勾选的释放空间
    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    /// 已勾选条目数
    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }
}
