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

    public var id: String { rawValue }

    public var isOrphan: Bool {
        self == .executableMissing
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

    public init(
        id: String,
        name: String,
        path: String,
        targetPath: String?,
        kind: LoginItemKind,
        issue: LoginItemIssue,
        size: Int64,
        isSelected: Bool = true
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.targetPath = targetPath
        self.kind = kind
        self.issue = issue
        self.size = size
        self.isSelected = isSelected
    }
}

// MARK: - 登录项治理全景汇总

public struct LoginItemSummary: Equatable {
    public var items: [LoginItemEntry]
    public var orphanCount: Int
    public var totalSize: Int64

    public init(
        items: [LoginItemEntry] = [],
        orphanCount: Int = 0,
        totalSize: Int64 = 0
    ) {
        self.items = items
        self.orphanCount = orphanCount
        self.totalSize = totalSize
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
