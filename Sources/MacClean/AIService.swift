import Foundation
import Security

// MARK: - AI 配置（baseURL/model 存 UserDefaults，apiKey 存钥匙串）

struct AIConfig: Codable, Equatable {
    // 默认值：opencode go 网关（本机验证可达 https://opencode.ai/zen/go/v1）
    var baseURL: String = "https://opencode.ai/zen/go/v1"
    var model: String = "deepseek-v4-flash"
    var enabled: Bool = false

    static let defaultsKey = "aiConfig"

    static func load() -> AIConfig {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let cfg = try? JSONDecoder().decode(AIConfig.self, from: data) {
            return cfg
        }
        if let appDefaults = UserDefaults(suiteName: "com.macclean.app"),
           let data = appDefaults.data(forKey: defaultsKey),
           let cfg = try? JSONDecoder().decode(AIConfig.self, from: data) {
            return cfg
        }
        return AIConfig()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AIConfig.defaultsKey)
            UserDefaults(suiteName: "com.macclean.app")?.set(data, forKey: AIConfig.defaultsKey)
        }
    }

    // MARK: API Key 存储（钥匙串优先；钥匙串不可用时仅存内存，**绝不落盘**）
    //
    // 为什么不再写明文文件：v1.35 及以前把 Key 写进
    // ~/Library/Application Support/MacClean/ai.key（0600）。那与本项目自己的发布门槛
    // docs/RELEASE-CHECKLIST.md「API Key 不落盘」直接矛盾，且任何能读该文件的进程都能
    // 拿到可用凭据。现在只写钥匙串；进程内会话缓存是唯一的内存退路，进程退出即消失。
    //
    // 为什么钥匙串会失败：本 App 是 **ad-hoc 签名**（`codesign --sign -`，TeamIdentifier
    // 为空），每次重新构建都会换签名身份 → 钥匙串 ACL 失配 → `SecItemCopyMatching` 会
    // 弹窗甚至永久挂起（见提交 4ec2fe5 的根因二）。因此：数据保护钥匙串
    // （kSecUseDataProtectionKeychain）在无 team ID 时不可用；传统钥匙串则必须
    // **一律走后台线程 + 超时兜底**，失败时退到会话缓存并要求用户重新输入，
    // 而不是挂死主线程、也不是回退去写明文。

    private static let keychainService = "com.macclean.app"
    private static let keychainAccount = "aiApiKey"

    /// 自检注入：指向一次性测试 service，避免污染真实钥匙串
    static var keychainServiceOverride: String?

    /// 自检注入：指向临时文件，避免碰真实的历史明文 Key 文件
    static var legacyKeyFileURLOverride: URL?

    /// 钥匙串操作超时（ACL 失配时 SecItemCopyMatching 会挂起）
    private static let keychainTimeout: DispatchTimeInterval = .seconds(3)

    private static let stateLock = NSLock()
    /// 进程内会话缓存——钥匙串不可用时的唯一去处
    private static var sessionKey: String?
    /// 首次读取超时后置位：避免每次调用都白付 3s 代价；显式保存时清除并重试
    private static var keychainReadFailed = false
    /// 最近一次钥匙串操作的 OSStatus（诊断用）
    private static var lastStatusStorage: OSStatus = errSecSuccess

    /// 超时哨兵：非系统状态码，仅用于诊断输出（区分"ACL 挂起"与"明确错误码"）
    static let keychainTimeoutStatus: OSStatus = -9999

    /// 最近一次钥匙串操作结果：`errSecSuccess` = 成功，`keychainTimeoutStatus` = 超时挂起，其余为系统错误码
    static var lastKeychainStatus: OSStatus {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastStatusStorage
    }

    private static func recordStatus(_ status: OSStatus) {
        stateLock.lock(); defer { stateLock.unlock() }
        lastStatusStorage = status
    }

    /// 最近一次钥匙串结果的可读文案（诊断输出用）
    static var lastKeychainStatusDescription: String {
        let status = lastKeychainStatus
        if status == keychainTimeoutStatus { return "超时挂起（ACL 失配，见提交 4ec2fe5）" }
        if status == errSecSuccess { return "成功" }
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        return "OSStatus \(status)（\(msg)）"
    }

    private static func cachedKey() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return sessionKey
    }

    private static func setCachedKey(_ key: String?) {
        stateLock.lock(); defer { stateLock.unlock() }
        sessionKey = key
    }

    private static func markKeychainReadFailed() {
        stateLock.lock(); defer { stateLock.unlock() }
        keychainReadFailed = true
    }

    private static func shouldSkipKeychainRead() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return keychainReadFailed
    }

    private static func resetKeychainReadFailure() {
        stateLock.lock(); defer { stateLock.unlock() }
        keychainReadFailed = false
    }

    /// 自检注入：模拟"新进程启动"——清空会话缓存与读失败标记，**不动**钥匙串与文件
    static func resetSessionStateForTesting() {
        setCachedKey(nil)
        resetKeychainReadFailure()
    }

    /// 旧版明文 Key 文件（v1.35 及以前遗留）：**只读 + 删除，永不写入**
    private static var legacyKeyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MacClean", isDirectory: true).appendingPathComponent("ai.key")
    }

    private static var effectiveLegacyKeyFileURL: URL {
        legacyKeyFileURLOverride ?? legacyKeyFileURL
    }

    static func loadAPIKey() -> String? {
        if let cached = cachedKey() { return cached }

        if !shouldSkipKeychainRead() {
            if let k = keychainRead(), !k.isEmpty {
                setCachedKey(k)
                // 钥匙串已有可用 Key：清掉任何历史明文残留，否则它会一直躺在磁盘上
                if legacyKeyFileExists() { removeLegacyKeyFile() }
                return k
            }
        }

        // 一次性迁移：旧明文文件 → 钥匙串。
        // 只有写入成功才删除明文（safe-fail：宁可暂时留文件，也不丢凭据）。
        if let legacy = readLegacyKeyFile(), !legacy.isEmpty {
            if keychainWrite(legacy) {
                removeLegacyKeyFile()
            }
            setCachedKey(legacy)
            return legacy
        }
        return nil
    }

    /// 返回是否成功持久化到钥匙串。
    /// `false` = 仅本次会话可用，下次启动需重新输入（调用方应告知用户）。
    @discardableResult
    static func saveAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        setCachedKey(trimmed)
        removeLegacyKeyFile()          // 不再写明文，顺手清掉历史残留
        resetKeychainReadFailure()     // 用户显式保存 → 允许重试一次钥匙串
        return keychainWrite(trimmed)
    }

    static func clearAPIKey() {
        setCachedKey(nil)
        removeLegacyKeyFile()
        keychainDelete()
    }

    // MARK: 旧明文文件（只读 + 删除）

    /// 旧明文 Key 文件当前是否仍存在（迁移诊断用）
    static var legacyKeyFileStillPresent: Bool { legacyKeyFileExists() }

    private static func legacyKeyFileExists() -> Bool {
        FileManager.default.fileExists(atPath: effectiveLegacyKeyFileURL.path)
    }

    private static func readLegacyKeyFile() -> String? {
        guard let s = try? String(contentsOf: effectiveLegacyKeyFileURL, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func removeLegacyKeyFile() {
        try? FileManager.default.removeItem(at: effectiveLegacyKeyFileURL)
    }

    // MARK: 钥匙串（全部带超时兜底，避免 ACL 失配时挂起）

    private static var service: String { keychainServiceOverride ?? keychainService }

    private static func runGuarded<T>(_ fallback: T, _ body: @escaping () -> T) -> (value: T, timedOut: Bool) {
        let sem = DispatchSemaphore(value: 0)
        var result = fallback
        DispatchQueue.global().async {
            result = body()
            sem.signal()
        }
        let finished = sem.wait(timeout: .now() + keychainTimeout) == .success
        return (finished ? result : fallback, !finished)
    }

    private static func keychainRead() -> String? {
        let (value, timedOut) = runGuarded(nil) { keychainLoad() }
        if timedOut {
            recordStatus(keychainTimeoutStatus)
            markKeychainReadFailed()
            return nil
        }
        // 只有"真错误"（如 -50 / ACL 拒绝）才短路后续读取；
        // errSecItemNotFound 是正常的"尚未配置"，不能当成故障
        if value == nil, lastKeychainStatus != errSecItemNotFound {
            markKeychainReadFailed()
        }
        return value
    }

    private static func keychainWrite(_ key: String) -> Bool {
        let (ok, timedOut) = runGuarded(false) { keychainSave(key) }
        if timedOut { recordStatus(keychainTimeoutStatus) }
        return ok
    }

    private static func keychainDelete() {
        let (_, timedOut) = runGuarded(false) { keychainDeleteSync() }
        if timedOut { recordStatus(keychainTimeoutStatus) }
    }

    private static func keychainLoad() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        recordStatus(status)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 先 Add；已存在则 Update（避免产生重复条目）
    private static func keychainSave(_ key: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
        ]
        let value: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        let addStatus = SecItemAdd(base.merging(value) { _, new in new } as CFDictionary, nil)
        if addStatus == errSecSuccess { recordStatus(addStatus); return true }
        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(base as CFDictionary, value as CFDictionary)
            recordStatus(updateStatus)
            return updateStatus == errSecSuccess
        }
        recordStatus(addStatus)
        return false
    }

    private static func keychainDeleteSync() -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
        ]
        let status = SecItemDelete(deleteQuery as CFDictionary)
        recordStatus(status)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - 对话消息

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let content: String
    let date = Date()

    enum Role: String {
        case user
        case assistant
    }
}

