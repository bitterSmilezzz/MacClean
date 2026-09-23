import Foundation

// MARK: - 清理历史记录（借鉴 Mole `mo history`）

struct CleanRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var date: Date
    var categoryName: String
    var itemCount: Int
    var bytes: Int64
    var mode: String        // 废纸篓 / 彻底删除
    var failures: Int

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        categoryName: String,
        itemCount: Int,
        bytes: Int64,
        mode: String,
        failures: Int = 0
    ) {
        self.id = id
        self.date = date
        self.categoryName = categoryName
        self.itemCount = itemCount
        self.bytes = bytes
        self.mode = mode
        self.failures = failures
    }
}

enum HistoryStore {
    /// 测试注入用：置为非 nil 时读写该路径（自检不碰真实历史）
    static var fileURLOverride: URL?

    static var fileURL: URL {
        if let override = fileURLOverride { return override }
        // 落点统一由 MacCleanState 决定：自检/CI 设了 MACCLEAN_STATE_DIR 时不碰用户历史
        return MacCleanState.stateDirectory.appendingPathComponent("history.json")
    }

    /// 历史记录条数上限。
    ///
    /// 原先这个上限只写在 `AppState.recordClean` 里（`history.count > 200` 才截断），
    /// 而 `HistoryStore.save` 自己不设限。v1.72 之后写历史的入口多了好几个
    /// （统一删除网关、下载/截图归档、硬链接去重都直接 `HistoryStore.save`），
    /// 它们全都不经过 AppState → 磁盘上的 `history.json` 只增不减。
    /// 上限必须放在唯一的写入口上，而不是放在某个调用方里。
    static let recordLimit = 200

    static func load() -> [CleanRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        // 已经被写爆的老文件：读的时候就裁，下次 save 自然落回上限
        return (try? JSONDecoder().decode([CleanRecord].self, from: data)).map { Array($0.prefix(recordLimit)) } ?? []
    }

    /// 落盘。返回**是否真的写进去了**——`options: .atomic` 是"同目录建临时文件再 rename"，
    /// 所以它只看**状态目录**的写权限（实测：目录 0555 时失败并抛 NSCocoaError 513，
    /// 而单把文件改成只读仍然写得动）。
    @discardableResult
    private static func save(_ records: [CleanRecord]) -> Bool {
        let bounded = Array(records.prefix(recordLimit))
        guard let data = try? JSONEncoder().encode(bounded) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// `load → 改 → save` 是读改写，必须整段串行。
    /// 注意 `load`/`save` 自己**一把锁都没有**，单次写与整段读改写全靠这一把
    /// `transactionLock`——这也是 `save` 不对外开的原因。
    private static let transactionLock = NSLock()

    /// **变更历史的唯一入口**：原子的"读盘—改—落盘"，返回合并后的完整清单与写入是否成功。
    /// 生产代码不许再直接 `save`（`save` 已是 `private`，编译期就挡死；
    /// 一条源码不变量自检作为兜底）。
    @discardableResult
    private static func mutate(_ body: (inout [CleanRecord]) -> Void) -> (records: [CleanRecord], written: Bool) {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        var records = load()
        body(&records)
        let bounded = Array(records.prefix(recordLimit))
        return (bounded, save(bounded))
    }

    /// 追加一条历史，返回合并后的完整清单（调用方用它刷新内存缓存，
    /// 而不是往自己的缓存里插一条再整片写回）。
    ///
    /// **故意不回读磁盘**：写失败时返回值仍然含着刚记的那条与别的模块刚写的那些，
    /// 界面上那一行因此留着——用户看得见"清过了"。若改成回读，写失败时那一行会
    /// 从界面上凭空消失，等于把"没记账成功"报成"什么都没发生过"。
    @discardableResult
    static func append(_ record: CleanRecord) -> [CleanRecord] {
        mutate { $0.insert(record, at: 0) }.records
    }

    /// 清空历史，返回**盘上真的写掉了**没有。
    ///
    /// 为什么要返回值：`save` 过去是 `try? data.write`，失败无人知晓（真实成因见
    /// `save` 的注释：状态目录被 root 建过）。静默失败时若照样把内存列表清空，
    /// 界面显示"共 0 次清理"而盘上一条没少，下一次任何 `append` 又把整片旧历史
    /// 读回来"复活"——那是把"没做成"报成"已清空"。
    @discardableResult
    static func clear() -> Bool {
        mutate { $0 = [] }.written
    }

    /// 自检专用：整体替换（走同一把事务锁）。生产代码不许调用。
    static func replaceAllForSelftest(_ records: [CleanRecord]) {
        _ = mutate { $0 = records }
    }

    /// 统计最近 7 天的每日清理释放量（用于菜单栏迷你回收趋势）
    static func dailyFreedBytesLast7Days(records: [CleanRecord], relativeTo now: Date = Date()) -> [(dayLabel: String, bytes: Int64)] {
        let calendar = Calendar.current
        var result: [(dayLabel: String, bytes: Int64)] = []

        for i in (0..<7).reversed() {
            guard let targetDay = calendar.date(byAdding: .day, value: -i, to: now) else { continue }
            let dayStart = calendar.startOfDay(for: targetDay)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            let dayRecords = records.filter { $0.date >= dayStart && $0.date < dayEnd }
            let total = dayRecords.reduce(0) { $0 + $1.bytes }
            let label = i == 0 ? "今" : String(calendar.component(.day, from: targetDay))
            result.append((dayLabel: label, bytes: total))
        }
        return result
    }

    /// 统计最近 7 天累计释放总字节数
    static func totalFreedLast7Days(records: [CleanRecord], relativeTo now: Date = Date()) -> Int64 {
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        return records.filter { $0.date >= sevenDaysAgo }.reduce(0) { $0 + $1.bytes }
    }
}

// MARK: - 导航目的地

enum Destination: Hashable, Identifiable {
    case dashboard
    case category(CleanCategory)
    case uninstaller
    case history
    case search
    case riskCheck
    case duplicates
    case spaceTreemap
    /// 空间审计：只报告"很大/很久没动"的项（规则 v2 步骤 7 / 决策 D-3）。
    /// 与「空间透视」的分工：透视回答"空间被什么占了"，审计回答"哪些东西值得你自己看一眼"，
    /// 而**两者都不给删除按钮**——判据是大小和年龄时，工具没有资格替你决定删不删。
    case spaceAudit
    case startupItems

