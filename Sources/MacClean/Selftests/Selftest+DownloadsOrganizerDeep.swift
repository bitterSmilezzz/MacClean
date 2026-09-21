import Foundation

// MARK: - 下载目录智能时效归档与治理深度自检 (v1.62.0)

extension Selftest {
    static func suiteDownloadsOrganizerDeep() {
        print("--- [Suite] 下载目录智能时效归档与治理深度自检 (v1.62.0) ---")

        // 1. 下载项类型解析
        check("DownloadsOrganizer: 文件后缀与分类类型映射解析") {
            guard DownloadItemKind.from(path: "Chrome.dmg") == .installer else { return false }
            guard DownloadItemKind.from(path: "Node.pkg") == .installer else { return false }
            guard DownloadItemKind.from(path: "Ubuntu.iso") == .installer else { return false }
            guard DownloadItemKind.from(path: "archive.zip") == .archive else { return false }
            guard DownloadItemKind.from(path: "project.tar.gz") == .archive else { return false }
            guard DownloadItemKind.from(path: "movie.mp4") == .media else { return false }
            guard DownloadItemKind.from(path: "doc.pdf") == .document else { return false }
            guard DownloadItemKind.from(path: "data.csv") == .document else { return false }
            guard DownloadItemKind.from(path: "binary.bin") == .other else { return false }
            return true
        }

        // 2. 闲置时效与高推荐清理判定
        check("DownloadsOrganizer: 闲置时效与推荐清理策略校验") {
            let freshInstaller = DownloadItem(
                id: "1", fileName: "app.dmg", path: "/app.dmg", size: 100, kind: .installer,
                modificationDate: Date(), ageDays: 2, isSelected: false
            )
            guard !freshInstaller.isHighlyRecommendedToClean else { return false }

            let oldInstaller = DownloadItem(
                id: "2", fileName: "app.dmg", path: "/app.dmg", size: 100, kind: .installer,
                modificationDate: Date(), ageDays: 8, isSelected: false
            )
            guard oldInstaller.isHighlyRecommendedToClean else { return false }

            let oldArchive = DownloadItem(
                id: "3", fileName: "data.zip", path: "/data.zip", size: 200, kind: .archive,
                modificationDate: Date(), ageDays: 35, isSelected: false
            )
            guard oldArchive.isHighlyRecommendedToClean else { return false }

            let oldDoc = DownloadItem(
                id: "4", fileName: "report.pdf", path: "/report.pdf", size: 50, kind: .document,
                modificationDate: Date(), ageDays: 100, isSelected: false
            )
            guard oldDoc.isHighlyRecommendedToClean else { return false }

            return true
        }

        // 3. 概要指标统计精算
        check("DownloadsOrganizer: 概要指标统计与已选容量精算") {
            let item1 = DownloadItem(id: "1", fileName: "i1.dmg", path: "1", size: 1000, kind: .installer, modificationDate: Date(), ageDays: 10, isSelected: true)
            let item2 = DownloadItem(id: "2", fileName: "i2.zip", path: "2", size: 2000, kind: .archive, modificationDate: Date(), ageDays: 40, isSelected: true)
            let item3 = DownloadItem(id: "3", fileName: "i3.pdf", path: "3", size: 500, kind: .document, modificationDate: Date(), ageDays: 5, isSelected: false)

            let summary = DownloadsSummary(
                items: [item1, item2, item3],
                totalSize: 3500,
                installerSize: 1000,
                installerCount: 1,
                archiveSize: 2000,
                archiveCount: 1,
                staleSize: 3000,
                staleCount: 2
            )

            guard summary.totalSize == 3500 else { return false }
            guard summary.selectedSize == 3000 else { return false }
            guard summary.selectedCount == 2 else { return false }
            guard summary.staleCount == 2 else { return false }

            return true
        }

        // 4. 系统越界与安全性防线
        check("DownloadsOrganizer: 系统目录扫描与清理越界拦截") {
            let sysSummary = DownloadsOrganizerScanner.shared.scan(customDirectory: "/System")
            guard sysSummary.items.isEmpty else { return false }

            let fakeItem = DownloadItem(
                id: "/System/fake.dmg", fileName: "fake.dmg", path: "/System/fake.dmg",
                size: 100, kind: .installer, modificationDate: Date(), ageDays: 10, isSelected: true
            )
            let cleanRes = DownloadsOrganizerScanner.shared.clean(items: [fakeItem], toTrash: true, journal: .none)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }

            let archiveRes = DownloadsOrganizerScanner.shared.archive(items: [fakeItem], targetDirectory: "/System/Archived", journal: .none)
            guard archiveRes.movedCount == 0 && archiveRes.errorCount > 0 else { return false }

            return true
        }

