import Foundation
import Combine

// MARK: - 风险级别（对应 CLEANUP-RULES.md G4）

// `RiskLevel(safe/review/danger)` 已删除：它是"手写等级 + 独立频率"双轴模型的产物，
// 两轴从不调和，必然产出「安全 + 频繁使用中」这种自相矛盾的标注。
// 现在由 ItemNature（删了会怎样）× UseState（此刻是否在用）合成唯一的 Recommendation。

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
        case .largeFiles: return "废纸篓"
        case .browserAndSystem: return "浏览器与系统数据"
        }
    }

    var subtitle: String {
        switch self {
        case .userCaches: return "应用可重建的缓存文件"
        case .logsAndTemp: return "日志、崩溃报告与临时文件"
        case .devResidue: return "DerivedData 与包管理器缓存"
        case .appResidue: return "已卸载应用的遗留数据"
        case .largeFiles: return "已被你丢进垃圾箱的内容（清理 = 彻底删除）"
        case .browserAndSystem: return "浏览器缓存与站点数据"
        }
    }

    var icon: String {
        switch self {
        case .userCaches: return "archivebox"
        case .logsAndTemp: return "doc.text"
        case .devResidue: return "hammer"
        case .appResidue: return "shippingbox"
        case .largeFiles: return "trash"
        case .browserAndSystem: return "globe"
        }
    }

    /// 本分类的规则编号区间（如 "C1–C7"）。
    /// v1.1：改为从 `CleanupRules` 动态派生，避免硬编码编号与规则源头失配
    /// （v1.0 曾出现 `B1–B4` 但实际只有 B1–B3 的幽灵规则）。
    /// v1.72.12：只算**清理页真的会列出**的规则——`auditOnly` 的规则（决策 D-3）
    /// 仍然登记在册（编号连续性由自检守住），但这一行是给用户看的"这页凭什么"，
    /// 写着一个本页永远不会出现的编号就是假。
    var ruleRef: String {
        let ids = CleanupRules.rules(in: self).filter { !$0.auditOnly }.map(\.id)
        guard let first = ids.first, let last = ids.last else { return "" }
        return first == last ? first : "\(first)–\(last)"
    }

}

// MARK: - 使用档位（用户诉求：判断"最近还在不在动"，决定值不值得删）
//
// 档位标签只说**量到的东西**。历史上这里叫"频繁使用中/偶尔使用"，可我们手上只有一个
// mtime——单次时间戳推不出"频率"。后果不是措辞不雅，而是用户不敢用：
// 同一行既写"使用:5 天前 · 频繁使用中"、又写"确定是垃圾"，两句互相打架，
// 唯一理性的反应是两个都不信（用户原话："很多标记高频使用中的文件还标记了安全，这种我都不敢删"）。

enum UsageLevel: Int, Codable {
    case active       // 7 天内有写入
    case recent       // 7–30 天
    case occasional   // 30–90 天
    case dormant      // 90 天以上
    case unknown      // 无法判定

    var label: String {
        switch self {
        case .active: return "7 天内有写入"
        case .recent: return "7–30 天内有写入"
        case .occasional: return "30–90 天内有写入"
        case .dormant: return "90 天以上无写入"
        case .unknown: return "写入时间未知"
        }
    }

    /// 是否属于"最近在用"（active/recent）——清理时应提示/确认
    var isRecentlyUsed: Bool {
        self == .active || self == .recent
    }
}

// MARK: - 项目本质：删了会发生什么
//
// 这是"规则自带"的属性，与用户何时用过它无关。
//
// 历史缺陷：早期只有一个 `RiskLevel(safe/review/danger)`，由每条规则**手写**，而且是在
// 构造 CleanItem 的那一刻就定死了；"使用频率"则是扫描全部结束后另起一遍 `annotateUsage`
// 盖上去的。两条轴各自独立、从不调和，于是结构性地必然出现
// `[安全] … 使用:12 天前 · 近期使用` 这种自相矛盾的标注——用户看到"安全"和"频繁使用中"
// 同时打在一个文件上，唯一理性的反应就是两个都不信，然后不敢用这个工具。
//
// 现在把"本质"与"占用状态"分开建模，再由**唯一一处**推导函数合成一个结论。

