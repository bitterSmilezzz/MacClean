import Foundation

// MARK: - 打印机驱动与 PPD 文件类型枚举 (v1.71.0)

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

public enum PrinterDriverStatus: String, Codable, CaseIterable, Identifiable {
    case activeConfigured = "当前在用配置 (受保护)"
    case orphanUnused = "未连接/废弃驱动 (建议清理)"
    case corrupted = "损坏配置 (建议清理)"
    case systemProtected = "系统核心组件 (受保护)"

    public var id: String { rawValue }

    public var isOrphanOrCorrupted: Bool {
        self == .orphanUnused || self == .corrupted
    }
}

// MARK: - 打印机驱动条目数据模型

public struct PrinterDriverItem: Identifiable, Equatable, Hashable {
    public let id: String                     // 绝对路径
    public let name: String                   // 显示名称
    public let vendor: String                 // 驱动厂商 (HP, Canon, Epson 等)
    public let path: String                   // 绝对路径
    public let kind: PrinterDriverKind        // 分类
    public let status: PrinterDriverStatus    // 状态
    public let size: Int64                    // 占用字节
    public let fileCount: Int                 // 包含文件数
    public let modificationDate: Date         // 修改时间
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
        self.isSelected = isSelected
    }
}

// MARK: - 打印机驱动治理全景概览

public struct PrinterDriverSummary: Equatable {
    public var items: [PrinterDriverItem]
    public var totalSize: Int64
    public var orphanCount: Int
    public var orphanSize: Int64
    public var activeCount: Int

    public init(
        items: [PrinterDriverItem] = [],
        totalSize: Int64 = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        activeCount: Int = 0
    ) {
        self.items = items
        self.totalSize = totalSize
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.activeCount = activeCount
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