        // 5. 模拟下载目录扫描与推荐勾选
        check("DownloadsOrganizer: 模拟下载目录扫描与时效分析") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_Scan"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let dmgPath = (testDir as NSString).appendingPathComponent("installer.dmg")
            let zipPath = (testDir as NSString).appendingPathComponent("backup.zip")
            try? "dmg data".data(using: .utf8)?.write(to: URL(fileURLWithPath: dmgPath))
            try? "zip data".data(using: .utf8)?.write(to: URL(fileURLWithPath: zipPath))

            // 设置 dmg mtime 为 15 天前（应被判定为高推荐清理）
            let oldDate = Date().addingTimeInterval(-15 * 86400)
            try? fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: dmgPath)

            let summary = DownloadsOrganizerScanner.shared.scan(customDirectory: testDir)
            guard summary.items.count == 2 else { return false }

            let dmgItem = summary.items.first { $0.fileName == "installer.dmg" }
            guard let dmgItem, dmgItem.kind == .installer, dmgItem.ageDays >= 14, dmgItem.isSelected == true else {
                return false
            }

            return true
        }

        // 6. 模拟归档移动与安全清理核验
        check("DownloadsOrganizer: 模拟归档子目录移动与清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_Action"
            let archiveDir = (testDir as NSString).appendingPathComponent("Archived_Test")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let f1 = (testDir as NSString).appendingPathComponent("doc1.pdf")
            let f2 = (testDir as NSString).appendingPathComponent("doc2.pdf")
            try? "pdf1".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))
            try? "pdf2".data(using: .utf8)?.write(to: URL(fileURLWithPath: f2))

            let item1 = DownloadItem(id: f1, fileName: "doc1.pdf", path: f1, size: 4, kind: .document, modificationDate: Date(), ageDays: 1, isSelected: true)
            let item2 = DownloadItem(id: f2, fileName: "doc2.pdf", path: f2, size: 4, kind: .document, modificationDate: Date(), ageDays: 1, isSelected: true)

            // 执行归档移动 item1
            let archiveRes = DownloadsOrganizerScanner.shared.archive(items: [item1], targetDirectory: archiveDir, journal: .none)
            guard archiveRes.movedCount == 1 && archiveRes.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: f1) && fm.fileExists(atPath: (archiveDir as NSString).appendingPathComponent("doc1.pdf")) else {
                return false
            }

            // 执行彻底删除 item2
            let cleanRes = DownloadsOrganizerScanner.shared.clean(items: [item2], toTrash: false, journal: .none)
            guard cleanRes.cleanedCount == 1 && cleanRes.freedBytes == 4 else { return false }
            guard !fm.fileExists(atPath: f2) else { return false }

            return true
        }

        // 7. 释放量必须等于删除前实测，而非扫描缓存值
        check("DownloadsOrganizer: 释放量等于删除前实测而非缓存值") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_Accounting"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let file = (testDir as NSString).appendingPathComponent("report.pdf")
            let payload = "real-on-disk-bytes".data(using: .utf8)!
            try? payload.write(to: URL(fileURLWithPath: file))
            DownloadsOrganizerTestSupport.age(file, days: 20)

            // 条目里挂着一个"上一次会话"的虚高缓存值
            let staleCached = DownloadItem(id: file, fileName: "report.pdf", path: file,
                                           size: 999_999, kind: .document,
                                           modificationDate: Date(), ageDays: 20, isSelected: true)
            let res = DownloadsOrganizerScanner.shared.clean(items: [staleCached], toTrash: false, journal: .none)
            guard res.cleanedCount == 1, res.freedBytes == Int64(payload.count), res.freedBytes != 999_999 else {
                print("    记账用了缓存值：\(res.freedBytes)")
                return false
            }
            guard !fm.fileExists(atPath: file) else { return false }

            // 归档移动同样按移动前实测记账（而不是 item.size）
            let toMove = (testDir as NSString).appendingPathComponent("notes.txt")
            try? "1234567".data(using: .utf8)?.write(to: URL(fileURLWithPath: toMove))
            DownloadsOrganizerTestSupport.age(toMove, days: 20)
            let moveItem = DownloadItem(id: toMove, fileName: "notes.txt", path: toMove,
                                        size: 1, kind: .document, modificationDate: Date(),
                                        ageDays: 20, isSelected: true)
            let moved = DownloadsOrganizerScanner.shared.archive(items: [moveItem],
                                                                targetDirectory: (testDir as NSString).appendingPathComponent("Archived"),
                                                                journal: .none)
            guard moved.movedCount == 1, moved.movedBytes == 7, moved.errorCount == 0 else {
                print("    移动量用了缓存值：\(moved.movedBytes)")
                return false
            }
            return true
        }

        // 8. 白名单 / G6 硬排除 / 软链跳板在本模块 policy 下必被拒
        check("DownloadsOrganizer: 白名单与硬排除路径必被拒且文件仍在") {
            let fm = FileManager.default
            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            let testDir = "/tmp/MacCleanTest_Downloads_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer {
                wm.rules = savedRules
                try? fm.removeItem(atPath: testDir)
            }

            let kept = (testDir as NSString).appendingPathComponent("合同终稿.pdf")
            try? "contract".data(using: .utf8)?.write(to: URL(fileURLWithPath: kept))
            DownloadsOrganizerTestSupport.age(kept, days: 60)
            let rule = wm.addPathRule(kept, comment: "自检保护")

            let item = DownloadItem(id: kept, fileName: "合同终稿.pdf", path: kept, size: 8, kind: .document,
                                    modificationDate: Date(), ageDays: 60, isSelected: true)
            let resWhite = DownloadsOrganizerScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard resWhite.cleanedCount == 0 && resWhite.errorCount > 0 else {
                print("    白名单文件被清了")
                return false
            }
            guard fm.fileExists(atPath: kept) else { return false }
            guard resWhite.outcome.rejected.contains(where: { $0.reason == .userWhitelisted }) else { return false }

            // 白名单文件也不许被归档挪走
            let resMove = DownloadsOrganizerScanner.shared.archive(items: [item],
                                                                  targetDirectory: (testDir as NSString).appendingPathComponent("Archived"),
                                                                  journal: .none)
            guard resMove.movedCount == 0 && resMove.errorCount > 0 && fm.fileExists(atPath: kept) else { return false }
            wm.removeRule(id: rule.id)

            // G6：iCloud Drive 与照片图库里的下载项
            for path in [NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs/x.dmg",
                         NSHomeDirectory() + "/Pictures/Photos Library.photoslibrary/originals/x.zip",
                         NSHomeDirectory() + "/Library/CloudStorage/OneDrive-y/x.zip"] {
                let g6 = DownloadItem(id: path, fileName: (path as NSString).lastPathComponent, path: path,
                                      size: 10, kind: .archive, modificationDate: Date(), ageDays: 400, isSelected: true)
                let res = DownloadsOrganizerScanner.shared.clean(items: [g6], toTrash: false, journal: .none)
                guard res.cleanedCount == 0 && res.errorCount > 0,
                      res.outcome.rejected.contains(where: { $0.reason == .hardExcluded || $0.reason == .missing }) else {
                    print("    G6 位置未拦住：\(path)")
                    return false
                }
            }

            // 软链跳板：下载目录里一条指向系统位置的软链
            let link = (testDir as NSString).appendingPathComponent("fake-installer.dmg")
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: "/System/Library/CoreServices/Finder.app")
            let linkItem = DownloadItem(id: link, fileName: "fake-installer.dmg", path: link, size: 100,
                                        kind: .installer, modificationDate: Date(), ageDays: 400, isSelected: true)
            let resLink = DownloadsOrganizerScanner.shared.clean(items: [linkItem], toTrash: false, journal: .none)
            guard resLink.cleanedCount == 0 && resLink.errorCount > 0,
                  fm.fileExists(atPath: link), fm.fileExists(atPath: "/System/Library/CoreServices/Finder.app") else {
                return false
            }
            return true
        }

        // 9. 归档目标位置护栏：越界目标整体拒绝，源文件原地不动
        check("DownloadsOrganizer: 归档目标越界与自我嵌套必须拒绝") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_Dest"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let file = (testDir as NSString).appendingPathComponent("movie.mp4")
            try? "movie-bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: file))
            DownloadsOrganizerTestSupport.age(file, days: 20)
            let item = DownloadItem(id: file, fileName: "movie.mp4", path: file, size: 11, kind: .media,
                                    modificationDate: Date(), ageDays: 20, isSelected: true)

            for bad in ["/System/Archived", "/usr/local/Archived",
                        NSHomeDirectory() + "/Library/Mail/Archived", "/etc/Archived"] {
                let res = DownloadsOrganizerScanner.shared.archive(items: [item], targetDirectory: bad, journal: .none)
                guard res.movedCount == 0, res.errorCount > 0 else {
                    print("    越界归档目标被接受：\(bad)")
                    return false
                }
                guard fm.fileExists(atPath: file) else { return false }
            }
            guard DownloadsOrganizerScanner.destinationRejection("") == .emptyPath,
                  DownloadsOrganizerScanner.destinationRejection("/System/x") == .systemProtected,
                  DownloadsOrganizerScanner.destinationRejection(NSHomeDirectory() + "/Library/Mobile Documents/x") == .hardExcluded,
                  DownloadsOrganizerScanner.destinationRejection("/tmp/ok-dir") == nil else { return false }

            // 自我嵌套：把目录归档进它自己
            let dirItem = DownloadItem(id: testDir, fileName: (testDir as NSString).lastPathComponent, path: testDir,
                                       size: 11, kind: .other, modificationDate: Date(), ageDays: 20, isSelected: true)
            let nested = DownloadsOrganizerScanner.shared.archive(items: [dirItem], targetDirectory: file, journal: .none)
            guard nested.movedCount == 0, nested.errorCount > 0, fm.fileExists(atPath: file) else { return false }
            return true
        }

        // 10. 正在下载的安装包/压缩包既不删也不挪
        check("DownloadsOrganizer: 疑似仍在下载的文件必须跳过") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_InFlight"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let dmg = (testDir as NSString).appendingPathComponent("Xcode_26.dmg")
            let dmgPayload = "partially-downloaded".data(using: .utf8)!
            try? dmgPayload.write(to: URL(fileURLWithPath: dmg))
            // mtime = 现在 → 30 秒写入窗口内
            let item = DownloadItem(id: dmg, fileName: "Xcode_26.dmg", path: dmg, size: 1, kind: .installer,
                                    modificationDate: Date(), ageDays: 0, isSelected: true)
            let resClean = DownloadsOrganizerScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard resClean.cleanedCount == 0, resClean.errorCount > 0, fm.fileExists(atPath: dmg) else {
                print("    正在下载的安装包被删了")
                return false
            }
            let resMove = DownloadsOrganizerScanner.shared.archive(items: [item],
                                                                  targetDirectory: (testDir as NSString).appendingPathComponent("Archived"),
                                                                  journal: .none)
            guard resMove.movedCount == 0, resMove.errorCount > 0, fm.fileExists(atPath: dmg) else { return false }

            // 同一文件放冷 20 天后就允许处理
            DownloadsOrganizerTestSupport.age(dmg, days: 20)
            let aged = DownloadsOrganizerScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard aged.cleanedCount == 1, aged.freedBytes == Int64(dmgPayload.count),
                  !fm.fileExists(atPath: dmg) else {
                print("    放冷后仍未能删除或记账不对：\(aged.cleanedCount)/\(aged.freedBytes)")
                return false
            }
            return true
        }

        // 11. 清理与归档结果写历史（自检注入隔离，不碰用户真实历史）
        check("DownloadsOrganizer: 清理结果写入历史记录") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_History"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            let savedOverride = HistoryStore.fileURLOverride
            defer {
                HistoryStore.fileURLOverride = savedOverride
                try? fm.removeItem(atPath: testDir)
            }
            HistoryStore.fileURLOverride = URL(fileURLWithPath: (testDir as NSString).appendingPathComponent("history.json"))

            let gone = (testDir as NSString).appendingPathComponent("old-installer.pkg")
            try? "pkg-bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: gone))
            DownloadsOrganizerTestSupport.age(gone, days: 30)
            let moved = (testDir as NSString).appendingPathComponent("clip.mp4")
            try? "video".data(using: .utf8)?.write(to: URL(fileURLWithPath: moved))
            DownloadsOrganizerTestSupport.age(moved, days: 30)

            let cleanItem = DownloadItem(id: gone, fileName: "old-installer.pkg", path: gone, size: 9, kind: .installer,
                                         modificationDate: Date(), ageDays: 30, isSelected: true)
            let moveItem = DownloadItem(id: moved, fileName: "clip.mp4", path: moved, size: 5, kind: .media,
                                        modificationDate: Date(), ageDays: 30, isSelected: true)
            let resClean = DownloadsOrganizerScanner.shared.clean(items: [cleanItem], toTrash: false)
            let resMove = DownloadsOrganizerScanner.shared.archive(items: [moveItem],
                                                                  targetDirectory: (testDir as NSString).appendingPathComponent("Archived"))
            guard resClean.cleanedCount == 1, resMove.movedCount == 1 else { return false }

            let records = HistoryStore.load()
            let cleanRecord = records.first { $0.mode == "彻底删除" }
            let moveRecord = records.first { $0.mode == "归档移动" }
            guard let cleanRecord, let moveRecord,
                  cleanRecord.categoryName == DownloadsOrganizerScanner.historyCategory,
                  cleanRecord.itemCount == 1, cleanRecord.bytes == 9,
                  moveRecord.itemCount == 1, moveRecord.bytes == 0 else {
                print("    历史未落盘：\(records.map { "\($0.categoryName):\($0.mode):\($0.bytes)" } )")
                return false
            }
            return true
        }
    }
}

/// 下载目录归档自检 fixture 工具
enum DownloadsOrganizerTestSupport {
    /// 把 fixture 的 mtime 拨老 N 天（模拟"闲置很久的下载文件"）
    static func age(_ path: String, days: Int) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-Double(days) * 86400)], ofItemAtPath: path)
    }
}
