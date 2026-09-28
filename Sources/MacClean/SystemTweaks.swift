import Foundation

// MARK: - 系统使用体验优化：目录与值模型
//
// ## 为什么这块不能复用"清理"那条链路
//
// 这个应用此前的副作用只有一种：**删文件**，且全部走统一删除网关
// （治理域 + SIP 护栏 + 白名单 + 软链防跳板 + 撤销快照）。
//
// "改系统偏好"是**另一种副作用**：它不删任何东西，却改变你每天看到和摸到的行为，
// 而且改错了同样难受——把按键重复调到 1，输入法选字基本没法用；
// 把访达搜索范围改错，找文件反而更慢。
//
// 所以它有自己的链路，但规矩与清理链路是**同一套价值观**：
//   ① **先读再谈改**：`defaults read` 拿到现状才谈建议；读不到就说"读不到"，
//      不许把"没看到"当成"没设过"；
//   ② **能改就要能还原**：写之前把旧值（含"原本没设过"）落进撤销记录。
//      "原本没设过"必须还原成**删除该键**，而不是写一个看起来像默认值的数——
//      那等于伪造历史；
//   ③ **没有"一键优化全部"**：每一条你自己决定，工具不批量替你改系统；
//   ④ **如实说要重启什么**：Dock / Finder / 系统界面服务各不相同，
//      不说清用户会以为"改了没用"，然后怀疑整个工具。

/// 偏好值的类型。决定怎么解析 `defaults read` 的输出、怎么拼 `defaults write` 的参数。
enum TweakKind: String, Codable {
    case bool, int, string
}

/// 一个偏好键的值。
///
/// `.unset` 是**一等公民**：`defaults` 里"这个键不存在"与"这个键等于 0"是两个不同状态，
/// 还原时一个要删键、一个要写回原值。把它们混成一个"默认值"，撤销就是假的。
enum TweakValue: Equatable, Codable {
    case bool(Bool)
    case int(Int)
    case string(String)
    /// 该键当前**不存在**。
    case unset

    /// `defaults read` 的输出 → 值。`nil` = 解析不了（当作读失败，**不许猜**）。
    static func parse(raw: String, kind: TweakKind) -> TweakValue? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case .bool:
            // `defaults read` 对布尔键实际返回 0/1，但 `-bool true` 写进去再读，
            // 不同 macOS 版本可能回 true/false。两种都认。
            switch trimmed.lowercased() {
            case "1", "true", "yes": return .bool(true)
            case "0", "false", "no": return .bool(false)
            default: return nil
            }
        case .int:
            return Int(trimmed).map { .int($0) }
        case .string:
            // `defaults read` 对字符串可能带引号
            let unquoted = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return unquoted.isEmpty ? nil : .string(unquoted)
        }
    }

    /// `defaults write <domain> <key>` 后面要跟的参数。
    /// `.unset` 没有可写的形式——它对应的是 `defaults delete`。
    var writeArguments: [String] {
        switch self {
        case .bool(let v): return ["-bool", v ? "true" : "false"]
        case .int(let v): return ["-int", String(v)]
        case .string(let v): return ["-string", v]
        case .unset: return []
        }
    }

    /// 给人看的一句话。**"未设置"与"等于 0"必须长得不一样。**
    var display: String {
        switch self {
        case .bool(let v): return v ? "开" : "关"
        case .int(let v): return String(v)
        case .string(let v): return v
        case .unset: return "未设置（跟随系统默认）"
        }
    }
}

/// 优化项分组。
enum SystemTweakGroup: String, CaseIterable, Codable {
    case dock, finder, screenshot, keyboard

    var title: String {
        switch self {
        case .dock: return "程序坞"
        case .finder: return "访达"
        case .screenshot: return "截图"
        case .keyboard: return "键盘"
        }
    }
}

