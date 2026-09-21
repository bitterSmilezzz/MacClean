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

    static func save(_ records: [CleanRecord]) {
        let bounded = Array(records.prefix(recordLimit))
        guard let data = try? JSONEncoder().encode(bounded) else { return }
        try? data.write(to: fileURL, options: .atomic)
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
