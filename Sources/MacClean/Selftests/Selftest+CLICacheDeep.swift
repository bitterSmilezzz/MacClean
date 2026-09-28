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
            // 保护清单命中属"本模块判它不是可清理对象"，不再借用 G6 的 .hardExcluded 语义
            guard res.rejected.allSatisfy({ $0.reason == .notDeletable }) else { return false }
            guard res.rejected.allSatisfy({ $0.message.contains("拒绝删除") }) else { return false }
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
            guard res.rejected.first?.reason == .notDeletable,
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
            // 命中的是**本模块**的保护清单，不是 G6 硬排除：reason 必须是 .notDeletable
            guard res.rejected.allSatisfy({ $0.reason == .notDeletable }) else { return false }
            guard res.rejected.allSatisfy({ $0.message.contains("保护清单") }) else { return false }
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
            // 数据根命中的是**本模块**的数据根清单（`~/.cargo` 不在 G6 hardExclude 里），
            // 因此原因必须是 .notDeletable；.hardExcluded 只留给真 G6 位置
            guard reasons.contains(.userWhitelisted), reasons.contains(.notDeletable) else {
                print("    ❌ 白名单与数据根都要有拒绝原因: \(res.rejected.map { $0.reason })")
                return false
            }
            guard !reasons.contains(.hardExcluded) else {
                print("    ❌ 把模块数据根伪装成了 G6 硬排除: \(res.rejected.map { $0.reason })")
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

        // MARK: - 求体积契约：遍历被掐断时不得默认勾选（v1.73.7）

        check("CLICache 面板：遍历被权限掐断时不得默认勾选，且残缺项仍要列出来") {
            // 上两轮把 handler 补了、把 readable 加上了；这一条钉住**消费方真的用了它**。
            // 之前是 `if size > 0 { isSelected: true }`——残缺的 size 会被当完整事实
            // 直接把勾选框打给用户，那是本轮 G9「读不到 ≠ 干净」没做完的那一半。
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-cli-den-sel-\(UUID().uuidString)"
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
            let sum = CLICacheScanner.shared.scan(customPaths: [.pip: [root]])
            guard sum.items.count == 1, let it = sum.items.first else {
                print("      残缺的树还是应该被列出来（不能因权限缺失整项从面板消失）："
                      + "items=\(sum.items.count)")
                return false
            }
            guard !it.readable else {
                print("      item 模型上的 readable 字段没被填成 false——卡片全选按它过滤，"
                      + "不填就等于放行（v1.73.7 复审 P1-1）")
                return false
            }
            guard !it.isSelected else {
                print("      遍历被掐断却仍默认勾选（size=\(it.size) 是\"至少这么多\"，不是完整事实）")
                return false
            }
            // 反证：完整可读的缓存必须仍然默认勾选——否则等于把这条契约焊死成"永不勾选"，
            // 那是另一种坏（正常项被压成手动确认，用户体验回退）。
            let ok = "/private/tmp/macclean-cli-ok-sel-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: ok, withIntermediateDirectories: true)
            fm.createFile(atPath: ok + "/x.bin", contents: Data(repeating: 3, count: 4096))
            defer { try? fm.removeItem(atPath: ok) }
            FileSystem.resetDeniedAccess()
            let clean = CLICacheScanner.shared.scan(customPaths: [.npm: [ok]])
            guard let ci = clean.items.first, ci.readable, ci.isSelected else {
                print("      完整可读的缓存被去默认勾选了（正常项被压成手动确认）")
                return false
            }
            FileSystem.resetDeniedAccess()
            return true
        }

        check("CLICacheItem 的 isSelected 默认必须是 false（v1.73.7 复审 P1-3）") {
            // `isSelected: Bool = true` 的模型默认是本轮 lint 与行为自检都抓不到的第三条
            // 退路：调用方只要把 `isSelected:` 实参整个删掉，就无声回到"默认勾选"。
            // lint #2 只看字面 `isSelected:`，删掉字面就绕开；behavioral 只看 scan 输出，
            // 但 scan 里不显式传就等于走模型默认——两条都测不到。
            // 所以钉模型：`isSelected` 的默认必须是 false；要默认勾选必须显式写出。
            let bare = CLICacheItem(
                id: "/Users/example/.cache/whatever", toolKind: .npm, title: "npm",
                path: "/Users/example/.cache/whatever", size: 100, fileCount: 1)
            if bare.isSelected {
                print("      不传 `isSelected:` 时默认值仍是 true——契约可以整段消失")
                return false
            }
            if !bare.readable {
                print("      `readable` 的默认值被翻成了 false——那会让所有 fixture 都变成残缺")
                return false
            }
            return true
        }

        check("QuickLookCacheItem / SpotlightStoreItem 的 isSelected 默认也必须是 false（v1.73.7 二次复审 P2-4）") {
            // 上一版只钉了 CLICacheItem；QuickLook 与 Spotlight 的同族默认翻回 true
            // 时，lint #2 与 behavioral 都抓不到（scan 里传的是显式实参）。三个默认值
            // 一条 check 一起钉住。
            let ql = QuickLookCacheItem(
                id: "/Users/example/ql", kind: .thumbnailDatabase, title: "T",
                path: "/Users/example/ql", size: 100, fileCount: 1)
            if ql.isSelected {
                print("      QuickLookCacheItem 默认勾选没关掉")
                return false
            }
            let spot = SpotlightStoreItem(
                id: "/Users/example/spot", name: "s", path: "/Users/example/spot",
                kind: .spotlightCache, status: .bloatedOrCorrupted,
                size: 100, modificationDate: Date.distantPast)
            if spot.isSelected {
                print("      SpotlightStoreItem 默认勾选没关掉")
                return false
            }
            return true
        }

        check("CLICache 根完全读不到时不得静默：unreadablePaths 记账 + tool 落到 unrecognizedTools") {
            // v1.73.7 二次复审 P1-D：之前 `matched = true` 无条件短路，整棵读不到的树
            // 既不进 items（size=0 触发 if 前置门失败），又不进 unrecognizedTools
            //（matched=true 让它跳过），CLICacheSummary 又没有 issue 通道 → 三无状态。
            // 现在把这条路径记进 unreadablePaths 且不设 matched，让工具落到 unrecognized；
            // 卡片至少亮"这一路本轮没看清"的通道，不再是"这里 0 字节"的谎报。
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-cli-fail-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
                try? fm.removeItem(atPath: root)
            }
            FileSystem.resetDeniedAccess()
            let sum = CLICacheScanner.shared.scan(customPaths: [.pip: [root]])
            // scanner 内部会 normalizePath（macOS 上 /private/tmp/... 归一成 /tmp/...），
            // 断言两侧都要用归一化形式比较，否则永远对不上（v1.73.7 首测踩到过）。
            let normRoot = FileSystem.normalizePath(root)
            var bad: [String] = []
            if sum.items.contains(where: { $0.path == normRoot || $0.path == root }) {
                bad.append("整棵读不到还是被列成了正常项")
            }
            if !sum.unreadablePaths.contains(normRoot) {
                bad.append("unreadablePaths 没记这条路径：\(sum.unreadablePaths)")
            }
            if !sum.unrecognizedTools.contains(.pip) {
                bad.append("pip 没落到 unrecognizedTools——三无状态又回来了")
            }
            if !FileSystem.deniedAccessSnapshot().contains(normRoot) {
                bad.append("nil 分支的记账没生效：domain/errno 形状过不了 isPermissionError 过滤器")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // ── v1.73.13 求体积口径统一（R2-P2-11 收编）──────────────────────────
        // 四个模块各自的递归 walker 已删除，统一委托 `FileSystem.directoryStats`。
        // 下面两族断言钉住新口径：a/d 走 CLICache 元组，e 走稀疏/软链/隐藏/软链-mtime。

        check("CLICache: calculateDirectoryStats 与 FileSystem.directoryStats 同树逐项相等（口径收编 a/d）") {
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            FileSystem.resetDeniedAccess()
            let root = statsFixtureTree("cli")
            defer {
                removeStatsFixtureTree(root)
                FileSystem.resetDeniedAccess()
            }
            let fm = FileManager.default
            // 夹具样本断言先立住：稀疏文件是真稀疏（`?? 0` 兜底不能吞掉真实值）、
            // 软链/隐藏/000 子项都在场
            let sv = try? URL(fileURLWithPath: root + "/sparse.bin")
                .resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            guard sv?.fileSize == 1_048_576, (sv?.totalFileAllocatedSize ?? 65_536) < 65_536 else {
                print("      夹具不成立：sparse logical=\(sv?.fileSize ?? -1) "
                    + "alloc=\(sv?.totalFileAllocatedSize ?? -1)")
                return false
            }
            // locked_000 已是 mode 000：对它**内部**的条目 stat 会 EACCES，fileExists
            // 返回 false（fixture 自检时踩过）——所以这里只验目录本身在场；secret.bin
            // 的存在性由「fileCount == 4 而非 5」的对比（d 族断言）承担，builder 在
            // 上锁之前就已把文件建好。
            guard fm.fileExists(atPath: root + "/locked_000"),
                  fm.fileExists(atPath: root + "/.hidden"),
                  fm.fileExists(atPath: root + "/link-to-file"),
                  fm.fileExists(atPath: root + "/link-to-dir") else {
                print("      夹具不成立：软链/隐藏/000 子项缺失")
                return false
            }

            let tuple = CLICacheScanner.calculateDirectoryStats(at: root)
            let stats = FileSystem.directoryStats(at: root)
            guard tuple.size == stats.size, tuple.fileCount == stats.fileCount,
                  tuple.readable == stats.readable else {
                print("      薄委托与共享实现不等：tuple=(\(tuple.size),\(tuple.fileCount),\(tuple.readable)) "
                    + "stats=(\(stats.size),\(stats.fileCount),\(stats.readable))")
                return false
            }

            let totals = statsFixtureTotals(root: root)
            // d) mode-000 子目录在场 → readable 必须翻假（size 是"至少这么多"）
            guard tuple.readable == false else {
                print("      夹具含 mode-000 子目录却仍 readable=true")
                return false
            }
            // d) 000 内 secret.bin 不计入；软链/隐藏也不计 → 恰好 4 个普通文件
            guard tuple.fileCount == 4, tuple.fileCount == totals.fileCount else {
                print("      fileCount=\(tuple.fileCount) ≠ 4（000 内文件/隐藏文件/软链被计入了）")
                return false
            }
            guard tuple.size == totals.allocated else {
                print("      size=\(tuple.size) ≠ 可见文件实占合计 \(totals.allocated)")
                return false
            }
            // e) 稀疏文件按 allocated 计：远小于逻辑大小（ftruncate 拉出的洞不算体积）
            guard totals.logical > 1_000_000, tuple.size < totals.logical / 8 else {
                print("      size=\(tuple.size) 逼近/超过逻辑合计 \(totals.logical)——allocated 口径没生效")
                return false
            }
            // e) 反向样本：可见实数据（3×4KB + 8KB 稀疏实占）必须真的被算到，不许全变 0
            guard tuple.size >= 20_000 else {
                print("      size=\(tuple.size) 连可见实数据（≥20480）都没算到")
                return false
            }
            return true
        }

        check("CLICache: 软链不进 mtime 账（口径收编 e，变异①判红锚点）") {
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            FileSystem.resetDeniedAccess()
            let root = statsFixtureTree("cli-mtime")
            defer {
                removeStatsFixtureTree(root)
                FileSystem.resetDeniedAccess()
            }
            // link-to-file 的自身 mtime 被 lutimes 钉在 2030（夹具全树唯一的未来时刻）。
            // 夹具自证：resourceValues 读到的就是它自己（2030），不是跟随目标。
            let linkMtime = try? URL(fileURLWithPath: root + "/link-to-file")
                .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            guard linkMtime == statsFixtureFutureMtime else {
                print("      夹具不成立：link mtime=\(String(describing: linkMtime)) ≠ 2030 锚点")
                return false
            }
            // 软链一旦被计入 mtime 账（变异①摘掉软链 continue），newestModification
            // 就会跳到这个固定未来时刻——那正是"删一条软链却把它的 mtime 当树内最新"的错口径。
            let stats = FileSystem.directoryStats(at: root)
            guard let newest = stats.newestModification, newest < statsFixtureFutureMtime else {
                print("      newestModification=\(String(describing: stats.newestModification)) "
                    + "≥ 2030 锚点——软链被计入了 mtime 账")
                return false
            }
            return true
        }
    }
}

