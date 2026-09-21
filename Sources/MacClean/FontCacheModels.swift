import Foundation
import CoreText

// MARK: - 字体文件状态与格式

public enum FontItemStatus: String, Codable, CaseIterable {
    case valid = "正常"
    case duplicate = "重复副本"
    case corrupted = "已损坏/无法解析"
    case orphan = "未注册孤儿"

    /// Web 字体格式（WOFF / WOFF2）：CoreText **本就不支持**解析它们，
    /// 解析失败是格式属性而非文件缺陷，因此绝不可据此判损坏（v1.73.0 判据修复）。
    case webFormat = "Web 字体（CoreText 不解析）"

    /// 证据不足：解析失败但容器特征仍像字体（或读不到字节）。
    /// 「读不到」≠「可以删」——一律降级为需确认，不默认勾选。
    case needsReview = "需确认（证据不足）"

    /// 该状态是否构成删除的正向依据（默认勾选的唯一来源）
    public var providesDeletionEvidence: Bool {
        // .webFormat / .needsReview / .valid / .orphan 都不构成依据：
        // 前者是格式属性、后者是证据缺失，.orphan 从未被本模块产出过。
        self == .corrupted || self == .duplicate
    }
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
    /// 该文件此刻就在系统字体注册表里（`CTFontManagerCopyAvailableFontURLs`）。
    /// **在用者坚决不可删**：它是判定链上唯一能证明"这个字体正被系统使用"的证据。
    public let isRegisteredInUse: Bool
    /// 判定依据的一句话说明，卡片如实展示（不藏结论背后的理由）
    public let note: String?

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
        isSelected: Bool = false,
        isRegisteredInUse: Bool = false,
        note: String? = nil
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
        self.isRegisteredInUse = isRegisteredInUse
        self.note = note
    }

    /// 本模块允许进入删除网关的判据：有正向证据、未在用、非系统受保护。
    public var isDeletableVerdict: Bool {
        status.providesDeletionEvidence && !isRegisteredInUse && !isSystemProtected
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
    /// 系统字体注册表**读取失败**：此时本模块不产出任何"在用"结论，
    /// 也不允许据"不在注册表里"判孤儿（读不到 ≠ 可以删）。
    public var registryUnavailable: Bool

    public init(
        userFonts: [FontItem] = [],
        cacheItems: [FontCacheItem] = [],
        totalFontSize: Int64 = 0,
        totalCacheSize: Int64 = 0,
        registryUnavailable: Bool = false
    ) {
        self.userFonts = userFonts
        self.cacheItems = cacheItems
        self.totalFontSize = totalFontSize
        self.totalCacheSize = totalCacheSize
        self.registryUnavailable = registryUnavailable
    }

    /// 损坏字体列表
    public var corruptedFonts: [FontItem] {
        userFonts.filter { $0.status == .corrupted }
    }

    /// 重复字体列表
    public var duplicateFonts: [FontItem] {
        userFonts.filter { $0.status == .duplicate }
    }

    /// Web 字体（WOFF/WOFF2）：只归类，永不判损坏
    public var webFonts: [FontItem] {
        userFonts.filter { $0.status == .webFormat }
    }

    /// 证据不足、需用户确认的项
    public var needsReviewFonts: [FontItem] {
        userFonts.filter { $0.status == .needsReview }
    }

    /// 此刻正被系统字体注册表使用的字体（坚决保留）
    public var registeredInUseFonts: [FontItem] {
        userFonts.filter(\.isRegisteredInUse)
    }

    /// 可清理字体释放潜力（损坏 + 重复勾选项，且在用者与受保护者一律排除）
    public var reclaimableFontSize: Int64 {
        userFonts
            .filter { $0.isDeletableVerdict && $0.isSelected }
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

// MARK: - ATS 字体数据库重置结果

/// "字体缓存已重置"这句话只有拿到命令成功的证据才能说（v1.73.0）。
/// 旧实现 `try? task.run()` 后不看退出码就回 Bool，把"根本没启动"报成"已完成"。
public struct AtsResetResult: Equatable {
    /// 是否真的启起了进程并拿到退出码
    public let executed: Bool
    /// 退出码是否为 0（未超时）
    public let succeeded: Bool
    /// 给用户看的结论
    public let message: String
    /// 命令退出码（未执行为 nil）
    public let exitCode: Int32?

    public init(executed: Bool, succeeded: Bool, message: String, exitCode: Int32?) {
        self.executed = executed
        self.succeeded = succeeded
        self.message = message
        self.exitCode = exitCode
    }

    public static let notExecuted = AtsResetResult(
        executed: false, succeeded: false,
        message: "未执行：本机没有可用的 atsutil，字体缓存未做任何改动",
        exitCode: nil)
}
