import Foundation

// MARK: - 屏幕截图与录屏归档助手深度自检 (v1.64.0)

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

            let item1 = ScreenshotItem(
                id: f1, fileName: "Screen Shot.png", path: f1, size: 4,
                captureType: .screenshot, modificationDate: Date(), ageDays: 10, isSelected: true
            )

            // 第一次归档（按类型归档）
            let res1 = ScreenshotsOrganizerScanner.shared.archive(items: [item1], targetDirectory: archiveDir, strategy: .byType)
            guard res1.archivedCount == 1 && res1.errorCount == 0 else { return false }
            let expectedPath = ((archiveDir as NSString).appendingPathComponent("Screenshots") as NSString).appendingPathComponent("Screen Shot.png")
            guard fm.fileExists(atPath: expectedPath) else { return false }

            // 重新在源位置创建同名文件并再次归档，验证防撞重命名
            try? "png2".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))
            let res2 = ScreenshotsOrganizerScanner.shared.archive(items: [item1], targetDirectory: archiveDir, strategy: .byType)
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
            let cleanRes = ScreenshotsOrganizerScanner.shared.clean(items: [fakeItem], toTrash: true)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }

            let archiveRes = ScreenshotsOrganizerScanner.shared.archive(items: [fakeItem], targetDirectory: "/System/Archive")
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

            // 扫描
            let summary = ScreenshotsOrganizerScanner.shared.scan(directories: [testDir])
            guard summary.items.count == 2 else { return false }
            guard summary.screenshotCount == 1 && summary.recordingCount == 1 else { return false }

            // 归档 shotFile（按年月模式）
            let shotItem = summary.items.first { $0.captureType == .screenshot }!
            let archiveRes = ScreenshotsOrganizerScanner.shared.archive(items: [shotItem], targetDirectory: archiveDir, strategy: .byYearMonth)
            guard archiveRes.archivedCount == 1 && archiveRes.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: shotFile) else { return false }

            // 清理 recFile（彻底删除）
            let recItem = summary.items.first { $0.captureType == .recording }!
            let cleanRes = ScreenshotsOrganizerScanner.shared.clean(items: [recItem], toTrash: false)
            guard cleanRes.cleanedCount == 1 && cleanRes.freedBytes > 0 else { return false }
            guard !fm.fileExists(atPath: recFile) else { return false }

            return true
        }
    }
}
