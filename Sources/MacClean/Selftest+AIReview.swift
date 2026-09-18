import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：AI 再筛查
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 531–614）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteAIReview() {
        // MARK: - AI 再筛查（AI 扫描）

        check("AI 筛查：JSON 输出解析（含围栏）") {
            let items = [
                CleanItem(name: "CacheA", path: "/tmp/a", size: 10, rule: "C1", category: .userCaches),
                CleanItem(name: "DataB", path: "/tmp/b", size: 20, rule: "A1", category: .appResidue),
                CleanItem(name: "LogC", path: "/tmp/c", size: 30, rule: "C1", category: .logsAndTemp),
            ]
            let raw = """
            ```json
            [{"name": "CacheA", "verdict": "可删", "reason": "缓存可重建"},
             {"name": "DataB", "verdict": "不建议删", "reason": "App 数据"},
             {"name": "LogC", "verdict": "谨慎", "reason": "近期使用"}]
            ```
            """
            let reviews = AIService.parseReviewOutput(raw, items: items)
            guard reviews.count == 3 else { return false }
            let byName = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), items))
            for r in reviews {
                guard let item = byName[r.itemID] else { return false }
                switch item.name {
                case "CacheA": guard r.verdict == .delete else { return false }
                case "DataB": guard r.verdict == .keep else { return false }
                case "LogC": guard r.verdict == .caution else { return false }
                default: return false
                }
            }
            return reviews.allSatisfy { !$0.reason.isEmpty }
        }
        check("AI 筛查：表格行回退解析") {
            let items = [
                CleanItem(name: "A", path: "/tmp/a", size: 10, rule: "C1", category: .userCaches),
                CleanItem(name: "B", path: "/tmp/b", size: 20, rule: "C1", category: .userCaches),
            ]
            let raw = "1 | A | 可删 | 缓存\n2 | B | 谨慎 | 需确认"
            let reviews = AIService.parseReviewOutput(raw, items: items)
            guard reviews.count == 2 else { return false }
            return reviews[0].verdict == .delete && reviews[1].verdict == .caution
        }
        check("AI 筛查：垃圾输入返回空") {
            let items = [CleanItem(name: "A", path: "/tmp/a", size: 10, rule: "C1", category: .userCaches)]
            return AIService.parseReviewOutput("我不确定，无法判断", items: items).isEmpty
        }
        check("AI 筛查：状态机（未配置 AI 时给出明确错误）") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "A", path: "/tmp/a", size: 10, rule: "C1", category: .userCaches)]
            // 未启用 AI 时 review 应报错而非静默（networkDisabled 下 send 也会被短路）
            app.aiReview.review(items: st.items)
            let deadline = Date().addingTimeInterval(2)
            while app.aiReview.isReviewing && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return !app.aiReview.isReviewing
                && (app.aiReview.lastError != nil || app.aiReview.reviews.isEmpty)
        }
        check("AI 筛查：启动自动开抽屉 + 思考过程日志") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "A", path: "/tmp/a", size: 10, rule: "C1", category: .userCaches)]
            app.aiReview.review(items: st.items)
            // 启动即开抽屉 + 记录日志（即使后续失败，过程也可见）
            let opened = app.aiReview.isDrawerOpen
            let hasLog = !app.aiReview.processLog.isEmpty
            let hasName = app.aiReview.itemNames.values.contains("A")
            return opened && hasLog && hasName
        }
        check("AI 筛查：抽屉与对话抽屉互斥") {
            let app = AppState()
            app.ai.openDrawer()
            let chatOpened = app.ai.isDrawerOpen
            let reviewClosedByChat = !app.aiReview.isDrawerOpen
            app.aiReview.openDrawer()
            return chatOpened && reviewClosedByChat
                && app.aiReview.isDrawerOpen && !app.ai.isDrawerOpen
        }
        check("AI 筛查：ReviewBadge 渲染") {
            let delete = try ReviewBadge(verdict: .delete).inspect().text().string()
            let keep = try ReviewBadge(verdict: .keep).inspect().text().string()
            return delete == "AI·可删" && keep == "AI·不建议删"
        }

    }
}