/// 删除这个项目会发生什么。这是"规则自带"的属性，与用户何时用过它无关。
enum ItemNature: String, Codable {
    /// 自动重建，用户无感（浏览器 Cache、pip/npm 缓存、Clang ModuleCache…）
    case losslessCache
    /// 需要重新编译/生成，有代价但没有数据损失（DerivedData、__pycache__）
    case rebuildable
    /// 用途已经完成的历史产物，且**判定依据是确定的**
    /// （已安装应用的旧安装包、已轮转的历史日志、更新完成后的残留）
    case staleArtifact
    /// **靠启发式推断**"应该已经没用了"，存在误判可能
    /// （从 opt 软链推断的 Homebrew 旧版本、从命名推断的废弃副本、系统临时目录）
    case inferredUnused
    /// 需要重新下载；下载完成前相关功能不可用（DRM 组件、TTS 引擎、语言包）
    case redownloadable
    /// 属于已卸载的应用
    case orphanedResidue
    /// 用户自己的文件（下载、文档、备份、照片）
    case userData
    /// 系统或厂商的关键组件，删除会破坏功能
    case systemCritical
}

// MARK: - 占用状态

/// 扫描时观测到的"当前是否在被使用"。这是**事实**，不是结论。
struct UseState: Equatable {
    /// 所属 App 此刻是否在运行
    var ownerIsRunning: Bool = false
    /// 所属 App 的显示名（用于文案；未知则 nil）
    var ownerName: String?
    /// 最近一次写入时间
    var lastUsed: Date?
    /// 由 lastUsed 推出的频率档
    var level: UsageLevel = .unknown
    /// 观测时刻（用于计算"刚刚"这类细粒度信号）
    var observedAt: Date = Date()

    static let unknown = UseState()

    /// "正在被写入"的时间窗。
    static let liveWindow: TimeInterval = 10 * 60

    /// 最近一次写入是否就发生在刚刚。
    ///
    /// 这是**不依赖名称匹配**的在用证据，用来兜住名称匹配的漏判：实测
    /// `~/Library/Application Support/Tabbit Browser/` 的目录名是英文，而运行中的 App
    /// 本地化名是「Tabbit浏览器」，两边对不上，光靠 bundle id / 显示名匹配会把它判成
    /// "没在用"；但"这个目录 3 分钟前刚被写过"这个事实不会骗人。
    var isBeingWrittenNow: Bool {
        guard let lastUsed else { return false }
        return observedAt.timeIntervalSince(lastUsed) < Self.liveWindow
    }

    /// 供文案使用的"刚刚"描述
    var liveEvidenceText: String {
        guard let lastUsed else { return "刚刚还有写入" }
        let secs = max(0, observedAt.timeIntervalSince(lastUsed))
        if secs < 60 { return "几秒前还有写入" }
        if secs < 3600 { return "\(Int(secs / 60)) 分钟前还有写入" }
        return "刚刚还有写入"
    }
}

// MARK: - 结论（用户唯一需要读懂的东西）

/// 处置结论。**一个项目只有一个结论**，由 `ItemNature` + `UseState` 合成。
///
/// 不变量（由 `CleanItem.deriveRecommendation` 保证，并有 Selftest 锁住）：
/// **`.safe` 蕴含"所属 App 未在运行"**。也就是说，界面上永远不会再出现
/// 「可清理」和「频繁使用中」同时打在一个项目上的情况。
struct Recommendation: Equatable {
    enum Kind: String, Codable {
        /// 有 OS 契约或结构标记背书的确定垃圾（规则 v2 的 T0 档）。
        /// 与 `safe` 的区别不是"更安全"——两者都可放心删——而是**依据的来源不同**：
        /// `garbage` 的依据是 Apple 目录契约 / 工具自身 prune 语义 / 文件系统结构标记，
        /// 换一台机器、换一个人依然成立；`safe` 只是"这类东西通常能重建"。
        /// 只有这一档将来允许默认勾选（v2 步骤 4）。
        case garbage
        /// 放心删：删了没有任何损失，且当前没在用
        case safe
        /// 能删，但现在别删：正在被使用，删了会立刻重建 / 需要重新下载
        case inUse
        /// 需要你自己判断
        case review
        /// 不建议删
        case keep
    }

    let kind: Kind
    /// 为什么是这个结论——一句话，直接展示给用户
    let reason: String

    var label: String {
        switch kind {
        case .garbage: return "确定是垃圾"
        case .safe: return "可清理"
        case .inUse: return "使用中"
        case .review: return "需确认"
        case .keep: return "勿删"
        }
    }

