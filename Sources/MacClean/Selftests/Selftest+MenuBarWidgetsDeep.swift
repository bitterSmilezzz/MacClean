import Foundation
import Combine
import SwiftUI
import ViewInspector

// 自检套件：菜单栏常驻助手快捷小组件与状态指示深化 (v1.51.0)
extension Selftest {
    static func suiteMenuBarWidgetsDeep() {
        check("菜单栏回收趋势：近 7 天每日释放量统计聚合 (dailyFreedBytesLast7Days)") {
            let calendar = Calendar.current
            let now = Date()

            // 构造测试清理记录：
            // - 今天：10 MB
            // - 昨天：20 MB
            // - 3 天前：30 MB
            // - 10 天前：50 MB（应被过滤排除）
            let todayDate = now
            let yesterdayDate = calendar.date(byAdding: .day, value: -1, to: now)!
            let threeDaysAgoDate = calendar.date(byAdding: .day, value: -3, to: now)!
            let tenDaysAgoDate = calendar.date(byAdding: .day, value: -10, to: now)!

            let testRecords = [
                CleanRecord(date: todayDate, categoryName: "系统垃圾", itemCount: 5, bytes: 10 * 1024 * 1024, mode: "废纸篓"),
                CleanRecord(date: yesterdayDate, categoryName: "应用缓存", itemCount: 8, bytes: 20 * 1024 * 1024, mode: "废纸篓"),
                CleanRecord(date: threeDaysAgoDate, categoryName: "开发残留", itemCount: 12, bytes: 30 * 1024 * 1024, mode: "彻底删除"),
                CleanRecord(date: tenDaysAgoDate, categoryName: "大文件", itemCount: 20, bytes: 50 * 1024 * 1024, mode: "废纸篓")
            ]

            let trend = HistoryStore.dailyFreedBytesLast7Days(records: testRecords, relativeTo: now)
            guard trend.count == 7 else { return false }

            // 最后一个柱子为当天，标签为 "今"
            guard let lastItem = trend.last, lastItem.dayLabel == "今" else { return false }
            guard lastItem.bytes == 10 * 1024 * 1024 else { return false }

            // 倒数第二个柱子为昨天
            let yesterdayItem = trend[trend.count - 2]
            guard yesterdayItem.bytes == 20 * 1024 * 1024 else { return false }

            // 倒数第四个柱子为 3 天前
            let threeDaysAgoItem = trend[trend.count - 4]
            guard threeDaysAgoItem.bytes == 30 * 1024 * 1024 else { return false }

            // 10 天前的记录绝不能泄露进入 7 天聚合中
            let totalInTrend = trend.reduce(0) { $0 + $1.bytes }
            guard totalInTrend == 60 * 1024 * 1024 else { return false }

            // 空记录边界测试
            let emptyTrend = HistoryStore.dailyFreedBytesLast7Days(records: [], relativeTo: now)
            guard emptyTrend.count == 7 else { return false }
            guard emptyTrend.allSatisfy({ $0.bytes == 0 }) else { return false }

            return true
        }

        check("菜单栏回收趋势：近 7 天累计减负总量计算 (totalFreedLast7Days)") {
            let calendar = Calendar.current
            let now = Date()

            let recordInWeek1 = CleanRecord(date: now, categoryName: "系统垃圾", itemCount: 1, bytes: 100 * 1024, mode: "废纸篓")
            let recordInWeek2 = CleanRecord(date: calendar.date(byAdding: .day, value: -5, to: now)!, categoryName: "应用缓存", itemCount: 2, bytes: 200 * 1024, mode: "废纸篓")
            let recordOld = CleanRecord(date: calendar.date(byAdding: .day, value: -15, to: now)!, categoryName: "开发残留", itemCount: 5, bytes: 999 * 1024, mode: "彻底删除")

            let total = HistoryStore.totalFreedLast7Days(records: [recordInWeek1, recordInWeek2, recordOld], relativeTo: now)
            guard total == 300 * 1024 else { return false }

            guard HistoryStore.totalFreedLast7Days(records: [], relativeTo: now) == 0 else { return false }
            return true
        }

        check("菜单栏系统工具：本地快照与幽灵自启项批量清理边界与状态健壮性") {
            // 1. 空快照批量释放
            let snapRes = SystemDeepStorageInspector.deleteAllLocalSnapshots(snapshots: [])
            guard snapRes.succeededCount == 0 && snapRes.failedCount == 0 else { return false }

            // 2. 空自启项批量清理
            let startupRes = StartupItemManager.shared.cleanAllDangling(items: [])
            guard startupRes.removedCount == 0 && startupRes.freedBytes == 0 else { return false }

            // 3. 幽灵自启项判定
            let danglingMissing = StartupItemStatus.missingExecutable
            let danglingOrphan = StartupItemStatus.orphanedApp
            let validNormal = StartupItemStatus.valid

            guard danglingMissing.isDangling == true else { return false }
            guard danglingOrphan.isDangling == true else { return false }
            guard validNormal.isDangling == false else { return false }

            return true
        }

        check("菜单栏浮窗渲染：底层存储体检组与存储回收趋势微卡 ViewInspector 检验") {
            let app = AppState()
            let menuBarView = MenuBarView().environmentObject(app)

            guard let inspected = try? menuBarView.inspect() else { return false }

            // 检验底层存储体检组存在
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "menuBarSystemToolsGroup")) != nil else {
                return false
            }

            // 检验存储回收趋势微卡存在
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "menuBarRecoveryTrendGroup")) != nil else {
                return false
            }

            return true
        }
    }
}
