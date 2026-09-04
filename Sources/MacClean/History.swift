import Foundation

// MARK: - 清理历史记录（借鉴 Mole `mo history`）

struct CleanRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var categoryName: String
    var itemCount: Int
    var bytes: Int64
    var mode: String        // 废纸篓 / 彻底删除
    var failures: Int
}

enum HistoryStore {
    /// 测试注入用：置为非 nil 时读写该路径（自检不碰真实历史）
    static var fileURLOverride: URL?

    static var fileURL: URL {
        if let override = fileURLOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MacClean", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func load() -> [CleanRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CleanRecord].self, from: data)) ?? []
    }

    static func save(_ records: [CleanRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - 导航目的地

enum Destination: Hashable, Identifiable {
    case dashboard
    case category(CleanCategory)
    case uninstaller
    case history
    case search

    var id: String {
        switch self {
        case .dashboard: return "dashboard"
        case .category(let c): return "category-\(c.rawValue)"
        case .uninstaller: return "uninstaller"
        case .history: return "history"
        case .search: return "search"
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
    let risk: RiskLevel?

    static func from(item: CleanItem) -> SearchResult {
        SearchResult(id: "item-\(item.category.rawValue)-\(item.id.uuidString)",
                     kind: .item(item.category), name: item.name,
                     subtitle: item.path, size: item.size, risk: item.risk)
    }

    static func from(record: CleanRecord) -> SearchResult {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return SearchResult(id: "history-\(record.id.uuidString)",
                            kind: .history(record), name: record.categoryName,
                            subtitle: f.string(from: record.date) + " · \(record.mode)",
                            size: record.bytes, risk: nil)
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
