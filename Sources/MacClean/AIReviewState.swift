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

    /// 启动 AI 再筛查（分批调用 AIService.review，逐批合并结果）
    /// - Parameters:
    ///   - items: 待筛查的清理项（已扫描结果）
    ///   - onFinished: 全部完成回调（主线程）
    func review(items: [CleanItem], onFinished: (() -> Void)? = nil) {
        guard !items.isEmpty, !isReviewing else { return }
        let config = AIConfig.load()
        guard config.enabled else {
            lastError = "AI 尚未配置：请先在 AI 面板 ⚙️ 完成配置并测试连接"
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
                    isReviewing = false
                    progressText = "AI 筛查完成：\(results.count) 项已给出结论"
                    onFinished?()
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    lastError = error.localizedDescription
                    isReviewing = false
                    progressText = nil
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
    }
}
