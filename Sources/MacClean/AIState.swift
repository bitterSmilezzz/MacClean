import Combine
import Foundation
import SwiftUI

/// AI 对话状态：消息、上下文、加载、设置弹窗
final class AIState: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var context: AskContext?
    @Published var draft = ""
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var showSettings = false
    /// 抽屉式面板：默认收起，提问/打开设置时滑出，回复到达后自动收起（深度优化共识 d1）
    @Published var isDrawerOpen = false

    private var cancellables = Set<AnyCancellable>()

    /// 弱引用 AppState（用于自动携带当前分类列表上下文）
    weak var app: AppState?

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

    // MARK: - 列表级提问（grill 共识：当前列表 Top 50 / 全部每类 Top 20）

    /// 「问当前列表」：当前分类扫描结果打包（Top 50，按大小降序）
    func askAboutCurrentList() {
        guard let app, case .category(let cat) = app.destination else {
            lastError = "当前不在分类页面"
            return
        }
        let st = app.state(for: cat)
        guard st.isScanned, !st.items.isEmpty else {
            lastError = "当前分类尚未扫描或没有结果"
            return
        }
        attachList(items: st.items, summary: "\(cat.title) · 共 \(st.items.count) 项",
                   total: st.items.count, limit: 50,
                   prompt: "请分析左侧当前分类列表（上下文已给出），按表格清单逐项判断哪些可以删除、哪些谨慎、哪些不建议删。")
    }

    /// 「问全部」：6 个分类各取 Top 20 打包
    func askAboutAll() {
        guard let app else { return }
        var all: [AskListItem] = []
        var summaryParts: [String] = []
        var total = 0
        var index = 1
        for cat in CleanCategory.allCases {
            let st = app.state(for: cat)
            guard st.isScanned, !st.items.isEmpty else { continue }
            let top = st.items.sorted { $0.size > $1.size }.prefix(20)
            summaryParts.append("\(cat.title) \(st.items.count) 项")
            total += st.items.count
            for item in top {
                all.append(AskListItem(index: index, name: item.name, path: item.path,
                                       size: item.size, risk: item.risk.label))
                index += 1
            }
        }
        guard !all.isEmpty else {
            lastError = "尚无任何扫描结果，请先扫描"
            return
        }
        var ctx = AskContext(title: "全部扫描结果", path: "", size: 0,
                             category: "全部", risk: "", note: "")
        ctx.listItems = all
        ctx.listTotal = total
        ctx.listSummary = summaryParts.joined(separator: "、")
        self.context = ctx
        let prompt = "请分析所有分类的清理候选项（上下文已给出），按表格清单逐项判断哪些可以删除、哪些谨慎、哪些不建议删，并给出总体建议。"
        messages.append(ChatMessage(role: .user, content: prompt))
        lastError = nil
        send()
    }

    /// 首条自动携带：输入框直接提问时若无可问上下文，自动附带当前分类列表（grill Q4/Q5）
    func autoAttachContextIfNeeded() {
        guard context == nil else { return }
        guard let app, case .category(let cat) = app.destination else { return }
        let st = app.state(for: cat)
        guard st.isScanned, !st.items.isEmpty else { return }
        attachList(items: st.items, summary: "\(cat.title) · 共 \(st.items.count) 项",
                   total: st.items.count, limit: 50,
                   prompt: nil)   // 不追加消息，上下文随系统提示词附带
    }

    private func attachList(items: [CleanItem], summary: String, total: Int,
                            limit: Int, prompt: String?) {
        let top = items.sorted { $0.size > $1.size }.prefix(limit)
        var list: [AskListItem] = []
        for (i, item) in top.enumerated() {
            list.append(AskListItem(index: i + 1, name: item.name, path: item.path,
                                    size: item.size, risk: item.risk.label))
        }
        var ctx = AskContext(title: summary, path: "", size: 0, category: "列表", risk: "", note: "")
        ctx.listItems = list
        ctx.listTotal = total
        ctx.listSummary = summary
        self.context = ctx
        if let prompt {
            messages.append(ChatMessage(role: .user, content: prompt))
        }
        lastError = nil
    }

    private func ask(context: AskContext) {
        var ctx = context
        // 本地占用检测（lsof，只读）
        ctx.inUseBy = AIService.detectProcesses(using: ctx.path)
        self.context = ctx
        let prompt = "请分析这个清理项（上下文已给出），告诉我：1) 它是做什么的 2) 是否适合删除 3) 当前是否正在被使用。"
        messages.append(ChatMessage(role: .user, content: prompt))
        lastError = nil
        openDrawer()
        send()
    }

    /// 发送当前 draft（或自动提问后的首条），调用 AI
    func send() {
        // 首条自动携带列表上下文（仅当尚无上下文时）
        if context == nil { autoAttachContextIfNeeded() }
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
                    scheduleAutoCollapse()
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    /// 抽屉共识（d1）：回复到达后延迟收起，给一点阅读缓冲；用户再次提问会重新打开
    private func scheduleAutoCollapse() {
        guard isDrawerOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            // 若期间用户又发了新消息（isLoading），则不收起
            guard let self, !self.isLoading else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.isDrawerOpen = false }
        }
    }

    /// 打开抽屉（✨ / 问列表 / 设置入口统一走这里）
    func openDrawer() {
        withAnimation(.easeOut(duration: 0.25)) { isDrawerOpen = true }
    }

    func closeDrawer() {
        withAnimation(.easeOut(duration: 0.25)) { isDrawerOpen = false }
    }

    /// 重试：错误后重新发送最后一条用户消息（网络抖动/超时恢复用）
    func retry() {
        guard !isLoading, lastError != nil,
              let last = messages.last(where: { $0.role == .user }) else { return }
        lastError = nil
        messages.append(ChatMessage(role: .user, content: "（重试）" + last.content))
        performRequest()
    }

    func clear() {
        messages = []
        context = nil
        lastError = nil
        draft = ""
    }

    /// Q7 切换即换：仅作废旧上下文（保留对话消息，便于回溯）
    func clearContext() {
        context = nil
    }
}