    /// `garbage` 当然是安全的：它是 `safe` 里"依据最硬"的那一子集。
    var isSafe: Bool { kind == .safe || kind == .garbage }
    /// 是否应当阻止"一键全选"勾中它
    var blocksBulkSelection: Bool { !isSafe }
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
    /// 项目本质（规则自带）
    let nature: ItemNature
    /// 删除后果的一句话描述（规则自带，展示给用户）
    let consequence: String
    let category: CleanCategory
    let note: String
    /// 已在废纸篓内的项：清理 = 彻底删除（无法再移入废纸篓）
    let permanentDelete: Bool
    /// 占用状态（扫描时观测）
    var use: UseState = .unknown
    /// 触发的规则编号（若适用）
    let rule: String?
    /// 用户勾选（默认不勾选，遵守 G2）
    var isSelected: Bool = false

    init(name: String, path: String, paths: [String]? = nil, size: Int64, nature: ItemNature,
         consequence: String = "", category: CleanCategory, note: String = "",
         permanentDelete: Bool = false, use: UseState = .unknown, rule: String? = nil) {
        self.name = name
        self.path = path
        self.paths = paths ?? [path]
        self.size = size
        self.nature = nature
        self.consequence = consequence
        self.category = category
        self.note = note
        self.permanentDelete = permanentDelete
        self.use = use
        self.rule = rule
    }

    /// 最近使用时间（转发，兼容既有调用）
    var lastUsed: Date? { use.lastUsed }
    /// 使用频率（转发，兼容既有调用）
    var usage: UsageLevel { use.level }
    /// 修改或最近使用时间（优先取 lastUsed，若无则从文件系统按需查询）
    var modificationDate: Date? {
        if let lu = use.lastUsed { return lu }
        return FileSystem.modificationDate(path)
    }

    /// **唯一**的结论推导入口。
    ///
    /// 任何地方想知道"这个能不能删"，都必须走这里，不许自己拿 nature 或 usage 拼结论——
    /// 那正是历史上两条轴打架的成因。
    var recommendation: Recommendation {
        Self.deriveRecommendation(nature: nature, use: use, consequence: consequence, rule: rule)
    }

