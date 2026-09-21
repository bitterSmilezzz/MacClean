import Foundation

// 自检套件：智能清理推荐引擎（v1.36.0）
extension Selftest {
    static func suiteSmartRecommendation() {
        // MARK: - 智能清理推荐引擎

        check("智能推荐硬边界：系统勿删与运行中项目强制归零，绝对不入选推荐精选") {
            // 1. 系统勿删项目（100GB，闲置 1 年）
            let keepItem = CleanItem(
                name: "System Files",
                path: "/private/tmp/sys_test",
                size: 100 * 1024 * 1024 * 1024,
                nature: .systemCritical,
                consequence: "系统关键文件",
                category: .browserAndSystem,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: Date().addingTimeInterval(-365 * 86400), level: .dormant)
            )
            let keepScore = keepItem.recommendationScore
            guard keepScore.totalScore == 0.0 && keepScore.tier == .manual else { return false }

            // 2. 正在运行的 App 缓存
            let runningItem = CleanItem(
                name: "Xcode Cache",
                path: "/private/tmp/xcode_cache",
                size: 10 * 1024 * 1024 * 1024,
                nature: .losslessCache,
                consequence: "Xcode 缓存",
                category: .devResidue,
                use: UseState(ownerIsRunning: true, ownerName: "Xcode", lastUsed: Date().addingTimeInterval(-100 * 86400), level: .dormant)
            )
            let runningScore = runningItem.recommendationScore
            guard runningScore.totalScore == 0.0 && runningScore.tier == .manual else { return false }

            return true
        }

        check("智能推荐打分单调性：闲置越久、体积越大、无损性越高，得分严格递增") {
            let now = Date()

            // 1. 相同体积、不同闲置时间
            let recentCache = CleanItem(
                name: "Recent Cache",
                path: "/private/tmp/recent",
                size: 500 * 1024 * 1024, // 500MB
                nature: .losslessCache,
                consequence: "普通缓存",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-2 * 86400), level: .recent)
            )
            let dormantCache = CleanItem(
                name: "Dormant Cache",
                path: "/private/tmp/dormant",
                size: 500 * 1024 * 1024, // 500MB
                nature: .losslessCache,
                consequence: "普通缓存",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-120 * 86400), level: .dormant)
            )
            guard dormantCache.recommendationScore.totalScore > recentCache.recommendationScore.totalScore else { return false }

            // 2. 相同闲置时间、不同体积
            let smallCache = CleanItem(
                name: "Small Cache",
                path: "/private/tmp/small",
                size: 2 * 1024, // 2KB
                nature: .losslessCache,
                consequence: "小缓存",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-60 * 86400), level: .dormant)
            )
            let hugeCache = CleanItem(
                name: "Huge Cache",
                path: "/private/tmp/huge",
                size: 6 * 1024 * 1024 * 1024, // 6GB
                nature: .losslessCache,
                consequence: "大构建产物",
                category: .devResidue,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-60 * 86400), level: .dormant)
            )
            guard hugeCache.recommendationScore.totalScore > smallCache.recommendationScore.totalScore else { return false }
            guard hugeCache.recommendationScore.tier == .high else { return false }

            // 3. 边界值在 0 ~ 100 之间
            guard hugeCache.recommendationScore.totalScore <= 100.0 && smallCache.recommendationScore.totalScore >= 0.0 else { return false }

            return true
        }

        check("智能推荐与状态联动：selectSmartRecommendations 准确勾选高价值项并严格排除白名单") {
            let app = AppState()
            let now = Date()

            // 创建 high 推荐项
            let itemHigh = CleanItem(
                name: "High Rec Item",
                path: "/private/tmp/smart_high",
                size: 2 * 1024 * 1024 * 1024,
                nature: .losslessCache,
                consequence: "无损缓存",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-90 * 86400), level: .dormant)
            )
            // 创建 medium 推荐项
            let itemMedium = CleanItem(
                name: "Medium Rec Item",
                path: "/private/tmp/smart_med",
                size: 20 * 1024 * 1024,
                nature: .losslessCache,
                consequence: "普通日志",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-15 * 86400), level: .occasional)
            )
            // 创建 low 推荐项（近期活跃）
            let itemLow = CleanItem(
                name: "Low Rec Item",
                path: "/private/tmp/smart_low",
                size: 1024,
                nature: .losslessCache,
                consequence: "刚写的缓存",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now, level: .active)
            )
            // 创建白名单项（即便评分极高，也绝不入选）
            let itemWhitelisted = CleanItem(
                name: "Whitelisted Item",
                path: "/private/tmp/smart_white",
                size: 5 * 1024 * 1024 * 1024,
                nature: .losslessCache,
                consequence: "白名单缓存",
                category: .userCaches,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: now.addingTimeInterval(-100 * 86400), level: .dormant)
            )

            let catState = app.state(for: .userCaches)
            catState.items = [itemHigh, itemMedium, itemLow, itemWhitelisted]
            catState.isScanned = true

            // 添加白名单
            let whiteRule = app.whitelist.addPathRule(itemWhitelisted.path)
            defer { app.whitelist.removeRule(id: whiteRule.id) }

            // 验证 smartRecommendedItems 过滤行为
            let recItems = app.smartRecommendedItems
            guard recItems.contains(where: { $0.id == itemHigh.id }) else { return false }
            guard recItems.contains(where: { $0.id == itemMedium.id }) else { return false }
            guard !recItems.contains(where: { $0.id == itemLow.id }) else { return false }
            guard !recItems.contains(where: { $0.id == itemWhitelisted.id }) else { return false }

            // 验证一键勾选动作
            app.selectSmartRecommendations()
            let selectedHigh = catState.items.first(where: { $0.id == itemHigh.id })?.isSelected ?? false
            let selectedMed = catState.items.first(where: { $0.id == itemMedium.id })?.isSelected ?? false
            let selectedLow = catState.items.first(where: { $0.id == itemLow.id })?.isSelected ?? false
            let selectedWhite = catState.items.first(where: { $0.id == itemWhitelisted.id })?.isSelected ?? false

            guard selectedHigh && selectedMed && !selectedLow && !selectedWhite else { return false }

            // 验证一键取消勾选
            app.clearAllSelections()
            guard catState.items.allSatisfy({ !$0.isSelected }) else { return false }

            return true
        }
    }
}