// MARK: - 统一求体积口径共享夹具（四个 Deep 套件共用，v1.73.13 R2-P2-11 收编）

/// 2030-01-01：`statsFixtureTree` 把 link-to-file 的**软链自身 mtime**用 lutimes 钉在这里。
/// 变异①（摘掉 `directoryStats` 的软链 continue）的确定性判红锚点：软链一旦计入 mtime 账，
/// newestModification 就会跳到这个固定未来时刻。
let statsFixtureFutureMtime = Date(timeIntervalSince1970: 1_893_456_000)

/// 造一棵「统一口径」夹具树（NSTemporaryDirectory 下）。返回夹具根；**调用方负责清理**
/// （用 `removeStatsFixtureTree`，先恢复 locked_000 权限再删）。
///
/// 构成（与断言族 a–e 一一对应）：
/// - 3 个普通文件：a.bin / nested/b.bin / nested/deeper/c.bin（各 4KB）
/// - 1 个稀疏文件 sparse.bin：8KB 实数据 + `ftruncate` 拉出 1MB 的洞
///   （逻辑 ~1MB、实占 8KB——与 `dd seek` 同一产物形态，只是不额外起进程）
/// - 软链两条：link-to-file（自身 mtime 钉在 2030）、link-to-dir
/// - 隐藏文件 .hidden（2KB，默认口径不计）
/// - mode-000 子目录 locked_000（内含 secret.bin，readable 契约用；root 下造不出，断言方自判）
func statsFixtureTree(_ tag: String) -> String {
    let root = FileSystem.normalizePath(
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("MacCleanStatsFixture/\(tag)-\(UUID().uuidString)"))
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return buildStatsFixtureTree(at: root)
}

