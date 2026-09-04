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
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let cfg = try? JSONDecoder().decode(AIConfig.self, from: data) else {
            return AIConfig()
        }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AIConfig.defaultsKey)
        }
    }

    // MARK: 旧钥匙串（仅用于迁移读取；新 Key 存 0600 文件）

    private static let keychainService = "com.macclean.app"
    private static let keychainAccount = "aiApiKey"

    private static var keyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MacClean", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai.key")
    }

    /// 测试注入（自检不碰真实 Key 文件）
    static var keyFileURLOverride: URL?

    private static var effectiveKeyFileURL: URL {
        keyFileURLOverride ?? keyFileURL
    }

    static func loadAPIKey() -> String? {
        // 1) 文件优先（MED#4：校验 0600 权限，宽松权限的 key 文件拒绝读取）
        if keyFileURLOverride == nil, let attrs = try? FileManager.default.attributesOfItem(atPath: effectiveKeyFileURL.path),
           let perms = attrs[.posixPermissions] as? NSNumber, perms.intValue != 0o600 {
            // 权限不符：尝试纠正后仍不符则视为不可信，走迁移/回退
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: effectiveKeyFileURL.path)
            if let perms2 = try? FileManager.default.attributesOfItem(atPath: effectiveKeyFileURL.path)[.posixPermissions] as? NSNumber,
               perms2.intValue != 0o600 {
                return nil
            }
        }
        if let s = try? String(contentsOf: effectiveKeyFileURL, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 2) 兼容迁移：尝试读旧钥匙串（可能因 ACL 挂起 → 后台线程 + 3s 超时保护）
        let sem = DispatchSemaphore(value: 0)
        var migrated: String?
        DispatchQueue.global().async {
            migrated = keychainLoad()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        if let m = migrated?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty {
            saveAPIKey(m)
            keychainDelete()
            return m
        }
        return nil
    }

    static func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // LOW-MED：先写临时文件并设 0600，再原子替换——避免"先 0644 后改权限"的窗口期
        let url = effectiveKeyFileURL
        let tmp = url.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        do {
            try trimmed.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
        // 异步清理旧钥匙串条目（避免潜在 ACL 阻塞）
        DispatchQueue.global().async { Self.keychainDelete() }
    }

    static func clearAPIKey() {
        try? FileManager.default.removeItem(at: effectiveKeyFileURL)
        keychainDelete()
    }

    private static func keychainLoad() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainDelete() {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
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

// MARK: - 提问上下文（针对某个清理项/关联文件/列表）

/// 列表模式下的单个条目（Top N 截断后）
struct AskListItem: Equatable {
    let index: Int       // 序号（对应左侧列表位置）
    let name: String
    let path: String
    let size: Int64
    let risk: String
    /// 最近使用描述（如"3 天前 · 频繁使用中"；未知为空）
    var usageDesc: String = ""
}

struct AskContext: Equatable {
    var title: String        // 条目名
    var path: String         // 主路径
    var size: Int64
    var category: String     // 所属分类或"App 关联文件"
    var risk: String         // 风险等级
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
            case .notConfigured: return "尚未配置 AI 接口：点击右上角 ⚙️ 填写 baseURL / API Key / 模型"
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

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

    /// 连通性测试：发一条最小请求，验证 baseURL + key + 模型可用
    static func testConnection(baseURL: String, apiKey: String, model: String) async throws -> String {
        guard !baseURL.isEmpty, !apiKey.isEmpty, !model.isEmpty else {
            throw AIError.notConfigured
        }
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces))
                .flatMap({ URL(string: $0.appendingPathComponent("/chat/completions").absoluteString) }) else {
            throw AIError.network("无效的 baseURL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "回复 OK 两个字母即可"]],
            "max_tokens": 10,
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
    用户会给出清理候选项的信息（单条模式：路径/大小/类别/风险/占用进程；\
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

    static func render(context: AskContext) -> String {
        // 列表模式：按序号表格输出（Top N 截断）
        if context.isListMode {
            var lines: [String] = []
            lines.append("列表：\(context.listSummary)")
            lines.append("共 \(context.listTotal) 项，以下列出最大的 \(context.listItems.count) 项：")
            lines.append("编号 | 名称 | 路径 | 大小 | 风险 | 最近使用")
            for item in context.listItems {
                lines.append("\(item.index) | \(item.name) | \(item.path) | \(item.size.byteStringCN) | \(item.risk) | \(item.usageDesc.isEmpty ? "未知" : item.usageDesc)")
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
        lines.append("- 风险等级：\(context.risk)")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
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
