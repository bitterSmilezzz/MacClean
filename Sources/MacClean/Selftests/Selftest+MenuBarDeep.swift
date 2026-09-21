import Foundation
import Combine
import SwiftUI

// 自检套件：日常运行与菜单栏常驻调优 (v1.45.0)
extension Selftest {
    static func suiteMenuBarDeep() {
        check("常驻能耗调优：SystemMonitor 休眠时挂起与唤醒时恢复") {
            let monitor = SystemMonitor.shared
            monitor.apply(mode: .background)
            guard monitor.mode == .background, !monitor.isSleeping else { return false }

            // 模拟系统合盖休眠
            monitor.handleWillSleep()
            guard monitor.isSleeping else { return false }

            // 处于休眠态时设置档位应被暂存
            monitor.apply(mode: .foreground)
            guard monitor.isSleeping else { return false }

            // 模拟系统唤醒
            monitor.handleDidWake()
            guard !monitor.isSleeping, monitor.mode == .foreground else { return false }

            // 还原为默认 dormant 档位
            monitor.apply(mode: .dormant)
            guard monitor.mode == .dormant else { return false }

            return true
        }

        check("常驻能耗调优：DiskMonitor 休眠挂起与唤醒重调度") {
            let diskMon = DiskMonitor.shared
            guard !diskMon.isSleeping else { return false }

            // 模拟系统休眠
            diskMon.handleWillSleep()
            guard diskMon.isSleeping else { return false }

            // 模拟系统唤醒
            diskMon.handleDidWake()
            guard !diskMon.isSleeping else { return false }

            return true
        }

        check("常驻能耗调优：MenuBarLabelView 档位映射 (requiredPollingMode)") {
            // iconOnly 与 iconAndDisk 均不需要内存定时器轮询（0 唤醒）
            guard MenuBarLabelView.requiredPollingMode(displayMode: .iconOnly) == .dormant else { return false }
            guard MenuBarLabelView.requiredPollingMode(displayMode: .iconAndDisk) == .dormant else { return false }
            // 仅 iconAndMemory 模式才需要 background 档位刷新
            guard MenuBarLabelView.requiredPollingMode(displayMode: .iconAndMemory) == .background else { return false }
            return true
        }

        check("菜单栏交互增强：清理成效横幅与即时撤销链路") {
            let app = AppState()
            let dummySnapshot = CleanResultSnapshot(
                title: "测试清理",
                releasedBytes: 1024 * 1024 * 50, // 50 MB
                itemCount: 5,
                failureCount: 0,
                mode: "废纸篓",
                beforeAvailable: 100_000_000,
                afterAvailable: 150_000_000,
                breakdown: [:],
                timestamp: Date(),
                undoSessionID: UUID()
            )

            app.lastCleanSummary = "已释放 50 MB"
            app.lastCleanResult = dummySnapshot

            guard app.lastCleanSummary == "已释放 50 MB" else { return false }
            guard let res = app.lastCleanResult, res.canUndo else { return false }
            guard res.releasedBytes == 1024 * 1024 * 50 else { return false }

            // 模拟关闭反馈
            app.lastCleanSummary = nil
            app.lastCleanResult = nil
            guard app.lastCleanSummary == nil && app.lastCleanResult == nil else { return false }

            return true
        }
    }
}