// MARK: - AI 再筛查（AI 扫描）：对已扫描结果逐项二次判断

enum ReviewVerdict: String, Codable, Equatable {
    case delete    // 可删
    case caution   // 谨慎
    case keep      // 不建议删
    case unknown   // AI 未判定/无法判断

    var label: String {
        switch self {
        case .delete: return "可删"
        case .caution: return "谨慎"
        case .keep: return "不建议删"
        case .unknown: return "未判定"
        }
    }

    /// 是否明确给出结论（非 unknown）
    var isDecided: Bool { self != .unknown }
}

/// 单条 AI 筛查结论
struct ItemReview: Equatable {
    let itemID: UUID
    let verdict: ReviewVerdict
    let reason: String
}

// MARK: - 提问上下文（针对某个清理项/关联文件/列表）

/// 列表模式下的单个条目（Top N 截断后）
struct AskListItem: Equatable {
    let index: Int       // 序号（对应左侧列表位置）
    let name: String
    let path: String
    let size: Int64
    /// 处置结论 label（可清理 / 使用中 / 需确认 / 勿删）。
    ///
    /// 字段名沿用历史的 `risk`：`AskContext.risk` 被 `AIChatView` 读取、被 `Selftest` 构造，
    /// 改名会波及本任务范围外的文件。语义已随模型迁移——这里装的是**结论**，不是旧风险级。
    let risk: String
    /// 结论依据（`Recommendation.reason`）。
    ///
    /// 模型需要"为什么是这个结论"才能复核，只给标签等于让它自己再猜一遍。
    var verdictReason: String = ""
    /// 最近使用描述（如"3 天前 · 频繁使用中"；未知为空）
    var usageDesc: String = ""
}

