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

        // MARK: - 读不到 ≠ 没有文件（G9 在归档面板上的落地）

        check("归档面板：目录读不到时给出 unreadableRoots，不再回一个空 summary 装作扫过了") {
            let fm = FileManager.default
            let locked = "/private/tmp/macclean-dl-locked-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
            fm.createFile(atPath: locked + "/inner/a.dmg", contents: Data(repeating: 1, count: 4096))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
                try? fm.removeItem(atPath: locked)
            }
            FileSystem.resetDeniedAccess()
            let sum = DownloadsOrganizerScanner.shared.scan(customDirectory: locked)
            guard sum.unreadableRoots == [FileSystem.normalizePath(locked)] else {
                print("      读不到的目录没被标出来：unreadableRoots 共 \(sum.unreadableRoots.count) 条")
                return false
            }
            // 盲区也要记账：面板之外（扫描诊断）得知道这里没看清
            guard FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(locked)) else {
                print("      没记进盲区清单（本轮盲区 \(FileSystem.deniedAccessSnapshot().count) 处）")
                return false
            }
            return true
        }

        check("反证：可读目录照常列出条目，且 unreadableRoots 必须为空") {
            // 上一条只断"标出来了"。若实现退化成"一律标 unreadable"，它也照样绿——
            // 那等于把面板所有结果都判成不完整，是另一种坏。
            let fm = FileManager.default
            let root = "/private/tmp/macclean-dl-ok-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            fm.createFile(atPath: root + "/app.dmg", contents: Data(repeating: 7, count: 8192))
            defer { try? fm.removeItem(atPath: root) }
            FileSystem.resetDeniedAccess()
            let sum = DownloadsOrganizerScanner.shared.scan(customDirectory: root)
            guard sum.unreadableRoots.isEmpty, sum.deferredRoots.isEmpty else {
                print("      可读目录被误标成没读到：unreadable=\(sum.unreadableRoots.count) "
                      + "deferred=\(sum.deferredRoots.count)")
                return false
            }
            // 不断 totalSize 的具体字节数：那是 totalFileAllocatedSize，换卷/克隆就变，
            // 与代码语义无关，只会造出顺序相关的假红。
            guard sum.items.count == 1, sum.totalSize > 0 else {
                print("      可读目录没列到那一个条目：items=\(sum.items.count) total=\(sum.totalSize)")
                return false
            }
            return true
        }

        check("两个归档扫描器的门禁根用三态探测，不许退回折叠成 Bool 的写法") {
            // `isReadableWithDeadline` 把"读不到"和"本轮没去试"都折成 false。
            // 对扫描器的 `guard … else { continue }` 没问题，但面板拿它生成用户可见的
            // "读不到"文案，就是在对没碰过的目录凭空造一条权限告警（本轮查出过的真 P0）。
            let dir = Selftest.sourceDirectoryPath
            var bad: [String] = []
            for file in ["DownloadsOrganizerScanner.swift", "ScreenshotsOrganizerScanner.swift"] {
                guard let src = try? String(
                    contentsOfFile: (dir as NSString).appendingPathComponent(file), encoding: .utf8) else {
                    bad.append("\(file):<不可读>")
                    continue
                }
                if !src.contains("FileSystem.probeDirectory(") {
                    bad.append("\(file): 根读取不再带截止")
                }
                if src.contains("FileSystem.isReadableWithDeadline(")
                    || src.contains("FileSystem.canOpenDirectory(")
                    || src.contains("isReadableFile(atPath:") {
                    bad.append("\(file): 用了折叠成 Bool 的探测，分不清「读不到」与「没去试」")
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("卡片：「没读到」与「没有文件」互斥，且两种情形的措辞只有一个来源") {
            let dir = Selftest.sourceDirectoryPath
            guard let banner = try? String(
                contentsOfFile: (dir as NSString).appendingPathComponent("OrganizerRootsBanner.swift"),
                encoding: .utf8) else {
                print("      读不到 OrganizerRootsBanner.swift")
                return false
            }
            var bad: [String] = []
            // 读不到 / 没顾上 是两句话；把后者也说成权限不足就是谎报。
            let parts = banner.components(separatedBy: "if !deferred.isEmpty {")
            guard parts.count == 2 else {
                print("      banner 不再分「读不到」与「没顾上」两支")
                return false
            }
            if !parts[0].contains("本轮没能读到") || !parts[0].contains("lock.fill") {
                bad.append("「读不到」那支缺了警示措辞或锁形图标")
            }
            if parts[1].contains("lock.fill") || parts[1].contains("没能读到") {
                bad.append("「没顾上读」那支借用了权限/锁的措辞——会对没去 open 的目录声称读不到")
            }
            for file in ["DownloadsOrganizerCard.swift", "ScreenshotsOrganizerCard.swift"] {
                guard let src = try? String(
                    contentsOfFile: (dir as NSString).appendingPathComponent(file), encoding: .utf8) else {
                    bad.append("\(file):<不可读>")
                    continue
                }
                // 只圈列表容器：撞到下一个 private 成员就收口，否则会被同文件别处的字样蒙过去
                guard let head = src.range(of: "private var contentListContainer") else {
                    bad.append("\(file):<没有 contentListContainer>")
                    continue
                }
                let after = src[head.upperBound...]
                let scope: Substring = after.range(of: "\n    private ")
                    .map { after[..<$0.lowerBound] } ?? after
                if !scope.contains("&& !rootsBanner.hasAnything") {
                    bad.append("\(file): 「未发现符合条件的…」不再与警示条互斥")
                }
                // 钉**具体标识符**：上一版写成 "isScanning 或 isProcessing 任一命中"，
                // 于是截图卡片把守卫挂到了 isProcessing（只在清理/归档时为真，那时 items 必非空）
                // ——「正在读取…」成了死代码，而这条断言照样绿。或集是假断言。
                if !scope.contains("if isScanning && summary.items.isEmpty {") {
                    bad.append("\(file): 读取中没用 isScanning 抑制「没有文件」（写错标识符=死代码）")
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("卡死过的目录：面板要拿到 unreadable（不是 deferred），措辞才是「没能读到」") {
            // 真机卡死走的是**超时**这一支，而其余几条用的都是 mode 000（立即 EACCES），
            // 那条路径一次都没被执行过。这里用同一个卡死源把超时支钉住：
            // 超时之后 TTL 内的再问必须仍答 .unreadable 并带盲区记账，
            // 否则面板会把它讲成"本轮没顾上"，用户就不会去查授权。
            let saved = FileSystem.gatedReadDeadline
            FileSystem.gatedReadDeadline = 0.3
            FileSystem.resetWedgedReadsForSelftest()
            FileSystem.resetDeniedAccess()
            defer { FileSystem.gatedReadDeadline = saved }
            let wedge = "/private/tmp/macclean-dl-wedge-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: wedge, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: wedge) }
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let first: [String]? = FileSystem.readWithinDeadline(wedge) { () -> [String] in
                gate.wait()
                return []
            }
            guard first == nil else {
                print("      卡死源没兜住，本条没在测超时支")
                return false
            }
            guard FileSystem.probeDirectory(wedge) == .unreadable else {
                print("      超时过的目录被归成了别的结局（面板措辞会退成「没顾上」）")
                return false
            }
            guard FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(wedge)) else {
                print("      超时支没记盲区（本轮盲区 \(FileSystem.deniedAccessSnapshot().count) 处）")
                return false
            }
            return true
        }

        check("在途额度满时归入 deferredRoots，不得报成读不到也不得记盲区") {
            let saved = FileSystem.gatedReadDeadline
            FileSystem.gatedReadDeadline = 0.3
            FileSystem.resetWedgedReadsForSelftest()
            defer { FileSystem.gatedReadDeadline = saved }
            let fm = FileManager.default
            let ok = "/private/tmp/macclean-dl-defer-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: ok, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: ok) }
            let gate = DispatchSemaphore(value: 0)
            // 占几条还几条，且**只还一次**：多 signal 会把在途上限抬到 4 以上，
            // 那就不是在测限流了。早退时也要还，所以 defer 与显式调用共用一个开关。
            let releaseOnce = SelftestOnce { for _ in 0..<4 { gate.signal() } }
            for i in 0..<4 {
                let blocker = "/private/tmp/macclean-dl-block-\(UUID().uuidString)-\(i)"
                _ = FileSystem.readWithinDeadline(blocker) { () -> [String] in
                    gate.wait()
                    return []
                }
            }
            FileSystem.resetDeniedAccess()
            let sum = DownloadsOrganizerScanner.shared.scan(customDirectory: ok)
            // 4 条卡死的 body 各占一分令牌，就必须放行 4 次；只 signal 一次会把
            // 3 分令牌永久吃掉，后面所有门禁读取都退化成 .deferred——本条自己制造饥饿。
            releaseOnce.run()
            // 归还的验证要看**满额**回来了，而不是"还剩一分"（那一分正是本条要用的）。
            var drained = false
            var notReadableLast = -1
            let probes = (0..<4).map { "/private/tmp/macclean-drain-\(UUID().uuidString)-\($0)" }
            for p2 in probes { try? FileManager.default.createDirectory(atPath: p2,
                                                                       withIntermediateDirectories: true) }
            defer { probes.forEach { try? FileManager.default.removeItem(atPath: $0) } }
            // 刚被放行的那几条 body 还要一点时间才把令牌还回来，所以要重试着等满额，
            // 不能假设 signal 之后立刻可用（第一版就是这么假红的）。
            for _ in 0..<60 {
                let drainGroup = DispatchGroup()
                let drainLock = NSLock()
                var notReadable = 0
                for p2 in probes {
                    drainGroup.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { drainGroup.leave() }
                        if FileSystem.probeDirectory(p2) != .readable {
                            drainLock.lock(); notReadable += 1; drainLock.unlock()
                        }
                    }
                }
                drainGroup.wait()
                notReadableLast = notReadable
                if notReadable == 0 { drained = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            var bad: [String] = []
            if !sum.unreadableRoots.isEmpty {
                bad.append("根本没去 open 的目录被报成「读不到」，面板会弹权限告警")
            }
            if sum.deferredRoots != [FileSystem.normalizePath(ok)] {
                bad.append("额度满时没有归入 deferredRoots：\(sum.deferredRoots.count) 条")
            }
            if !FileSystem.deniedAccessSnapshot().isEmpty {
                bad.append("对没试过的目录凭空记了一条盲区")
            }
            if !drained { bad.append("额度未归还：最后一轮仍有 \(notReadableLast) 个探测拿不到令牌") }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
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

/// 只执行一次的清理块（自检里用来归还并发令牌）
final class SelftestOnce {
    private let body: () -> Void
    private let lock = NSLock()
    private var done = false
    init(_ body: @escaping () -> Void) { self.body = body }
    func run() {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        lock.unlock()
        body()
    }
}
