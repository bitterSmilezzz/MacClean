import Foundation

// MARK: - 终端与命令行开发缓存治理深度自检 (v1.65.0)

extension Selftest {
    static func suiteCLICacheDeep() {
        print("--- [Suite] 终端与命令行开发缓存治理深度自检 (v1.65.0) ---")

        // 1. 工具类型与命令映射解析
        check("CLICache: 命令行开发工具分类与路径映射解析") {
            guard CLIToolKind.homebrew.typicalPaths.contains("~/Library/Caches/Homebrew") else { return false }
            guard CLIToolKind.npm.typicalPaths.contains("~/.npm/_cacache") else { return false }
            guard CLIToolKind.cocoapods.typicalPaths.contains("~/Library/Caches/CocoaPods") else { return false }
            guard CLIToolKind.cargo.typicalPaths.contains("~/.cargo/registry/cache") else { return false }
            guard CLIToolKind.pip.typicalPaths.contains("~/Library/Caches/pip") else { return false }
            guard CLIToolKind.gradle.typicalPaths.contains("~/.gradle/caches") else { return false }

            guard CLIToolKind.homebrew.commandSuggestion.contains("brew cleanup") else { return false }
            guard CLIToolKind.npm.commandSuggestion.contains("npm cache clean") else { return false }
            guard CLIToolKind.pip.commandSuggestion.contains("pip cache purge") else { return false }

            return true
        }

        // 2. 概要指标统计与已选容量精算
        check("CLICache: 概要指标统计与已选容量精算") {
            let item1 = CLICacheItem(id: "1", toolKind: .homebrew, title: "Homebrew", path: "/h", size: 1000, fileCount: 10, isSelected: true)
            let item2 = CLICacheItem(id: "2", toolKind: .npm, title: "npm", path: "/n", size: 2000, fileCount: 50, isSelected: true)
            let item3 = CLICacheItem(id: "3", toolKind: .pip, title: "pip", path: "/p", size: 500, fileCount: 5, isSelected: false)

            let summary = CLICacheSummary(
                items: [item1, item2, item3],
                totalSize: 3500,
                toolCount: 3
            )

            guard summary.totalSize == 3500 else { return false }
            guard summary.toolCount == 3 else { return false }
            guard summary.selectedSize == 3000 else { return false }
            guard summary.selectedCount == 2 else { return false }

            return true
        }

        // 3. 系统目录与关键配置文件安全保护防线
        check("CLICache: 系统目录与关键配置文件安全保护防线") {
            // 尝试对系统关键目录进行清理拦截测试
            let sysItem = CLICacheItem(
                id: "/System/Library/Caches", toolKind: .homebrew, title: "Sys",
                path: "/System/Library/Caches", size: 100, fileCount: 1, isSelected: true
            )
            let resSys = CLICacheScanner.shared.clean(items: [sysItem], toTrash: true)
            guard resSys.cleanedCount == 0 && resSys.errorCount > 0 else { return false }

            // 尝试对关键用户配置文件进行拦截测试（防误删 .npmrc / .zshrc）
            let npmrcItem = CLICacheItem(
                id: "/Users/test/.npmrc", toolKind: .npm, title: "npmrc",
                path: "/Users/test/.npmrc", size: 50, fileCount: 1, isSelected: true
            )
            let resNpmrc = CLICacheScanner.shared.clean(items: [npmrcItem], toTrash: true)
            guard resNpmrc.cleanedCount == 0 && resNpmrc.errorCount > 0 else { return false }

            let zshrcItem = CLICacheItem(
                id: "/Users/test/.zshrc", toolKind: .npm, title: "zshrc",
                path: "/Users/test/.zshrc", size: 50, fileCount: 1, isSelected: true
            )
            let resZshrc = CLICacheScanner.shared.clean(items: [zshrcItem], toTrash: true)
            guard resZshrc.cleanedCount == 0 && resZshrc.errorCount > 0 else { return false }

            return true
        }

        // 4. 模拟命令行缓存目录扫描与文件统计
        check("CLICache: 模拟命令行缓存目录扫描与文件统计") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Scan"
            let brewDir = (testDir as NSString).appendingPathComponent("Homebrew")
            let npmDir = (testDir as NSString).appendingPathComponent("npm/_cacache")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: brewDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: npmDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let file1 = (brewDir as NSString).appendingPathComponent("pkg1.bottle.tar.gz")
            let file2 = (npmDir as NSString).appendingPathComponent("index-v5")
            try? "brew_bottle_data_12345".data(using: .utf8)?.write(to: URL(fileURLWithPath: file1))
            try? "npm_cache_blob_abc".data(using: .utf8)?.write(to: URL(fileURLWithPath: file2))

            let summary = CLICacheScanner.shared.scan(customPaths: [
                .homebrew: [brewDir],
                .npm: [npmDir]
            ])

            guard summary.items.count == 2 else { return false }
            guard summary.totalSize > 0 else { return false }

            let brewItem = summary.items.first { $0.toolKind == .homebrew }
            guard let brewItem, brewItem.fileCount == 1, brewItem.size > 0 else { return false }

            return true
        }

        // 5. 模拟缓存安全清空与空间释放核验
        check("CLICache: 模拟缓存安全清空与空间释放核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Clean"
            let pipDir = (testDir as NSString).appendingPathComponent("pip")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: pipDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let wheel1 = (pipDir as NSString).appendingPathComponent("numpy.whl")
            let wheel2 = (pipDir as NSString).appendingPathComponent("pandas.whl")
            try? "numpy_wheel_cache".data(using: .utf8)?.write(to: URL(fileURLWithPath: wheel1))
            try? "pandas_wheel_cache".data(using: .utf8)?.write(to: URL(fileURLWithPath: wheel2))

            let stats = CLICacheScanner.calculateDirectoryStats(at: pipDir)
            guard stats.fileCount == 2 && stats.size > 0 else { return false }

            let item = CLICacheItem(
                id: pipDir, toolKind: .pip, title: "pip",
                path: pipDir, size: stats.size, fileCount: stats.fileCount, isSelected: true
            )

            // 执行安全清空
            let res = CLICacheScanner.shared.clean(items: [item], toTrash: false)
            guard res.cleanedCount == 1 && res.freedBytes == stats.size && res.errorCount == 0 else { return false }

            // 根目录应依然存在，但子文件已被安全清空
            guard fm.fileExists(atPath: pipDir) else { return false }
            let remaining = (try? fm.contentsOfDirectory(atPath: pipDir)) ?? []
            guard remaining.isEmpty else { return false }

            return true
        }

        // 6. 空目录与非法路径鲁棒性断言
        check("CLICache: 空目录与非法路径鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Empty"
            let emptyDir = (testDir as NSString).appendingPathComponent("empty_cargo")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: emptyDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 空目录扫描不应计入缓存结果
            let summary = CLICacheScanner.shared.scan(customPaths: [
                .cargo: [emptyDir],
                .gradle: ["/non_existent_gradle_path"]
            ])

            guard summary.items.isEmpty && summary.totalSize == 0 else { return false }

            return true
        }
    }
}
