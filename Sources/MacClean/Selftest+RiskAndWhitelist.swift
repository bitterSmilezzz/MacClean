import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：风险检查与白名单
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 615–1055）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteRiskAndWhitelist() {
        // MARK: - 风险检查（电脑风险提醒）

        check("风险检查：SSH 私钥权限过宽") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            let ssh = home + "/.ssh"
            try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let key = ssh + "/id_rsa"
            FileManager.default.createFile(atPath: key, contents: Data("test".utf8))
            // 权限 644（group/other 可读）→ 应报高风险
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh)
            let item = RiskScanner.checkSSHKeys(home: home)
            return item?.severity == .high && item?.category == .sensitiveData
        }
        check("风险检查：SSH 目录权限过宽") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            let ssh = home + "/.ssh"
            try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh)
            let item = RiskScanner.checkSSHKeys(home: home)
            return item?.severity == .medium
        }
        check("风险检查：明文密钥环境变量") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let zshrc = home + "/.zshrc"
            try "export OPENAI_KEY=sk-REPLACE_ME_1234567890abcdef\n".write(toFile: zshrc, atomically: true, encoding: .utf8)
            let item = RiskScanner.checkEnvSecrets(home: home)
            guard let item, item.severity == .high else { return false }
            // 检测详情不得包含明文密钥本身（安全边界）
            return !item.detail.contains("sk-REPLACE_ME_1234567890abcdef")
        }
        check("风险检查：敏感命名文件暴露") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            let desktop = home + "/Desktop"
            try FileManager.default.createDirectory(atPath: desktop, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: desktop + "/passwords.txt",
                                           contents: Data("a=b".utf8))
            FileManager.default.createFile(atPath: desktop + "/normal.txt",
                                           contents: Data("x".utf8))
            let items = RiskScanner.checkSensitiveFiles(home: home)
            return items.contains { $0.title == "发现疑似敏感文件" && $0.path?.hasSuffix("passwords.txt") == true }
                && !items.contains { $0.path?.hasSuffix("normal.txt") == true }
        }
        check("风险检查：敏感项不含明文（边界）") {
            // scan 全量时，任何 item 的 detail 不得包含常见密钥前缀明文
            let items = RiskScanner.scan(home: "/private/tmp/macclean-risk-\(UUID().uuidString)") { _ in }
            return items.allSatisfy {
                !$0.detail.contains("sk-") && !$0.detail.contains("AKIA") && !$0.detail.contains("ghp_")
            }
        }
        check("风险检查：RiskRow 渲染严重度徽标") {
            let item = RiskItem(title: "测试", detail: "d", severity: .high,
                                category: .sensitiveData, suggestion: "s")
            let row = RiskRow(item: item)
            _ = try row.inspect().find(text: "高风险")
            return true
        }
        check("历史导出器：CSV 导出（含 BOM 与列头）") {
            let records = [
                CleanRecord(date: Date(), categoryName: "系统日志", itemCount: 5, bytes: 1_000_000, mode: "移入废纸篓", failures: 0),
                CleanRecord(date: Date(), categoryName: "用户缓存", itemCount: 10, bytes: 2_000_000, mode: "彻底删除", failures: 1)
            ]
            let csv = HistoryExporter.generateCSV(records: records)
            guard csv.hasPrefix("\u{FEFF}") else { return false }
            guard csv.contains("记录ID,清理时间,分类,清理模式,清理项数,失败项数,释放字节数,释放大小") else { return false }
            guard csv.contains("系统日志") && csv.contains("用户缓存") && csv.contains("1 MB") && csv.contains("2 MB") else { return false }
            return true
        }
        check("历史导出器：Markdown 报告生成统计分析") {
            let records = [
                CleanRecord(date: Date(), categoryName: "系统日志", itemCount: 5, bytes: 1_000_000, mode: "移入废纸篓", failures: 0),
                CleanRecord(date: Date(), categoryName: "用户缓存", itemCount: 10, bytes: 2_000_000, mode: "彻底删除", failures: 1)
            ]
            let report = HistoryExporter.generateReport(records: records)
            guard report.contains("# MacClean 清理历史归档报告") else { return false }
            guard report.contains("清理执行次数：2 次") else { return false }
            guard report.contains("3 MB") else { return false }
            guard report.contains("各分类释放分布统计") else { return false }
            guard report.contains("详细清理流水记录") else { return false }
            return true
        }
        check("清单导出器：大文件与清理项 CSV / Markdown 报告生成") {
            let items = [
                CleanItem(name: "Xcode_16.dmg", path: "/Users/test/Downloads/Xcode_16.dmg", size: 10_000_000_000, rule: "A1", category: .largeFiles, note: "安装包"),
                CleanItem(name: "old_dataset.zip", path: "/Users/test/Downloads/old_dataset.zip", size: 2_000_000_000, rule: "C1", category: .largeFiles, note: "数据包")
            ]
            let csv = HistoryExporter.generateItemsCSV(items: items, categoryTitle: "大文件与垃圾箱")
            guard csv.hasPrefix("\u{FEFF}") else { return false }
            guard csv.contains("分类,名称,大小,字节数,处置结论,结论依据,使用情况,主路径,备注") else { return false }
            // A1 = 已卸载 App 的残留 → 「需确认」；同时必须带出结论依据
            guard csv.contains("Xcode_16.dmg") && csv.contains("10 GB") && csv.contains("需确认") else { return false }
            guard csv.contains("已卸载应用的数据目录") else { return false }

            let report = HistoryExporter.generateItemsReport(items: items, categoryTitle: "大文件与垃圾箱")
            guard report.contains("# MacClean 大文件与垃圾箱清单报告") else { return false }
            guard report.contains("总计项目：2 项") && report.contains("12 GB") else { return false }
            guard report.contains("Xcode_16.dmg") && report.contains("old_dataset.zip") else { return false }
            return true
        }
        check("清单导出器：重复/相似大文件 CSV / Markdown 报告生成") {
            let item1 = DuplicateFileItem(path: "/a/video.mp4", name: "video.mp4", size: 100_000_000, modificationDate: Date(), isSelected: false, isOriginal: true, recommendationReason: "保留最早修改")
            let item2 = DuplicateFileItem(path: "/b/video copy.mp4", name: "video copy.mp4", size: 100_000_000, modificationDate: Date(), isSelected: true, isOriginal: false, recommendationReason: "重复副本")
            let group = DuplicateGroup(hash: "sha256_mock_hash", fileSize: 100_000_000, items: [item1, item2], matchKind: .exact, suggestionNote: "哈希完全一致")

            let csv = HistoryExporter.generateDuplicatesCSV(groups: [group])
            guard csv.hasPrefix("\u{FEFF}") else { return false }
            guard csv.contains("分组类型,哈希/特征,推荐操作,文件名,大小,字节数,修改时间,推荐说明,路径") else { return false }
            guard csv.contains("完全一致") && csv.contains("推荐保留") && csv.contains("已勾选清理") else { return false }

            let report = HistoryExporter.generateDuplicatesReport(groups: [group])
            guard report.contains("# MacClean 重复与相似大文件排查报告") else { return false }
            guard report.contains("总分组数：1 组（共 2 个文件）") else { return false }
            guard report.contains("100 MB") && report.contains("video.mp4") else { return false }
            return true
        }
        check("系统通知：扫描完成通知组装与派发") {
            let mgr = NotificationManager.shared
            mgr.notifyScanCompleted(categoryName: "开发残留", itemCount: 42, totalBytes: 52_428_800)
            guard let notif = mgr.lastNotification else { return false }
            guard notif.title == "开发残留 扫描完成" else { return false }
            guard notif.body.contains("42 个可清理项目") && notif.body.contains("52.4 MB") else { return false }
            return true
        }
        check("系统通知：清理完成通知与状态组装") {
            let mgr = NotificationManager.shared
            mgr.notifyCleanCompleted(releasedBytes: 104_857_600, failureCount: 0)
            guard let notif = mgr.lastNotification else { return false }
            guard notif.title == "MacClean 清理完成" else { return false }
            guard notif.body.contains("105 MB") else { return false }

            mgr.notifyCleanCompleted(releasedBytes: 20_000_000, failureCount: 2)
            guard let notif2 = mgr.lastNotification else { return false }
            guard notif2.body.contains("2 项清理失败或跳过") && notif2.body.contains("20 MB") else { return false }
            return true
        }
        check("系统通知：Dock 徽标状态同步") {
            NotificationManager.shared.updateDockBadge(count: 88)
            guard NSApplication.shared.dockTile.badgeLabel == "88" else { return false }
            NotificationManager.shared.updateDockBadge(count: 0)
            guard NSApplication.shared.dockTile.badgeLabel == nil else { return false }
            return true
        }
        check("大文件细分过滤：类型规则与匹配断言") {
            let dmg = CleanItem(name: "Xcode_16.dmg", path: "/Downloads/Xcode_16.dmg", size: 10_000_000_000, rule: "A1", category: .largeFiles)
            let zip = CleanItem(name: "dataset.zip", path: "/Downloads/dataset.zip", size: 2_000_000_000, rule: "A1", category: .largeFiles)
            let mov = CleanItem(name: "demo.mov", path: "/Downloads/demo.mov", size: 1_500_000_000, rule: "A1", category: .largeFiles)
            let raw = CleanItem(name: "Landscape_001.ARW", path: "/Pictures/Landscape_001.ARW", size: 85_000_000, rule: "A1", category: .largeFiles)
            let vdi = CleanItem(name: "Ubuntu22.vdi", path: "/VirtualBox/Ubuntu22.vdi", size: 40_000_000_000, rule: "A1", category: .largeFiles)
            let archive = CleanItem(name: "MacClean.xcarchive", path: "/Library/Developer/Xcode/Archives/MacClean.xcarchive", size: 120_000_000, rule: "A1", category: .largeFiles)
            let sim = CleanItem(name: "iPhone 15 Pro", path: "/Library/Developer/CoreSimulator/Devices/UUID", size: 5_000_000_000, rule: "A3", category: .largeFiles, note: "模拟器缓存")
            let unknown = CleanItem(name: "raw_data.bin", path: "/Downloads/raw_data.bin", size: 1_000_000_000, rule: "A1", category: .largeFiles)

            guard LargeFileTypeFilter.installer.matches(item: dmg) && !LargeFileTypeFilter.installer.matches(item: zip) else { return false }
            guard LargeFileTypeFilter.archive.matches(item: zip) && !LargeFileTypeFilter.archive.matches(item: mov) else { return false }
            guard LargeFileTypeFilter.media.matches(item: mov) && !LargeFileTypeFilter.media.matches(item: dmg) else { return false }
            guard LargeFileTypeFilter.rawMedia.matches(item: raw) && !LargeFileTypeFilter.rawMedia.matches(item: zip) else { return false }
            guard LargeFileTypeFilter.diskImage.matches(item: vdi) && !LargeFileTypeFilter.diskImage.matches(item: mov) else { return false }
            guard LargeFileTypeFilter.codeArchive.matches(item: archive) && !LargeFileTypeFilter.codeArchive.matches(item: dmg) else { return false }
            guard LargeFileTypeFilter.simulator.matches(item: sim) && !LargeFileTypeFilter.simulator.matches(item: dmg) else { return false }
            guard LargeFileTypeFilter.other.matches(item: unknown) && !LargeFileTypeFilter.other.matches(item: dmg) else { return false }
            return true
        }
        check("磁盘监控：DiskMonitorConfig 配置加载与保存") {
            var cfg = DiskMonitorConfig()
            cfg.autoScanEnabled = true
            cfg.scanIntervalHours = 6
            cfg.lowSpaceAlertEnabled = true
            cfg.lowSpaceThresholdGB = 20
            cfg.autoCleanEnabled = true
            cfg.dndEnabled = true
            cfg.dndStartHour = 22
            cfg.dndEndHour = 6
            cfg.save()

            let loaded = DiskMonitorConfig.load()
            guard loaded.autoScanEnabled == true && loaded.scanIntervalHours == 6 else { return false }
            guard loaded.lowSpaceAlertEnabled == true && loaded.lowSpaceThresholdGB == 20 else { return false }
            guard loaded.autoCleanEnabled == true && loaded.dndEnabled == true else { return false }
            guard loaded.dndStartHour == 22 && loaded.dndEndHour == 6 else { return false }
            return true
        }
        check("智能静默清理：免打扰时间窗口判定") {
            var cfg = DiskMonitorConfig()
            cfg.dndEnabled = true
            cfg.dndStartHour = 23
            cfg.dndEndHour = 7

            let cal = Calendar.current
            // 构造 02:00（在允许窗口内）
            var compsNight = cal.dateComponents([.year, .month, .day], from: Date())
            compsNight.hour = 2
            let dateNight = cal.date(from: compsNight)!
            guard cfg.isWithinAllowedWindow(date: dateNight) else { return false }

            // 构造 14:00（在允许窗口外）
            var compsDay = cal.dateComponents([.year, .month, .day], from: Date())
            compsDay.hour = 14
            let dateDay = cal.date(from: compsDay)!
            guard !cfg.isWithinAllowedWindow(date: dateDay) else { return false }

            return true
        }
        check("磁盘监控：空间充足时不触发预警弹窗与通知") {
            let monitor = DiskMonitor.shared
            monitor.config.lowSpaceAlertEnabled = true
            monitor.config.lowSpaceThresholdGB = 15
            monitor.showLowSpaceAlert = false

            // 可用 50 GB (> 15 GB)
            monitor.checkDiskSpaceAlert(availableBytes: 50_000_000_000)
            guard monitor.showLowSpaceAlert == false else { return false }
            return true
        }
        check("磁盘监控：空间不足触发警戒弹窗与系统预警通知") {
            let monitor = DiskMonitor.shared
            monitor.config.lowSpaceAlertEnabled = true
            monitor.config.lowSpaceThresholdGB = 15
            monitor.showLowSpaceAlert = false

            // 可用 5 GB (< 15 GB)
            monitor.checkDiskSpaceAlert(availableBytes: 5_000_000_000)
            guard monitor.showLowSpaceAlert == true else { return false }

            // 检查系统通知是否派发
            guard let notif = NotificationManager.shared.lastNotification else { return false }
            guard notif.title == "磁盘空间不足" else { return false }
            guard notif.body.contains("5 GB") && notif.body.contains("15 GB") else { return false }

            // 复位测试状态
            monitor.showLowSpaceAlert = false
            return true
        }
        check("白名单：WhitelistManager 添加与持久化存储") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            let r1 = wm.addPathRule("~/workspace/secret-project", comment: "私人项目")
            let r2 = wm.addAppRule("MyCustomApp", comment: "自定义受保护应用")

            guard wm.rules.count == 2 else { return false }
            guard wm.rules.contains(where: { $0.id == r1.id && $0.type == .path }) else { return false }
            guard wm.rules.contains(where: { $0.id == r2.id && $0.type == .appName }) else { return false }

            let loaded = WhitelistManager.load()
            guard loaded.rules.count == 2, loaded.warning == nil else { return false }
            return true
        }
        // MARK: - 白名单持久化健壮性
        //
        // 白名单消失不只是"数据丢了"，而是**安全降级**：用户明确保护过的路径
        // 会重新变成"可清理"。历史上的写法是 `try? decode(...) ?? []`，
        // 于是任何一次解码失败都会静默清空白名单。

        check("白名单：拉黑软链目录时，其指向的真实路径同样受保护") {
            // `isSafeToClean` 会先把路径解析到真实位置再判定（软链防跳板），
            // 于是白名单也是拿解析后的路径来查的。若只比对字面路径，
            // 用户拉黑一个软链目录后，删除时查到的是 /real/target → 匹配不上 → 保护失效。
            let base = "/private/tmp/macclean-wl-link-\(UUID().uuidString)"
            let realDir = base + "/real"
            let link = base + "/link"
            try? FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: base) }
            guard (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: realDir)) != nil else {
                return true
            }

            let wm = WhitelistManager.shared
            let saved = wm.rules
            defer { wm.rules = saved }

            wm.removeAllRules()
            wm.addPathRule(link, comment: "软链形式的保护")

            // 直接命中软链本身
            guard wm.isWhitelisted(path: link) else { return false }
            // 关键：经由软链与直达真实路径，都必须命中
            guard wm.isWhitelisted(path: link + "/inner.bin") else { return false }
            guard wm.isWhitelisted(path: realDir + "/inner.bin") else { return false }
            // 底层护栏也要认
            return !FileSystem.isSafeToClean(realDir + "/inner.bin")
        }

        check("白名单持久化：新增未知字段不会毁掉老数据（前向兼容）") {
            // Swift 合成的 Codable 对缺失 key 直接抛错、且**不使用属性默认值**。
            // 也就是说只要将来给 WhitelistRule 加一个字段，老用户的整个白名单就会解不出来。
            // 这条用例把"加字段"这件事模拟出来。
            let json = """
            [{"id":"11111111-1111-1111-1111-111111111111",
              "pattern":"~/secret",
              "comment":"私人目录",
              "type":"path",
              "createdAt":750000000,
              "futureFieldAddedInV2":"whatever",
              "anotherOne":42}]
            """
            let result = WhitelistManager.decode(Data(json.utf8))
            return result.rules.count == 1
                && result.rules[0].pattern == "~/secret"
                && result.rules[0].type == .path
                && result.warning == nil
        }

        check("白名单持久化：缺失可选字段取默认值，不整体失败") {
            // 只给 pattern —— 其余字段（id/comment/type/createdAt）都该有默认值
            let json = """
            [{"pattern":"~/minimal"}]
            """
            let result = WhitelistManager.decode(Data(json.utf8))
            return result.rules.count == 1
                && result.rules[0].pattern == "~/minimal"
                && result.rules[0].type == .path
                && result.warning == nil
        }

        check("白名单持久化：单条记录损坏不影响其余规则生效") {
            let json = """
            [{"pattern":"~/keep-me","type":"path"},
             {"comment":"这条没有 pattern，非法"},
             {"pattern":"~/keep-me-too","type":"path"}]
            """
            let result = WhitelistManager.decode(Data(json.utf8))
            // 两条合法的必须活下来，并且要如实告知丢了一条
            return result.rules.count == 2
                && result.rules.map(\.pattern).sorted() == ["~/keep-me", "~/keep-me-too"]
                && result.warning != nil
        }

        check("白名单持久化：整体损坏时给出警告而不是静默清空") {
            let result = WhitelistManager.decode(Data("这不是 JSON".utf8))
            return result.rules.isEmpty && result.warning != nil
        }

        check("白名单：路径精准匹配与子目录通配匹配") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            wm.addPathRule("/private/tmp/protected-suite", comment: "测试保护目录")

            // 1. 命中自身
            guard wm.isWhitelisted(path: "/private/tmp/protected-suite") else { return false }
            // 2. 命中子路径
            guard wm.isWhitelisted(path: "/private/tmp/protected-suite/build/output.log") else { return false }
            // 3. 不命中相似前缀但不是子目录的路径
            guard !wm.isWhitelisted(path: "/private/tmp/protected-suite-other") else { return false }
            // 4. 不命中其他无关路径
            guard !wm.isWhitelisted(path: "/private/tmp/random-file.txt") else { return false }
            return true
        }
        check("白名单：App 名称不区分大小写与空白匹配") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            wm.addAppRule("WeChat", comment: "微信")

            guard wm.isAppWhitelisted(appName: "WeChat") else { return false }
            guard wm.isAppWhitelisted(appName: "wechat") else { return false }
            guard wm.isAppWhitelisted(appName: " WECHAT ") else { return false }
            guard !wm.isAppWhitelisted(appName: "QQ") else { return false }
            return true
        }
        check("白名单：底层 FileSystem.isSafeToClean 防御阻断") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            let protectedDir = "/private/tmp/macclean-safe-test-\(UUID().uuidString)"
            wm.addPathRule(protectedDir, comment: "底层阻断测试")

            // 未加入白名单时普通 tmp 目录安全检查返回 true，加入后必须返回 false
            guard !FileSystem.isSafeToClean(protectedDir) else { return false }
            guard !FileSystem.isSafeToClean(protectedDir + "/child.txt") else { return false }

            // 清理规则
            wm.removeAllRules()
            return true
        }
        check("白名单：AppState.addPathToWhitelist 联动移除已扫描项") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            let keepItem = CleanItem(name: "KeepCache", path: "/private/tmp/keep-cache", size: 100, rule: "C1", category: .userCaches)
            let removePath = "/private/tmp/whitelist-target-cache"
            let removeItem = CleanItem(name: "RemoveCache", path: removePath, size: 200, rule: "C1", category: .userCaches)
            st.items = [keepItem, removeItem]

            guard st.items.count == 2 else { return false }
            app.addPathToWhitelist(removePath, comment: "测试移除")

            guard st.items.count == 1 && st.items.first?.path == keepItem.path else { return false }
            guard app.whitelist.isWhitelisted(path: removePath) else { return false }

            // 清理测试白名单
            app.whitelist.removeAllRules()
            return true
        }
        check("白名单：自定义文件扩展名排除规则与底层阻断") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            let r = wm.addExtensionRule(".iso", comment: "镜像文件保护")
            _ = wm.addExtensionRule("dmg", comment: "安装包保护")

            guard wm.rules.count == 2 else { return false }
            guard r.normalizedExtension == "iso" else { return false }

            // 扩展名匹配
            guard wm.isExtensionWhitelisted(path: "/Users/test/Downloads/ubuntu.iso") else { return false }
            guard wm.isExtensionWhitelisted(path: "/Users/test/Downloads/UBUNTU.ISO") else { return false }
            guard wm.isExtensionWhitelisted(path: "/Users/test/Downloads/app.dmg") else { return false }
            guard !wm.isExtensionWhitelisted(path: "/Users/test/Downloads/app.pkg") else { return false }

            // 底层安全检查阻断
            guard !FileSystem.isSafeToClean("/private/tmp/installer.dmg") else { return false }

            wm.removeAllRules()
            return true
        }
        check("白名单：AppState.addExtensionToWhitelist 联动移除扫描与重复项") {
            let app = AppState()
            let st = app.state(for: .largeFiles)
            st.isScanned = true
            let keepItem = CleanItem(name: "archive.zip", path: "/tmp/archive.zip", size: 100, rule: "C1", category: .largeFiles)
            let isoItem = CleanItem(name: "fedora.iso", path: "/tmp/fedora.iso", size: 200, rule: "C1", category: .largeFiles)
            st.items = [keepItem, isoItem]

            app.duplicateState.groups = [
                DuplicateGroup(hash: "h1", fileSize: 200, items: [
                    DuplicateFileItem(path: "/tmp/a.iso", name: "a.iso", size: 200, modificationDate: Date()),
                    DuplicateFileItem(path: "/tmp/b.iso", name: "b.iso", size: 200, modificationDate: Date())
                ])
            ]

            guard st.items.count == 2 && app.duplicateState.groups.count == 1 else { return false }
            app.addExtensionToWhitelist("iso", comment: "测试扩展名排除")

            guard st.items.count == 1 && st.items.first?.path == keepItem.path else { return false }
            guard app.duplicateState.groups.isEmpty else { return false }

            app.whitelist.removeAllRules()
            return true
        }

    }
}
