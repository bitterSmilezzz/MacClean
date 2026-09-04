import Combine
import Foundation

/// AI 再筛查状态（AI 扫描）：对已扫描结果逐项二次判断「值不值得删」
/// 用户诉求：脚本扫描之外，用 AI 再筛查已扫描结果，给出可删/谨慎/不建议删 + 理由
final class AIReviewState: ObservableObject {
    /// 筛查结论（按 item id 关联）
    @Published var reviews: [UUID: ItemReview] = [:]
    @Published var isReviewing = false
    @Published var progressText: String?
    @Published var lastError: String?
    /// 本次筛查覆盖的 item id 集合（结果失效判断：重新扫描后清空）
    @Published var reviewedItemIDs: Set<UUID> = []

    // MARK: - 抽屉与思考过程（用户诉求：筛查时侧面弹抽屉，展示过程）
    /// 筛查抽屉是否展开
    @Published var isDrawerOpen = false
    /// 思考过程日志（实时追加：开始/批次/结论/完成/失败）
    @Published var processLog: [String] = []
    /// item id → 名称（抽屉结论列表展示用）
    @Published var itemNames: [UUID: String] = [:]
    /// 已完成结论数 / 总数（进度条）
    @Published var completedCount = 0
    @Published var totalCount = 0

    /// 弱引用 AppState（读取 AI 配置是否可用）
    weak var app: AppState?

    private var task: Task<Void, Never>?

    /// 某 item 的筛查结论（无则 nil）
    func review(for item: CleanItem) -> ItemReview? {
        reviews[item.id]
    }

    /// 该分类的筛查统计（供分组标题显示）
    func summary(for items: [CleanItem]) -> String {
        let decided = items.filter { reviews[$0.id]?.verdict.isDecided == true }
        guard !decided.isEmpty else { return "" }
        let deleteCount = decided.filter { reviews[$0.id]?.verdict == .delete }.count
        let cautionCount = decided.filter { reviews[$0.id]?.verdict == .caution }.count
        let keepCount = decided.filter { reviews[$0.id]?.verdict == .keep }.count
        var parts: [String] = []
        if deleteCount > 0 { parts.append("AI 建议删 \(deleteCount)") }
        if cautionCount > 0 { parts.append("谨慎 \(cautionCount)") }
        if keepCount > 0 { parts.append("保留 \(keepCount)") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 抽屉控制

    /// 打开筛查抽屉（同时收起 AI 对话抽屉，避免两个抽屉叠压）
    func openDrawer() {
        isDrawerOpen = true
        app?.ai.closeDrawer()
    }

    func closeDrawer() {
        isDrawerOpen = false
    }

    private func appendLog(_ line: String) {
        processLog.append(line)
        if processLog.count > 200 { processLog = Array(processLog.suffix(200)) }
    }

    /// 启动 AI 再筛查（分批调用 AIService.review，逐批合并结果）
    /// - Parameters:
    ///   - items: 待筛查的清理项（已扫描结果）
    ///   - onFinished: 全部完成回调（主线程）
    func review(items: [CleanItem], onFinished: (() -> Void)? = nil) {
        guard !items.isEmpty, !isReviewing else { return }
        // 先记录上下文并打开抽屉——即使配置失败，用户也能看到"正在做什么"
        totalCount = items.count
        completedCount = 0
        itemNames = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
        openDrawer()
        appendLog("🤖 AI 再筛查启动：共 \(items.count) 项，按批次逐项分析…")
        let config = AIConfig.load()
        guard config.enabled else {
            lastError = "AI 尚未配置：请先在 AI 面板 ⚙️ 完成配置并测试连接"
            appendLog("❌ 未配置 AI：请先在 ⚙️ 完成配置并测试连接")
            return
        }
        isReviewing = true
        lastError = nil
        progressText = "准备筛查 \(items.count) 项…"
        task?.cancel()
        task = Task {
            do {
                let results = try await AIService.review(items: items) { [weak self] msg in
                    Task { @MainActor in
                        self?.progressText = msg
                        if msg.hasPrefix("AI 筛查中（第") {
                            self?.appendLog("⏳ \(msg)")
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    var merged = reviews
                    for r in results where r.verdict.isDecided {
                        merged[r.itemID] = r
                    }
                    reviews = merged
                    reviewedItemIDs.formUnion(items.map(\.id))
                    completedCount = results.count
                    isReviewing = false
                    progressText = "AI 筛查完成：\(results.count) 项已给出结论"
                    let decided = results.filter { $0.verdict.isDecided }.count
                    appendLog("✅ 筛查完成：\(decided)/\(results.count) 项给出结论")
                    onFinished?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    lastError = error.localizedDescription
                    isReviewing = false
                    progressText = nil
                    appendLog("❌ 筛查失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 移除指定 item 的筛查结论（重新扫描某分类后调用）
    func removeReviews(for itemIDs: Set<UUID>) {
        guard !itemIDs.isEmpty else { return }
        reviews = reviews.filter { !itemIDs.contains($0.key) }
        reviewedItemIDs.subtract(itemIDs)
    }

    /// 清空全部筛查结论（重新扫描后调用）
    func clear() {
        task?.cancel()
        task = nil
        reviews = [:]
        reviewedItemIDs = []
        isReviewing = false
        progressText = nil
        lastError = nil
        processLog = []
        itemNames = [:]
        completedCount = 0
        totalCount = 0
    }
}