    /// - Parameters:
    ///   - nature: 删了会怎样（规则自带）
    ///   - use: 此刻的占用事实（扫描观测）
    ///   - consequence: 该规则自己的后果描述，用于向用户解释"删了会怎样"
    ///   - rule: 触发的规则编号；命中规则 v2 的 T0 档时，`safe` 会升级为 `garbage`
    static func deriveRecommendation(nature: ItemNature,
                                     use: UseState,
                                     consequence: String,
                                     rule: String? = nil) -> Recommendation {
        let owner = use.ownerName ?? "所属应用"
        let running = use.ownerIsRunning

        /// 运行时事实永远压过档位：宿主在跑、正在被写的项，绝不会被算成"确定是垃圾"。
        /// T0 只是"这类东西的依据够硬"，不是"现在就能删"。
        ///
        /// 档位同时负责**降级**——这才是用户真正抱怨的方向：`.gradle/caches`（D7）
        /// 在 v2 规格里是"需你裁决"，因为它要重下 GB 级依赖，而本机不做联网探测就无法
        /// 保证重建得了；可它 `nature` 是 `losslessCache`，旧引擎照样报"可清理"。
        /// 只升级不降级，等于新登记的档位是装饰品。
        func verdict(_ kind: Recommendation.Kind, _ why: String) -> Recommendation {
            var k = kind
            switch CleanupRules.tier(forRule: rule) {
            case .t0:
                if k == .safe {
                    k = .garbage
                    return Recommendation(kind: k, reason: why + promotionNote(rule))
                }
            case .t1, .none:
                break                       // 契约成立但重建有代价：维持"可清理"
            case .t2:
                if k == .safe || k == .garbage {
                    k = .review
                    return Recommendation(kind: k, reason: why + demotionNote(rule))
                }
            case .t3:
                if k != .inUse {
                    k = .keep
                    return Recommendation(kind: k, reason: why + demotionNote(rule))
                }
            }
            return Recommendation(kind: k, reason: why)
        }

        /// 升级同样要说清依据来自哪一条契约——「确定是垃圾」是界面上唯一将来会被
        /// 默认勾选的档，用户必须能一眼看到它凭什么这么硬。
        func promotionNote(_ id: String?) -> String {
            guard let rule = CleanupRules.rule(id: id) else { return "" }
            let basis: String
            switch rule.contract {
            case .appleCaches:   basis = "Apple 声明此位置由应用自行重建"
            case .userCacheDir:  basis = "Apple 明说系统不会自动清理此目录"
            case .tempDir:       basis = "超过 Apple 自己的 3 天临时文件阈值"
            case .toolPrune:     basis = "该工具自身的 prune 语义认定未被引用"
            case .namedPattern:  basis = "文件/目录名本身就是用途已完成的结构标记"
            case .userData:      basis = ""   // 不会到这：userData 进不了 T0（自检已锁）
            }
            return basis.isEmpty ? "" : "（确定是垃圾的依据：\(basis)）"
        }

        /// 降级必须说清"缺哪一维"，否则用户只看到结论变严，不知道依据变了什么。
        func demotionNote(_ id: String?) -> String {
            guard let rule = CleanupRules.rule(id: id) else { return "（依据不足，需你判断）" }
            let why: String
            switch rule.restore {
            case .autoExpensive: why = "重建要重下 GB 级内容，而本工具不探测网络可达性"
            case .stateLoss: why = "能重建但会丢状态（登录态、注册信息等）"
            case .impossible: why = "删了不可重建"
            case .none, .autoCheap:
                why = rule.contract == .userData ? "该位置语义上是用户数据" : "归属或宿主证据不足"
            }
            return "（降级依据：\(why)）"
        }

        switch nature {
        case .systemCritical:
            return verdict(.keep, consequence)

        case .userData, .orphanedResidue:
            return verdict(.review, consequence)

        case .redownloadable:
            // 删掉不是"重建缓存"，而是"功能暂时不可用，直到重新下载完"
            return verdict(.review, running ? "\(owner) 正在运行。\(consequence)" : consequence)

        case .staleArtifact:
            if running || use.isBeingWrittenNow {
                return Recommendation(
                    kind: .inUse,
                    reason: running
                        ? "\(owner) 正在运行；现在删除可能影响它，建议退出后再清理。\(consequence)"
                        : "\(use.liveEvidenceText)，说明仍在被使用。\(consequence)")
            }
            return verdict(.safe, consequence)

        case .inferredUnused:
            // "看起来没用了"是推断而非事实，所以永远不自动给安全结论
            if running {
                return Recommendation(kind: .inUse, reason: "\(owner) 正在运行。\(consequence)")
            }
            return verdict(.review, consequence)

        case .losslessCache:
            if running {
                return Recommendation(
                    kind: .inUse,
                    reason: "\(owner) 正在运行并使用此缓存；现在删除会立刻重建，建议退出 App 后再清理")
            }
            if use.isBeingWrittenNow {
                return Recommendation(
                    kind: .inUse,
                    reason: "\(use.liveEvidenceText)——有进程正在使用它；现在删除会立刻重建，建议稍后再清理")
            }
            return verdict(.safe, "\(consequence)（\(writeAgeText(use.level))）")

        case .rebuildable:
            // 重建有代价（重编译 / 重新生成），所以"最近还在动"也一并提示
            if running {
                return Recommendation(
                    kind: .inUse,
                    reason: "\(owner) 正在运行；现在删除会在下次使用时重新生成")
            }
            if use.isBeingWrittenNow {
                return Recommendation(
                    kind: .inUse,
                    reason: "\(use.liveEvidenceText)，说明正在被使用。\(consequence)")
            }
            if use.level == .active {
                return Recommendation(
                    kind: .inUse,
                    reason: "最近 7 天内还有写入，可能正在被使用。\(consequence)")
            }
            return verdict(.safe, "\(consequence)（\(writeAgeText(use.level))）")
        }
    }

    /// 把"最近写入时间"如实讲出来，取代历史上那个会与结论打架的频率徽标。
    private static func writeAgeText(_ level: UsageLevel) -> String {
        switch level {
        case .active: return "最近 7 天内有过写入"
        case .recent: return "最近 30 天内有过写入"
        case .occasional: return "超过 30 天没有写入"
        case .dormant: return "超过 90 天没有写入"
        case .unknown: return "无法判定最近写入时间"
        }
    }
}

