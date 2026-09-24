import Foundation

// MARK: - 屏幕截图与录屏归档助手深度自检 (v1.64.0 / v1.72.0 安全加固)

extension Selftest {
    static func suiteScreenshotsOrganizerDeep() {
        print("--- [Suite] 屏幕截图与录屏归档助手深度自检 (v1.64.0) ---")

        // 1. 命名特征与类型识别
        check("ScreenshotsOrganizer: 截图与录屏命名特征匹配与类型识别") {
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "Screen Shot 2026-09-01 at 12.00.00.png") == .screenshot else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "Screenshot_2026-09-02.jpg") == .screenshot else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "截屏2026-09-03 14.20.11.png") == .screenshot else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "屏幕快照 2026-09-04.heic") == .screenshot else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "CleanShot 2026-09-05.png") == .screenshot else { return false }

            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "Screen Recording 2026-09-01 at 12.00.00.mov") == .recording else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "屏幕录制2026-09-02.mp4") == .recording else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "录屏_20260903.mov") == .recording else { return false }

            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "normal_photo.jpg") == nil else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "movie.mp4") == nil else { return false }
            guard ScreenshotsOrganizerScanner.detectCaptureType(fileName: "document.pdf") == nil else { return false }

            return true
        }

        // 2. 时效阶梯分层与高推荐治理策略
        check("ScreenshotsOrganizer: 时效阶梯分层与推荐治理策略判定") {
            guard CaptureAgeTier.from(ageDays: 3) == .within7Days else { return false }
            guard CaptureAgeTier.from(ageDays: 15) == .days8To30 else { return false }
            guard CaptureAgeTier.from(ageDays: 60) == .days31To90 else { return false }
            guard CaptureAgeTier.from(ageDays: 120) == .over90Days else { return false }

            let freshScreen = ScreenshotItem(
                id: "1", fileName: "s1.png", path: "/s1.png", size: 100,
                captureType: .screenshot, modificationDate: Date(), ageDays: 2, isSelected: false
            )
            guard !freshScreen.isHighRiskStale else { return false }

            let oldScreen = ScreenshotItem(
                id: "2", fileName: "s2.png", path: "/s2.png", size: 100,
                captureType: .screenshot, modificationDate: Date(), ageDays: 35, isSelected: false
            )
            guard oldScreen.isHighRiskStale else { return false }

            let freshRec = ScreenshotItem(
                id: "3", fileName: "r1.mov", path: "/r1.mov", size: 1000,
                captureType: .recording, modificationDate: Date(), ageDays: 2, isSelected: false
            )
            guard !freshRec.isHighRiskStale else { return false }

            let oldRec = ScreenshotItem(
                id: "4", fileName: "r2.mov", path: "/r2.mov", size: 1000,
                captureType: .recording, modificationDate: Date(), ageDays: 8, isSelected: false
            )
            guard oldRec.isHighRiskStale else { return false }

            return true
        }

        // 3. 归档策略与重名冲突处理
        check("ScreenshotsOrganizer: 归档策略模式与重名冲突处理") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Screenshots_Conflict"
            let archiveDir = (testDir as NSString).appendingPathComponent("Archive")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let f1 = (testDir as NSString).appendingPathComponent("Screen Shot.png")
            try? "png1".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))
            try? "png2".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))
            ScreenshotsOrganizerTestSupport.age(f1, days: 10)

            let item1 = ScreenshotItem(
                id: f1, fileName: "Screen Shot.png", path: f1, size: 4,
                captureType: .screenshot, modificationDate: Date(), ageDays: 10, isSelected: true
            )

            // 第一次归档（按类型归档）
            let res1 = ScreenshotsOrganizerScanner.shared.archive(items: [item1], targetDirectory: archiveDir, strategy: .byType, journal: .none)
            guard res1.archivedCount == 1 && res1.errorCount == 0 else { return false }
            let expectedPath = ((archiveDir as NSString).appendingPathComponent("Screenshots") as NSString).appendingPathComponent("Screen Shot.png")
            guard fm.fileExists(atPath: expectedPath) else { return false }

            // 重新在源位置创建同名文件并再次归档，验证防撞重命名
            try? "png2".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))
            ScreenshotsOrganizerTestSupport.age(f1, days: 10)
            let res2 = ScreenshotsOrganizerScanner.shared.archive(items: [item1], targetDirectory: archiveDir, strategy: .byType, journal: .none)
            guard res2.archivedCount == 1 && res2.errorCount == 0 else { return false }

            // 目标目录下应有两个文件
            let destFiles = (try? fm.contentsOfDirectory(atPath: (archiveDir as NSString).appendingPathComponent("Screenshots"))) ?? []
            guard destFiles.count == 2 else { return false }

            return true
        }

        // 4. 概要指标统计精算
        check("ScreenshotsOrganizer: 概要指标统计与已选容量精算") {
            let item1 = ScreenshotItem(id: "1", fileName: "s.png", path: "1", size: 1000, captureType: .screenshot, modificationDate: Date(), ageDays: 10, isSelected: true)
            let item2 = ScreenshotItem(id: "2", fileName: "r.mov", path: "2", size: 5000, captureType: .recording, modificationDate: Date(), ageDays: 40, isSelected: true)
            let item3 = ScreenshotItem(id: "3", fileName: "s2.png", path: "3", size: 500, captureType: .screenshot, modificationDate: Date(), ageDays: 5, isSelected: false)

            let summary = ScreenshotsSummary(
                items: [item1, item2, item3],
                totalSize: 6500,
                screenshotSize: 1500,
                screenshotCount: 2,
                recordingSize: 5000,
                recordingCount: 1,
                staleSize: 5000,
                staleCount: 1
            )

            guard summary.totalSize == 6500 else { return false }
            guard summary.screenshotSize == 1500 && summary.screenshotCount == 2 else { return false }
            guard summary.recordingSize == 5000 && summary.recordingCount == 1 else { return false }
            guard summary.selectedSize == 6000 && summary.selectedCount == 2 else { return false }

            return true
        }

        // 5. 系统关键路径拦截与安全防线
        check("ScreenshotsOrganizer: 系统目录扫描与清理越界拦截") {
            let sysSummary = ScreenshotsOrganizerScanner.shared.scan(directories: ["/System", "/Library"])
            guard sysSummary.items.isEmpty else { return false }

            let fakeItem = ScreenshotItem(
                id: "/System/Screen Shot.png", fileName: "Screen Shot.png", path: "/System/Screen Shot.png",
                size: 100, captureType: .screenshot, modificationDate: Date(), ageDays: 10, isSelected: true
            )
            let cleanRes = ScreenshotsOrganizerScanner.shared.clean(items: [fakeItem], toTrash: true, journal: .none)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }
            guard cleanRes.outcome.rejected.contains(where: { $0.reason == .systemProtected }) else { return false }

            let archiveRes = ScreenshotsOrganizerScanner.shared.archive(items: [fakeItem], targetDirectory: "/System/Archive", journal: .none)
            guard archiveRes.archivedCount == 0 && archiveRes.errorCount > 0 else { return false }

            return true
        }

        // 6. 模拟文件扫描、归档移动与安全清理核验
        check("ScreenshotsOrganizer: 模拟文件扫描、归档移动与清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Screenshots_Full"
            let archiveDir = (testDir as NSString).appendingPathComponent("Screenshots_Archive")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let shotFile = (testDir as NSString).appendingPathComponent("Screen Shot 2026-09-10.png")
            let recFile = (testDir as NSString).appendingPathComponent("Screen Recording 2026-09-11.mov")
            try? "screenshot".data(using: .utf8)?.write(to: URL(fileURLWithPath: shotFile))
            try? "recording_video_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: recFile))
            // 40 天前拍的：既进入高推荐档位，也不在"还在写"的保护窗口内
            ScreenshotsOrganizerTestSupport.age(shotFile, days: 40)
            ScreenshotsOrganizerTestSupport.age(recFile, days: 40)

            // 扫描
            let summary = ScreenshotsOrganizerScanner.shared.scan(directories: [testDir])
            guard summary.items.count == 2 else { return false }
            guard summary.screenshotCount == 1 && summary.recordingCount == 1 else { return false }

            // 归档 shotFile（按年月模式）
            let shotItem = summary.items.first { $0.captureType == .screenshot }!
            let archiveRes = ScreenshotsOrganizerScanner.shared.archive(items: [shotItem], targetDirectory: archiveDir, strategy: .byYearMonth, journal: .none)
            guard archiveRes.archivedCount == 1 && archiveRes.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: shotFile) else { return false }

            // 清理 recFile（彻底删除）
            let recItem = summary.items.first { $0.captureType == .recording }!
            let cleanRes = ScreenshotsOrganizerScanner.shared.clean(items: [recItem], toTrash: false, journal: .none)
            guard cleanRes.cleanedCount == 1 && cleanRes.freedBytes > 0 else { return false }
            guard !fm.fileExists(atPath: recFile) else { return false }

            return true
        }

        // 7. 白名单 / G6 硬排除路径在本模块 policy 下必被拒
        check("ScreenshotsOrganizer: 白名单与 iCloud 位置必被拒且文件仍在") {
            let fm = FileManager.default
            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            let testDir = "/tmp/MacCleanTest_Screenshots_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer {
                wm.rules = savedRules
                try? fm.removeItem(atPath: testDir)
            }

            let shot = (testDir as NSString).appendingPathComponent("Screen Shot guarded.png")
            try? "guarded".data(using: .utf8)?.write(to: URL(fileURLWithPath: shot))
            ScreenshotsOrganizerTestSupport.age(shot, days: 60)
            let rule = wm.addPathRule(shot, comment: "自检保护")

            let item = ScreenshotItem(id: shot, fileName: (shot as NSString).lastPathComponent, path: shot,
                                      size: 7, captureType: .screenshot, modificationDate: Date(), ageDays: 60, isSelected: true)
            let resWhite = ScreenshotsOrganizerScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard resWhite.cleanedCount == 0 && resWhite.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: shot) else {
                print("    白名单截图被删了")
                return false
            }
            guard resWhite.outcome.rejected.contains(where: { $0.reason == .userWhitelisted }) else { return false }

            // 归档同样不得把白名单文件挪走
            let resArchive = ScreenshotsOrganizerScanner.shared.archive(items: [item], targetDirectory: (testDir as NSString).appendingPathComponent("Archive"), journal: .none)
            guard resArchive.archivedCount == 0 && resArchive.errorCount > 0, fm.fileExists(atPath: shot) else { return false }
            wm.removeRule(id: rule.id)

            // G6：iCloud Drive（~/Library/Mobile Documents）里的截图不得动
            let icloud = ScreenshotItem(id: "i", fileName: "Screen Shot icloud.png",
                                        path: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/Screen Shot icloud.png",
                                        size: 7, captureType: .screenshot, modificationDate: Date(), ageDays: 90, isSelected: true)
            let resG6 = ScreenshotsOrganizerScanner.shared.clean(items: [icloud], toTrash: false, journal: .none)
            guard resG6.cleanedCount == 0 && resG6.errorCount > 0,
                  resG6.outcome.rejected.contains(where: { $0.reason == .hardExcluded }) else { return false }

            // 归档目标落在 G6 里 → 整体拒绝
            let badDest = ScreenshotsOrganizerScanner.shared.archive(
                items: [item],
                targetDirectory: NSHomeDirectory() + "/Library/Mail/Archive", journal: .none)
            guard badDest.archivedCount == 0 && badDest.errorCount >= 1,
                  badDest.rejected.first?.reason == .hardExcluded else { return false }
            return true
        }

        // 8. 释放量与移动量必须等于操作前实测，而非扫描缓存
        check("ScreenshotsOrganizer: 释放量等于删除前实测而非缓存值") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Screenshots_Accounting"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let shot = (testDir as NSString).appendingPathComponent("Screen Shot real.png")
            let payload = "real-bytes-on-disk".data(using: .utf8)!
            try? payload.write(to: URL(fileURLWithPath: shot))
            ScreenshotsOrganizerTestSupport.age(shot, days: 45)

            // 条目里挂着扫描时期的旧缓存值（这里故意写成远大于真实体积）
            let staleCachedItem = ScreenshotItem(id: shot, fileName: "Screen Shot real.png", path: shot,
                                                 size: 999_999, captureType: .screenshot,
                                                 modificationDate: Date(), ageDays: 45, isSelected: true)
            let measured = FileSystem.size(at: shot)
            guard measured == Int64(payload.count) else { return false }

            let res = ScreenshotsOrganizerScanner.shared.clean(items: [staleCachedItem], toTrash: false, journal: .none)
            guard res.cleanedCount == 1, res.freedBytes == measured, res.freedBytes != 999_999 else {
                print("    记账沿用了缓存值：\(res.freedBytes) vs 实测 \(measured)")
                return false
            }
            guard !fm.fileExists(atPath: shot) else { return false }
            return true
        }

        // 9. 正在录屏 / 刚写入的文件既不删也不挪
        check("ScreenshotsOrganizer: 保护窗口内正在写入的录屏不得处理") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Screenshots_InFlight"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let rec = (testDir as NSString).appendingPathComponent("Screen Recording 正在录.mov")
            try? "growing-mov-data".data(using: .utf8)?.write(to: URL(fileURLWithPath: rec))
            // mtime = 现在（正在被写）
            let item = ScreenshotItem(id: rec, fileName: (rec as NSString).lastPathComponent, path: rec,
                                      size: 16, captureType: .recording, modificationDate: Date(),
                                      ageDays: 0, isSelected: true)
            guard ScreenshotsOrganizerScanner.isInFlight(FileSystem.normalizePath(FileSystem.realPath(rec)), now: Date()) else {
                return false
            }
            let resClean = ScreenshotsOrganizerScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            let resMove = ScreenshotsOrganizerScanner.shared.archive(items: [item],
                                                                     targetDirectory: (testDir as NSString).appendingPathComponent("Archive"),
                                                                     journal: .none)
            guard resClean.cleanedCount == 0 && resClean.errorCount > 0,
                  resMove.archivedCount == 0 && resMove.errorCount > 0,
                  fm.fileExists(atPath: rec) else {
                print("    正在写入的录屏被处理了")
                return false
            }
            return true
        }

        // 10. mtime 读不到时按"在用"处理：宁可不动
        check("ScreenshotsOrganizer: 时间戳取不到时降级为不处理") {
            let missing = "/tmp/MacCleanTest_Screenshots_Ghost/Screen Shot ghost.png"
            guard FileManager.default.fileExists(atPath: missing) == false else { return false }
            guard ScreenshotsOrganizerScanner.isInFlight(missing, now: Date()) else { return false }

            let item = ScreenshotItem(id: missing, fileName: "Screen Shot ghost.png", path: missing,
                                      size: 100, captureType: .screenshot, modificationDate: Date(),
                                      ageDays: 99, isSelected: true)
            let res = ScreenshotsOrganizerScanner.shared.clean(items: [item], journal: .none)
            guard res.cleanedCount == 0 && res.errorCount > 0,
                  res.outcome.rejected.contains(where: { $0.reason == .missing }) else { return false }
            return true
        }

        // 11. 治理结果写历史（自检注入隔离）
        check("ScreenshotsOrganizer: 清理与归档结果写入历史记录") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Screenshots_History"
            let archiveDir = (testDir as NSString).appendingPathComponent("Archive")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            let savedOverride = HistoryStore.fileURLOverride
            defer {
                HistoryStore.fileURLOverride = savedOverride
                try? fm.removeItem(atPath: testDir)
            }
            HistoryStore.fileURLOverride = URL(fileURLWithPath: (testDir as NSString).appendingPathComponent("history.json"))

            let a = (testDir as NSString).appendingPathComponent("Screen Shot a.png")
            let b = (testDir as NSString).appendingPathComponent("Screen Recording b.mov")
            try? "aaaa".data(using: .utf8)?.write(to: URL(fileURLWithPath: a))
            try? "bbbbbbbb".data(using: .utf8)?.write(to: URL(fileURLWithPath: b))
            ScreenshotsOrganizerTestSupport.age(a, days: 30)
            ScreenshotsOrganizerTestSupport.age(b, days: 30)

            let itemA = ScreenshotItem(id: a, fileName: "Screen Shot a.png", path: a, size: 4,
                                       captureType: .screenshot, modificationDate: Date(), ageDays: 30, isSelected: true)
            let itemB = ScreenshotItem(id: b, fileName: "Screen Recording b.mov", path: b, size: 8,
                                       captureType: .recording, modificationDate: Date(), ageDays: 30, isSelected: true)

            let moved = ScreenshotsOrganizerScanner.shared.archive(items: [itemA], targetDirectory: archiveDir, strategy: .byType)
            let cleaned = ScreenshotsOrganizerScanner.shared.clean(items: [itemB], toTrash: false)
            guard moved.archivedCount == 1, cleaned.cleanedCount == 1, cleaned.freedBytes == 8 else { return false }

            let records = HistoryStore.load()
            let moveRecord = records.first { $0.mode == "归档移动" }
            let cleanRecord = records.first { $0.mode == "彻底删除" }
            guard let moveRecord, let cleanRecord,
                  moveRecord.itemCount == 1, moveRecord.bytes == 0,        // 同宗卷移动不谎报释放
                  cleanRecord.itemCount == 1, cleanRecord.bytes == 8,
                  cleanRecord.categoryName == ScreenshotsOrganizerScanner.historyCategory else {
                print("    历史未落盘：\(records.map { "\($0.categoryName):\($0.mode):\($0.bytes)" })")
                return false
            }
            return true
        }

        check("三个根只读到一部分时：没读到的那个要单独报出来，读到的条目不许一起丢") {
            // 这张卡片的默认根（桌面/下载/图片）是**多个**目录，所以"全空"不是唯一的坏法：
            // 只要有一个根没读到就整单报空、或反过来把没读到的根悄悄吞掉，都得拦下来。
            let fm = FileManager.default
            let base = "/private/tmp/macclean-shot-\(UUID().uuidString)"
            let ok = base + "/ok"
            let locked = base + "/locked"
            try? fm.createDirectory(atPath: ok, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
            // 文件名要能被 detectCaptureType 认出来，否则条目为 0 就成了合理结果
            fm.createFile(atPath: ok + "/Screenshot 2026-01-01 at 10.00.00.png",
                          contents: Data(repeating: 3, count: 2048))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
                try? fm.removeItem(atPath: base)
            }
            let sum = ScreenshotsOrganizerScanner.shared.scan(directories: [ok, locked])
            var bad: [String] = []
            if sum.unreadableRoots != [FileSystem.normalizePath(locked)] {
                bad.append("没读到的根没被单独标出：unreadable=\(sum.unreadableRoots.count)")
            }
            if !sum.deferredRoots.isEmpty {
                bad.append("可读的根被一起算成「没顾上」：\(sum.deferredRoots.count)")
            }
            if sum.items.count != 1 {
                bad.append("可读那个根的条目被一起吞掉了：items=\(sum.items.count)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }
    }
}

/// 截图/录屏自检 fixture 工具
enum ScreenshotsOrganizerTestSupport {
    /// 把 fixture 的 mtime 拨老 N 天（模拟"很久没动的截图"）
    static func age(_ path: String, days: Int) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: path)
    }
}