/// 在**指定路径**上长出夹具树（PrinterDriver 套件要把夹具放到扫描根的条目位置上用）。
/// 前置条件：`root` 目录已存在。返回传入的 root（归一化后）。
func buildStatsFixtureTree(at root: String) -> String {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: root + "/nested/deeper", withIntermediateDirectories: true)
    fm.createFile(atPath: root + "/a.bin", contents: Data(repeating: 1, count: 4096))
    fm.createFile(atPath: root + "/nested/b.bin", contents: Data(repeating: 2, count: 4096))
    fm.createFile(atPath: root + "/nested/deeper/c.bin", contents: Data(repeating: 3, count: 4096))
    let sparse = root + "/sparse.bin"
    fm.createFile(atPath: sparse, contents: Data(repeating: 7, count: 8192))
    if let fh = FileHandle(forWritingAtPath: sparse) {
        _ = ftruncate(fh.fileDescriptor, 1_048_576)   // 中段成洞：逻辑 ~1MB，实占仍是 8KB
        try? fh.close()
    }
    try? fm.createSymbolicLink(atPath: root + "/link-to-file", withDestinationPath: root + "/a.bin")
    try? fm.createSymbolicLink(atPath: root + "/link-to-dir", withDestinationPath: root + "/nested")
    // lutimes 不跟随软链：改的是链接自身的 mtime（已实测，resourceValues 读到的也是它自己）
    var times = [timeval(tv_sec: 1_893_456_000, tv_usec: 0),
                 timeval(tv_sec: 1_893_456_000, tv_usec: 0)]
    _ = lutimes(root + "/link-to-file", &times)
    fm.createFile(atPath: root + "/.hidden", contents: Data(repeating: 4, count: 2048))
    let locked = root + "/locked_000"
    try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
    fm.createFile(atPath: locked + "/secret.bin", contents: Data(repeating: 5, count: 4096))
    try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    return FileSystem.normalizePath(root)
}

