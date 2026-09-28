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

        // MARK: - 废纸篓自动清空（v1.73.14）

        check("废纸篓自动清空：开关关闭时是 no-op，不碰任何文件系统") {
            // 注入 config（enabled=false），**永不**读真实 UserDefaults/真实废纸篓：
            // 万一开发者本机开着这个开关，无注入的自检就会清空用户真废纸篓。
            guard TrashAutoEmptyService.emptyIfEnabled(config: DiskMonitorConfig()) == nil else {
                print("      默认配置（关）却执行了清空")
                return false
            }
            guard TrashAutoEmptyService.emptyIfEnabled(
                trashRoot: "/nonexistent-macclean-probe",
                config: DiskMonitorConfig()) == nil else {
                print("      默认配置（关）却执行了清空")
                return false
            }
            return true
        }

        check("废纸篓自动清空：到期项删除、未到期保留、历史落账、无撤销快照") {
            // 夹具放 /private/tmp：网关的常规放行根是主目录与 /private/tmp，
            // 不含 per-user 的 /var/folders——生产路径 ~/.Trash 在主目录内不受影响，
            // 夹具想经网关真删就必须落在放行根里（用 /var/folders 会全数被拒）。
            let root = "/private/tmp/macclean-trash-fixture-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let fm = FileManager.default
            let oldFile = (root as NSString).appendingPathComponent("old.txt")
            let recentFile = (root as NSString).appendingPathComponent("recent.txt")
            let oldDir = (root as NSString).appendingPathComponent("olddir")
            fm.createFile(atPath: oldFile, contents: Data(repeating: 3, count: 4096))
            fm.createFile(atPath: recentFile, contents: Data(repeating: 4, count: 2048))
            try? fm.createDirectory(atPath: oldDir, withIntermediateDirectories: true)
            fm.createFile(atPath: (oldDir as NSString).appendingPathComponent("inner.bin"),
                          contents: Data(repeating: 5, count: 8192))
            let old = Date().addingTimeInterval(-40 * 86400)
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: oldFile)
            try? fm.setAttributes([.modificationDate: old], ofItemAtPath: oldDir)

            let beforeID = HistoryStore.load().first?.id
            let out = TrashAutoEmptyService.emptyOlderThan(days: 30, trashRoot: root)
            guard out.rootUnreadable == false, out.cleaned == 2, out.skippedRecent >= 1 else {
                print("      cleaned=\(out.cleaned) skipped=\(out.skippedRecent) unreadable=\(out.rootUnreadable)"
                      + " scanned=\(out.scanned) rejected=\(out.rejected.map { "\($0.name): \($0.message)" })"
                      + " failed=\(out.failed.map { "\($0.name): \($0.message)" })")
                return false
            }
            guard out.freedBytes > 0 else {
                print("      freedBytes=\(out.freedBytes)，删除前实测体积没记账")
                return false
            }
            guard !fm.fileExists(atPath: oldFile), !fm.fileExists(atPath: oldDir),
                  fm.fileExists(atPath: recentFile) else {
                print("      到期项没删干净或未到期项被误删")
                return false
            }
            // 历史：按身份比对（不比绝对条数——两个存储都有上限裁剪）
            let after = HistoryStore.load()
            guard after.first?.id != beforeID,
                  after.first?.categoryName == "废纸篓自动清空",
                  after.first?.bytes == out.freedBytes else {
                print("      历史记录缺失或字段对不上：\(after.first.map { "\($0.categoryName) \($0.bytes)" } ?? "nil")")
                return false
            }
            // 彻底删除不该有撤销快照（不可恢复是本功能定义；有快照反而说明走了废纸篓）
            if let rec = after.first, UndoManagerStore.session(for: rec.id) != nil {
                print("      彻底删除却落了撤销快照——闸门走错档了")
                return false
            }
            return true
        }

        check("废纸篓自动清空：根读不到时明示 rootUnreadable，什么都不删、不落账（G9）") {
            let root = "/private/tmp/macclean-trash-locked-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            let inner = (root as NSString).appendingPathComponent("victim.txt")
            FileManager.default.createFile(atPath: inner, contents: Data(repeating: 9, count: 1024))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
                try? FileManager.default.removeItem(atPath: root)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            let beforeID = HistoryStore.load().first?.id
            let out = TrashAutoEmptyService.emptyOlderThan(days: 30, trashRoot: root)
            guard out.rootUnreadable, out.cleaned == 0 else {
                print("      读不到的根没有明示：unreadable=\(out.rootUnreadable) cleaned=\(out.cleaned)")
                return false
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
            guard FileManager.default.fileExists(atPath: inner) else {
                print("      根读不到却删了里面的文件——G9 被违反")
                return false
            }
            guard HistoryStore.load().first?.id == beforeID else {
                print("      什么都没删却写了清理历史——凭空记账")
                return false
            }
            return true
        }

        check("废纸篓自动清空：policy 二道闸必须钉「废纸篓根的直接子项」（源码形状）") {
            // 这道防御在服务自己的枚举下**结构上不可达**（候选本来就来自根的顶层枚举），
            // 它保护的是"将来有人改了候选来源"——按清单规矩，不可达分支不配行为自检，
            // 钉形状：policy 闭包必须存在且判据是「父目录 == 废纸篓根」。
            let path = (Selftest.sourceDirectoryPath as NSString)
                .appendingPathComponent("TrashAutoEmptyService.swift")
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("      TrashAutoEmptyService.swift 不可读")
                return false
            }
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            guard code.contains("parent==normRoot") else {
                print("      二道闸判据不见了——越出废纸篓的删除不再被兜")
                return false
            }
            guard code.contains("toTrash:false") else {
                print("      没有走彻底删除档——自动清空变成了二次进废纸篓")
                return false
            }
            return true
        }

        check("DiskMonitorConfig：老配置数据缺 trashAutoEmpty* 键不得整份解码失败（复审 #1 的防回归）") {
            // Swift 合成 Codable **不用属性默认值**：老数据缺一个新键 → 整份 throw →
            // `load()` 回落出厂值 → 用户已有的全部设置被静默重置。手写 `init(from:)`
            // 是唯一防线；旧断言全是「先 encode 再 decode」的往返，**结构上测不出缺键**
            // （复审变异实测：删掉手写解码，全仓自检照样全绿）。这里手造老格式载荷。
            guard let encoded = try? JSONEncoder().encode(DiskMonitorConfig()),
                  var obj = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                print("      夹具构造失败")
                return false
            }
            obj.removeValue(forKey: "trashAutoEmptyEnabled")
            obj.removeValue(forKey: "trashAutoEmptyDays")
            obj["scanIntervalHours"] = 9      // 模拟老数据里用户自己的设置
            obj["autoCleanEnabled"] = true
            guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
            guard let decoded = try? JSONDecoder().decode(DiskMonitorConfig.self, from: data) else {
                print("      缺新键的旧配置解码失败——手写 decodeIfPresent 被拆了？")
                return false
            }
            guard decoded.trashAutoEmptyEnabled == false, decoded.trashAutoEmptyDays == 30 else {
                print("      新字段没有落默认值：\(decoded.trashAutoEmptyEnabled) / \(decoded.trashAutoEmptyDays)")
                return false
            }
            // 老数据里用户自己的设置必须原样活下来（这才是"被静默重置"的本体）
            return decoded.scanIntervalHours == 9 && decoded.autoCleanEnabled == true
        }
    }
}
