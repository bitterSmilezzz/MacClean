import Combine
import Foundation

/// AI 对话状态：消息、上下文、加载、设置弹窗
final class AIState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var context: AskContext?
    @Published var draft = ""
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var showSettings = false

    private var cancellables = Set<AnyCancellable>()

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    /// 针对某个清理项发起提问（构造上下文 + 本地占用检测 + 自动发送）
    func askAbout(item: CleanItem) {
        ask(context: AskContext(
            title: item.name,
            path: item.path,
            size: item.size,
            category: item.category.title,
            risk: item.risk.label,
            note: item.note
        ))
    }

    /// 针对卸载器关联文件发起提问
    func askAbout(file: RelatedFile) {
        ask(context: AskContext(
            title: file.name,
            path: file.path,
            size: file.size,
            category: "App 关联文件",
            risk: "谨慎",
            note: file.kind,
            kind: file.kind
        ))
    }

    /// 针对大文件/垃圾箱项（无 CleanItem 场景的兜底）
    func askAbout(title: String, path: String, size: Int64, category: String, note: String) {
        ask(context: AskContext(
            title: title, path: path, size: size,
            category: category, risk: "谨慎", note: note
        ))
    }

    private func ask(context: AskContext) {
        var ctx = context
        // 本地占用检测（lsof，只读）
        ctx.inUseBy = AIService.detectProcesses(using: ctx.path)
        self.context = ctx
        let prompt = "请分析这个清理项（上下文已给出），告诉我：1) 它是做什么的 2) 是否适合删除 3) 当前是否正在被使用。"
        messages.append(ChatMessage(role: .user, content: prompt))
        lastError = nil
        send()
    }

    /// 发送当前 draft（或自动提问后的首条），调用 AI
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isLoading else { return }
        messages.append(ChatMessage(role: .user, content: text))
        draft = ""
        lastError = nil
        performRequest()
    }

    private func performRequest() {
        isLoading = true
        let history = messages
        let ctx = context
        Task {
            do {
                let reply = try await AIService.send(messages: history, context: ctx)
                await MainActor.run {
                    messages.append(ChatMessage(role: .assistant, content: reply))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    func clear() {
        messages = []
        context = nil
        lastError = nil
        draft = ""
    }
}
