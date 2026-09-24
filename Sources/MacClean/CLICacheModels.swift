import Foundation

// MARK: - 命令行开发工具类型定义

public enum CLIToolKind: String, Codable, CaseIterable, Identifiable {
    case homebrew = "Homebrew 缓存"
    case npm = "npm 缓存"
    case pnpm = "pnpm 存储与缓存"
    case yarn = "Yarn 缓存"
    case cocoapods = "CocoaPods 缓存"
    case cargo = "Cargo (Rust) 缓存"
    case pip = "pip (Python) 缓存"
    case gradle = "Gradle 缓存"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .homebrew: return "shippingbox.fill"
        case .npm: return "cube.box.fill"
        case .pnpm: return "cube.transparent.fill"
        case .yarn: return "circle.grid.cross.fill"
        case .cocoapods: return "leaf.fill"
        case .cargo: return "gearshape.2.fill"
        case .pip: return "terminal.fill"
        case .gradle: return "ant.fill"
        }
    }

    /// 各工具在 macOS 上的典型缓存路径列表（带波浪号）
    ///
    /// **只登记精确缓存子路径，一律不带"工具目录兜底根"**（v1.73.0 判据修复）。
    /// 旧版 `.npm` 的列表是 `["~/.npm/_cacache", "~/.npm"]`：本机 `~/.npm` 下确实没有
    /// `_cacache`（只有 `_logs`、`_npx`、`_prebuilds` 与安装期状态），于是命中兜底根，
    /// 而 `clean` 会把兜底根的**全部子项逐个删掉**。现在找不到精确路径就报
    /// "该工具缓存位置未识别"，由用户按 `commandSuggestion` 用官方命令清理。
    public var typicalPaths: [String] {
        switch self {
        case .homebrew:
            return ["~/Library/Caches/Homebrew"]
        case .npm:
            return ["~/.npm/_cacache"]
        case .pnpm:
            return ["~/Library/Caches/pnpm", "~/.local/share/pnpm/store"]
        case .yarn:
            return ["~/Library/Caches/Yarn", "~/.yarn/berry/cache", "~/.yarn/cache"]
        case .cocoapods:
            return ["~/Library/Caches/CocoaPods"]
        case .cargo:
            return ["~/.cargo/registry/cache"]
        case .pip:
            return ["~/Library/Caches/pip"]
        case .gradle:
            return ["~/.gradle/caches"]
        }
    }

    /// 该工具"数据根"里可能混有配置与状态的目录名（点号目录）：
    /// 命中即**绝不允许**作为缓存根被清空。
    public var toolDataRoots: [String] {
        switch self {
        case .homebrew: return []
        case .npm: return ["~/.npm"]
        case .pnpm: return ["~/.local/share/pnpm"]
        case .yarn: return ["~/.yarn"]
        case .cocoapods: return []
        case .cargo: return ["~/.cargo"]
        case .pip: return []
        case .gradle: return ["~/.gradle"]
        }
    }

    /// 官方推荐的 CLI 清理命令建议
    public var commandSuggestion: String {
        switch self {
        case .homebrew: return "brew cleanup --prune=all"
        case .npm: return "npm cache clean --force"
        case .pnpm: return "pnpm store prune"
        case .yarn: return "yarn cache clean"
        case .cocoapods: return "pod cache clean --all"
        case .cargo: return "cargo cache -a"
        case .pip: return "pip cache purge"
        case .gradle: return "rm -rf ~/.gradle/caches"
        }
    }
}

// MARK: - 命令行缓存条目数据模型

public struct CLICacheItem: Identifiable, Equatable, Hashable {
    public let id: String                 // 文件绝对路径
    public let toolKind: CLIToolKind      // 工具类型
    public let title: String              // 显示名称
    public let path: String               // 绝对路径
    public let size: Int64                // 缓存占用字节
    public let fileCount: Int             // 包含的文件数量
    /// 本次遍历是否完整。false = 被权限掐断过，`size` 是"至少这么多"而不是"就这么大"。
    /// 卡片的全选按钮**必须**按这个字段过滤，否则残缺项会被用户一次点击重新默认勾上——
    /// v1.73.7 复审 P1-1 抓到的正是这条：`scan()` 阶段把 `isSelected` 关到 `readable` 上，
    /// 但 `selectAll(true)` 里裸 `for i in … { items[i].isSelected = true }` 会把它翻回来。
    public let readable: Bool
    public var isSelected: Bool           // 是否勾选清理

    /// `isSelected` 的默认值是 `false`——默认勾选是安全策略，不该由"忘了传"这种
    /// 编译期过得去的形状悄悄打开（v1.73.7 复审 P1-3）。任何调用方要默认勾选都必须
    /// 显式写出 `isSelected: readable`（或 `isSelected: readable && …`），
    /// 让 lint 能钉住"这个 true 是从 readable 来的"这条链。
    public init(
        id: String,
        toolKind: CLIToolKind,
        title: String,
        path: String,
        size: Int64,
        fileCount: Int,
        readable: Bool = true,
        isSelected: Bool = false
    ) {
        self.id = id
        self.toolKind = toolKind
        self.title = title
        self.path = path
        self.size = size
        self.fileCount = fileCount
        self.readable = readable
        self.isSelected = isSelected
    }
}

// MARK: - 命令行缓存概览

public struct CLICacheSummary: Equatable {
    public var items: [CLICacheItem]
    public var totalSize: Int64
    public var toolCount: Int
    /// 扫不到**精确**缓存路径的工具：卡片必须如实说"该工具缓存位置未识别"，
    /// 而不是悄悄退回到删工具目录（v1.73.0）。
    public var unrecognizedTools: [CLIToolKind]
    /// 本轮**认得出**但**读不到**（枚举器 nil）的路径。v1.73.7 二次复审 P1-D：
    /// 只把残缺项的 `isSelected` 关掉、又让 `matched = true` 短路掉 unrecognizedTools，
    /// 结果就是"三无状态"——面板既没列这一项、也没亮未识别、也没报残缺。
    /// 这条通道给卡片顶栏用："本轮 X 处缓存读不到，下面的列表不完整"。
    public var unreadablePaths: [String]

    public init(
        items: [CLICacheItem] = [],
        totalSize: Int64 = 0,
        toolCount: Int = 0,
        unrecognizedTools: [CLIToolKind] = [],
        unreadablePaths: [String] = []
    ) {
        self.items = items
        self.totalSize = totalSize
        self.toolCount = toolCount
        self.unrecognizedTools = unrecognizedTools
        self.unreadablePaths = unreadablePaths
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
