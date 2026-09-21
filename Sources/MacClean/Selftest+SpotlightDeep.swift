import Foundation
import Darwin

/// 自检用的"完整可信"已安装清单。
///
/// 之所以要显式注入而不是用真机清单：`scan()` 判孤儿依赖 `AppInventory`，
/// 若不注入，这条用例的结论会随本机装了哪些 App、`/Applications` 可读与否而翻转。
private func selftestInventory() -> AppInventory.Snapshot {
    AppInventory.Snapshot(
        bundleIDs: ["com.apple.Safari"], bundlePrefixes: ["com.apple"],
        normalizedNames: [], executableNames: [], runningBundleIDs: [],
        appPaths: [], unreadableRoots: [])
}

// MARK: - Spotlight 废弃索引与搜索数据库深度重建深度自检 (v1.69.0 / v1.73.0 加固)

extension Selftest {
    static func suiteSpotlightDeep() {
        print("--- [Suite] Spotlight 废弃索引与搜索数据库深度重建深度自检 (v1.69.0) ---")

        // 1. 分类、图标与健康状态枚举判定
        check("Spotlight: 分类、图标与健康状态枚举判定") {
            guard SpotlightStoreKind.coreSpotlightIndex.icon == "magnifyingglass" else { return false }
            guard SpotlightStoreKind.spotlightCache.icon == "archivebox.fill" else { return false }
            guard SpotlightStoreKind.volumeIndex.icon == "internaldrive.fill" else { return false }
            guard SpotlightStoreKind.importerCache.icon == "puzzlepiece.extension.fill" else { return false }

            guard SpotlightIndexStatus.orphanAppResidue.isOrphanOrCorrupted == true else { return false }
            guard SpotlightIndexStatus.bloatedOrCorrupted.isOrphanOrCorrupted == true else { return false }
            guard SpotlightIndexStatus.activeHealthy.isOrphanOrCorrupted == false else { return false }
            guard SpotlightIndexStatus.systemProtected.isOrphanOrCorrupted == false else { return false }
            // v1.73.0：证据不足降级态既不算可删、也不算在用
            guard SpotlightIndexStatus.needsConfirmation.isOrphanOrCorrupted == false else { return false }
            guard SpotlightIndexStatus.allCases.contains(.needsConfirmation) else { return false }

            return true
        }

        // 2. 概要指标统计与已选释放容量精算
        check("Spotlight: 概要指标统计与已选释放容量精算") {
            let date = Date()
            let item1 = SpotlightStoreItem(
                id: "/p1", name: "com.uninstalled.app", path: "/p1",
                kind: .coreSpotlightIndex, status: .orphanAppResidue,
                size: 1024, fileCount: 5, modificationDate: date, isSelected: true
            )
            let item2 = SpotlightStoreItem(
                id: "/p2", name: "com.apple.Spotlight", path: "/p2",
                kind: .spotlightCache, status: .bloatedOrCorrupted,
                size: 2048, fileCount: 10, modificationDate: date, isSelected: true
            )
            let item3 = SpotlightStoreItem(
                id: "/p3", name: "com.apple.mobilesms", path: "/p3",
                kind: .coreSpotlightIndex, status: .activeHealthy,
                size: 4096, fileCount: 20, modificationDate: date, isSelected: false
            )

            let summary = SpotlightSummary(
                items: [item1, item2, item3],
                totalSize: 7168,
                orphanCount: 2,
                orphanSize: 3072,
                activeCount: 1
            )

            guard summary.totalSize == 7168 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.orphanSize == 3072 else { return false }
            guard summary.activeCount == 1 else { return false }
            guard summary.selectedSize == 3072 else { return false }
            guard summary.selectedCount == 2 else { return false }

            return true
        }

        // 3. 系统核心白名单与 SIP 防线越界拦截
        check("Spotlight: 系统核心白名单与 SIP 防线越界拦截") {
            // Apple 官方服务前缀保护
            let appleCore = SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.apple.mobilesms",
                path: "/dummy/com.apple.mobilesms",
                installedBIDs: []
            )
            guard appleCore.status == .activeHealthy else { return false }

            // 已安装第三方应用保护
            let installedApp = SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.tencent.xinwechat",
                path: "/dummy/com.tencent.xinwechat",
                installedBIDs: ["com.tencent.xinwechat"]
            )
            guard installedApp.status == .activeHealthy else { return false }

