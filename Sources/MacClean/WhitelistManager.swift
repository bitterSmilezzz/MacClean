import Foundation
import Combine

/// 白名单规则类型
enum WhitelistType: String, Codable {
    case path        // 指定路径或文件夹前缀
    case appName     // 指定 App 名称
}

/// 单条白名单规则
struct WhitelistRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var pattern: String             // 路径（支持 ~）或 App 名称
    var comment: String             // 备注说明（如“开发项目源码”、“公司内网证书”等）
    var type: WhitelistType = .path
    var createdAt: Date = Date()

    /// 展开波浪号并标准化后的绝对路径（对于 path 类型）
    var standardPath: String {
        guard type == .path else { return pattern }
        return (CleanPaths.expand(pattern) as NSString).standardizingPath
    }
}

/// 白名单管理中心
final class WhitelistManager: ObservableObject {
    static let shared = WhitelistManager()

    @Published var rules: [WhitelistRule] = [] {
        didSet {
            save()
        }
    }

    private static let storageKey = "MacClean_UserWhitelistRules_v1"

    init() {
        self.rules = Self.load()
    }

    static func load() -> [WhitelistRule] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let items = try? JSONDecoder().decode([WhitelistRule].self, from: data) else {
            return []
        }
        return items
    }

    func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// 添加一条路径白名单
    @discardableResult
    func addPathRule(_ path: String, comment: String = "") -> WhitelistRule {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = rules.first(where: { $0.type == .path && $0.standardPath == (CleanPaths.expand(trimmed) as NSString).standardizingPath }) {
            return existing
        }
        let rule = WhitelistRule(pattern: trimmed, comment: comment, type: .path)
        rules.append(rule)
        return rule
    }

    /// 添加一条 App 名称白名单
    @discardableResult
    func addAppRule(_ appName: String, comment: String = "") -> WhitelistRule {
        let trimmed = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = rules.first(where: { $0.type == .appName && $0.pattern.lowercased() == trimmed.lowercased() }) {
            return existing
        }
        let rule = WhitelistRule(pattern: trimmed, comment: comment, type: .appName)
        rules.append(rule)
        return rule
    }

    /// 移除白名单规则
    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// 清空所有白名单规则
    func removeAllRules() {
        rules.removeAll()
    }

    /// 检查指定路径是否被用户白名单命中
    func isWhitelisted(path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let target = (CleanPaths.expand(path) as NSString).standardizingPath
        for rule in rules where rule.type == .path {
            let rulePath = rule.standardPath
            // 1. 完全相同
            if target == rulePath { return true }
            // 2. target 是 rulePath 的子路径
            if target.hasPrefix(rulePath + "/") { return true }
        }
        return false
    }

    /// 检查指定 App 名称是否被用户白名单命中
    func isAppWhitelisted(appName: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let norm = appName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for rule in rules where rule.type == .appName {
            if norm == rule.pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
                return true
            }
        }
        return false
    }
}
