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

// MARK: - QuickLook 清理结果（v1.72.0 安全加固）

/// 一次 `purge` 的完整结论。
///
/// **为什么不是简单三元组**：旧版把"没跑成 qlmanage"也算成功，卡片于是固定播报
/// "已重置系统缩略图缓存"。现在删除结论（来自统一网关）与系统重置结论
/// （来自命令真实退出码）分开记账，UI 必须按 `systemCacheReset` 说话。
public struct QuickLookPurgeResult {
    /// 网关逐项结果（含每项被拦原因与失败原因）
    let outcome: ResidueDeletionGate.Outcome

    /// 是否请求了系统缩略图缓存重置
    public let resetRequested: Bool
    /// 重置是否**有命令成功证据**
    public let systemCacheReset: Bool
    /// 未重置的真实原因（`systemCacheReset == false` 且已请求时非 nil）
    public let systemResetFailure: String?

    /// 已清理的缓存子项数
    public var purgedCount: Int { outcome.cleanedCount }
    /// 删除**前**实测到的释放字节数
    public var freedBytes: Int64 { outcome.freedBytes }
    /// 被护栏拦下 / 删除失败 / 重置未成功的总计数
    public var errorCount: Int { outcome.errorCount }
    /// 一句话结论
    public var summary: String { outcome.summary }

    init(outcome: ResidueDeletionGate.Outcome, resetRequested: Bool,
         systemCacheReset: Bool, systemResetFailure: String?) {
        self.outcome = outcome
        self.resetRequested = resetRequested
        self.systemCacheReset = systemCacheReset
        self.systemResetFailure = systemResetFailure
    }
}
