import Foundation

// MARK: - 登录项与后台守护分类枚举

public enum LoginItemKind: String, Codable, CaseIterable, Identifiable {
    case launchAgent = "用户自启代理 (LaunchAgents)"
    case globalAgent = "全局自启代理 (/Library/LaunchAgents)"
    case globalDaemon = "系统全局守护 (/Library/LaunchDaemons)"
    case backgroundTask = "BTM 后台任务"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .launchAgent: return "person.crop.circle"
        case .globalAgent: return "globe"
        case .globalDaemon: return "gearshape.2"
        case .backgroundTask: return "bolt.horizontal.circle"
        }
    }
}

// MARK: - 登录项健康状态与问题分类

public enum LoginItemIssue: String, Codable, CaseIterable, Identifiable {
    case executableMissing = "程序缺失 (宿主已卸载)"
    case validActive = "正常有效"

    /// Apple 官方自启项：`Program` 解析出来的**真实可执行路径**落在
    /// `/System/Library`、`/usr/libexec` 等系统前缀里，或 label 是 `com.apple.*`。
    /// 旧实现拿这些前缀去比**文件名**的 `hasPrefix`，实测永远不命中，是死代码。
    case appleManaged = "Apple 官方自启项"

    /// 证据不足：plist 读不到、没有 `Program`/`ProgramArguments`、或裸命令名解析不出来。
    /// 「读不到」≠「可以删」——不判孤儿、不默认勾选。
    case needsReview = "需确认（证据不足）"

    public var id: String { rawValue }

    public var isOrphan: Bool {
        self == .executableMissing
    }

    /// 构成删除判据的正向证据（只有"声明的绝对路径确实不存在"这一种）
    public var providesDeletionEvidence: Bool { self == .executableMissing }
}

// MARK: - 单份 plist 的研判结果

public struct LoginItemInspection: Equatable {
    /// 从 `Program` / `ProgramArguments[0]` 解析出的**真实可执行路径**
    public let targetPath: String?
    /// plist 里的 `Label`（缺失时用文件名），launchd 卸载按它寻址
    public let label: String?
    public let issue: LoginItemIssue
    /// 判定依据，卡片如实展示
    public let note: String?

    public init(targetPath: String?, label: String?, issue: LoginItemIssue, note: String? = nil) {
        self.targetPath = targetPath
        self.label = label
        self.issue = issue
        self.note = note
    }

    /// 兼容旧调用形状的元组
    public var targetPathIsOrphan: (targetPath: String?, isOrphan: Bool) {
        (targetPath, issue.isOrphan)
    }
}

// MARK: - launchd 卸载结果

public struct LaunchctlUnloadResult: Equatable {
    public let label: String
    public let target: String
    public let attempted: Bool
    public let succeeded: Bool
    public let exitCode: Int32?
    public let message: String

    public init(label: String, target: String, attempted: Bool, succeeded: Bool,
                exitCode: Int32?, message: String) {
        self.label = label
        self.target = target
        self.attempted = attempted
        self.succeeded = succeeded
        self.exitCode = exitCode
        self.message = message
    }
}

// MARK: - 登录项与后台守护条目模型

public struct LoginItemEntry: Identifiable, Equatable, Hashable {
    public let id: String                 // 配置绝对路径
    public let name: String               // 显示名称（如 com.baidu.netdisk.helper）
    public let path: String               // .plist 配置文件绝对路径
    public let targetPath: String?        // 目标可执行程序路径（如 /Applications/BaiduNetdisk.app/...）
    public let kind: LoginItemKind        // 所属分类
    public let issue: LoginItemIssue      // 状态与问题
    public let size: Int64                // plist 文件大小
    public var isSelected: Bool           // 是否勾选清理
    /// launchd 服务标识（`Label` 键，回退文件名）：删除成功后按它卸载
    public let serviceLabel: String?
    /// 判定依据说明
    public let note: String?

    public init(
        id: String,
        name: String,
        path: String,
        targetPath: String?,
        kind: LoginItemKind,
        issue: LoginItemIssue,
        size: Int64,
        isSelected: Bool = true,
        serviceLabel: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.targetPath = targetPath
        self.kind = kind
        self.issue = issue
        self.size = size
        self.isSelected = isSelected
        self.serviceLabel = serviceLabel
        self.note = note
    }
}

// MARK: - 登录项治理全景汇总

public struct LoginItemSummary: Equatable {
    public var items: [LoginItemEntry]
    public var orphanCount: Int
    public var totalSize: Int64
    /// 读不到 / 证据不足而无法判定的条目数（卡片须与"死链数"分开显示）
    public var needsReviewCount: Int
    /// root 管理位置（`/Library/LaunchAgents`、`/Library/LaunchDaemons`）下的条目数：
    /// 本工具不提权，这些项**不可能**被删掉，只能如实说明。
    public var rootManagedCount: Int

    public init(
        items: [LoginItemEntry] = [],
        orphanCount: Int = 0,
        totalSize: Int64 = 0,
        needsReviewCount: Int = 0,
        rootManagedCount: Int = 0
    ) {
        self.items = items
        self.orphanCount = orphanCount
        self.totalSize = totalSize
        self.needsReviewCount = needsReviewCount
        self.rootManagedCount = rootManagedCount
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
