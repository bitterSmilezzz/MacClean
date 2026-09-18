import Foundation
import Combine

/// 白名单规则类型
enum WhitelistType: String, Codable {
    case path        // 指定路径或文件夹前缀
    case appName     // 指定 App 名称
    case `extension` // 指定排除文件扩展名（如 iso, dmg, raw 等）
}

/// 单条白名单规则
///
/// **必须手写 `init(from:)`**：Swift 合成的 Codable 对缺失的 key 会直接抛错，
/// 属性上的默认值**不参与解码**。也就是说，将来只要给这个结构加一个字段，
/// 所有老用户的 `rules` 都会解码失败、白名单整体消失——而白名单消失意味着
/// 用户明确保护过的路径重新变成"可清理"。这是静默的安全降级，不能留。
struct WhitelistRule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var pattern: String             // 路径（支持 ~）、App 名称或文件扩展名
    var comment: String             // 备注说明（如“系统安装包镜像”、“专业工程原稿”等）
    var type: WhitelistType = .path
    var createdAt: Date = Date()

    init(id: UUID = UUID(), pattern: String, comment: String,
         type: WhitelistType = .path, createdAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.comment = comment
        self.type = type
        self.createdAt = createdAt
    }

    /// 宽松解码：只有 `pattern` 是必需的，其余字段缺失一律取默认值。
    /// 这样"新增字段"不会毁掉老数据，"个别字段损坏"也只丢那一个字段。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pattern = try c.decode(String.self, forKey: .pattern)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        comment = (try? c.decode(String.self, forKey: .comment)) ?? ""
        type = (try? c.decode(WhitelistType.self, forKey: .type)) ?? .path
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, comment, type, createdAt
    }

    /// 展开波浪号并归一化后的绝对路径（对于 path 类型）。
    /// 归一化统一走 `FileSystem.normalizePath`，与 `FileSystem.isSafeToClean`
    /// 采用同一口径——若此处沿用 `standardizingPath`，其行为依赖路径是否存在
    /// （`/private/var/db` 存在则被改写成 `/var/db`），会与护栏判定出现
    /// `/private/tmp/x` 与 `/tmp/x` 匹配不上的问题（曾致白名单阻断用例失败）。
    var standardPath: String {
        guard type == .path else { return pattern }
        return FileSystem.normalizePath(pattern)
    }

    /// 标准化扩展名（统一去点、小写）
    var normalizedExtension: String {
        guard type == .extension else { return pattern }
        var p = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if p.hasPrefix(".") { p.removeFirst() }
        return p
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
    /// 解析失败时原始字节的存放位置。**不再静默丢弃**——丢弃之后任何一次
    /// `save()`（比如用户新加一条规则）都会把仅存的那份数据覆盖掉，永久无法恢复。
    private static let corruptBackupKey = "MacClean_UserWhitelistRules_v1_corrupt_backup"

    /// 上次加载是否出了问题。界面应据此提示用户"白名单可能有丢失，且当前保护可能不完整"。
    @Published private(set) var loadWarning: String?

    init() {
        let result = Self.load()
        self.rules = result.rules
        self.loadWarning = result.warning
    }

    /// 逐条解码的包装：**单条损坏不应毁掉整个白名单**。
    private struct LenientRule: Decodable {
        let rule: WhitelistRule?
        init(from decoder: Decoder) throws {
            rule = try? WhitelistRule(from: decoder)
        }
    }

    static func load() -> (rules: [WhitelistRule], warning: String?) {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return ([], nil)   // 从未存过 → 正常空列表
        }
        let result = decode(data)
        if result.warning != nil {
            // 整体解不开：留一份原始备份。**绝不静默丢弃**——丢弃之后任何一次
            // `save()`（比如用户新加一条规则）都会把仅存的那份数据覆盖掉，永久无法恢复。
            UserDefaults.standard.set(data, forKey: corruptBackupKey)
        }
        return result
    }

    /// 纯函数版解码，便于自检直接喂构造数据（不碰 UserDefaults）。
    static func decode(_ data: Data) -> (rules: [WhitelistRule], warning: String?) {
        if let wrapped = try? JSONDecoder().decode([LenientRule].self, from: data) {
            let rules = wrapped.compactMap(\.rule).filter { !$0.pattern.isEmpty }
            let dropped = wrapped.count - rules.count
            if dropped > 0 {
                return (rules, "白名单中有 \(dropped) 条记录无法解析，已跳过；其余 \(rules.count) 条仍然生效。")
            }
            return (rules, nil)
        }
        return ([], "白名单数据无法解析，已备份原始数据并暂时停用。此前受保护的路径可能不再被排除，请检查后重新添加。")
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
            loadWarning = nil
        } catch {
            // 保存失败必须让用户知道：白名单写不进去 = 下次启动保护就没了
            loadWarning = "白名单保存失败：\(error.localizedDescription)"
        }
    }

    /// 添加一条路径白名单
    @discardableResult
    func addPathRule(_ path: String, comment: String = "") -> WhitelistRule {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = rules.first(where: { $0.type == .path && $0.standardPath == FileSystem.normalizePath(trimmed) }) {
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

    /// 添加一条文件扩展名排除白名单（如 iso, dmg, raw 等，自动去前缀点）
    @discardableResult
    func addExtensionRule(_ ext: String, comment: String = "") -> WhitelistRule {
        var trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix(".") { trimmed.removeFirst() }
        if let existing = rules.first(where: { $0.type == .extension && $0.normalizedExtension == trimmed }) {
            return existing
        }
        let rule = WhitelistRule(pattern: trimmed, comment: comment, type: .extension)
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

    /// 检查指定路径是否被用户白名单命中。
    ///
    /// **必须同时比对"真实路径"形态**。`isSafeToClean` 现在会先把路径解析到真实位置再判定
    /// （软链防跳板），于是白名单也是拿**解析后**的路径来查的。若用户当初拉黑的是软链
    /// `~/mylink`，规则里存的是 `~/mylink`，而删除时来查的是 `/real/target/...` —— 匹配不上，
    /// 白名单就被绕过去了。用户拉黑一个软链目录，本意显然是保护它指向的东西。
    ///
    /// 注意这里**只增加候选、不做替换**：判定变宽 = 保护变强，方向上永远是安全的。
    /// 反向（用 realPath 替换掉字面路径）才危险——那会因路径是否存在而改变判定结果。
    func isWhitelisted(path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        // 与 isSafeToClean 共用归一化口径（见 WhitelistRule.standardPath 说明）
        var targets = [FileSystem.normalizePath(path)]
        let resolvedTarget = FileSystem.normalizePath(FileSystem.realPath(path))
        if resolvedTarget != targets[0] { targets.append(resolvedTarget) }

        for rule in rules where rule.type == .path {
            var rulePaths = [rule.standardPath]
            let resolvedRule = FileSystem.normalizePath(FileSystem.realPath(rule.standardPath))
            if resolvedRule != rulePaths[0] { rulePaths.append(resolvedRule) }

            for target in targets {
                for rulePath in rulePaths where !rulePath.isEmpty && rulePath != "/" {
                    if target == rulePath { return true }
                    if target.hasPrefix(rulePath + "/") { return true }
                }
            }
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

    /// 检查指定文件路径的扩展名是否被排除白名单命中
    func isExtensionWhitelisted(path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        for rule in rules where rule.type == .extension {
            if rule.normalizedExtension == ext {
                return true
            }
        }
        return false
    }
}
