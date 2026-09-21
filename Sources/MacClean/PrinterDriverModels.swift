import Foundation

// MARK: - 打印机驱动与 PPD 文件类型枚举 (v1.71.0，v1.72.0 安全加固)

public enum PrinterDriverKind: String, Codable, CaseIterable, Identifiable {
    case vendorDriverBundle = "厂商驱动包"
    case ppdResource = "PPD 描述文件库"
    case cupsQueue = "CUPS 打印队列"
    case scannerDriver = "扫描仪驱动组件"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .vendorDriverBundle: return "printer.fill"
        case .ppdResource: return "doc.text.fill"
        case .cupsQueue: return "list.bullet.rectangle"
        case .scannerDriver: return "scanner.fill"
        }
    }
}

// MARK: - 打印机驱动健康状态

// v1.72.0 新增 `needsConfirmation`：真机上 `/etc/cups/printers.conf` 实测权限
// `-rw------- root:_cups`，本工具**永远读不到**已配置队列。旧实现把"读不到"当成
// "一个队列都没配"，于是全部驱动判 `.orphanUnused` 并默认全勾选——这正是
// G13（"读不到"不等于"很干净"）在本模块的复发。现在证据缺失必须落到这个新状态：
// 它既不是孤儿也不是损坏，`isOrphanOrCorrupted == false`，因此永不进默认可删集合。
public enum PrinterDriverStatus: String, Codable, CaseIterable, Identifiable {
    case activeConfigured = "当前在用配置 (受保护)"
    case orphanUnused = "未连接/废弃驱动 (建议清理)"
    case corrupted = "损坏配置 (建议清理)"
    case systemProtected = "系统核心组件 (受保护)"
    case needsConfirmation = "证据不足 (需人工确认)"

    public var id: String { rawValue }

    public var isOrphanOrCorrupted: Bool {
        self == .orphanUnused || self == .corrupted
    }

    /// 受保护（在用/系统核心）——卡片显示锁形图标
    public var isInUseOrProtected: Bool {
        self == .activeConfigured || self == .systemProtected
    }
}

// MARK: - 在用证据（CUPS 配置）

/// CUPS 配置源的读取结果 + **可信度**。
///
/// 判据只有一条：`/etc/cups/printers.conf` 与 `/etc/cups/ppd` 这两处证据源
/// 只要有任何一处**存在但读不到**（权限拒绝、解析失败），`sourcesReadable` 就是 false。
/// 「文件不存在」不算读不到（那台机器真的没配队列），「存在但 EACCES」才算。
public struct PrinterEvidence: Equatable {
    /// 已配置队列名及其下划线片段（小写）
    public let keywords: Set<String>
    /// 全部证据源是否都读成功——false 时**禁止**得出"孤儿"结论
    public let sourcesReadable: Bool
    /// 读失败的证据源（给用户看的原因）
    public let unreadableSources: [String]
    /// 成功读到的证据源（证明结论有依据）
    public let readableSources: [String]

    public init(keywords: Set<String>, sourcesReadable: Bool,
                unreadableSources: [String] = [], readableSources: [String] = []) {
        self.keywords = keywords
        self.sourcesReadable = sourcesReadable
        self.unreadableSources = unreadableSources
        self.readableSources = readableSources
    }

    /// 证据完全不可用（自检与降级路径用）
    public static let unreadable = PrinterEvidence(
        keywords: [], sourcesReadable: false,
        unreadableSources: ["/etc/cups/printers.conf", "/etc/cups/ppd"],
        readableSources: [])
}

// MARK: - 打印机驱动条目数据模型

public struct PrinterDriverItem: Identifiable, Equatable, Hashable {
    public let id: String                     // 绝对路径
    public let name: String                   // 显示名称
    public let vendor: String                 // 驱动厂商 (HP, Canon, Epson 等)
    public let path: String                   // 绝对路径（PPD 分组仅为**展示**用途，见 memberPaths）
    public let kind: PrinterDriverKind        // 分类
    public let status: PrinterDriverStatus    // 状态
    public let size: Int64                    // 占用字节
    public let fileCount: Int                 // 包含文件数
    public let modificationDate: Date         // 修改时间
    /// 该条目**真正可删的文件清单**。
    ///
    /// PPD 厂商分组是个聚合条目：旧实现把它的 `path` 写成共享的 Resources 根目录，
    /// 于是勾任一厂商就把整棵 PPD 资源树移进废纸篓。现在分组自身**不再是删除目标**，
    /// 删除只按 `memberPaths` 里的具体文件逐个进行。
    public let memberPaths: [String]
    /// 判定依据 / 降级原因（中文，卡片如实展示）
    public let evidenceNote: String?
    public var isSelected: Bool               // 是否勾选清理

    public init(
        id: String,
        name: String,
        vendor: String,
        path: String,
        kind: PrinterDriverKind,
        status: PrinterDriverStatus,
        size: Int64,
        fileCount: Int = 1,
        modificationDate: Date,
        memberPaths: [String] = [],
        evidenceNote: String? = nil,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.path = path
        self.kind = kind
        self.status = status
        self.size = size
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.memberPaths = memberPaths
        self.evidenceNote = evidenceNote
        self.isSelected = isSelected
    }

    /// 删除目标路径：PPD 分组走成员文件，其余走条目自身。
    /// 分组条目**永不**把自己（共享资源根）交给删除网关。
    public var deletionTargets: [String] {
        kind == .ppdResource ? memberPaths : [path]
    }
}

// MARK: - 打印机驱动治理全景概览

public struct PrinterDriverSummary: Equatable {
    public var items: [PrinterDriverItem]
    public var totalSize: Int64
    public var orphanCount: Int
    public var orphanSize: Int64
    public var activeCount: Int
    /// CUPS 证据是否读到了。false 时卡片必须显示降级说明，且没有任何条目会被默认勾选。
    public var cupsEvidenceReadable: Bool
    /// 因证据不足而降级的条目数
    public var needsConfirmationCount: Int
    /// 读不到的证据源（卡片顶栏点名）
    public var unreadableSources: [String]

    public init(
        items: [PrinterDriverItem] = [],
        totalSize: Int64 = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        activeCount: Int = 0,
        cupsEvidenceReadable: Bool = true,
        needsConfirmationCount: Int = 0,
        unreadableSources: [String] = []
    ) {
        self.items = items
        self.totalSize = totalSize
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.activeCount = activeCount
        self.cupsEvidenceReadable = cupsEvidenceReadable
        self.needsConfirmationCount = needsConfirmationCount
        self.unreadableSources = unreadableSources
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
