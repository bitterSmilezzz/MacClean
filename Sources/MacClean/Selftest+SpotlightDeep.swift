import Foundation

// MARK: - Spotlight 废弃索引与搜索数据库深度重建深度自检 (v1.69.0)

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
            let resRoot = SpotlightScanner.shared.clean(items: [rootItem], toTrash: false)
            guard resRoot.cleanedCount == 0 && resRoot.errorCount > 0 else { return false }

            // 活动受保护项清理拦截
            let activeItem = SpotlightStoreItem(
                id: "/dummy/active", name: "Active", path: "/dummy/active",
                kind: .coreSpotlightIndex, status: .activeHealthy,
                size: 1000, fileCount: 1, modificationDate: Date(), isSelected: true
            )
            let resActive = SpotlightScanner.shared.clean(items: [activeItem], toTrash: false)
            guard resActive.cleanedCount == 0 && resActive.errorCount > 0 else { return false }

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
                customVolumeDirs: []
            )

            guard summary.items.count == 2 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.totalSize > 0 else { return false }

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

            let res = SpotlightScanner.shared.clean(items: [item], toTrash: false)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == fileSize else { return false }
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
                customVolumeDirs: []
            )

            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0 else { return false }

            return true
        }
    }
}
