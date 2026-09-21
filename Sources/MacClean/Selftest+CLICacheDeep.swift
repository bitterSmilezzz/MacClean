import Foundation

// MARK: - 终端与命令行开发缓存治理深度自检 (v1.65.0 · v1.73.0 加固)

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

            // 每条内置典型路径都必须是"精确缓存子路径"，不带工具数据根兜底
            for tool in CLIToolKind.allCases {
                for path in tool.typicalPaths {
                    guard !CLICacheScanner.isToolDataRoot(path) else {
                        print("    ❌ \(tool.rawValue) 的典型路径里混了工具数据根 \(path)")
                        return false
                    }
                    guard CLICacheScanner.isPreciseCachePath(
                        NSString(string: path).expandingTildeInPath) else {
                        print("    ❌ \(path) 不是精确缓存子路径")
                        return false
                    }
                }
            }
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
                toolCount: 3,
                unrecognizedTools: [.cargo, .gradle]
            )

            guard summary.totalSize == 3500 else { return false }
            guard summary.toolCount == 3 else { return false }
            guard summary.selectedSize == 3000 else { return false }
            guard summary.selectedCount == 2 else { return false }
            guard summary.unrecognizedTools.count == 2 else { return false }
            return true
        }

        // 3. 系统目录与关键配置文件安全保护防线
        check("CLICache: 系统目录与关键配置文件安全保护防线") {
            let sysItem = CLICacheItem(
                id: "/System/Library/Caches", toolKind: .homebrew, title: "Sys",
                path: "/System/Library/Caches", size: 100, fileCount: 1, isSelected: true
            )
            let resSys = CLICacheScanner.shared.clean(items: [sysItem], toTrash: true, journal: .none)
            guard resSys.cleanedCount == 0 && resSys.errorCount > 0 else { return false }
            guard resSys.rejected.first?.reason == .outsideDomain else { return false }

            // 关键配置文件保护：父路径干净、子路径带关键词 → 也必须被拒（旧版漏校验）
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Protect"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir + "/caches", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            for name in [".npmrc", "config.toml", "settings.json"] {
                try? "secret".data(using: .utf8)?.write(to: URL(fileURLWithPath: testDir + "/caches/" + name))
            }
            let item = CLICacheItem(id: testDir + "/caches", toolKind: .npm, title: "npm",
                                    path: testDir + "/caches", size: 18, fileCount: 3, isSelected: true)
            let res = CLICacheScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 0 && res.errorCount == 3 else {
                print("    ❌ 保护清单未按 childPath 生效: cleaned=\(res.cleanedCount) errors=\(res.errorCount)")
                return false
            }
            guard res.rejected.allSatisfy({ $0.reason == .hardExcluded }) else { return false }
            for name in [".npmrc", "config.toml", "settings.json"] {
                guard fm.fileExists(atPath: testDir + "/caches/" + name) else { return false }
            }
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
            guard summary.unrecognizedTools.isEmpty else { return false }

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
            let d1 = "numpy_wheel_cache".data(using: .utf8)!.count
            let d2 = "pandas_wheel_cache".data(using: .utf8)!.count
            try? "numpy_wheel_cache".data(using: .utf8)?.write(to: URL(fileURLWithPath: wheel1))
            try? "pandas_wheel_cache".data(using: .utf8)?.write(to: URL(fileURLWithPath: wheel2))

            let stats = CLICacheScanner.calculateDirectoryStats(at: pipDir)
            guard stats.fileCount == 2 && stats.size > 0 else { return false }

            let item = CLICacheItem(
                id: pipDir, toolKind: .pip, title: "pip",
                path: pipDir, size: stats.size, fileCount: stats.fileCount, isSelected: true
            )

            // 执行安全清空：逐个子项过网关，计数是**子项数**而不是"工具数"
            let res = CLICacheScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 2 && res.errorCount == 0 else {
                print("    ❌ cleaned=\(res.cleanedCount) errors=\(res.errorCount)")
                return false
            }
            guard res.freedBytes == Int64(d1 + d2) else {
                print("    ❌ 释放量应为删除前实测 \(d1 + d2)，实际 \(res.freedBytes)")
                return false
            }
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
            // 不存在的路径 → 报"位置未识别"，而不是退化成删父目录
            guard summary.unrecognizedTools.contains(.gradle) else { return false }
            return true
        }

        // ── v1.73.0 安全加固 ──

        // 7. `~/.npm` 兜底根 P0：只认精确缓存子路径，找不到就报未识别，绝不整体清空
        check("CLICache: npm 兜底根已删除且工具数据目录永不被清空") {
            // ① 兜底根从列表里彻底消失
            guard !CLIToolKind.npm.typicalPaths.contains("~/.npm") else { return false }
            guard CLIToolKind.npm.toolDataRoots.contains("~/.npm") else { return false }
            guard CLICacheScanner.isToolDataRoot("~/.npm"),
                  CLICacheScanner.isToolDataRoot("/tmp/x/.cargo"),
                  !CLICacheScanner.isToolDataRoot("~/.npm/_cacache") else { return false }
            guard !CLICacheScanner.isPreciseCachePath("~/.npm") else { return false }

            // ② 复刻真机形态：数据根下有 _logs/_npx/_prebuilds 与一个文件，**没有** _cacache
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_NpmRoot"
            try? fm.removeItem(atPath: testDir)
            let npmRoot = testDir + "/.npm"
            for sub in ["_logs", "_npx", "_prebuilds"] {
                try? fm.createDirectory(atPath: npmRoot + "/" + sub, withIntermediateDirectories: true)
                try? "payload".data(using: .utf8)?
                    .write(to: URL(fileURLWithPath: npmRoot + "/" + sub + "/x.log"))
            }
            try? "//registry=\n".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: npmRoot + "/.npmrc-userconfig"))
            defer { try? fm.removeItem(atPath: testDir) }

            let allBefore = (try? fm.contentsOfDirectory(atPath: npmRoot)) ?? []
            guard allBefore.count == 4 else { return false }

            // 扫描：命中数据根 → 什么都不列，且报"该工具缓存位置未识别"
            let summary = CLICacheScanner.shared.scan(customPaths: [.npm: [npmRoot]])
            guard summary.items.isEmpty, summary.totalSize == 0 else { return false }
            guard summary.unrecognizedTools.contains(.npm) else {
                print("    ❌ 未把 npm 报成位置未识别")
                return false
            }

            // 即便调用方硬造一条"缓存项"指向数据根，也必须整项拒绝、一个子项都不删
            let forced = CLICacheItem(id: npmRoot, toolKind: .npm, title: "npm 缓存",
                                      path: npmRoot, size: 1_000_000, fileCount: 4, isSelected: true)
            let res = CLICacheScanner.shared.clean(items: [forced], toTrash: false, journal: .none)
            guard res.cleanedCount == 0, res.freedBytes == 0 else { return false }
            guard res.rejected.first?.reason == .hardExcluded,
                  res.rejected.first?.message.contains("数据目录") == true else { return false }
            let after = Set((try? fm.contentsOfDirectory(atPath: npmRoot)) ?? [])
            guard after == Set(allBefore) else {
                print("    ❌ 工具数据目录被清空了：\(allBefore) → \(after)")
                return false
            }
            return true
        }

        // 8. 保护清单校验对象是 childPath（父路径干净也拦得住）
        check("CLICache: 保护关键词按子项路径校验，父路径不含关键词同样拒绝") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Child"
            let cacheRoot = testDir + "/precise_cache"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: cacheRoot + "/_cacache", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            try? "blob".data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheRoot + "/_cacache/index"))
            try? "[registry]".data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheRoot + "/.npmrc"))
            try? "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheRoot + "/settings.json"))
            try? "tar".data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheRoot + "/pkg.tar.gz"))

            // 父路径本身不含任何保护关键词
            guard CLICacheScanner.protectedKeywordHit(in: cacheRoot) == nil else { return false }
            guard CLICacheScanner.protectedKeywordHit(in: cacheRoot + "/.npmrc") != nil,
                  CLICacheScanner.protectedKeywordHit(in: cacheRoot + "/settings.json") != nil else { return false }

            let item = CLICacheItem(id: cacheRoot, toolKind: .npm, title: "npm",
                                    path: cacheRoot, size: 100, fileCount: 4, isSelected: true)
            let res = CLICacheScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 2, res.errorCount == 2 else {
                print("    ❌ cleaned=\(res.cleanedCount) errors=\(res.errorCount)")
                return false
            }
            guard fm.fileExists(atPath: cacheRoot + "/.npmrc"),
                  fm.fileExists(atPath: cacheRoot + "/settings.json") else { return false }
            guard !fm.fileExists(atPath: cacheRoot + "/pkg.tar.gz"),
                  !fm.fileExists(atPath: cacheRoot + "/_cacache") else { return false }
            guard res.rejected.allSatisfy({ $0.reason == .hardExcluded }) else { return false }
            return true
        }

        // 9. 白名单 / 系统位置 / 数据根：参数化必拒，且文件全部完好
        check("CLICache: 白名单与系统位置在缓存模块判据下必被拒且文件仍在") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir + "/protected_cache", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            try? "keep".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: testDir + "/protected_cache/blob.bin"))
            try? "keep2".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: testDir + "/protected_cache/other.bin"))

            let wm = WhitelistManager.shared
            wm.removeAllRules()
            defer { wm.removeAllRules() }
            wm.addPathRule(testDir + "/protected_cache", comment: "命令行缓存网关自检")

            let roots: [(CLIToolKind, String)] = [
                (.homebrew, testDir + "/protected_cache"),          // 用户白名单
                (.npm, "/System/Library/Caches"),                    // G8 系统硬保护
                (.cargo, NSString(string: "~/.cargo").expandingTildeInPath),  // 工具数据根
            ]
            let items = roots.map { tool, path in
                CLICacheItem(id: path, toolKind: tool, title: tool.rawValue,
                             path: path, size: 4, fileCount: 2, isSelected: true)
            }
            let res = CLICacheScanner.shared.clean(items: items, toTrash: false, journal: .none)
            guard res.errorCount > 0 && res.cleanedCount == 0 && res.freedBytes == 0 else {
                print("    ❌ cleaned=\(res.cleanedCount) freed=\(res.freedBytes) errors=\(res.errorCount)")
                return false
            }
            let reasons = Set(res.rejected.map { $0.reason })
            guard reasons.contains(.userWhitelisted), reasons.contains(.hardExcluded) else {
                print("    ❌ 白名单与硬排除都要有拒绝原因: \(res.rejected.map { $0.reason })")
                return false
            }
            guard res.rejected.contains(where: { $0.path.hasPrefix("/System") }) else { return false }
            guard fm.fileExists(atPath: testDir + "/protected_cache/blob.bin"),
                  fm.fileExists(atPath: testDir + "/protected_cache/other.bin") else { return false }
            return true
        }

        // 10. 软链跳板：缓存目录里指向系统位置的软链必被拒，真身完好
        check("CLICache: 缓存目录软链跳板被网关拒绝且真身未被删除") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Link"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir + "/caches", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: testDir + "/outside", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let victim = testDir + "/outside/important.bin"
            try? "user data".data(using: .utf8)?.write(to: URL(fileURLWithPath: victim))
            try? fm.createSymbolicLink(atPath: testDir + "/caches/escape", withDestinationPath: victim)

            let item = CLICacheItem(id: testDir + "/caches", toolKind: .yarn, title: "Yarn",
                                    path: testDir + "/caches", size: 9, fileCount: 1, isSelected: true)
            let res = CLICacheScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 0, res.errorCount == 1 else { return false }
            guard res.rejected.first?.reason == .symlinkJump else {
                print("    ❌ 未按软链跳板拒绝: \(res.rejected.map { $0.reason })")
                return false
            }
            guard fm.fileExists(atPath: victim) else { return false }
            return true
        }

        // 11. 释放量与清理数只认删除前实测与真实结果
        check("CLICache: 释放量取删除前实测，虚报的 item.size 不参与记账") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_Account"
            let root = testDir + "/brew"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            try? "12345".data(using: .utf8)?.write(to: URL(fileURLWithPath: root + "/a.bottle"))
            let gone = root + "/b.bottle"
            try? "1234567890".data(using: .utf8)?.write(to: URL(fileURLWithPath: gone))

            // 扫描后就消失的项：不得按扫描时的 size 记账，也不得算成已清理
            let item = CLICacheItem(id: root, toolKind: .homebrew, title: "Homebrew",
                                    path: root, size: 5_000_000, fileCount: 2, isSelected: true)
            try? fm.removeItem(atPath: gone)
            let res = CLICacheScanner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == 5 else {
                print("    ❌ 释放量应为实测 5 字节，实际 \(res.freedBytes)")
                return false
            }
            guard !fm.fileExists(atPath: root + "/a.bottle") else { return false }
            guard fm.fileExists(atPath: root) else {
                print("    ❌ 缓存根被删了，工具目录结构假设被破坏")
                return false
            }
            return true
        }

        // 12. 本模块只给建议命令、绝不代跑 CLI（SafeProcess 调用点保持为零）
        check("CLICache: 扫描与清理全程不执行任何外部命令") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_CLICache_NoExec"
            let root = testDir + "/pip"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            try? "wheel".data(using: .utf8)?.write(to: URL(fileURLWithPath: root + "/x.whl"))

            SafeProcess.resetInvokedCommands()
            _ = CLICacheScanner.shared.scan(customPaths: [.pip: [root]])
            _ = CLICacheScanner.shared.clean(
                items: [CLICacheItem(id: root, toolKind: .pip, title: "pip", path: root,
                                     size: 5, fileCount: 1, isSelected: true)],
                toTrash: false, journal: .none)
            let invoked = SafeProcess.invokedCommands
            SafeProcess.resetInvokedCommands()
            guard invoked.isEmpty else {
                print("    ❌ 缓存治理自己起了进程: \(invoked.map { $0.path })")
                return false
            }
            // 建议命令只做展示与复制，且不得是 rm -rf 数据根
            guard CLIToolKind.npm.commandSuggestion.contains("npm cache clean") else { return false }
            return true
        }
    }
}
