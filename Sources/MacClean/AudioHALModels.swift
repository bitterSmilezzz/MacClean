import Foundation

// MARK: - 系统音频 HAL 驱动与插件类型枚举 (v1.70.0)

public enum AudioPluginKind: String, Codable, CaseIterable, Identifiable {
    case halDriver = "HAL 硬件抽象层音频驱动"
    case audioUnit = "AudioUnit 插件组件"
    case vstPlugin = "VST 效果器插件"
    case coreAudioCache = "CoreAudio 运行缓存"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .halDriver: return "speaker.wave.3.fill"
        case .audioUnit: return "waveform"
        case .vstPlugin: return "dial.low.fill"
        case .coreAudioCache: return "archivebox.fill"
        }
    }
}

// MARK: - 音频插件与驱动健康状态

public enum AudioPluginStatus: String, Codable, CaseIterable, Identifiable {
    case activeInUse = "活跃在用 (受保护)"
    case orphanResidue = "已卸载应用残存 (建议清理)"
    case corrupted = "损坏驱动 (建议清理)"
    case appleOfficial = "Apple 官方核心 (受保护)"

    public var id: String { rawValue }

    public var isOrphanOrCorrupted: Bool {
        self == .orphanResidue || self == .corrupted
    }
}

// MARK: - 音频驱动与插件条目数据模型

public struct AudioPluginItem: Identifiable, Equatable, Hashable {
    public let id: String                     // 绝对路径
    public let name: String                   // 显示名称
    public let path: String                   // 绝对路径
    public let kind: AudioPluginKind          // 分类
    public let status: AudioPluginStatus      // 状态
    public let bundleID: String?              // 插件 Bundle Identifier
    public let size: Int64                    // 占用字节
    public let fileCount: Int                 // 包含文件数
    public let modificationDate: Date         // 修改时间
    public var isSelected: Bool               // 是否勾选清理

    public init(
        id: String,
        name: String,
        path: String,
        kind: AudioPluginKind,
        status: AudioPluginStatus,
        bundleID: String? = nil,
        size: Int64,
        fileCount: Int = 1,
        modificationDate: Date,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.status = status
        self.bundleID = bundleID
        self.size = size
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.isSelected = isSelected
    }
}

// MARK: - 音频驱动治理全景概览

public struct AudioPluginSummary: Equatable {
    public var items: [AudioPluginItem]
    public var totalSize: Int64
    public var orphanCount: Int
    public var orphanSize: Int64
    public var activeCount: Int

    public init(
        items: [AudioPluginItem] = [],
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
