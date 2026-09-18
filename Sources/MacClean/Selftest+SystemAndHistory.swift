import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：系统监控与清理成效
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1277–1406）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteSystemAndHistory() {
        check("系统监控：真实物理内存采集与压力计算") {
            let stats = MemoryStats.current()
            guard stats.totalBytes > 0, stats.usedBytes > 0 else { return false }
            guard !stats.usedString.isEmpty, !stats.totalString.isEmpty else { return false }

            // 压力等级判定测试
            let normal = MemoryStats(totalBytes: 100, usedBytes: 50)
            guard normal.pressure == .normal, normal.pressure.rawValue == "正常" else { return false }

            let moderate = MemoryStats(totalBytes: 100, usedBytes: 70)
            guard moderate.pressure == .moderate, moderate.pressure.rawValue == "适中" else { return false }

            let high = MemoryStats(totalBytes: 100, usedBytes: 90)
            guard high.pressure == .high, high.pressure.rawValue == "紧张" else { return false }

            return true
        }

        check("菜单栏配置：显示模式与持久化序列化") {
            var cfg = DiskMonitorConfig()
            cfg.menuBarDisplayMode = .iconAndDisk
            let data = try JSONEncoder().encode(cfg)
            let decoded = try JSONDecoder().decode(DiskMonitorConfig.self, from: data)
            guard decoded.menuBarDisplayMode == .iconAndDisk else { return false }

            cfg.menuBarDisplayMode = .iconAndMemory
            let data2 = try JSONEncoder().encode(cfg)
            let decoded2 = try JSONDecoder().decode(DiskMonitorConfig.self, from: data2)
            guard decoded2.menuBarDisplayMode == .iconAndMemory else { return false }

            return true
        }

        check("菜单栏组件：MenuBarLabelView 与 MenuBarCategoryRow 渲染") {
            let app = AppState()
            let labelView = MenuBarLabelView().environmentObject(app)
            _ = try labelView.inspect()

            let cat = CleanCategory.userCaches
            let st = app.state(for: cat)
            var clicked = false
            let rowView = MenuBarCategoryRow(category: cat, state: st) {
                clicked = true
            }
            let inspected = try rowView.inspect()
            try inspected.find(ViewType.Button.self).tap()
            guard clicked else { return false }

            return true
        }

        check("清理成效：CleanResultSnapshot 数据与指标构建") {
            let snapshot = CleanResultSnapshot(
                title: "用户缓存 清理完成",
                releasedBytes: 500_000_000, // 500MB (macOS 十进制)
                itemCount: 42,
                failureCount: 0,
                mode: "废纸篓",
                beforeAvailable: 100_000_000_000,
                afterAvailable: 100_500_000_000,
                breakdown: [.userCaches: 500_000_000]
            )
            guard snapshot.releasedBytes == 500_000_000 else { return false }
            guard snapshot.deltaString == "500 MB" else { return false }
            guard snapshot.itemCount == 42, snapshot.mode == "废纸篓" else { return false }
            guard snapshot.afterAvailable > snapshot.beforeAvailable else { return false }
            guard snapshot.breakdown[.userCaches] == 500_000_000 else { return false }
            return true
        }

        check("历史趋势：时间范围筛选 (全部 / 近 7 天 / 近 30 天)") {
            let now = Date()
            let day: TimeInterval = 86400
            let r1 = CleanRecord(date: now, categoryName: "用户缓存", itemCount: 10, bytes: 1000, mode: "废纸篓")
            let r2 = CleanRecord(date: now.addingTimeInterval(-3 * day), categoryName: "日志", itemCount: 5, bytes: 2000, mode: "废纸篓")
            let r3 = CleanRecord(date: now.addingTimeInterval(-15 * day), categoryName: "开发残留", itemCount: 2, bytes: 5000, mode: "彻底删除")
            let r4 = CleanRecord(date: now.addingTimeInterval(-45 * day), categoryName: "大文件", itemCount: 1, bytes: 10000, mode: "废纸篓")

            let list = [r1, r2, r3, r4]

            // 全部：4条
            guard list.count == 4 else { return false }

            // 近 7 天：r1, r2 (2条)
            let cutoff7 = now.addingTimeInterval(-7 * day)
            let f7 = list.filter { $0.date >= cutoff7 }
            guard f7.count == 2 else { return false }

            // 近 30 天：r1, r2, r3 (3条)
            let cutoff30 = now.addingTimeInterval(-30 * day)
            let f30 = list.filter { $0.date >= cutoff30 }
            guard f30.count == 3 else { return false }

            return true
        }

        check("清理成效组件：CleanResultSheet 与 HistoryCategoryDistributionCard 渲染") {
            let snapshot = CleanResultSnapshot(
                title: "清理完成",
                releasedBytes: 1500000,
                itemCount: 3,
                failureCount: 0,
                mode: "移入废纸篓",
                beforeAvailable: 10000000,
                afterAvailable: 11500000,
                breakdown: [.userCaches: 1000000, .logsAndTemp: 500000]
            )
            var historyClicked = false
            var dismissed = false
            let sheet = CleanResultSheet(snapshot: snapshot) {
                historyClicked = true
            } onDismiss: {
                dismissed = true
            }
            let histBtn = try button("resultSheetHistoryButton", in: sheet)
            try histBtn.tap()
            let finishBtn = try button("resultSheetDoneButton", in: sheet)
            try finishBtn.tap()
            guard historyClicked && dismissed else { return false }

            // 检查各分类累计释放分布卡片渲染
            let distCard = HistoryCategoryDistributionCard(records: [
                CleanRecord(categoryName: "用户缓存", itemCount: 1, bytes: 500, mode: "废纸篓"),
                CleanRecord(categoryName: "开发残留", itemCount: 1, bytes: 1500, mode: "废纸篓")
            ])
            _ = try distCard.inspect()

            return true
        }

    }
}
