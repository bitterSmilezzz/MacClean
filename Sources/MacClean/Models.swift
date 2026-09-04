import Foundation

// MARK: - 风险级别（对应 CLEANUP-RULES.md G4）

enum RiskLevel: String, Codable {
    case safe    // 缓存/日志，可重建
    case review  // 残留/大文件，需人眼确认
    case danger  // 不可恢复/可能有用

    var label: String {
        switch self {
        case .safe: return "安全"
        case .review: return "谨慎"
        case .danger: return "危险"
        }
    }
}

// MARK: - 清理分类（对应 CLEANUP-RULES.md 第 1-6 章）

enum CleanCategory: String, CaseIterable, Identifiable, Codable {
    case userCaches
    case logsAndTemp
    case devResidue
    case appResidue
    case largeFiles
    case browserAndSystem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .userCaches: return "用户缓存"
        case .logsAndTemp: return "日志与临时文件"
        case .devResidue: return "开发残留"
        case .appResidue: return "App 残留"
        case .largeFiles: return "大文件与垃圾箱"
        case .browserAndSystem: return "浏览器与系统数据"
        }
    }

    var subtitle: String {
        switch self {
        case .userCaches: return "应用可重建的缓存文件"
        case .logsAndTemp: return "日志、崩溃报告与临时文件"
        case .devResidue: return "DerivedData 与包管理器缓存"
        case .appResidue: return "已卸载应用的遗留数据"
        case .largeFiles: return "垃圾箱、旧下载与超大文件"
        case .browserAndSystem: return "浏览器缓存与站点数据"
        }
    }

    var icon: String {
        switch self {
        case .userCaches: return "archivebox"
        case .logsAndTemp: return "doc.text"
        case .devResidue: return "hammer"
        case .appResidue: return "shippingbox"
        case .largeFiles: return "externaldrive"
        case .browserAndSystem: return "globe"
        }
    }

    var ruleRef: String {
        switch self {
        case .userCaches: return "C1–C6"
        case .logsAndTemp: return "L1–L5"
        case .devResidue: return "D1–D12"
        case .appResidue: return "A1–A4"
        case .largeFiles: return "T1–T5"
        case .browserAndSystem: return "B1–B4"
        }
    }
}

// MARK: - 使用频率（用户诉求：判断"是否最近在频繁使用"，决定值不值得删）

enum UsageLevel: Int, Codable {
    case active       // 7 天内使用过：频繁使用中
    case recent       // 30 天内使用过：近期使用
    case occasional   // 90 天内使用过：偶尔使用
    case dormant      // 超过 90 天未用：长期未用
    case unknown      // 无法判定

    var label: String {
        switch self {
        case .active: return "频繁使用中"
        case .recent: return "近期使用"
        case .occasional: return "偶尔使用"
        case .dormant: return "长期未用"
        case .unknown: return "使用情况未知"
        }
    }

    /// 是否属于"最近在用"（active/recent）——清理时应提示/确认
    var isRecentlyUsed: Bool {
        self == .active || self == .recent
    }
}

// MARK: - 清理项

struct CleanItem: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// 主路径（展示用）
    let path: String
    /// 实际要清理的全部路径（默认 [path]）
    let paths: [String]
    let size: Int64
    var risk: RiskLevel
    let category: CleanCategory
    let note: String
    /// 已在废纸篓内的项：清理 = 彻底删除（无法再移入废纸篓）
    let permanentDelete: Bool
    /// 最近使用时间（扫描时标注；无则 nil）
    var lastUsed: Date?
    /// 使用频率（扫描时标注）
    var usage: UsageLevel = .unknown
    /// 用户勾选（默认不勾选，遵守 G2）
    var isSelected: Bool = false

    init(name: String, path: String, paths: [String]? = nil, size: Int64, risk: RiskLevel,
         category: CleanCategory, note: String = "", permanentDelete: Bool = false,
         lastUsed: Date? = nil, usage: UsageLevel = .unknown) {
        self.name = name
        self.path = path
        self.paths = paths ?? [path]
        self.size = size
        self.risk = risk
        self.category = category
        self.note = note
        self.permanentDelete = permanentDelete
        self.lastUsed = lastUsed
        self.usage = usage
    }
}

// MARK: - 分类扫描状态

final class CategoryState: ObservableObject, Identifiable {
    let category: CleanCategory
    @Published var items: [CleanItem] = []
    @Published var isScanned = false
    @Published var isScanning = false
    @Published var lastError: String?
    @Published var releasedBytes: Int64 = 0

    var id: CleanCategory { category }

    init(category: CleanCategory) {
        self.category = category
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    var selectedCount: Int { items.filter { $0.isSelected }.count }
    var selectedSize: Int64 { items.filter { $0.isSelected }.reduce(0) { $0 + $1.size } }
    var allSelected: Bool { !items.isEmpty && items.allSatisfy { $0.isSelected } }

    func setSelected(_ itemID: UUID, _ selected: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        var newItems = items
        newItems[idx].isSelected = selected
        items = newItems   // 整体赋值才能触发 @Published
    }

    func setAllSelected(_ selected: Bool) {
        items = items.map { item in
            var copy = item
            copy.isSelected = selected
            return copy
        }
    }

    var selectedItems: [CleanItem] { items.filter { $0.isSelected } }
}

// MARK: - 字节格式化

extension Int64 {
    var byteString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }

    /// 中文友好格式（避免 "Zero KB" 英文混排；与 macOS 一致采用十进制 1GB=10^9）
    var byteStringCN: String {
        let v = Double(self)
        let units: [(Double, String)] = [(1_000_000_000_000, "TB"), (1_000_000_000, "GB"), (1_000_000, "MB"), (1_000, "KB")]
        for (factor, unit) in units where abs(v) >= factor {
            let val = v / factor
            if val >= 100 {
                return String(format: "%.0f %@", val, unit)
            }
            // 整数时省略小数（5.0 MB → 5 MB）
            if val == val.rounded() {
                return String(format: "%.0f %@", val, unit)
            }
            return String(format: "%.1f %@", val, unit)
        }
        if v == 0 { return "0 KB" }
        return String(format: "%.0f B", v)
    }
}

// MARK: - 日期工具（最近使用时间展示，UI 与 AI 上下文共用）

extension Date {
    /// 最近使用时间格式化（"2026-09-01 14:30"）
    static let usageFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// 相对时间描述（"刚刚" / "3 小时前" / "3 天前" / "2 个月前" / "1 年前"）
    var relativeUsage: String {
        let interval = Date().timeIntervalSince(self)
        let day: TimeInterval = 86400
        if interval < 3600 { return "刚刚" }
        if interval < day { return "\(Int(interval / 3600)) 小时前" }
        if interval < 30 * day { return "\(Int(interval / day)) 天前" }
        if interval < 365 * day { return "\(Int(interval / (30 * day))) 个月前" }
        return "\(Int(interval / (365 * day))) 年前"
    }
}