/// 一条优化项。
///
/// **每条都要写清"收益"和"代价"**：只说收益、不说代价的建议，用户凭什么信？
struct SystemTweak: Identifiable, Equatable {
    let id: String
    let group: SystemTweakGroup
    let title: String
    /// 改了之后体验上的**具体**收益（不写"提升效率"这种废话）
    let benefit: String
    /// 诚实的代价 / 影响；确实没有就写"无副作用"
    let tradeoff: String
    let domain: String
    let key: String
    let kind: TweakKind
    let recommended: TweakValue
    /// 改完要重启哪个进程才生效；`nil` = 立即生效（或由系统下次读取时生效）
    let restartProcess: String?
    /// 是否需要重新登录才完全生效（部分 App 只在启动时读一次偏好）
    let needsRelogin: Bool

    /// `defaults read <domain> <key>` 的完整参数，供自检断言"读的到底是哪个键"。
    var readArguments: [String] { ["read", domain, key] }
}

extension SystemTweak {
    /// 优化项目录。
    ///
    /// 收录标准只有三条，**三条全中才收**：
    ///  ① **用户域**：不需要管理员权限，不动 `/Library`，不碰 SIP 保护的东西；
    ///  ② **可逆**：写回旧值、或删掉键，就能回到原样；没有"删了就没了"的语义；
    ///  ③ **收益可一句话说清**：不是"据说更快"，而是能讲明白改了会怎样、代价是什么。
    ///
    /// 刻意**没有**收录的（留给"空间审计/风险提醒"那类只读面板，不进这里）：
    /// 需要 root 的（`pmset`、`scutil` 系统级 DNS）、影响安全边界的（Gatekeeper、
    /// 文件保险箱、隐私授权）、以及"改坏了很难查"的（`LaunchServices` 注册表）。
    static let catalog: [SystemTweak] = [
        // ── 程序坞 ──
        SystemTweak(
            id: "dock.showRecents",
            group: .dock,
            title: "关掉程序坞里的「最近使用的应用」",
            benefit: "程序坞右侧不再堆一排自动变化的图标，你固定的那些图标位置不会自己挪动",
            tradeoff: "要打开刚用过的 App 得走启动台或聚焦搜索（Command+空格）",
            domain: "com.apple.dock", key: "show-recents", kind: .bool,
            recommended: .bool(false),
            restartProcess: "Dock", needsRelogin: false),

        SystemTweak(
            id: "dock.mineffect",
            group: .dock,
            title: "窗口最小化改用「缩放」动画",
            benefit: "缩放（scale）比默认的精灵（genie）特效帧数少得多，最小化/复原明显更跟手",
            tradeoff: "失去精灵动画那个「吸进程序坞」的观感",
            domain: "com.apple.dock", key: "mineffect", kind: .string,
            recommended: .string("scale"),
            restartProcess: "Dock", needsRelogin: false),

        // ── 访达 ──
        SystemTweak(
            id: "finder.showAllFiles",
            group: .finder,
            title: "访达里显示隐藏文件",
            benefit: "能直接看到 .git、.env、~/Library 这类隐藏项，开发和排查时不用来回按 Command+Shift+点",
            tradeoff: "文件列表里会多出不少系统文件，纯日常浏览时会显得嘈杂",
            domain: "com.apple.finder", key: "AppleShowAllFiles", kind: .bool,
            recommended: .bool(true),
            restartProcess: "Finder", needsRelogin: false),

        SystemTweak(
            id: "finder.showPathbar",
            group: .finder,
            title: "访达窗口显示路径栏",
            benefit: "窗口底部显示完整路径，一眼看清自己在哪一层，可以直接拖文件到路径上的某一级",
            tradeoff: "无副作用",
            domain: "com.apple.finder", key: "ShowPathbar", kind: .bool,
            recommended: .bool(true),
            restartProcess: "Finder", needsRelogin: false),

        SystemTweak(
            id: "finder.showStatusBar",
            group: .finder,
            title: "访达窗口显示状态栏",
            benefit: "底部显示当前文件夹的项目数量与磁盘可用空间，不用再开「显示简介」",
            tradeoff: "无副作用",
            domain: "com.apple.finder", key: "ShowStatusBar", kind: .bool,
            recommended: .bool(true),
            restartProcess: "Finder", needsRelogin: false),

        SystemTweak(
            id: "finder.foldersFirst",
            group: .finder,
            title: "文件夹始终排在文件前面",
            benefit: "列表视图里文件夹不再混在文件中间，长目录下找文件夹快很多",
            tradeoff: "无副作用",
            domain: "com.apple.finder", key: "_FXSortFoldersFirst", kind: .bool,
            recommended: .bool(true),
            restartProcess: "Finder", needsRelogin: false),

        SystemTweak(
            id: "finder.searchScope",
            group: .finder,
            title: "访达搜索默认搜「当前文件夹」",
            benefit: "默认搜当前文件夹而不是整台 Mac，结果又快又准（整盘搜索动辄几十秒且常搜到同名无关文件）",
            tradeoff: "想全盘搜索时要手动把搜索范围切回「这台 Mac」",
            domain: "com.apple.finder", key: "FXDefaultSearchScope", kind: .string,
            recommended: .string("SCcf"),
            restartProcess: "Finder", needsRelogin: false),

        // ── 截图 ──
        SystemTweak(
            id: "screenshot.noShadow",
            group: .screenshot,
            title: "窗口截图不带阴影",
            benefit: "截窗口时不再带那一圈大阴影，贴进文档、聊天、PPT 里都是干净的矩形",
            tradeoff: "需要阴影时可以在截图时按 Option 临时切换",
            domain: "com.apple.screencapture", key: "disable-shadow", kind: .bool,
            recommended: .bool(true),
            restartProcess: nil, needsRelogin: false),

        // ── 键盘 ──
        SystemTweak(
            id: "keyboard.keyRepeat",
            group: .keyboard,
            title: "加快按键重复速率",
            benefit: "按住方向键或字母时的重复更快（推荐 2；系统默认约 6），长按移动光标、连续删字更跟手",
            tradeoff: "调得过低（1）会让依赖长按的输入法选字变难，**2 是比较安全的下限**",
            domain: "NSGlobalDomain", key: "KeyRepeat", kind: .int,
            recommended: .int(2),
            restartProcess: nil, needsRelogin: true),

        SystemTweak(
            id: "keyboard.initialKeyRepeat",
            group: .keyboard,
            title: "缩短长按开始重复的等待",
            benefit: "按住键后开始连续重复的等待变短（推荐 15；系统默认约 25），长按退格删字更跟手",
            tradeoff: "无副作用（只影响开始重复前的延迟）",
            domain: "NSGlobalDomain", key: "InitialKeyRepeat", kind: .int,
            recommended: .int(15),
            restartProcess: nil, needsRelogin: true),

        SystemTweak(
            id: "keyboard.windowAnimations",
            group: .keyboard,
            title: "关闭窗口缩放动画",
            benefit: "打开/关闭窗口不再做缩放动画，窗口直接出现，整个系统感觉更利落",
            tradeoff: "少了动画的过渡感；这是动效偏好，完全看你个人口味",
            domain: "NSGlobalDomain", key: "NSAutomaticWindowAnimationsEnabled", kind: .bool,
            recommended: .bool(false),
            restartProcess: nil, needsRelogin: true),
    ]
}

/// 一条优化项的体检结论。
struct TweakFinding: Identifiable, Equatable {
    enum Status: Equatable {
        /// 已经是推荐值
        case alreadyOptimal
        /// 与推荐值不一致（**含"未设置"**——见 `status(current:recommended:)` 的说明）
        case deviates
        /// 读不到。既不能说它需要改，也不能说它没问题
        case unreadable
    }

    var id: String { tweak.id }
    let tweak: SystemTweak
    /// 读到的现状；`nil` = 读失败（不是"没设过"）
    let current: TweakValue?
    let status: Status

    /// 纯函数：现状 × 推荐 → 结论。抽出来是为了能穷举测试，不必碰真实系统。
    ///
    /// **"未设置"按"与推荐值不一致"处理**，理由要说明白：`defaults` 只告诉我们这个键
    /// 存不存在，不告诉我们各 App 编译进去的默认值是什么。所以工具**无法**断言
    /// "未设置就等于已经是推荐值"——只能如实呈现"未设置（跟随系统默认）"，
    /// 由用户判断。宁可多说一句，也不假装知道。
    static func status(current: TweakValue?, recommended: TweakValue) -> Status {
        guard let current else { return .unreadable }
        return current == recommended ? .alreadyOptimal : .deviates
    }
}