            // 未安装第三方应用判定为孤儿
            let orphanApp = SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.deleted.tool",
                path: "/dummy/com.deleted.tool",
                installedBIDs: ["com.tencent.xinwechat"]
            )
            guard orphanApp.status == .orphanAppResidue else { return false }

            // 系统根目录与核心索引拦截
            let rootItem = SpotlightStoreItem(
                id: "/.Spotlight-V100", name: "Root", path: "/.Spotlight-V100",
                kind: .volumeIndex, status: .systemProtected,
                size: 1000, fileCount: 1, modificationDate: Date(), isSelected: true
            )
            let resRoot = SpotlightScanner.shared.clean(items: [rootItem], toTrash: false, journal: .none)
            guard resRoot.cleanedCount == 0 && resRoot.errorCount > 0 else { return false }

            // 活动受保护项清理拦截
            let activeItem = SpotlightStoreItem(
                id: "/dummy/active", name: "Active", path: "/dummy/active",
                kind: .coreSpotlightIndex, status: .activeHealthy,
                size: 1000, fileCount: 1, modificationDate: Date(), isSelected: true
            )
            let resActive = SpotlightScanner.shared.clean(items: [activeItem], toTrash: false, journal: .none)
            guard resActive.cleanedCount == 0 && resActive.errorCount > 0 else { return false }

            return true
        }

        // 3b. 已安装清单不完整时绝不判孤儿（「读不到」≠「可以删」）
        check("Spotlight: 已安装清单不完整时降级为需确认且不默选") {
            let incomplete = AppInventory.Snapshot(
                bundleIDs: ["com.apple.Safari"], bundlePrefixes: ["com.apple"],
                normalizedNames: [], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: ["/Applications"])
            let verdict = SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.maybe.still.installed", path: "/dummy/x", inventory: incomplete)
            guard verdict.status == .needsConfirmation else { return false }

            let complete = AppInventory.Snapshot(
                bundleIDs: ["com.apple.Safari"], bundlePrefixes: ["com.apple"],
                normalizedNames: [], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: [])
            let confirmed = SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.maybe.still.installed", path: "/dummy/x", inventory: complete)
            guard confirmed.status == .orphanAppResidue else { return false }
            // 命中清单（含正在运行的 App）→ 在用
            guard SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.apple.Safari", path: "/dummy/x", inventory: incomplete).status == .activeHealthy
            else { return false }

            // Apple 核心服务前缀在任何清单状态下都受保护
            guard SpotlightScanner.evaluateCoreSpotlightEntry(
                name: "com.apple.mdworker", path: "/dummy/x", inventory: incomplete).status == .activeHealthy
            else { return false }
            return true
        }

        // 4. 模拟 CoreSpotlight 目录扫描与孤儿索引识别
        check("Spotlight: 模拟 CoreSpotlight 目录扫描与孤儿索引识别") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Spotlight_Scan"
            let coreSpotlightDir = (testDir as NSString).appendingPathComponent("CoreSpotlight")
            let cacheDir = (testDir as NSString).appendingPathComponent("Cache")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: coreSpotlightDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入已卸载应用索引目录
            let orphanAppDir = (coreSpotlightDir as NSString).appendingPathComponent("com.old.defunctapp")
            try? fm.createDirectory(atPath: orphanAppDir, withIntermediateDirectories: true)
            let f1 = (orphanAppDir as NSString).appendingPathComponent("index.db")
            try? "mock_index_binary_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))

            // 写入 Spotlight 缓存文件
            let cacheFile = (cacheDir as NSString).appendingPathComponent("search.cache")
            try? "mock_cache_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheFile))

            let summary = SpotlightScanner.shared.scan(
                customCoreSpotlightDir: coreSpotlightDir,
                customCacheDir: cacheDir,
                customVolumeDirs: [],
                inventory: AppInventory.Snapshot(
                    bundleIDs: ["com.tencent.xinwechat"], bundlePrefixes: ["com.tencent"],
                    normalizedNames: [], executableNames: [], runningBundleIDs: [],
                    appPaths: [], unreadableRoots: [])
            )

            guard summary.items.count == 2 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.totalSize > 0 else { return false }
            // 读得到就必须是"完整结果"，且不得残留任何"不完整"提示
            guard summary.isResultComplete, summary.incompletenessBanner == nil else { return false }

            let orphanItem = summary.items.first(where: { $0.name == "com.old.defunctapp" })
            guard let orphanItem, orphanItem.status == .orphanAppResidue else { return false }

            let cItem = summary.items.first(where: { $0.kind == .spotlightCache })
            guard let cItem, cItem.status == .bloatedOrCorrupted else { return false }

            return true
        }

        // 5. 模拟安全清理与文件移除核验
        check("Spotlight: 模拟安全清理与文件移除核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Spotlight_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let orphanDir = (testDir as NSString).appendingPathComponent("com.uninstalled.junk")
            try? fm.createDirectory(atPath: orphanDir, withIntermediateDirectories: true)
            let file = (orphanDir as NSString).appendingPathComponent("store.db")
            try? "mock_junk_bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: file))
            let fileSize = Int64((try? fm.attributesOfItem(atPath: file)[.size] as? UInt64) ?? 0)

            let item = SpotlightStoreItem(
                id: orphanDir,
                name: "com.uninstalled.junk",
                path: orphanDir,
                kind: .coreSpotlightIndex,
                status: .orphanAppResidue,
                size: fileSize,
                fileCount: 1,
                modificationDate: Date(),
                isSelected: true
            )

            guard fm.fileExists(atPath: orphanDir) else { return false }

            let res = SpotlightScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 1 else { return false }
            // 记账改为删除**前实测**（含块分配大小），不再沿用扫描时缓存的 item.size
            guard res.freedBytes >= fileSize else { return false }
            guard res.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: orphanDir) else { return false }

            return true
        }

        // 6. 空目录与非索引杂项文件鲁棒性断言
        check("Spotlight: 空目录与非索引杂项文件鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Spotlight_Filter"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入隐藏目录（以 . 开头）
            let hiddenDir = (testDir as NSString).appendingPathComponent(".DS_Store")
            try? "hidden".data(using: .utf8)?.write(to: URL(fileURLWithPath: hiddenDir))

            let summary = SpotlightScanner.shared.scan(
                customCoreSpotlightDir: testDir,
                customCacheDir: testDir + "/nonexistent",
                customVolumeDirs: [],
                inventory: AppInventory.Snapshot(
                    bundleIDs: ["com.apple.Safari"], bundlePrefixes: [], normalizedNames: [],
                    executableNames: [], runningBundleIDs: [], appPaths: [], unreadableRoots: [])
            )

            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0 else { return false }

            return true
        }

        // 7. mdutil 全部走 SafeProcess：命令与参数受控，失败绝不读成"已重建"
        check("Spotlight: mdutil 经 SafeProcess 执行且非 0 退出/超时/不可用不报成功") {
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            var seen: [(String, [String], TimeInterval)] = []

            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 0, output: "Simulation: I/O OK")
            }
            let ok = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: "/Volumes/USBStick")
            guard ok.success else { return false }
            guard seen.last?.0 == SpotlightScanner.mdutilPath,
                  seen.last?.1 == ["-E", "/Volumes/USBStick"] else {
                print("    ❌ 调的不是 mdutil -E：<\(String(describing: seen.last))>")
                return false
            }
            // 必须带超时（旧实现完全没有超时，子进程挂死即整轮挂死）
            guard (seen.last?.2 ?? 0) > 0 else { return false }

            // 非 0 退出码 → 失败，且把真实输出带回去
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "cannot modify volume")
            }
            let fail = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: "/")
            guard !fail.success,
                  fail.message.contains("退出码 1"),
                  fail.message.contains("cannot modify volume") else { return false }

            // 超时 → 失败，且不得说"已成功"
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            let timeoutRes = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: "/")
            guard !timeoutRes.success, timeoutRes.message.contains("超时") else { return false }

            // 进程根本没起来（runner 返回 nil）→ 失败
            SafeProcess.runner = { _, _, _ in nil }
            let noStart = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: "/")
            guard !noStart.success, noStart.message.contains("未能启动") else { return false }

            // 空卷路径直接拒绝，不拼出一条 `mdutil -E ""`
            SafeProcess.runner = { path, args, _ in
                print("    ❌ 空卷路径仍执行了命令：\(path) \(args)")
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            let emptyRes = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: "")
            guard !emptyRes.success else { return false }
            return true
        }

        // 8. 索引目录读不到 → 必须报"结果不完整"，条目降级为需确认且不默选
        check("Spotlight: 索引目录权限不足时报结果不完整而非干净") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Spotlight_Denied_\(UUID().uuidString)"
            let lockedCore = base + "/CoreSpotlight"
            let volumeRoot = base + "/Volumes/USBStick"
            let v100 = volumeRoot + "/.Spotlight-V100"
            defer {
                chmod(lockedCore, 0o755); chmod(v100, 0o755)
                try? fm.removeItem(atPath: base)
            }
            try? fm.createDirectory(atPath: lockedCore, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: v100, withIntermediateDirectories: true)
            try? "index".data(using: .utf8)?.write(to: URL(fileURLWithPath: v100 + "/StoreDatabase"))
            guard chmod(lockedCore, 0o000) == 0, chmod(v100, 0o000) == 0 else {
                return true   // 以 root 跑自检时造不出"读不到"，跳过而非误报
            }

            // ① CoreSpotlight 根读不到：0 项 + 一条问题记录，绝不能显示"没有残留"
            let denied = SpotlightScanner.shared.scan(
                customCoreSpotlightDir: lockedCore,
                customCacheDir: base + "/no-cache",
                customVolumeDirs: [],
                inventory: selftestInventory())
            guard denied.items.isEmpty else { return false }
            guard !denied.isResultComplete else {
                print("    ❌ 权限不足的目录被读成了「完整结果」")
                return false
            }
            guard denied.issues.first?.kind == .permissionDenied else { return false }
            guard denied.incompletenessBanner?.contains("不完整") == true else { return false }

            // ② 卷索引读不到：条目降级为 needsConfirmation 且**不默选**
            let vol = SpotlightScanner.shared.scan(
                customCoreSpotlightDir: base + "/no-core",
                customCacheDir: base + "/no-cache",
                customVolumeDirs: [volumeRoot],
                inventory: selftestInventory())
            guard let volItem = vol.items.first(where: { $0.kind == .volumeIndex }) else {
                print("    ❌ 读不到的卷索引条目被整条丢弃了")
                return false
            }
            guard volItem.status == .needsConfirmation else { return false }
            guard volItem.isSelected == false else { return false }
            guard volItem.note?.contains("不可读") == true else { return false }
            guard !vol.isResultComplete, vol.needsConfirmationCount == 1 else { return false }
            // 读不到的卷同样不得被隐式纳入重建范围
            guard vol.volumesSelectedForRebuild.isEmpty else { return false }
            return true
        }

        // 9. 白名单 / 硬排除在每个模块 policy 下必被拒，且文件仍在
        check("Spotlight: 白名单与硬排除路径在清理网关下必被拒绝") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Spotlight_WL_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: base) }
            let junkDir = base + "/com.whitelisted.app"
            try? fm.createDirectory(atPath: junkDir, withIntermediateDirectories: true)
            try? "x".data(using: .utf8)?.write(to: URL(fileURLWithPath: junkDir + "/index.db"))

            let wm = WhitelistManager.shared
            let saved = wm.rules
            defer { wm.rules = saved }
            wm.removeAllRules()
            wm.addPathRule(junkDir, comment: "自检保护")

            let item = SpotlightStoreItem(
                id: junkDir, name: "com.whitelisted.app", path: junkDir,
                kind: .coreSpotlightIndex, status: .orphanAppResidue,
                size: 100, fileCount: 1, modificationDate: Date(), isSelected: true)
            let res = SpotlightScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 0 && res.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: junkDir) else {
                print("    ❌ 白名单路径被删除了")
                return false
            }

            // 主目录内被硬排除的用户数据（G6）也必须拦住
            let mailish = CleanPaths.expand("~/Library/Mail/selftest-index.store")
            let mailItem = SpotlightStoreItem(
                id: mailish, name: "mail", path: mailish,
                kind: .coreSpotlightIndex, status: .bloatedOrCorrupted,
                size: 1, fileCount: 1, modificationDate: Date(), isSelected: true)
            let mailRes = SpotlightScanner.shared.clean(items: [mailItem], toTrash: false, journal: .none)
            guard mailRes.cleanedCount == 0 && mailRes.errorCount > 0 else { return false }
            return true
        }

        // 10. 删除失败不得计入 cleanedCount / freedBytes
        check("Spotlight: 删除失败不记账（cleanedCount 与 freedBytes 均为 0）") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Spotlight_Fail_\(UUID().uuidString)"
            let junkDir = base + "/com.failing.app"
            let inner = junkDir + "/index.db"
            try? fm.createDirectory(atPath: junkDir, withIntermediateDirectories: true)
            try? "payload".data(using: .utf8)?.write(to: URL(fileURLWithPath: inner))
            defer {
                lchflags(inner, 0)
                try? fm.removeItem(atPath: base)
            }
            guard lchflags(inner, UInt32(UF_IMMUTABLE)) == 0 else { return true }

            let item = SpotlightStoreItem(
                id: junkDir, name: "com.failing.app", path: junkDir,
                kind: .coreSpotlightIndex, status: .orphanAppResidue,
                // 扫描时缓存的"预计大小"故意写大：失败时一个字节都不许计
                size: 999_999, fileCount: 1, modificationDate: Date(), isSelected: true)
            let res = SpotlightScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 0 else {
                print("    ❌ 删除失败却计了 cleanedCount")
                return false
            }
            guard res.freedBytes == 0 else {
                print("    ❌ 删除失败却计了 freedBytes：\(res.freedBytes)")
                return false
            }
            guard res.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: junkDir) else { return false }
            return true
        }

        // 11. 卷索引重建范围：扫描后一个都不勾，且 never 走文件删除
        check("Spotlight: 卷索引重建只覆盖用户显式勾选的卷且不按文件删除") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Spotlight_Rebuild_\(UUID().uuidString)"
            let volA = base + "/VolA"
            try? fm.createDirectory(atPath: volA + "/.Spotlight-V100", withIntermediateDirectories: true)
            try? "x".data(using: .utf8)?.write(to: URL(fileURLWithPath: volA + "/.Spotlight-V100/db"))
            defer { try? fm.removeItem(atPath: base) }

            let summary = SpotlightScanner.shared.scan(
                customCoreSpotlightDir: base + "/none",
                customCacheDir: base + "/none",
                customVolumeDirs: [volA],
                inventory: selftestInventory())
            // ① 扫完就是零勾选——不存在"顺手把所有卷都重建"
            guard summary.volumesSelectedForRebuild.isEmpty else { return false }
            var item = summary.items.first(where: { $0.kind == .volumeIndex })
            guard let first = item, first.isSelectedForRebuild == false, first.isSelected == false else {
                return false
            }
            // ② 勾选后仍只包含这一个卷
            item?.isSelectedForRebuild = true
            let afterEdit = SpotlightSummary(
                items: [item!], totalSize: first.size, orphanCount: 0,
                orphanSize: 0, activeCount: 0, issues: [], needsConfirmationCount: 1)
            guard afterEdit.volumesSelectedForRebuild.map(\.path) == [first.path] else { return false }

            // ③ 卷索引条目走文件删除必须被拒（唯一受支持路径是 mdutil）
            let deletable = SpotlightStoreItem(
                id: first.id, name: first.name, path: first.path, kind: .volumeIndex,
                status: .bloatedOrCorrupted, size: first.size, fileCount: first.fileCount,
                modificationDate: first.modificationDate, isSelected: true)
            let res = SpotlightScanner.shared.clean(items: [deletable], toTrash: false, journal: .none)
            guard res.cleanedCount == 0 && res.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: volA + "/.Spotlight-V100") else {
                print("    ❌ 卷索引目录被按文件删除了")
                return false
            }
            return true
        }
    }
}
