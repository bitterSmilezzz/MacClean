import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：无人值守与后台开销
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 2615–2727）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteUnattended() {
        // MARK: - 无人值守路径（磁盘巡检与静默清理）

        // MARK: - 后台开销（菜单栏常驻应用的耗电来源）

        check("菜单栏轮询：仅图标模式不轮询，只有内存显示才需要轮询") {
            // 原实现是无条件每 3 秒刷新一次内存并触发 SwiftUI 重绘，
            // 即便标签上只有图标、根本没有动态内容。菜单栏应用是常驻的，
            // 这等于让 CPU 每 3 秒被唤醒一次直到 App 退出。
            let iconOnly = MenuBarLabelView.requiredPollingMode(displayMode: .iconOnly)
            let disk = MenuBarLabelView.requiredPollingMode(displayMode: .iconAndDisk)
            let memory = MenuBarLabelView.requiredPollingMode(displayMode: .iconAndMemory)
            guard iconOnly == .dormant, disk == .dormant else { return false }
            guard memory == .background else { return false }
            // 档位间隔：前台 3s、后台 15s、休眠不轮询
            guard SystemMonitor.PollingMode.foreground.interval == SystemMonitor.foregroundInterval,
                  SystemMonitor.PollingMode.background.interval == SystemMonitor.backgroundInterval,
                  SystemMonitor.PollingMode.dormant.interval == nil else { return false }
            // 后台必须比前台慢，否则分档没有意义
            return SystemMonitor.backgroundInterval > SystemMonitor.foregroundInterval
        }

        check("低空间告警：持续低于阈值时按冷却期节流，不刷屏") {
            // 历史缺陷：checkDiskSpaceAlert 每次调用都无条件发通知，而它挂在 refreshDisk() 上，
            // refreshDisk() 又在每个分类扫描结束时被调用 —— scanAll 几秒内就发 6 条通知，
            // 之后每 3 小时重复一轮，直到用户腾出空间。
            let monitor = DiskMonitor.shared
            let saved = monitor.config
            defer { monitor.config = saved }

            var cfg = DiskMonitorConfig()
            cfg.lowSpaceAlertEnabled = true
            cfg.lowSpaceThresholdGB = 15
            monitor.config = cfg

            let t0 = Date()
            let low = Int64(5_000_000_000)      // 5 GB < 15 GB
            let ok = Int64(50_000_000_000)      // 50 GB

            // 先确保处于"空间充足"状态，把边沿重置掉
            monitor.checkDiskSpaceAlert(availableBytes: ok, now: t0)

            // 首次跌破 → 置位
            monitor.checkDiskSpaceAlert(availableBytes: low, now: t0)
            guard monitor.showLowSpaceAlert else { return false }

            // 模拟"扫描结束又检查一次"：清掉弹窗后立刻再检查，冷却期内不该再置位
            monitor.showLowSpaceAlert = false
            monitor.checkDiskSpaceAlert(availableBytes: low, now: t0.addingTimeInterval(60))
            guard !monitor.showLowSpaceAlert else { return false }

            // 仍是低空间，再来一次（模拟多轮扫描）→ 依旧不该置位
            monitor.checkDiskSpaceAlert(availableBytes: low, now: t0.addingTimeInterval(3600))
            guard !monitor.showLowSpaceAlert else { return false }

            // 超过冷却期 → 允许再提醒一次
            monitor.checkDiskSpaceAlert(availableBytes: low,
                                        now: t0.addingTimeInterval(DiskMonitor.lowSpaceCooldown + 1))
            guard monitor.showLowSpaceAlert else { return false }

            // 空间恢复 → 状态重置，下次跌破应立刻再提醒
            monitor.showLowSpaceAlert = false
            monitor.checkDiskSpaceAlert(availableBytes: ok, now: t0.addingTimeInterval(70000))
            monitor.checkDiskSpaceAlert(availableBytes: low, now: t0.addingTimeInterval(70100))
            return monitor.showLowSpaceAlert
        }

        check("静默清理：等待扫描落地而不是固定延时（半份数据不动手）") {
            // 原实现是 asyncAfter(4.0)：扫描慢于 4 秒时清理会跑在半份数据上。
            // 这里只验证"上限兜底"的存在与取值合理，实际等待逻辑依赖主线程轮询。
            guard DiskMonitor.maxScanWaitAttempts >= 30 else { return false }
            // 上一个用例把 shared 的 config 改过，这里确认默认可关闭自动清理
            let cfg = DiskMonitorConfig()
            return cfg.autoCleanEnabled == false
                && cfg.autoCleanUserCaches && cfg.autoCleanLogsAndTemp
        }

        check("安全护栏：系统级硬保护一律拒绝清理（G8）") {
            for p in ["/Library/Updates", "/System/Volumes/Data", "/private/var/vm",
                      "/private/var/db/receipts", "/private/var/folders/zz"] {
                guard !FileSystem.isSafeToClean(p) else { return false }
            }
            return true
        }

        check("安全护栏：应用共享容器与云盘目录拒绝清理（G6 v1.1 新增）") {
            let home = NSHomeDirectory()
            for p in ["\(home)/Library/Group Containers/group.com.example",
                      "\(home)/Library/Mobile Documents/com~apple~CloudDocs",
                      "\(home)/Library/CloudStorage/GoogleDrive-x"] {
                guard !FileSystem.isSafeToClean(p) else { return false }
            }
            return true
        }

        check("安全护栏：常规缓存仍可正常清理（放行未被收紧过度）") {
            let home = NSHomeDirectory()
            guard FileSystem.isSafeToClean("\(home)/Library/Caches/com.example.app") else { return false }
            guard FileSystem.isSafeToClean("/private/tmp/macclean-selftest-probe") else { return false }
            // 主目录本身与根目录永远不可清理
            guard !FileSystem.isSafeToClean(home) else { return false }
            guard !FileSystem.isSafeToClean("/") else { return false }
            return true
        }

        check("TCC：可区分「读不到」与「真的空」（G9）") {
            // 不存在的路径不应被判为"权限拒绝"
            guard !FileSystem.isPermissionDenied("/nonexistent-macclean-selftest-probe") else { return false }
            // 可读目录不应被误判为权限拒绝
            guard !FileSystem.isPermissionDenied(NSTemporaryDirectory()) else { return false }
            // hasFullDiskAccess 环境相关，仅要求可调用并返回布尔
            _ = FileSystem.hasFullDiskAccess()
            return true
        }
    }
}
