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
    case category(CleanCategory)
    case uninstaller
    case history

    var id: String {
        switch self {
        case .category(let c): return "category-\(c.rawValue)"
        case .uninstaller: return "uninstaller"
        case .history: return "history"
        }
    }
}
