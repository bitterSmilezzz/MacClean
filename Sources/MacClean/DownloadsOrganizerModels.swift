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

// MARK: - 清理结果（v1.72.0 安全加固）

/// `DownloadsOrganizerScanner.clean` 的逐项结论。
///
/// 释放量来自**删除前实测**，`errorCount` 把"被护栏拦下"与"删除失败"分开计数后合并上报，
/// 不再出现旧版"删了没删都算成功"的记账。
public struct DownloadsCleanResult {
    let outcome: ResidueDeletionGate.Outcome

    public var cleanedCount: Int { outcome.cleanedCount }
    public var freedBytes: Int64 { outcome.freedBytes }
    public var errorCount: Int { outcome.errorCount }
    public var rejectedCount: Int { outcome.rejected.count }
    public var failedCount: Int { outcome.failed.count }
    public var needsPrivilegeCount: Int { outcome.needsPrivilege.count }
    public var summary: String { outcome.summary }
    public var cleanedPaths: [String] { outcome.cleanedPaths }

    init(outcome: ResidueDeletionGate.Outcome) { self.outcome = outcome }
}

/// `DownloadsOrganizerScanner.archive` 的逐项结论。
public struct DownloadsArchiveResult {
    public let movedCount: Int
    /// 移动**前**实测到的体积（同宗卷移动不释放空间，仅作为"挪了多少"的依据）
    public let movedBytes: Int64
    let rejected: [ResidueDeletionGate.Rejection]
    let failed: [(name: String, path: String, message: String)]

    public var errorCount: Int { rejected.count + failed.count }
    public var summary: String {
        var parts: [String] = []
        if movedCount > 0 { parts.append("已归档移动 \(movedCount) 项（\(movedBytes.byteStringCN)）") }
        if !rejected.isEmpty { parts.append("\(rejected.count) 项被安全护栏拦下") }
        if !failed.isEmpty { parts.append("\(failed.count) 项移动失败") }
        return parts.isEmpty ? "没有可归档的项目" : parts.joined(separator: "；")
    }
    public var firstFailure: String? {
        (rejected.first?.message ?? failed.first?.message)
    }

    init(movedCount: Int, movedBytes: Int64,
         rejected: [ResidueDeletionGate.Rejection],
         failed: [(name: String, path: String, message: String)]) {
        self.movedCount = movedCount
        self.movedBytes = movedBytes
        self.rejected = rejected
        self.failed = failed
    }
}
