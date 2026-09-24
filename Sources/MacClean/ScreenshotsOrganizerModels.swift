import Foundation

// MARK: - 截屏与录屏媒体类型定义

public enum CaptureType: String, Codable, CaseIterable, Identifiable {
    case screenshot = "📸 静态截屏"
    case recording = "🎥 屏幕录制"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .recording: return "video.badge.waveform"
        }
    }
}

// MARK: - 时效阶梯定义

public enum CaptureAgeTier: String, Codable, CaseIterable, Identifiable {
    case within7Days = "7 天内"
    case days8To30 = "8-30 天"
    case days31To90 = "31-90 天"
    case over90Days = "90 天以上"

    public var id: String { rawValue }

    public static func from(ageDays: Int) -> CaptureAgeTier {
        if ageDays <= 7 {
            return .within7Days
        } else if ageDays <= 30 {
            return .days8To30
        } else if ageDays <= 90 {
            return .days31To90
        } else {
            return .over90Days
        }
    }
}

// MARK: - 归档组织策略

public enum ArchiveStrategy: String, Codable, CaseIterable, Identifiable {
    case byYearMonth = "按年月归类 (YYYY-MM)"
    case byType = "按类型归类 (截屏/录屏)"

    public var id: String { rawValue }
}

// MARK: - 截屏/录屏文件条目数据模型

public struct ScreenshotItem: Identifiable, Equatable, Hashable {
    public let id: String                 // 文件绝对路径
    public let fileName: String           // 文件名
    public let path: String               // 路径
    public let size: Int64                // 文件大小（字节）
    public let captureType: CaptureType   // 截屏或录屏
    public let modificationDate: Date     // 修改时间
    public let ageDays: Int               // 闲置天数
    public var isSelected: Bool           // 是否选中归档/清理

    public init(
        id: String,
        fileName: String,
        path: String,
        size: Int64,
        captureType: CaptureType,
        modificationDate: Date,
        ageDays: Int,
        isSelected: Bool = false
    ) {
        self.id = id
        self.fileName = fileName
        self.path = path
        self.size = size
        self.captureType = captureType
        self.modificationDate = modificationDate
        self.ageDays = ageDays
        self.isSelected = isSelected
    }

    /// 年龄阶梯
    public var ageTier: CaptureAgeTier {
        CaptureAgeTier.from(ageDays: ageDays)
    }

    /// 是否为高推荐治理项（屏幕录制体积大超过7天，或截图闲置超过30天，或任意超过90天的陈旧项）
    public var isHighRiskStale: Bool {
        if captureType == .recording && ageDays >= 7 { return true }
        if captureType == .screenshot && ageDays >= 30 { return true }
        if ageDays >= 90 { return true }
        return false
    }
}

// MARK: - 全景统计摘要

public struct ScreenshotsSummary: Equatable {
    public var items: [ScreenshotItem]
    public var totalSize: Int64
    public var screenshotSize: Int64
    public var screenshotCount: Int
    public var recordingSize: Int64
    public var recordingCount: Int
    public var staleSize: Int64           // 超过 30 天的陈旧大小
    public var staleCount: Int            // 超过 30 天的陈旧文件数
    /// 本轮**没能读到**的根目录，理由同 `DownloadsSummary.unreadableRoots`。
    public var unreadableRoots: [String]
    /// 本轮**根本没去读**的根（在途额度已满），理由同 `DownloadsSummary.deferredRoots`。
    public var deferredRoots: [String]

    public init(
        items: [ScreenshotItem] = [],
        totalSize: Int64 = 0,
        screenshotSize: Int64 = 0,
        screenshotCount: Int = 0,
        recordingSize: Int64 = 0,
        recordingCount: Int = 0,
        staleSize: Int64 = 0,
        staleCount: Int = 0,
        unreadableRoots: [String] = [],
        deferredRoots: [String] = []
    ) {
        self.items = items
        self.totalSize = totalSize
        self.screenshotSize = screenshotSize
        self.screenshotCount = screenshotCount
        self.recordingSize = recordingSize
        self.recordingCount = recordingCount
        self.staleSize = staleSize
        self.staleCount = staleCount
        self.unreadableRoots = unreadableRoots
        self.deferredRoots = deferredRoots
    }

    /// 已选中的总空间
    public var selectedSize: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    /// 已选中的文件条目数
    public var selectedCount: Int {
        items.filter(\.isSelected).count
    }
}

// MARK: - 治理结果（v1.72.0 安全加固）

/// `ScreenshotsOrganizerScanner.clean` 的逐项结论：释放量为删除前实测，
/// 拦截与失败分开计数。
public struct ScreenshotsCleanResult {
    let outcome: ResidueDeletionGate.Outcome

    public var cleanedCount: Int { outcome.cleanedCount }
    public var freedBytes: Int64 { outcome.freedBytes }
    public var errorCount: Int { outcome.errorCount }
    public var rejectedCount: Int { outcome.rejected.count }
    public var failedCount: Int { outcome.failed.count }
    public var summary: String { outcome.summary }
    public var cleanedPaths: [String] { outcome.cleanedPaths }

    init(outcome: ResidueDeletionGate.Outcome) { self.outcome = outcome }
}

/// `ScreenshotsOrganizerScanner.archive` 的逐项结论。
public struct ScreenshotsArchiveResult {
    public let archivedCount: Int
    /// 移动**前**实测体积（同宗卷移动不释放空间，只作"挪了多少"的依据）
    public let archivedBytes: Int64
    let rejected: [ResidueDeletionGate.Rejection]
    let failed: [(name: String, path: String, message: String)]

    public var errorCount: Int { rejected.count + failed.count }
    public var summary: String {
        var parts: [String] = []
        if archivedCount > 0 { parts.append("已归档 \(archivedCount) 项（\(archivedBytes.byteStringCN)）") }
        if !rejected.isEmpty { parts.append("\(rejected.count) 项被安全护栏拦下") }
        if !failed.isEmpty { parts.append("\(failed.count) 项移动失败") }
        return parts.isEmpty ? "没有可归档的项目" : parts.joined(separator: "；")
    }
    public var firstFailure: String? { rejected.first?.message ?? failed.first?.message }

    init(archivedCount: Int, archivedBytes: Int64,
         rejected: [ResidueDeletionGate.Rejection],
         failed: [(name: String, path: String, message: String)]) {
        self.archivedCount = archivedCount
        self.archivedBytes = archivedBytes
        self.rejected = rejected
        self.failed = failed
    }
}