struct AskContext: Equatable {
    var title: String        // 条目名
    var path: String         // 主路径
    var size: Int64
    var category: String     // 所属分类或"App 关联文件"
    /// 处置结论 label（可清理 / 使用中 / 需确认 / 勿删）。字段名沿用历史的 `risk`，理由同 `AskListItem`。
    var risk: String
    /// 结论依据（`Recommendation.reason`）
    var verdictReason: String = ""
    var note: String         // 扫描器备注
    var kind: String = ""    // 文件类别（卸载器：Application Support 等）
    var inUseBy: [String] = []   // 本地检测到的占用进程
    /// 最近使用时间（用户诉求：判断值不值得删）
    var lastUsed: Date?
    /// 使用频率（用户诉求）
    var usage: UsageLevel = .unknown

    // 列表模式：非空时按"整表判断"提问（Q2: Top 50 截断 / Q6: 每类 Top 20）
    var listItems: [AskListItem] = []
    var listTotal: Int = 0       // 列表实际总条数（含未列出的）
    var listSummary: String = "" // 如"用户缓存 · 124 项"

    var isListMode: Bool { !listItems.isEmpty }
    var sizeString: String { size.byteStringCN }
}

// MARK: - AI 服务（OpenAI 兼容 chat/completions）

enum AIService {
    /// 自检模式禁用真实网络（AI 提问链路只验证状态机，不实际发请求）
    static var networkDisabled = false

