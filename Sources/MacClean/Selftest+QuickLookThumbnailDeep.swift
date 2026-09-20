import Foundation

// MARK: - 访达快速查看缩略图缓存释放深度自检 (v1.66.0)

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
            let resSys = QuickLookThumbnailPurger.shared.purge(items: [sysItem], resetSystemCache: false)
            guard resSys.purgedCount == 0 && resSys.errorCount > 0 else { return false }

            // 非 QuickLook 路径拦截
            let nonQLItem = QuickLookCacheItem(
                id: "/tmp/com.apple.Safari.cache", kind: .thumbnailDatabase, title: "Safari",
                path: "/tmp/com.apple.Safari.cache", size: 100, fileCount: 1, isSelected: true
            )
            let resNonQL = QuickLookThumbnailPurger.shared.purge(items: [nonQLItem], resetSystemCache: false)
            guard resNonQL.purgedCount == 0 && resNonQL.errorCount > 0 else { return false }

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

        // 5. 模拟缓存安全清空与重建逻辑核验
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

            let item = QuickLookCacheItem(
                id: qlDir, kind: .thumbnailDatabase, title: "Test",
                path: qlDir, size: stats.size, fileCount: stats.fileCount, isSelected: true
            )

            // 执行清空（不触发系统全局 reset，只测文件安全移除）
            let res = QuickLookThumbnailPurger.shared.purge(items: [item], resetSystemCache: false)
            guard res.purgedCount == 1 && res.freedBytes == stats.size && res.errorCount == 0 else { return false }

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

            return true
        }
    }
}
