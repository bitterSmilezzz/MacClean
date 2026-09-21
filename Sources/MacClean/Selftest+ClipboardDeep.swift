import Foundation
import AppKit

// MARK: - 剪贴板历史与大文件临时缓冲区治理深度自检 (v1.63.0 / v1.72.0 安全加固)

extension Selftest {
    static func suiteClipboardDeep() {
        print("--- [Suite] 剪贴板历史与大文件临时缓冲区治理深度自检 (v1.63.0) ---")

        // 1. 数据类型与枚举判定
        check("Clipboard: 数据格式与分类枚举校验") {
            let item = PasteboardItemSummary(
                id: "public.utf8-plain-text",
                typeName: "public.utf8-plain-text",
                dataType: .text,
                size: 1024,
                preview: "Hello World",
                isLarge: false,
                isSensitive: false
            )
            guard item.dataType == .text && !item.isLarge && !item.isSensitive else { return false }
            guard PasteboardDataType.allCases.count >= 5 else { return false }
            return true
        }

        // 2. 敏感凭据正则表达式识别
        check("Clipboard: 敏感凭据与 API Key 正则拦截校验") {
            let purger = ClipboardPurger.shared

            let sensitiveKeys = [
                "sk-proj-abc123456789012345678901234567890",
                "ghp_123456789012345678901234567890123456",
                "AKIAIOSFODNN7EXAMPLE",
                "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
                "-----BEGIN RSA PRIVATE KEY-----",
                "password = MySecretPassword123"
            ]
            for key in sensitiveKeys {
                guard purger.checkSensitivity(text: key) else {
                    print("    ❌ 未能识别敏感凭据: \(key)")
                    return false
                }
            }

            let normalTexts = [
                "Hello world, this is a normal text snippet.",
                "https://github.com/apple/swift",
                "let x = 100",
                "192.168.1.1"
            ]
            for text in normalTexts {
                guard !purger.checkSensitivity(text: text) else {
                    print("    ❌ 误报常规文本为敏感凭据: \(text)")
                    return false
                }
            }
            return true
        }

        // 3. 报告指标精算
        check("Clipboard: 报告指标与释放潜力精算") {
            let i1 = PasteboardItemSummary(id: "1", typeName: "t1", dataType: .image, size: 6 * 1024 * 1024, preview: "Image", isLarge: true, isSensitive: false)
            let i2 = PasteboardItemSummary(id: "2", typeName: "t2", dataType: .sensitiveCredential, size: 50, preview: "Key", isLarge: false, isSensitive: true)

            let c1 = ClipboardCacheItem(id: "c1", name: "cache1", path: "/tmp/c1", size: 4000, note: "note")

            let report = ClipboardReport(
                items: [i1, i2],
                cacheItems: [c1],
                totalMemorySize: 6 * 1024 * 1024 + 50,
                totalCacheSize: 4000,
                hasSensitiveData: true,
                changeCount: 10
            )

            guard report.totalMemorySize == (6 * 1024 * 1024 + 50) else { return false }
            guard report.totalCacheSize == 4000 else { return false }
            guard report.totalReclaimableSize == (6 * 1024 * 1024 + 4050) else { return false }
            guard report.hasSensitiveData == true else { return false }
            guard !report.isEmpty else { return false }
            // 体积与年龄依据：时间未知就不给"可释放"结论
            guard c1.sizeAndAgeEvidence.contains("时间未知，不处理") else { return false }
            let aged = ClipboardCacheItem(id: "c2", name: "cache2", path: "/tmp/c2", size: 4000, note: "n",
                                          modificationDate: Date(), ageDays: 9)
            guard aged.sizeAndAgeEvidence.contains("闲置 9 天") else { return false }
            return true
        }

        // 4. 系统越界与安全性防线
        check("Clipboard: 系统目录清理越界拦截") {
            let fakeCache = ClipboardCacheItem(
                id: "/System/Library/pboard",
                name: "pboard",
                path: "/System/Library/pboard",
                size: 1000,
                note: "test"
            )
            let res = ClipboardPurger.shared.cleanClipboardCaches(items: [fakeCache], journal: .none)
            guard res.cleanedCount == 0 && res.freedBytes == 0 && res.errorCount > 0 else { return false }
            guard res.outcome.rejected.contains(where: { $0.reason == .systemProtected }) else { return false }
            return true
        }

        // 5. 模拟临时缓存清理核验（释放量 = 删除前实测，而非条目声明值）
        check("Clipboard: 模拟剪贴板临时置换文件清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Clipboard_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let dummyFile = (testDir as NSString).appendingPathComponent("pasteboard_temp.dat")
            let payload = "dummy pasteboard buffer data".data(using: .utf8)!
            try? payload.write(to: URL(fileURLWithPath: dummyFile))
            // 剪贴板溢出文件必须"已过使用窗口"才允许处理（1 小时门槛）
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 3600)], ofItemAtPath: dummyFile)

            let cacheItem = ClipboardCacheItem(
                id: dummyFile,
                name: "pasteboard_temp.dat",
                path: dummyFile,
                size: 999_999,          // 故意给出与真实体积不符的"扫描缓存值"
                note: "test"
            )

            let res = ClipboardPurger.shared.cleanClipboardCaches(items: [cacheItem], journal: .none)
            guard res.cleanedCount == 1 && res.freedBytes == Int64(payload.count) else {
                print("    期望实测 \(payload.count)，实得 \(res.freedBytes)")
                return false
            }
            guard !fm.fileExists(atPath: dummyFile) else { return false }
            return true
        }

        // 6. 真实系统剪贴板读取无崩溃
        check("Clipboard: 真实系统剪贴板与临时缓存安全探测") {
            let report = ClipboardPurger.shared.inspect()
            // 无论当前剪贴板是否有内容，均应安全返回有效报告，无崩溃
            guard report.changeCount >= 0 else { return false }
            // 引用源必须给出"可判定/不可判定"的明确结论
            let refs = ClipboardPurger.pasteboardReferencedPaths()
            guard refs.readable else { return false }
            return true
        }

        // 7. TemporaryItems：新鲜项与无法归属项一律不删
        check("Clipboard: TemporaryItems 新鲜项与自动恢复草稿保护") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Clipboard_TempItems"
            let tempItems = (testDir as NSString).appendingPathComponent("TemporaryItems")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: tempItems, withIntermediateDirectories: true)
            // 只有"已登记的溢出目录"才允许整目录展开 → fixture 必须先登记
            let savedDirs = ClipboardPurger.extraTemporaryItemsDirs
            ClipboardPurger.extraTemporaryItemsDirs = [tempItems]
            defer {
                ClipboardPurger.extraTemporaryItemsDirs = savedDirs
                try? fm.removeItem(atPath: testDir)
            }

            func make(_ name: String, age: TimeInterval, text: String) -> String {
                let path = (tempItems as NSString).appendingPathComponent(name)
                try? text.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: path)
                return path
            }
            let day: TimeInterval = 86400
            let stale = make("com.apple.pasteboard.overflow.dat", age: 10 * day, text: "stale-overflow")
            let fresh = make("com.apple.pasteboard.recent.dat", age: 60, text: "fresh-still-in-use")
            let draft = make("AutoRecover-年度报告-草稿.pages", age: 30 * day, text: "autosave-draft")

            let staleSize = Int64(FileSystem.size(at: stale))
            let item = ClipboardCacheItem(id: tempItems, name: "TemporaryItems", path: tempItems,
                                          size: 100_000, note: "test")
            let res = ClipboardPurger.shared.cleanClipboardCaches(
                items: [item], journal: .none, references: .empty)

            guard res.cleanedCount == 1 && res.freedBytes == staleSize else {
                print("    TemporaryItems 展开判定失真：cleaned=\(res.cleanedCount) freed=\(res.freedBytes)/\(staleSize)")
                return false
            }
            guard !fm.fileExists(atPath: stale) else { return false }
            guard fm.fileExists(atPath: fresh) else {
                print("    新鲜剪贴板溢出项被删了")
                return false
            }
            guard fm.fileExists(atPath: draft) else {
                print("    无法归属的自动恢复草稿被删了")
                return false
            }
            guard res.rejectedCount >= 2 else { return false }
            return true
        }

        // 8. 当前剪贴板仍指向的内容绝对不删；引用源读不到时整体放弃
        check("Clipboard: 剪贴板引用中的大文件缓冲不得删除") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Clipboard_Ref"
            let tempItems = (testDir as NSString).appendingPathComponent("TemporaryItems")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: tempItems, withIntermediateDirectories: true)
            let savedDirs = ClipboardPurger.extraTemporaryItemsDirs
            ClipboardPurger.extraTemporaryItemsDirs = [tempItems]
            defer {
                ClipboardPurger.extraTemporaryItemsDirs = savedDirs
                try? fm.removeItem(atPath: testDir)
            }

            let big = (tempItems as NSString).appendingPathComponent("com.apple.pasteboard.bigimage.dat")
            try? "large-image-spill".data(using: .utf8)?.write(to: URL(fileURLWithPath: big))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-20 * 86400)], ofItemAtPath: big)
            let item = ClipboardCacheItem(id: tempItems, name: "TemporaryItems", path: tempItems,
                                          size: 1000, note: "test")

            // ① 剪贴板正指向它
            let referenced = FileSystem.normalizePath(FileSystem.realPath(big))
            let refs = ClipboardPurger.PasteboardReferences(paths: [referenced], readable: true)
            let resRef = ClipboardPurger.shared.cleanClipboardCaches(items: [item], journal: .none, references: refs)
            guard resRef.cleanedCount == 0 && resRef.freedBytes == 0 && resRef.errorCount > 0 else {
                print("    剪贴板仍指向的缓冲文件被删了")
                return false
            }
            guard fm.fileExists(atPath: big) else { return false }

            // ② 引用它的是**父目录**（目录条目同样不可整删）
            let dirRefs = ClipboardPurger.PasteboardReferences(
                paths: [FileSystem.normalizePath(FileSystem.realPath(tempItems))], readable: true)
            guard ClipboardPurger.isReferencedByPasteboard(referenced, dirRefs) else { return false }

            // ③ 引用源读不到 → "读不到"≠"可以删"
            let unreadable = ClipboardPurger.PasteboardReferences(paths: [], readable: false)
            let resUnknown = ClipboardPurger.shared.cleanClipboardCaches(items: [item], journal: .none, references: unreadable)
            guard resUnknown.cleanedCount == 0 && resUnknown.errorCount > 0,
                  fm.fileExists(atPath: big), !resUnknown.referencesReadable else { return false }

            // ④ 干净引用源下才允许删
            let resOk = ClipboardPurger.shared.cleanClipboardCaches(items: [item], journal: .none, references: .empty)
            guard resOk.cleanedCount == 1, !fm.fileExists(atPath: big) else { return false }
            return true
        }

        // 9. 白名单与硬排除路径在本模块 policy 下必被拒
        check("Clipboard: 白名单与硬排除路径必被拒且文件仍在") {
            let fm = FileManager.default
            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            let testDir = "/tmp/MacCleanTest_Clipboard_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer {
                wm.rules = savedRules
                try? fm.removeItem(atPath: testDir)
            }

            let fileA = (testDir as NSString).appendingPathComponent("pasteboard_whitelisted.dat")
            try? "keep-me".data(using: .utf8)?.write(to: URL(fileURLWithPath: fileA))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 86400)], ofItemAtPath: fileA)
            let rule = wm.addPathRule(fileA, comment: "自检保护")

            let itemA = ClipboardCacheItem(id: fileA, name: "pasteboard_whitelisted.dat", path: fileA,
                                           size: 8, note: "test")
            let resWhite = ClipboardPurger.shared.cleanClipboardCaches(items: [itemA], journal: .none, references: .empty)
            guard resWhite.cleanedCount == 0 && resWhite.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: fileA) else {
                print("    白名单文件被删了")
                return false
            }
            guard resWhite.outcome.rejected.contains(where: { $0.reason == .userWhitelisted }) else { return false }
            wm.removeRule(id: rule.id)

            // G6 硬排除：~/Library/Mail 里的同名残留文件绝不碰
            let mailLike = ClipboardCacheItem(id: "pasteboard", name: "pasteboard",
                                              path: NSHomeDirectory() + "/Library/Mail/pasteboard",
                                              size: 10, note: "test")
            let resG6 = ClipboardPurger.shared.cleanClipboardCaches(items: [mailLike], journal: .none, references: .empty)
            guard resG6.cleanedCount == 0 && resG6.errorCount > 0,
                  resG6.outcome.rejected.contains(where: { $0.reason == .hardExcluded }) else { return false }

            // 软链跳板
            let link = (testDir as NSString).appendingPathComponent("pasteboard-link")
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: fileA)
            let linkItem = ClipboardCacheItem(id: link, name: "pasteboard-link", path: link, size: 8, note: "test")
            let resLink = ClipboardPurger.shared.cleanClipboardCaches(items: [linkItem], journal: .none, references: .empty)
            guard resLink.cleanedCount == 0 && resLink.errorCount > 0,
                  fm.fileExists(atPath: link), fm.fileExists(atPath: fileA) else { return false }
            return true
        }

        // 9b. 未登记的目录条目：绝不整目录展开（旧版静默清空的入口）
        check("Clipboard: 未登记目录不得被整目录展开清理") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Clipboard_NotRegistered"
            let tempItems = (testDir as NSString).appendingPathComponent("TemporaryItems")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: tempItems, withIntermediateDirectories: true)
            let savedDirs = ClipboardPurger.extraTemporaryItemsDirs
            ClipboardPurger.extraTemporaryItemsDirs = [tempItems]   // 只认登记过的溢出目录
            defer {
                ClipboardPurger.extraTemporaryItemsDirs = savedDirs
                try? fm.removeItem(atPath: testDir)
            }
            ClipboardPurger.extraTemporaryItemsDirs = []

            let day: TimeInterval = 86400
            var files: [String] = []
            for name in ["com.apple.pasteboard.old1.dat", "com.apple.pasteboard.old2.dat"] {
                let path = (tempItems as NSString).appendingPathComponent(name)
                try? "should-survive".data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
                try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * day)], ofItemAtPath: path)
                files.append(path)
            }
            let item = ClipboardCacheItem(id: tempItems, name: "TemporaryItems", path: tempItems,
                                          size: 9000, note: "test")
            let res = ClipboardPurger.shared.cleanClipboardCaches(items: [item], journal: .none, references: .empty)
            guard res.cleanedCount == 0 && res.freedBytes == 0 && res.errorCount > 0 else {
                print("    未登记目录被整批清空了")
                return false
            }
            return files.allSatisfy { fm.fileExists(atPath: $0) }
        }

        // 10. 清理结果写历史记录（自检注入隔离，不碰用户真实历史）
        check("Clipboard: 清理写历史与撤销快照") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Clipboard_History"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            let savedOverride = HistoryStore.fileURLOverride
            let historyURL = URL(fileURLWithPath: (testDir as NSString).appendingPathComponent("history.json"))
            defer {
                HistoryStore.fileURLOverride = savedOverride
                try? fm.removeItem(atPath: testDir)
            }
            HistoryStore.fileURLOverride = historyURL

            let file = (testDir as NSString).appendingPathComponent("pboard_history.dat")
            let payload = "history-evidence".data(using: .utf8)!
            try? payload.write(to: URL(fileURLWithPath: file))
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 86400)], ofItemAtPath: file)

            let item = ClipboardCacheItem(id: file, name: "pboard_history.dat", path: file,
                                          size: 1, note: "test")
            let res = ClipboardPurger.shared.cleanClipboardCaches(items: [item], toTrash: true, references: .empty)
            guard res.cleanedCount == 1 && res.freedBytes == Int64(payload.count) else { return false }

            let records = HistoryStore.load()
            guard let record = records.first,
                  record.categoryName == ClipboardPurger.historyCategory,
                  record.itemCount == 1, record.bytes == Int64(payload.count),
                  record.mode == "废纸篓" else {
                print("    历史未落盘：\(records)")
                return false
            }
            return true
        }
    }
}