/// 删除 `statsFixtureTree` 造的夹具：先把 locked_000 的权限改回来再删整棵树。
func removeStatsFixtureTree(_ root: String) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                           ofItemAtPath: root + "/locked_000")
    try? FileManager.default.removeItem(atPath: root)
}

/// 夹具树「可见普通文件」的独立合计（逐文件 resourceValues 求和，不经过被测实现）。
/// 断言族 d/e 的样本锚——被测实现的 `?? 0` 兜底若全挂，这个和不会跟着变 0。
/// 软链（isRegularFile=false）与隐藏项不计；locked_000 内的文件因权限天然不在枚举里。
/// - Returns: (实占合计, 逻辑合计, 普通文件数)
func statsFixtureTotals(root: String) -> (allocated: Int64, logical: Int64, fileCount: Int) {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                  .totalFileAllocatedSizeKey]
    var allocated: Int64 = 0
    var logical: Int64 = 0
    var count = 0
    if let en = FileManager.default.enumerator(
        at: URL(fileURLWithPath: root, isDirectory: true),
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles],
        // 没有 errorHandler 时 Foundation 的语义是"第一个错误就停"——locked_000 会
        // 把整趟合计截断，这里的合计就错了。与被测口径一致：跳过、继续走。
        errorHandler: { _, _ in true }) {
        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isRegularFile == true {
                allocated += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                logical += Int64(v.fileSize ?? 0)
                count += 1
            }
        }
    }
    return (allocated, logical, count)
}