    var id: String {
        switch self {
        case .dashboard: return "dashboard"
        case .category(let c): return "category-\(c.rawValue)"
        case .uninstaller: return "uninstaller"
        case .history: return "history"
        case .search: return "search"
        case .riskCheck: return "riskCheck"
        case .duplicates: return "duplicates"
        case .spaceTreemap: return "spaceTreemap"
        case .spaceAudit: return "spaceAudit"
        case .startupItems: return "startupItems"
        }
    }
}

// MARK: - 全局搜索结果（检索跨分类 + 历史）

struct SearchResult: Identifiable, Equatable {
    enum Kind: Equatable {
        case item(CleanCategory)
        case history(CleanRecord)
    }

    let id: String
    let kind: Kind
    /// 展示名称
    let name: String
    /// 副标题（路径 / 时间）
    let subtitle: String
    /// 大小（history 也用，无则 0）
    let size: Int64
    /// 处置结论（唯一结论：可清理 / 使用中 / 需确认 / 勿删）。
    ///
    /// 直接取 `CleanItem.recommendation`，检索页不自行推导——历史上这里放的是手写的
    /// `RiskLevel`，与"使用频率"各说各话，正是"安全 + 近期使用"自相矛盾的来源之一。
    /// 历史记录（`CleanRecord`）不对应具体清理项，故为 nil。
    let recommendation: Recommendation?

    static func from(item: CleanItem) -> SearchResult {
        SearchResult(id: "item-\(item.category.rawValue)-\(item.id.uuidString)",
                     kind: .item(item.category), name: item.name,
                     subtitle: item.path, size: item.size,
                     recommendation: item.recommendation)
    }

    static func from(record: CleanRecord) -> SearchResult {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return SearchResult(id: "history-\(record.id.uuidString)",
                            kind: .history(record), name: record.categoryName,
                            subtitle: f.string(from: record.date) + " · \(record.mode)",
                            size: record.bytes, recommendation: nil)
    }
}

/// 全局检索：内存过滤已扫描项 + 历史（AppState.searchAllItems 由各分类状态聚合）
enum GlobalSearch {
    /// 大小写不敏感子串匹配（含路径）
    static func matches(_ query: String, _ text: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// 跨全部分类 + 历史检索，按大小降序，最多 200 条
    static func search(query: String, items: [CleanItem], history: [CleanRecord]) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results: [SearchResult] = []
        for item in items where matches(q, item.name) || matches(q, item.path) || matches(q, item.note) {
            results.append(.from(item: item))
        }
        for record in history where matches(q, record.categoryName) {
            results.append(.from(record: record))
        }
        return results.sorted { $0.size > $1.size }.prefix(200).map { $0 }
    }
}
