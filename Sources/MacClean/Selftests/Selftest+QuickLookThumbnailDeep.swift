import Foundation

// MARK: - 访达快速查看缩略图缓存释放深度自检 (v1.66.0 / v1.72.0 安全加固)

extension Selftest {
    static func suiteQuickLookThumbnailDeep() {
        print("--- [Suite] 访达快速查看缩略图缓存释放深度自检 (v1.66.0) ---")

        // 1. 缓存分类与命名特征判定
        check("QuickLookThumbnail: 缓存分类与命名特征判定") {
            guard QuickLookCacheKind.thumbnailDatabase.icon == "photo.stack.fill" else { return false }
            guard QuickLookCacheKind.previewExtensionCache.icon == "puzzlepiece.extension.fill" else { return false }
            guard QuickLookCacheKind.uiServiceCache.icon == "macwindow.on.rectangle" else { return false }
            guard QuickLookCacheKind.userQuickLookCache.icon == "eye.fill" else { return false }

            let validPath = "/var/folders/xx/com.apple.QuickLook.thumbnailcache"
            guard validPath.lowercased().contains("quicklook") else { return false }

            let invalidPath = "/var/folders/xx/com.apple.Safari"
            guard !invalidPath.lowercased().contains("quicklook") else { return false }
            guard QuickLookThumbnailPurger.isQuickLookCachePath(validPath) else { return false }
            guard !QuickLookThumbnailPurger.isQuickLookCachePath(invalidPath) else { return false }

            return true
        }

        // 2. 概要指标统计与容量精算
        check("QuickLookThumbnail: 概要指标统计与容量精算") {
            let item1 = QuickLookCacheItem(id: "1", kind: .thumbnailDatabase, title: "DB", path: "/p1", size: 1000, fileCount: 5, isSelected: true)
            let item2 = QuickLookCacheItem(id: "2", kind: .previewExtensionCache, title: "Ext", path: "/p2", size: 2000, fileCount: 10, isSelected: true)
            let item3 = QuickLookCacheItem(id: "3", kind: .userQuickLookCache, title: "User", path: "/p3", size: 500, fileCount: 2, isSelected: false)

            let summary = QuickLookThumbnailSummary(
                items: [item1, item2, item3],
                totalSize: 3500
            )

            guard summary.totalSize == 3500 else { return false }
            guard summary.selectedSize == 3000 else { return false }
            guard summary.selectedCount == 2 else { return false }

            return true
        }

        // 3. 系统关键目录与非 QuickLook 路径越界拦截
        check("QuickLookThumbnail: 系统关键目录与非 QuickLook 路径越界拦截") {
            // 系统关键目录拦截
            let sysItem = QuickLookCacheItem(
                id: "/System/Library/QuickLook", kind: .thumbnailDatabase, title: "Sys",
                path: "/System/Library/QuickLook", size: 100, fileCount: 1, isSelected: true
            )
            let resSys = QuickLookThumbnailPurger.shared.purge(items: [sysItem], resetSystemCache: false, journal: .none)
            guard resSys.purgedCount == 0 && resSys.errorCount > 0 else { return false }

            // 非 QuickLook 路径拦截
            let nonQLItem = QuickLookCacheItem(
                id: "/tmp/com.apple.Safari.cache", kind: .thumbnailDatabase, title: "Safari",
                path: "/tmp/com.apple.Safari.cache", size: 100, fileCount: 1, isSelected: true
            )
            let resNonQL = QuickLookThumbnailPurger.shared.purge(items: [nonQLItem], resetSystemCache: false, journal: .none)
            guard resNonQL.purgedCount == 0 && resNonQL.errorCount > 0 else { return false }
            // 拦截原因必须如实可查
            guard resNonQL.outcome.rejected.contains(where: { $0.reason == .outsideDomain }) else { return false }

            return true
        }

        // 4. 模拟 QuickLook 缓存目录扫描与文件统计
        check("QuickLookThumbnail: 模拟 QuickLook 缓存目录扫描与文件统计") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_QuickLook_Scan"
            let qlDir = (testDir as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let indexSqlite = (qlDir as NSString).appendingPathComponent("index.sqlite")
            let thumbData = (qlDir as NSString).appendingPathComponent("thumbnails.data")
            try? "mock_sqlite_index_header".data(using: .utf8)?.write(to: URL(fileURLWithPath: indexSqlite))
            try? "mock_thumbnails_blob_binary_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: thumbData))

            let summary = QuickLookThumbnailPurger.shared.scan(customDirectories: [qlDir])
            guard summary.items.count == 1 else { return false }
            guard summary.totalSize > 0 else { return false }

            let item = summary.items.first
            guard let item, item.fileCount == 2, item.size > 0 else { return false }

            return true
        }

        // 5. 模拟缓存安全清空与重建逻辑核验（释放量 = 删除前实测）
        check("QuickLookThumbnail: 模拟缓存安全清空与重建核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_QuickLook_Purge"
            let qlDir = (testDir as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let f1 = (qlDir as NSString).appendingPathComponent("thumbnails.data")
            try? "large_thumbnail_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))

            let stats = CLICacheScanner.calculateDirectoryStats(at: qlDir)
            guard stats.fileCount == 1 && stats.size > 0 else { return false }
            // 删除**前**实测（网关口径），作为记账的唯一依据
            let measuredBefore = FileSystem.size(at: f1)
            guard measuredBefore > 0 else { return false }

            let item = QuickLookCacheItem(
                id: qlDir, kind: .thumbnailDatabase, title: "Test",
                path: qlDir, size: stats.size, fileCount: stats.fileCount, isSelected: true
            )

            // 执行清空（不触发系统全局 reset，只测文件安全移除）
            let res = QuickLookThumbnailPurger.shared.purge(items: [item], resetSystemCache: false, journal: .none)
            guard res.purgedCount == 1 && res.freedBytes == measuredBefore && res.errorCount == 0 else {
                print("    期望实测 \(measuredBefore)，实得 \(res.freedBytes)/\(res.purgedCount)/err\(res.errorCount)")
                return false
            }

            // 根目录应依然存在，子项被移除
            guard fm.fileExists(atPath: qlDir) else { return false }
            let remaining = (try? fm.contentsOfDirectory(atPath: qlDir)) ?? []
            guard remaining.isEmpty else { return false }

            return true
        }

        // 6. 空目录与非法路径鲁棒性断言
        check("QuickLookThumbnail: 空目录与非法路径鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_QuickLook_Empty"
            let emptyDir = (testDir as NSString).appendingPathComponent("com.apple.QuickLook.empty")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let summary = QuickLookThumbnailPurger.shared.scan(customDirectories: [
                emptyDir,
                "/non_existent_quicklook_dir"
            ])

            guard summary.items.isEmpty && summary.totalSize == 0 else { return false }

            // 不存在的缓存目录不得被当成"已清理"
            let ghost = QuickLookCacheItem(id: "/non_existent_quicklook_dir", kind: .thumbnailDatabase,
                                           title: "Ghost", path: "/non_existent_quicklook_dir",
                                           size: 999, fileCount: 1, isSelected: true)
            let res = QuickLookThumbnailPurger.shared.purge(items: [ghost], resetSystemCache: false, journal: .none)
            guard res.purgedCount == 0 && res.freedBytes == 0 && res.errorCount > 0 else { return false }

            return true
        }

        // 7. qlmanage 命令与参数：只在**有成功证据**时才报"系统缓存已重置"
        check("QuickLookThumbnail: qlmanage 重置命令注入与成功证据") {
            let savedRunner = SafeProcess.runner
            let savedPath = QuickLookThumbnailPurger.qlmanagePath
            defer { SafeProcess.runner = savedRunner; QuickLookThumbnailPurger.qlmanagePath = savedPath }

            var invoked: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                invoked.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            let toolPath = "/usr/bin/qlmanage"
            QuickLookThumbnailPurger.qlmanagePath = toolPath
            guard SafeProcess.isAvailable(toolPath) else {
                // 本机没有该工具：必须如实报"未提供"，且一次调用都不发起
                SafeProcess.resetInvokedCommands()
                let absent = QuickLookThumbnailPurger.executeQLManageReset()
                return !absent.reset && SafeProcess.invokedCommands.isEmpty
                    && absent.failureReason?.contains("未提供") == true
            }

            let reset = QuickLookThumbnailPurger.executeQLManageReset()
            guard reset.reset, reset.failureReason == nil else { return false }
            // 必须调的是 qlmanage 本体 + 两条重置参数，不经过任何 shell
            guard invoked.count == 2,
                  invoked.allSatisfy({ $0.0 == toolPath }),
                  invoked[0].1 == ["-r", "cache"], invoked[1].1 == ["-r"] else {
                print("    实际调用：\(invoked)")
                return false
            }
            return true
        }

        // 8. 非 0 退出 / 未执行 / 工具不存在 → 一律不得计成"已重置"
        check("QuickLookThumbnail: qlmanage 失败与不可用不得谎报成功") {
            let savedRunner = SafeProcess.runner
            let savedPath = QuickLookThumbnailPurger.qlmanagePath
            defer {
                SafeProcess.runner = savedRunner
                QuickLookThumbnailPurger.qlmanagePath = savedPath
                SafeProcess.resetInvokedCommands()
            }

            // ① 非 0 退出
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 78, output: "operation not permitted") }
            QuickLookThumbnailPurger.qlmanagePath = "/usr/bin/qlmanage"
            let failed = QuickLookThumbnailPurger.executeQLManageReset()
            guard !failed.reset, failed.failureReason?.contains("78") == true else {
                print("    非 0 退出被当成成功：\(String(describing: failed.failureReason))")
                return false
            }

            // ② 超时
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "", timedOut: true) }
            guard !QuickLookThumbnailPurger.executeQLManageReset().reset else { return false }

            // ③ 未被执行（runner 返回 nil）
            SafeProcess.runner = { _, _, _ in nil }
            let notRun = QuickLookThumbnailPurger.executeQLManageReset()
            guard !notRun.reset, notRun.failureReason?.contains("未被执行") == true else {
                print("    未执行被当成成功：\(String(describing: notRun.failureReason))")
                return false
            }

            // ④ 工具不存在：连一次调用都不该发生
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            QuickLookThumbnailPurger.qlmanagePath = "/nonexistent/macclean-qlmanage"
            SafeProcess.resetInvokedCommands()
            let missing = QuickLookThumbnailPurger.executeQLManageReset()
            guard !missing.reset, SafeProcess.invokedCommands.isEmpty,
                  missing.failureReason?.contains("未提供") == true else { return false }

            // ⑤ purge 的整体结论也必须带上这条失败并计入 errorCount
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_QuickLook_ResetFail"
            let qlDir = (testDir as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            try? "blob".data(using: .utf8)?.write(
                to: URL(fileURLWithPath: (qlDir as NSString).appendingPathComponent("index.sqlite")))

            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 1, output: "denied") }
            QuickLookThumbnailPurger.qlmanagePath = "/usr/bin/qlmanage"
            let item = QuickLookCacheItem(id: qlDir, kind: .thumbnailDatabase, title: "T",
                                          path: qlDir, size: 4, fileCount: 1, isSelected: true)
            let res = QuickLookThumbnailPurger.shared.purge(items: [item], resetSystemCache: true, journal: .none)
            guard res.purgedCount == 1, !res.systemCacheReset, res.systemResetFailure != nil,
                  res.errorCount > 0 else {
                print("    purge 把失败的 reset 计成了成功")
                return false
            }
            guard !res.summary.isEmpty else { return false }
            return true
        }

        // 9. 用户白名单与软链跳板：网关必须拦下，文件原地不动
        check("QuickLookThumbnail: 白名单与软链跳板路径必被拒") {
            let fm = FileManager.default
            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            let testDir = "/tmp/MacCleanTest_QuickLook_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer {
                wm.rules = savedRules
                try? fm.removeItem(atPath: testDir)
            }

            // ① 白名单里的缓存目录
            let protectedDir = (testDir as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            try? fm.createDirectory(atPath: protectedDir, withIntermediateDirectories: true)
            let protectedFile = (protectedDir as NSString).appendingPathComponent("index.sqlite")
            try? "protected".data(using: .utf8)?.write(to: URL(fileURLWithPath: protectedFile))
            let rule = wm.addPathRule(protectedDir, comment: "自检保护")

            let protectedItem = QuickLookCacheItem(id: protectedDir, kind: .thumbnailDatabase, title: "Protected",
                                                   path: protectedDir, size: 9, fileCount: 1, isSelected: true)
            let resWhite = QuickLookThumbnailPurger.shared.purge(items: [protectedItem], resetSystemCache: false, journal: .none)
            guard resWhite.purgedCount == 0 && resWhite.errorCount > 0 else {
                print("    白名单目录被清了：\(resWhite.purgedCount)")
                return false
            }
            guard fm.fileExists(atPath: protectedFile) else { return false }
            guard resWhite.outcome.rejected.contains(where: { $0.reason == .userWhitelisted }) else { return false }
            wm.removeRule(id: rule.id)

            // ② 软链跳板：缓存目录里放一条指向系统位置的符号链接
            let jumpDir = (testDir as NSString).appendingPathComponent("com.apple.quicklook.jump")
            try? fm.createDirectory(atPath: jumpDir, withIntermediateDirectories: true)
            let link = (jumpDir as NSString).appendingPathComponent("quicklook-link-to-system")
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: "/System/Library/QuickLook")
            let jumpItem = QuickLookCacheItem(id: jumpDir, kind: .uiServiceCache, title: "Jump",
                                              path: jumpDir, size: 100, fileCount: 1, isSelected: true)
            let resJump = QuickLookThumbnailPurger.shared.purge(items: [jumpItem], resetSystemCache: false, journal: .none)
            guard resJump.purgedCount == 0 && resJump.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: link), FileManager.default.fileExists(atPath: "/System/Library/QuickLook") else {
                return false
            }
            return true
        }

        // 10. 系统动态缓存的治理域：授权精确到三个条目、且只准删子项
        check("QuickLookThumbnail: 系统动态缓存治理域判据") {
            guard let domain = QuickLookThumbnailPurger.darwinCacheDomain() else {
                print("    取不到 Darwin 用户缓存目录")
                return false
            }
            guard domain.id == "quicklook.darwinCache", domain.minDepthBelowRoot == 2,
                  domain.allowedEntryNames == QuickLookThumbnailPurger.darwinCacheEntries else { return false }

            // ① 域根本身（深度 0）与直接子项（深度 1）都删不掉
            switch FileSystem.governanceVerdict(domain.root, domain: domain) {
            case .rejected(let r): guard r == .tooShallowForDomain else { return false }
            case .allowed: return false
            }
            let cacheDir = (domain.root as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            switch FileSystem.governanceVerdict(cacheDir, domain: domain) {
            case .rejected(let r): guard r == .tooShallowForDomain else { return false }
            case .allowed: return false
            }
            // ② 名单外的条目一律拒
            let outsider = (domain.root as NSString).appendingPathComponent("com.apple.Safari/whatever.db")
            switch FileSystem.governanceVerdict(outsider, domain: domain) {
            case .rejected(let r): guard r == .outsideDomain else { return false }
            case .allowed: return false
            }
            // ③ 名单内但已不存在 → missing（不得当作"已清理"）
            let gone = (cacheDir as NSString).appendingPathComponent("index.sqlite.missing")
            switch FileSystem.governanceVerdict(gone, domain: domain) {
            case .rejected(let r): guard r == .missing else { return false }
            case .allowed: return false
            }
            // ④ 域外路径挂不到域上
            guard QuickLookThumbnailPurger.domain(forPath: "/tmp/com.apple.QuickLook.thumbnailcache") == nil else { return false }
            return true
        }

        // 11. 「读不到」≠「可以删」：列不出子项时一项都不动
        check("QuickLookThumbnail: 缓存目录不可读时不得删除任何文件") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_QuickLook_Denied"
            let qlDir = (testDir as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
            let inside = (qlDir as NSString).appendingPathComponent("index.sqlite")
            try? "unreadable".data(using: .utf8)?.write(to: URL(fileURLWithPath: inside))
            defer {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: qlDir)
                try? fm.removeItem(atPath: testDir)
            }
            guard FileManager.default.createFile(atPath: inside, contents: Data("unreadable".utf8)) else { return false }
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: qlDir)
            guard FileSystem.isPermissionDenied(qlDir) else {
                print("    当前环境未能构造不可读目录，判据无法验证")
                return false
            }

            let item = QuickLookCacheItem(id: qlDir, kind: .thumbnailDatabase, title: "Denied",
                                          path: qlDir, size: 9, fileCount: 1, isSelected: true)
            let res = QuickLookThumbnailPurger.shared.purge(items: [item], resetSystemCache: false, journal: .none)
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: qlDir)
            guard res.purgedCount == 0 && res.errorCount > 0,
                  res.outcome.rejected.contains(where: { $0.reason == .needsPrivilege }),
                  fm.fileExists(atPath: inside) else { return false }
            return true
        }

        check("QuickLook 面板：求体积被权限掐断时不得默认勾选（复用 CLICache 的 readable 契约）") {
            // QuickLook 与 CLICache 共用 `CLICacheScanner.calculateDirectoryStats`，
            // 上两轮改了 stats 的返回；这条测的是 QuickLook 消费方有没有跟上——否则
            // 面板显示 3 MB 默认勾选、实际还有 500 MB 没读到，正是 G9 要拦的那一半。
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-ql-den-sel-\(UUID().uuidString)"
            let locked = root + "/sub_lock"
            try? fm.createDirectory(atPath: locked + "/deep", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: root + "/sub_ok", withIntermediateDirectories: true)
            fm.createFile(atPath: root + "/sub_ok/a.bin", contents: Data(repeating: 1, count: 8192))
            fm.createFile(atPath: locked + "/deep/b.bin", contents: Data(repeating: 2, count: 8192))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
                try? fm.removeItem(atPath: root)
            }
            FileSystem.resetDeniedAccess()
            let sum = QuickLookThumbnailPurger.shared.scan(customDirectories: [root])
            guard sum.items.count == 1, let it = sum.items.first else {
                print("      残缺的树仍要被列出来（不能整项从面板消失）：items=\(sum.items.count)")
                return false
            }
            guard !it.readable else {
                print("      item 模型上的 readable 字段没被填成 false——"
                      + "卡片全选按它过滤，不填就等于放行（v1.73.7 复审 P1-1）")
                return false
            }
            guard !it.isSelected else {
                print("      遍历被掐断却默认勾选（size=\(it.size) 只是\"至少这么多\"）")
                return false
            }
            // 反证：完整可读的树必须仍然默认勾选，别把这条契约焊死成"永不勾选"
            let ok = "/private/tmp/macclean-ql-ok-sel-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: ok, withIntermediateDirectories: true)
            fm.createFile(atPath: ok + "/x.bin", contents: Data(repeating: 3, count: 4096))
            defer { try? fm.removeItem(atPath: ok) }
            FileSystem.resetDeniedAccess()
            let clean = QuickLookThumbnailPurger.shared.scan(customDirectories: [ok])
            guard let ci = clean.items.first, ci.readable, ci.isSelected else {
                print("      完整可读的 QuickLook 目录被去默认勾选了")
                return false
            }
            FileSystem.resetDeniedAccess()
            return true
        }
    }
}