/// 规则驱动的构造入口。
///
/// 扫描器一律走这里，**不要自己写 nature / consequence**：规则的唯一事实来源是
/// `CleanupRules`，一旦本质判定散落回扫描逻辑，就会重演"规则表说 safe、实现标 danger"
/// 的脱节（B4 那条错误规则就是这么来的）。
extension CleanItem {
    init(name: String, path: String, paths: [String]? = nil, size: Int64, rule: String,
         category: CleanCategory, note: String = "", permanentDelete: Bool = false,
         modificationDate: Date? = nil, use: UseState = .unknown) {
        let r = CleanupRules.rule(rule)
        var actualUse = use
        if let mtime = modificationDate, actualUse.lastUsed == nil {
            actualUse.lastUsed = mtime
        }
        // 规则编号写错时退到 .userData（→ 需确认）而不是 .losslessCache：
        // 失败要往"更保守"的方向倒，绝不能因为一个笔误把东西标成可安全删除。
        self.init(name: name, path: path, paths: paths, size: size,
                  nature: r?.nature ?? .userData,
                  consequence: r?.consequence ?? "",
                  category: category, note: note, permanentDelete: permanentDelete,
                  use: actualUse, rule: rule)
    }
}

// MARK: - 扫描诊断
//
// 为什么需要这一层：扫描器内部大量使用 `try?` 与 `errorHandler: { _, _ in true }`，
// 于是**"权限不足读不到"和"真的空"在结果上完全一样——都是 0 项**。
// 用户看到「大文件与垃圾箱：0 项」会读成"这里很干净"，而废纸篓里可能躺着几十 GB。
// `FileSystem.isPermissionDenied` / `hasFullDiskAccess` 本来就是为此写的，
// 但此前**从未被扫描链路调用过**（只在 FileSystem 内部定义）。
// 这个结构把"读不到"变成一条显式、可见、可解释的记录。

struct ScanIssue: Identifiable, Equatable {
    enum Kind: Equatable {
        /// 权限不足（通常是 TCC / 缺少「完全磁盘访问权限」）
        case permissionDenied
        /// 其他读取失败
        case unreadable
    }

    let id = UUID()
    let kind: Kind
    /// 出问题的路径
    let path: String
    /// 面向用户的一句话说明
    let message: String
    /// 补救建议（可空）
    let remedy: String?

    var icon: String {
        switch kind {
        case .permissionDenied: return "lock.fill"
        case .unreadable: return "exclamationmark.triangle.fill"
        }
    }
}

/// 一次分类扫描的完整结果。
struct ScanOutcome {
    var items: [CleanItem] = []
    /// 扫描过程中遇到的问题。非空即代表**结果不完整**，UI 必须如实说明。
    var issues: [ScanIssue] = []
    /// 只报告、不删除的项（规则 v2 步骤 7 / 决策 D-3）。
    ///
    /// 它们**不在** `items` 里：清理页的勾选框 + 「清理已选项」按钮是一种承诺，
    /// 而"这个文件 1.2 GB、半年没动"不构成"它可以删"。这些项改由「空间审计」呈现。
    var auditItems: [CleanItem] = []

    /// 结果是否完整可信（没有读不到的根目录）
    var isComplete: Bool { issues.isEmpty }
}

// MARK: - 分类扫描状态

final class CategoryState: ObservableObject, Identifiable {
    let category: CleanCategory
    @Published var items: [CleanItem] = []
    /// 本分类扫出的"只报告、不删除"项（决策 D-3）。放在分类上，
    /// 这样单独重扫一个分类只会替换它自己那一份，不会把别的分类的审计结果清掉。
    @Published var auditItems: [CleanItem] = []
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

    /// 无条件全选/全不选。**界面不要直接用这个方法**——它会把"不建议删除"的项也勾上。
    /// 界面上的"全选"请走 `selectAllSafe()`。
    func setAllSelected(_ selected: Bool) {
        items = items.map { item in
            var copy = item
            copy.isSelected = selected
            return copy
        }
    }

    /// 勾选所有结论为「可清理」的项。
    ///
    /// 这就是界面上"全选"应有的语义：**工具只替你勾它确认无损失的那些**。
    /// 历史行为是无条件勾选全部（含"使用中"与"不建议删除"），配合确认弹窗里一句泛泛的
    /// 警告，一次误点就能把 DRM 组件之类的东西送进废纸篓——这正是不敢用的来源。
    /// "使用中 / 需确认"档仍然可以整组勾选，但必须由用户在**读到该组说明之后**显式发起。
    func selectAllSafe() {
        items = items.map { item in
            var copy = item
            copy.isSelected = item.recommendation.isSafe
            return copy
        }
    }

    var selectedItems: [CleanItem] { items.filter { $0.isSelected } }

    /// 本次扫描遇到的问题（权限不足等）。非空时 UI 必须提示"结果可能不完整"，
    /// 否则用户会把"读不到"误读成"这里很干净"。
    var issues: [ScanIssue] = []
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
