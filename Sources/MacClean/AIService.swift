import Foundation
import Security

// MARK: - AI 配置（baseURL/model 存 UserDefaults，apiKey 存钥匙串）

struct AIConfig: Codable, Equatable {
    var baseURL: String = "https://api.deepseek.com"   // OpenAI 兼容端点
    var model: String = "deepseek-chat"
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

    // MARK: Keychain（apiKey 不落盘、不进日志）

    private static let keychainService = "com.macclean.app"
    private static let keychainAccount = "aiApiKey"

    static func loadAPIKey() -> String? {
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

    static func saveAPIKey(_ key: String) {
        let keyData = Data(key.utf8)
        // 先删旧值再写入
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func clearAPIKey() {
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

// MARK: - 提问上下文（针对某个清理项/关联文件）

struct AskContext: Equatable {
    var title: String        // 条目名
    var path: String         // 主路径
    var size: Int64
    var category: String     // 所属分类或"App 关联文件"
    var risk: String         // 风险等级
    var note: String         // 扫描器备注
    var kind: String = ""    // 文件类别（卸载器：Application Support 等）
    var inUseBy: [String] = []   // 本地检测到的占用进程

    var sizeString: String { size.byteStringCN }
}

// MARK: - AI 服务（OpenAI 兼容 chat/completions）

enum AIService {
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

    /// 发送对话，返回助手回复
    static func send(messages: [ChatMessage], context: AskContext?) async throws -> String {
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
        request.timeoutInterval = 60
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
    你是 MacClean 清理助手的专家，帮助用户判断某个文件/目录是否可以安全清理。\
    用户会给出一个清理候选项（路径、大小、类别、风险等级、本地检测到的占用进程等）。\
    请用中文回答，按以下结构输出：

    1. **用途**：根据路径/名称/上下文推断这个项目是什么（缓存、日志、App 数据、开发产物等），说明你的把握程度。
    2. **是否适合删除**：给出明确结论（可删 / 谨慎 / 不建议删）与理由；注意：缓存/日志可重建，App 数据/个人文件不要建议删。
    3. **当前是否正在使用**：结合"占用进程"信息判断；若列表为空说明当前无进程占用（但不排除未来使用）。
    4. **建议**：一句话给出清理方式（直接删/移废纸篓/保留）。

    回答要简洁（200 字内），不确定就明说"无法判断"，不要编造。
    """

    static func render(context: AskContext) -> String {
        var lines: [String] = []
        lines.append("- 名称：\(context.title)")
        lines.append("- 路径：\(context.path)")
        lines.append("- 大小：\(context.sizeString)")
        lines.append("- 类别：\(context.category)")
        lines.append("- 风险等级：\(context.risk)")
        if !context.kind.isEmpty { lines.append("- 文件类别：\(context.kind)") }
        if !context.note.isEmpty { lines.append("- 扫描备注：\(context.note)") }
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
