import Foundation

// MARK: - 系统音频 HAL 驱动与插件类型枚举 (v1.70.0，v1.72.0 安全加固)

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

// v1.72.0 新增 `unknownNeedsConfirmation`：真机 `/Library/Audio/Plug-Ins/HAL` 里的
// BlackHole、Steam Streaming、ParrotAudioPlugin 都是 pkg 安装、**没有对应 .app**，
// 旧判据（bundle id 是否等于某个已安装 App）把它们全部误判成孤儿并默认勾选。
// 现在证据不足必须落到这个状态：不是孤儿、不是损坏、永不进默认可删集合。
public enum AudioPluginStatus: String, Codable, CaseIterable, Identifiable {
    case activeInUse = "活跃在用 (受保护)"
    case orphanResidue = "已卸载应用残存 (建议清理)"
    case corrupted = "损坏驱动 (建议清理)"
    case appleOfficial = "Apple 官方核心 (受保护)"
    case unknownNeedsConfirmation = "证据不足 (需人工确认)"

    public var id: String { rawValue }

    public var isOrphanOrCorrupted: Bool {
        self == .orphanResidue || self == .corrupted
    }

    /// 有明确在用/受保护证据
    public var isInUseOrProtected: Bool {
        self == .activeInUse || self == .appleOfficial
    }
}

// MARK: - 真实音频设备证据（CoreAudio）

/// 「这台机器此刻到底有哪些音频驱动在跑」的证据 + 可信度。
///
/// 两条采集路径：
/// ① CoreAudio：`kAudioHardwarePropertyDevices`（设备名/UID/厂商）与
///    `kAudioHardwarePropertyPlugInList` + `kAudioPlugInPropertyBundleID`
///    （coreaudiod **实际加载的 HAL 插件 bundle id**）——已在本机实测编译与运行；
/// ② `system_profiler SPAudioDataType -json`（只有设备名，拿不到插件 bundle id）
///    → `pluginsReadable == false`，因此它只能证明"在用"，**不足以证明"孤儿"**。
public struct AudioDeviceEvidence: Equatable {
    /// coreaudiod 已加载的 HAL 插件标识（已做小写/去扩展名归一化）
    public let loadedPluginKeys: Set<String>
    /// 全部音频设备的名称/UID/厂商 token（已小写、已过滤停用词）
    public let deviceTokens: Set<String>
    /// 默认输出设备的名称/UID token
    public let defaultOutputTokens: Set<String>
    /// 插件清单是否读到了（false 时不得据"未加载"就判孤儿）
    public let pluginsReadable: Bool
    /// 设备清单是否读到了
    public let devicesReadable: Bool
    /// 采集来源："coreaudio" / "system_profiler" / "none"
    public let source: String
    /// 采集失败的中文原因
    public let failureNote: String?

    public init(loadedPluginKeys: Set<String>, deviceTokens: Set<String>,
                defaultOutputTokens: Set<String>, pluginsReadable: Bool,
                devicesReadable: Bool, source: String, failureNote: String? = nil) {
        self.loadedPluginKeys = loadedPluginKeys
        self.deviceTokens = deviceTokens
        self.defaultOutputTokens = defaultOutputTokens
        self.pluginsReadable = pluginsReadable
        self.devicesReadable = devicesReadable
        self.source = source
        self.failureNote = failureNote
    }

    /// 两条清单都读到，才允许得出"未被加载 → 孤儿"的结论
    public var isFullyReadable: Bool { pluginsReadable && devicesReadable }

    /// 完全读不到（CoreAudio 与 system_profiler 都失败时的降级起点）
    public static let unreadable = AudioDeviceEvidence(
        loadedPluginKeys: [], deviceTokens: [], defaultOutputTokens: [],
        pluginsReadable: false, devicesReadable: false, source: "none",
        failureNote: "无法枚举系统音频设备与已加载驱动")
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
    /// 判定依据 / 降级原因（中文，卡片如实展示）
    public let evidenceNote: String?
    /// 该条目归属的治理域 id（卡片与网关之间传递；nil = 主目录内）
    public let domainID: String?
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
        evidenceNote: String? = nil,
        domainID: String? = nil,
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
        self.evidenceNote = evidenceNote
        self.domainID = domainID
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
    /// 真实音频设备证据是否读全了。false 时卡片必须说明"仅提供定位与建议"。
    public var evidenceReadable: Bool
    /// 证据采集来源（"coreaudio" / "system_profiler" / "none"）
    public var evidenceSource: String
    /// 因证据不足而降级的条目数
    public var needsConfirmationCount: Int
    /// 采集失败原因
    public var evidenceFailure: String?

    public init(
        items: [AudioPluginItem] = [],
        totalSize: Int64 = 0,
        orphanCount: Int = 0,
        orphanSize: Int64 = 0,
        activeCount: Int = 0,
        evidenceReadable: Bool = true,
        evidenceSource: String = "coreaudio",
        needsConfirmationCount: Int = 0,
        evidenceFailure: String? = nil
    ) {
        self.items = items
        self.totalSize = totalSize
        self.orphanCount = orphanCount
        self.orphanSize = orphanSize
        self.activeCount = activeCount
        self.evidenceReadable = evidenceReadable
        self.evidenceSource = evidenceSource
        self.needsConfirmationCount = needsConfirmationCount
        self.evidenceFailure = evidenceFailure
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
