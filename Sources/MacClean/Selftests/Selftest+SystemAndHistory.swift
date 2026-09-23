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

        check("历史写入：AppState 的内存缓存不会抹掉其他模块已落盘的记录") {
            guard MacCleanState.isIsolated else { return false }
            let snapshot = HistoryStore.load()
            defer { HistoryStore.replaceAllForSelftest(snapshot) }
            HistoryStore.replaceAllForSelftest([])

            let app = AppState()
            // 启动时读盘一次；此后别的模块继续往盘上追加
            guard app.history.isEmpty else { return false }
            _ = HistoryStore.append(CleanRecord(categoryName: "删除网关侧记账", itemCount: 1,
                                                bytes: 1024, mode: "废纸篓", failures: 0))

            _ = app.recordClean(categoryName: "主界面清理", itemCount: 1, bytes: 2048,
                                mode: "废纸篓", failures: 0)

            // 旧实现：recordClean 拿启动时那份缓存整片写回 → 网关那条直接消失
            let onDisk = HistoryStore.load()
            guard onDisk.count == 2 else {
                print("      盘上只剩 \(onDisk.count) 条，另一条被陈旧缓存覆盖")
                return false
            }
            let names = Set(onDisk.map(\.categoryName))
            guard names.contains("删除网关侧记账"), names.contains("主界面清理") else { return false }
            // 内存缓存也必须跟上盘的真实内容，否则下一次写回又会丢
            return app.history.count == 2
        }

        check("历史写入：并发 append 一条都不丢（唯一写入口自己串行）") {
            guard MacCleanState.isIsolated else { return false }
            let snapshot = HistoryStore.load()
            defer { HistoryStore.replaceAllForSelftest(snapshot) }
            HistoryStore.replaceAllForSelftest([])

            let rounds = 12
            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            for i in 0..<rounds {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    start.wait()
                    _ = HistoryStore.append(CleanRecord(categoryName: "并发自检-\(i)", itemCount: 1,
                                                        bytes: Int64(i), mode: "废纸篓", failures: 0))
                }
            }
            for _ in 0..<rounds { start.signal() }
            group.wait()

            let onDisk = HistoryStore.load()
            guard onDisk.count == rounds, Set(onDisk.map(\.categoryName)).count == rounds else {
                print("      并发写了 \(rounds) 条，盘上只有 \(onDisk.count) 条")
                return false
            }
            return true
        }

        check("撤销快照：并发 record 一条都不丢（mutate 自己串行）") {
            guard MacCleanState.isIsolated else { return false }
            let snapshot = UndoManagerStore.load()
            defer { UndoManagerStore.replaceAllForSelftest(snapshot) }
            UndoManagerStore.replaceAllForSelftest([])

            let rounds = 12
            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            let ids = (0..<rounds).map { _ in UUID() }
            for (i, id) in ids.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    start.wait()
                    UndoManagerStore.record(session: CleanUndoSession(
                        id: id, recordID: UUID(),
                        entries: [TrashedItemEntry(originalPath: "/private/tmp/mc-\(i)",
                                                   trashPath: "/private/tmp/mc-trash-\(i)",
                                                   size: Int64(i), itemName: "e\(i)")]))
                }
            }
            for _ in 0..<rounds { start.signal() }
            group.wait()

            let onDisk = UndoManagerStore.load()
            let present = Set(onDisk.map(\.id))
            guard onDisk.count == rounds, ids.allSatisfy({ present.contains($0) }) else {
                print("      并发写了 \(rounds) 份快照，盘上只有 \(onDisk.count) 份")
                return false
            }
            return true
        }

        check("历史与快照写入不变量：两个存储的 save 只许在各自文件内被调用") {
            let sourceDir = Selftest.sourceDirectoryPath
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: sourceDir)) ?? []
            let files = all.filter {
                $0.hasSuffix(".swift") && !$0.hasPrefix("Selftests/")
                    && $0 != "History.swift" && $0 != "UndoSnapshot.swift"
            }.sorted()
            // 实测命中 117 个文件；下界留余量，但撞红时要能一眼看出是范围问题还是余量问题
            guard files.count > 110 else {
                print("      源码文件数异常（读到 \(files.count) 个），扫描范围没铺开")
                return false
            }
            var offenders: [String] = []
            for rel in files {
                let path = (sourceDir as NSString).appendingPathComponent(rel)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(rel):<不可读>")
                    continue
                }
                for (idx, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                    if t.contains("HistoryStore.save") || t.contains("UndoManagerStore.save")
                        || t.contains("replaceAllForSelftest") {
                        offenders.append("\(rel):\(idx + 1)")
                    }
                }
            }
            if !offenders.isEmpty { print("      绕过唯一写入口: \(offenders.prefix(5))") }
            return offenders.isEmpty
        }

        check("历史清空：盘与内存缓存同时清空（锁由上面那条并发断言守）") {
            guard MacCleanState.isIsolated else { return false }
            let snapshot = HistoryStore.load()
            defer { HistoryStore.replaceAllForSelftest(snapshot) }
            HistoryStore.replaceAllForSelftest([])
            _ = HistoryStore.append(CleanRecord(categoryName: "待清空", itemCount: 1, bytes: 1,
                                                mode: "废纸篓", failures: 0))
            guard HistoryStore.load().count == 1 else { return false }

            let app = AppState()
            app.history = HistoryStore.load()
            guard !app.history.isEmpty else { return false }
            app.clearHistory()
            return HistoryStore.load().isEmpty && app.history.isEmpty
        }

        check("历史：状态目录不可写时 clear() 报失败，append() 仍保住界面上那一行") {
            guard MacCleanState.isIsolated else { return false }
            let fm = FileManager.default
            let dir = "/private/tmp/macclean_rohist_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let savedOverride = HistoryStore.fileURLOverride
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
                try? fm.removeItem(atPath: dir)
                HistoryStore.fileURLOverride = savedOverride
            }
            HistoryStore.fileURLOverride = URL(fileURLWithPath: dir + "/history.json")
            _ = HistoryStore.append(CleanRecord(categoryName: "可写期", itemCount: 1, bytes: 1,
                                                mode: "废纸篓", failures: 0))
            guard HistoryStore.load().count == 1 else { return false }

            // `.atomic` 是同目录建临时文件再 rename，只看**目录**写权限
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
            let merged = HistoryStore.append(CleanRecord(categoryName: "写失败期", itemCount: 1,
                                                         bytes: 2, mode: "废纸篓", failures: 0))
            // 写失败时返回值仍要含着刚那一条，否则界面上那行凭空消失=把没记成报成没发生
            guard merged.contains(where: { $0.categoryName == "写失败期" }) else { return false }
            guard !HistoryStore.load().contains(where: { $0.categoryName == "写失败期" }) else { return false }
            let cleared = HistoryStore.clear()
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
            return cleared == false
        }

        check("撤销快照：文件搬回原位但记账失败时，必须把这件事说出来") {
            guard MacCleanState.isIsolated else { return false }
            let fm = FileManager.default
            let dir = "/private/tmp/macclean_roundo_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir + "/trash", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: dir + "/orig", withIntermediateDirectories: true)
            let trashPath = dir + "/trash/put-me-back.bin"
            try? Data(repeating: 0x4D, count: 512).write(to: URL(fileURLWithPath: trashPath))

            let savedOverride = UndoManagerStore.fileURLOverride
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
                try? fm.removeItem(atPath: dir)
                UndoManagerStore.fileURLOverride = savedOverride
            }
            UndoManagerStore.fileURLOverride = URL(fileURLWithPath: dir + "/undo_sessions.json")
            let session = CleanUndoSession(
                recordID: UUID(),
                entries: [TrashedItemEntry(originalPath: dir + "/orig/put-me-back.bin",
                                           trashPath: trashPath, size: 512, itemName: "put-me-back.bin")])
            UndoManagerStore.record(session: session)
            guard UndoManagerStore.load().count == 1 else { return false }

            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
            let res = UndoManagerStore.restore(sessionID: session.id)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)

            // 文件确实搬回去了，但快照没写成 → 必须报错，不能静默
            guard res.succeeded == 1, fm.fileExists(atPath: dir + "/orig/put-me-back.bin") else { return false }
            return res.errors.contains { $0.contains("未能记账") }
        }

        check("撤销快照 restore：不得退回「开头读一份数组、结尾整片写回」的形状") {
            let path = (Selftest.sourceDirectoryPath as NSString).appendingPathComponent("UndoSnapshot.swift")
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("      读不到 \(path)")
                return false
            }
            // 退回旧写法会各自多出一次 `load()` 与一次 `save(sessions)`——这两个计数就是形状指纹
            let loads = src.components(separatedBy: "var sessions = load()").count - 1
            let saves = src.components(separatedBy: "save(sessions)").count - 1
            guard loads == 1, saves == 1 else {
                print("      restore 形状变了：load \(loads) 次 / 整片 save \(saves) 次（应各 1 次，都在 mutate 内）")
                return false
            }
            return true
        }

        check("历史可见性：别的模块直接 append 的记录，刷新后必须出现在 app.history 里") {
            guard MacCleanState.isIsolated else { return false }
            let snapshot = HistoryStore.load()
            defer { HistoryStore.replaceAllForSelftest(snapshot) }
            HistoryStore.replaceAllForSelftest([])

            let app = AppState()
            app.reloadHistory()
            guard app.history.isEmpty else { return false }
            // 模拟删除网关/归档模块的记账：整条链路完全不经过 AppState.recordClean
            HistoryStore.append(CleanRecord(categoryName: "治理卡片记账", itemCount: 1, bytes: 1024,
                                            mode: "废纸篓", failures: 0))
            guard app.history.isEmpty else { return false }
            app.refreshDisk()
            return app.history.count == 1 && app.history.first?.categoryName == "治理卡片记账"
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