    enum AIError: LocalizedError {
        case notConfigured
        case badResponse
        case network(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "尚未配置 AI 接口：点击右上角的设置，填写 baseURL / API Key / 模型"
            case .badResponse: return "AI 接口返回了无法解析的响应"
            case .network(let msg): return "网络错误：\(msg)"
            }
        }
    }

    /// 专用会话（P4 根因修复）：绕过系统代理直连。
    /// 根因：系统代理 127.0.0.1:7890 对网关请求挂起（curl 直连 200 / URLSession 挂死 90s+）
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]   // 空字典 = 禁用系统代理，直连
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }()

    /// 强制超时兜底：URLSession 超时在代理半挂起场景可能不触发，任务组 race 强制中断
    private static func withTimeout<T>(_ seconds: TimeInterval,
                                       _ op: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AIError.network("请求超时（\(Int(seconds))s）：网关无响应，请检查网络/代理设置")
            }
            guard let first = try await group.next() else { throw AIError.badResponse }
            group.cancelAll()
            return first
        }
    }

    /// 统一构建 AI 请求（自动补全会话与认证头）
    private static func makeRequest(url: URL, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // opencode.ai 等网关要求必需会话头；标准 OpenAI/DeepSeek 兼容忽略
        request.setValue("macclean-session-\(UUID().uuidString.lowercased())", forHTTPHeaderField: "x-opencode-session")
        return request
    }

    /// 发送对话，返回助手回复
    static func send(messages: [ChatMessage], context: AskContext?) async throws -> String {
        // MED#7：自检模式禁用真实网络（状态机仍走通，请求被短路）
        if networkDisabled {
            throw AIError.network("自检模式：网络请求已禁用")
        }
        let config = AIConfig.load()
        guard config.enabled, let apiKey = AIConfig.loadAPIKey(), !apiKey.isEmpty else {
            throw AIError.notConfigured
        }
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespaces))
                .flatMap({ URL(string: $0.appendingPathComponent("/chat/completions").absoluteString) }) else {
            throw AIError.network("无效的 baseURL")
        }

        var request = makeRequest(url: url, apiKey: apiKey, timeout: 45)

        var systemPrompt = Self.systemPrompt
        if let context {
            systemPrompt += "\n\n【当前询问的目标】\n" + Self.render(context: context)
        }
        var apiMessages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        for m in messages {
            apiMessages.append(["role": m.role.rawValue, "content": m.content])
        }

        let body: [String: Any] = [
            "model": config.model,
            "messages": apiMessages,
            "temperature": 0.3,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await withTimeout(50) {
            try await Self.session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw AIError.network("无响应") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AIError.network("HTTP \(http.statusCode)：\(msg.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - AI 再筛查（AI 扫描）：批量判断已扫描结果值不值得删

    /// 筛查提示词：要求模型按表格逐项给结论，并输出 JSON 数组
    private static let reviewPrompt = """
    你是 MacClean 的清理专家。用户会给你一张"已扫描清理候选"表格，每行包含：编号 | 名称 | 路径 | 大小 | 处置结论 | 最近使用。
    「处置结论」是 MacClean 依据本地规则给出的结论（可清理 / 使用中 / 需确认 / 勿删），括号内是它的判断依据。请结合该依据逐项复核是否值得删除，判断依据：
    - 缓存/日志类即使最近在用也可删（可重建），但注明"频繁使用，删除后需重建"；
    - App 数据/个人文件/配置类不建议删（即使大）；
    - 长期未用（>90 天）且可重建的优先建议删；
    - 不确定就写"无法判断"。
    输出格式：严格只输出一个 JSON 数组，每个元素形如 {"name": "编号", "verdict": "可删|谨慎|不建议删|无法判断", "reason": "一句话理由"}。
    不要输出 JSON 以外的任何文字（不要 markdown 代码块标记）。
    """

    /// 执行 AI 再筛查：返回逐项结论（按名称匹配回 item）
    static func review(items: [CleanItem],
                       onBatchDone: (([ItemReview]) -> Void)? = nil,
                       progress: @escaping (String) -> Void) async throws -> [ItemReview] {
        if networkDisabled {
            throw AIError.network("自检模式：网络请求已禁用")
        }
        let config = AIConfig.load()
        guard config.enabled, let apiKey = AIConfig.loadAPIKey(), !apiKey.isEmpty else {
            throw AIError.notConfigured
        }
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespaces))
                .flatMap({ URL(string: $0.appendingPathComponent("/chat/completions").absoluteString) }) else {
            throw AIError.network("无效的 baseURL")
        }

        // 分批：每批 20 项，兼顾模型思考延迟与批次吞吐
        let batchSize = 20
        var allReviews: [ItemReview] = []
        var batchIndex = 0
        let totalBatches = max(1, Int(ceil(Double(items.count) / Double(batchSize))))
        while batchIndex < items.count {
            let batch = Array(items[batchIndex..<min(batchIndex + batchSize, items.count)])
            let table = batch.enumerated().map { i, item in
                let usage = item.lastUsed.map { "\($0.relativeUsage) · \(item.usage.label)" } ?? item.usage.label
                let verdict = verdictCell(label: item.recommendation.label,
                                          reason: item.recommendation.reason)
                return "\(i + 1) | \(item.name) | \(item.path) | \(item.size.byteStringCN) | \(verdict) | \(usage)"
            }.joined(separator: "\n")
            let userContent = "表格：\n\(table)"

            var request = makeRequest(url: url, apiKey: apiKey, timeout: 90)
            let body: [String: Any] = [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": reviewPrompt],
                    ["role": "user", "content": userContent],
                ],
                "temperature": 0.2,
                "stream": false,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let currentBatchNum = batchIndex / batchSize + 1
            progress("AI 筛查中（第 \(currentBatchNum) 批 / \(totalBatches) 批）…")
            let (data, response) = try await withTimeout(90) {
                try await Self.session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse else { throw AIError.network("无响应") }
            guard http.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw AIError.network("HTTP \(http.statusCode)：\(msg.prefix(200))")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw AIError.badResponse
            }
            // 解析模型输出 → 本批结论
            let batchReviews = parseReviewOutput(content, items: batch)
            allReviews.append(contentsOf: batchReviews)
            onBatchDone?(batchReviews)
            batchIndex += batchSize
        }
        return allReviews
    }

    /// 容错解析：优先 JSON 数组；失败则按表格行 "编号 | ... | 结论 | 理由" 解析
    static func parseReviewOutput(_ raw: String, items: [CleanItem]) -> [ItemReview] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) JSON 数组（含可能的 ```json 围栏 / 前后说明文字）
        if let jsonStart = text.firstIndex(of: "["),
           let jsonEnd = text.lastIndex(of: "]"),
           jsonStart < jsonEnd {
            let jsonStr = String(text[jsonStart...jsonEnd])
            if let data = jsonStr.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var reviews: [ItemReview] = []
                for obj in arr {
                    guard let name = obj["name"] as? String,
                          let verdictRaw = obj["verdict"] as? String else { continue }
                    let reason = (obj["reason"] as? String) ?? ""
                    let verdict: ReviewVerdict
                    switch verdictRaw {
                    // 提示词固定了输出词表（可删/谨慎/不建议删），但模型有可能把输入表格里的
                    // 结论标签（可清理/使用中/需确认/勿删）原样回显，所以两套都认。
                    case "可删", "可清理": verdict = .delete
                    case "谨慎", "需确认", "使用中": verdict = .caution
                    case "不建议删", "勿删": verdict = .keep
                    default: verdict = .unknown
                    }
                    // 按编号或名称匹配回 item（enumerated 防强制解包）
                    if let (idx, item) = items.enumerated().first(where: { $0.element.name == name || "\($0.offset + 1)" == name }) {
                        _ = idx
                        reviews.append(ItemReview(itemID: item.id, verdict: verdict, reason: reason))
                    }
                }
                if !reviews.isEmpty { return reviews }
            }
        }

        // 2) 表格行回退："1 | 名称 | 结论 | 理由"
        var reviews: [ItemReview] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 4, let idx = Int(parts[0]) else { continue }
            let verdict: ReviewVerdict
            switch parts[2] {
            case "可删": verdict = .delete
            case "谨慎": verdict = .caution
            case "不建议删": verdict = .keep
            default: verdict = .unknown
            }
            if idx >= 1, idx <= items.count {
                reviews.append(ItemReview(itemID: items[idx - 1].id, verdict: verdict, reason: parts[3]))
            }
        }
        return reviews
    }

    /// 连通性测试：发一条最小请求，验证 baseURL + key + 模型可用
    static func testConnection(baseURL: String, apiKey: String, model: String) async throws -> String {
        guard !baseURL.isEmpty, !apiKey.isEmpty, !model.isEmpty else {
            throw AIError.notConfigured
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))
                .flatMap({ URL(string: $0.appendingPathComponent("/chat/completions").absoluteString) }) else {
            throw AIError.network("无效的 baseURL")
        }
        var request = makeRequest(url: url, apiKey: apiKey, timeout: 30)
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "回复 OK 两个字母即可"]],
            "max_tokens": 300,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await withTimeout(35) {
            try await Self.session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw AIError.network("无响应") }
        guard http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AIError.network("HTTP \(http.statusCode)：\(msg.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIError.badResponse
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 系统提示词（固定：判断用途/是否可删/是否在用）

    static let systemPrompt = """
    你是 MacClean 清理助手的专家，帮助用户判断文件/目录是否可以安全清理。\
    用户会给出清理候选项的信息（单条模式：路径/大小/类别/处置结论与依据/占用进程；\
    列表模式：一张带序号的表格）。请用中文回答。

    【单条模式输出结构】
    1. **用途**：推断这是什么（缓存、日志、App 数据、开发产物等），说明把握程度。
    2. **是否适合删除**：明确结论（可删 / 谨慎 / 不建议删）与理由；缓存/日志可重建，App 数据/个人文件不要建议删。
    3. **当前是否正在使用**：结合"占用进程"判断；为空说明当前无进程占用。
    4. **建议**：一句话（直接删/移废纸篓/保留）。

    【列表模式输出结构】
    逐项按表格清单回答，每行格式：`编号 | 名称 | 结论（可删/谨慎/不建议删） | 一句话理由`。\
    最后给出**总体建议**：哪些可以放心清理、哪些需要人工确认、哪些建议保留。\
    只对表格中列出的编号做判断；不要编造未列出的项。

    回答要简洁（单条 200 字内；列表模式尽量紧凑），不确定就明说"无法判断"。
    """

    /// 把「结论 + 依据」渲染成提示词里的一格文本：`可清理（应用缓存文件，删除后应用会自动重建）`。
    ///
    /// 依据一并交给模型，而不是只给一个标签——模型要复核"能不能删"，缺了理由就只能自己重猜，
    /// 那正是旧模型里"标签与事实各说各话"的翻版。表格以 `|` 分列，故把格内竖线换掉。
    private static func verdictCell(label: String, reason: String) -> String {
        let cleaned = reason
            .replacingOccurrences(of: "|", with: "/")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? label : "\(label)（\(cleaned)）"
    }

    static func render(context: AskContext) -> String {
        // 列表模式：按序号表格输出（Top N 截断）
        if context.isListMode {
            var lines: [String] = []
            lines.append("列表：\(context.listSummary)")
            lines.append("共 \(context.listTotal) 项，以下列出最大的 \(context.listItems.count) 项：")
            lines.append("编号 | 名称 | 路径 | 大小 | 处置结论 | 最近使用")
            for item in context.listItems {
                let verdict = verdictCell(label: item.risk, reason: item.verdictReason)
                lines.append("\(item.index) | \(item.name) | \(item.path) | \(item.size.byteStringCN) | \(verdict) | \(item.usageDesc.isEmpty ? "未知" : item.usageDesc)")
            }
            if context.listItems.count < context.listTotal {
                lines.append("（其余 \(context.listTotal - context.listItems.count) 项未列出，均为更小的项）")
            }
            return lines.joined(separator: "\n")
        }
        // 单条模式
        var lines: [String] = []
        lines.append("- 名称：\(context.title)")
        lines.append("- 路径：\(context.path)")
        lines.append("- 大小：\(context.sizeString)")
        lines.append("- 类别：\(context.category)")
        lines.append("- 处置结论：\(context.risk)")
        if !context.verdictReason.isEmpty { lines.append("- 结论依据：\(context.verdictReason)") }
        if !context.kind.isEmpty { lines.append("- 文件类别：\(context.kind)") }
        if !context.note.isEmpty { lines.append("- 扫描备注：\(context.note)") }
        // 最近使用时间 + 使用频率（用户诉求：判断值不值得删）
        if let lastUsed = context.lastUsed {
            lines.append("- 最近使用：\(Date.usageFormatter.string(from: lastUsed))（\(lastUsed.relativeUsage)）")
            lines.append("- 使用频率：\(context.usage.label)")
        } else if context.usage != .unknown {
            lines.append("- 使用频率：\(context.usage.label)")
        }
        if context.inUseBy.isEmpty {
            lines.append("- 占用进程：无（本地 lsof 检测）")
        } else {
            lines.append("- 占用进程：\(context.inUseBy.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 本地占用检测（lsof，只读）

    /// 检测路径当前是否被进程占用，返回进程名列表
    static func detectProcesses(using path: String) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }
        // 走 SafeProcess：`lsof <path>` 在被审计的目录上可能输出很大（管道 64KB 就死锁），
        // 且对网络盘/异常 inode 会卡住——原来没有超时，一卡就把整个 AI 筛查挂死。
        guard let text = SafeProcess.output("/usr/sbin/lsof", [path], timeout: 8) else { return [] }
        var names = Set<String>()
        // lsof 输出: COMMAND  PID  USER  FD  TYPE  DEVICE  SIZE/OFF  NODE  NAME
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if let cmd = fields.first {
                names.insert(String(cmd))
            }
        }
        return Array(names).sorted()
    }
}
