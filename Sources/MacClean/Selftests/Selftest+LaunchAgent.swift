import Foundation

// 自检套件：系统后台定时维护计划器 (LaunchAgent & AutoClean)
extension Selftest {
    static func suiteLaunchAgent() {
        // MARK: - LaunchAgent Plist 生成与规范结构

        check("LaunchAgent Plist：每天定点调度生成正确的 StartCalendarInterval 与参数") {
            let manager = LaunchAgentManager()
            let xml = manager.generatePlistContent(
                frequency: .daily,
                dailyHour: 3,
                dailyMinute: 15,
                executablePath: "/Applications/MacClean.app/Contents/MacOS/MacClean"
            )

            guard xml.contains("<key>Label</key>") && xml.contains("<string>com.macclean.scheduler</string>") else { return false }
            guard xml.contains("<string>--autoclean</string>") else { return false }
            guard xml.contains("<string>/Applications/MacClean.app/Contents/MacOS/MacClean</string>") else { return false }
            guard xml.contains("<key>StartCalendarInterval</key>") else { return false }
            guard xml.contains("<key>Hour</key>") && xml.contains("<integer>3</integer>") else { return false }
            guard xml.contains("<key>Minute</key>") && xml.contains("<integer>15</integer>") else { return false }
            guard xml.contains("<key>ProcessType</key>") && xml.contains("<string>Background</string>") else { return false }
            guard xml.contains("<key>StandardOutPath</key>") && xml.contains("<key>StandardErrorPath</key>") else { return false }
            return true
        }

        check("LaunchAgent Plist：周期性与登录启动调度生成合规键值") {
            let manager = LaunchAgentManager()

            // 12 小时间隔 (43200 秒)
            let xml12h = manager.generatePlistContent(frequency: .every12Hours, executablePath: "/tmp/bin")
            guard xml12h.contains("<key>StartInterval</key>") && xml12h.contains("<integer>43200</integer>") else { return false }
            guard !xml12h.contains("StartCalendarInterval") else { return false }

            // 24 小时间隔 (86400 秒)
            let xml24h = manager.generatePlistContent(frequency: .every24Hours, executablePath: "/tmp/bin")
            guard xml24h.contains("<key>StartInterval</key>") && xml24h.contains("<integer>86400</integer>") else { return false }

            // 登录时启动 (RunAtLoad)
            let xmlLogin = manager.generatePlistContent(frequency: .login, executablePath: "/tmp/bin")
            guard xmlLogin.contains("<key>RunAtLoad</key>") && xmlLogin.contains("<true/>") else { return false }
            return true
        }

        check("LaunchAgent 配置：DiskMonitorConfig 新增调度字段的 JSON 序列化一致性") {
            var cfg = DiskMonitorConfig()
            cfg.launchAgentEnabled = true
            cfg.launchAgentFrequency = .every12Hours
            cfg.launchAgentDailyHour = 4
            cfg.launchAgentDailyMinute = 30
            cfg.autoHealOnLowSpace = true
            cfg.autoCleanSmartRecommended = true

            guard let data = try? JSONEncoder().encode(cfg) else { return false }
            guard let decoded = try? JSONDecoder().decode(DiskMonitorConfig.self, from: data) else { return false }

            return decoded.launchAgentEnabled == true
                && decoded.launchAgentFrequency == .every12Hours
                && decoded.launchAgentDailyHour == 4
                && decoded.launchAgentDailyMinute == 30
                && decoded.autoHealOnLowSpace == true
                && decoded.autoCleanSmartRecommended == true
        }

        // MARK: - LaunchAgentManager 隔离沙盒安装与卸载幂等性

        check("LaunchAgentManager：隔离目录安装、覆盖与卸载幂等性") {
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macclean_la_test_\(UUID().uuidString)")
            let laDir = tmpDir.appendingPathComponent("LaunchAgents")
            let logsDir = tmpDir.appendingPathComponent("Logs")
            let mockBin = tmpDir.appendingPathComponent("mock_macclean").path

            let manager = LaunchAgentManager()
            manager.overrideLaunchAgentsDirectory = laDir
            manager.overrideLogsDirectory = logsDir
            manager.overrideExecutablePath = mockBin
            manager.skipLaunchctlExecutionForTesting = true

            defer {
                try? FileManager.default.removeItem(at: tmpDir)
            }

            // 1. 初始未安装
            guard !manager.isInstalled() else { return false }

            // 2. 安装 Daily
            let installRes = manager.install(frequency: .daily, dailyHour: 2, dailyMinute: 0)
            guard installRes && manager.isInstalled() else { return false }

            let installedContent = (try? String(contentsOf: manager.plistURL, encoding: .utf8)) ?? ""
            guard installedContent.contains(mockBin) && installedContent.contains("<integer>2</integer>") else { return false }

            // 3. 覆盖安装 24h
            let reinstallRes = manager.install(frequency: .every24Hours)
            guard reinstallRes && manager.isInstalled() else { return false }
            let reinstalledContent = (try? String(contentsOf: manager.plistURL, encoding: .utf8)) ?? ""
            guard reinstalledContent.contains("86400") && !reinstalledContent.contains("StartCalendarInterval") else { return false }

            // 4. 卸载
            let uninstallRes = manager.uninstall()
            guard uninstallRes && !manager.isInstalled() else { return false }

            // 5. 二次卸载（幂等，不崩溃不报错）
            guard manager.uninstall() else { return false }

            return true
        }

        // MARK: - AutoClean 无人值守安全过滤与低空间自愈决策

        check("AutoClean 决策引擎：白名单、在用状态与推荐等级门槛") {
            let whitelist = WhitelistManager.shared
            let testDir = NSTemporaryDirectory().appending("autoclean_test_\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(atPath: testDir) }
            try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

            let safePath = testDir.appending("/safe.cache")
            let inUsePath = testDir.appending("/inuse.cache")
            let recentPath = testDir.appending("/recent.cache")
            let whitelistedPath = testDir.appending("/whitelisted.cache")

            // 1. 安全且长期未用项
            let itemSafe = CleanItem(
                name: "safe",
                path: safePath,
                size: 10_000,
                nature: .losslessCache,
                category: .userCaches,
                use: UseState(ownerIsRunning: false, lastUsed: Date().addingTimeInterval(-86400 * 95), level: .dormant)
            )

            // 2. 所属 App 正在运行项
            let itemInUse = CleanItem(
                name: "inuse",
                path: inUsePath,
                size: 20_000,
                nature: .losslessCache,
                category: .userCaches,
                use: UseState(ownerIsRunning: true, lastUsed: Date().addingTimeInterval(-86400 * 95), level: .dormant)
            )

            // 3. 近期使用过的项
            let itemRecent = CleanItem(
                name: "recent",
                path: recentPath,
                size: 15_000,
                nature: .losslessCache,
                category: .userCaches,
                use: UseState(ownerIsRunning: false, lastUsed: Date().addingTimeInterval(-100), level: .active)
            )

            // 4. 白名单项
            let rule = whitelist.addPathRule(whitelistedPath)
            defer { whitelist.removeRule(id: rule.id) }
            let itemWhitelisted = CleanItem(
                name: "whitelisted",
                path: whitelistedPath,
                size: 30_000,
                nature: .losslessCache,
                category: .userCaches,
                use: UseState(ownerIsRunning: false, lastUsed: Date().addingTimeInterval(-86400 * 95), level: .dormant)
            )

            // 常规模式过滤
            let regularCandidates = AutoCleanService.filterEligibleCandidates(
                items: [itemSafe, itemInUse, itemRecent, itemWhitelisted],
                whitelist: whitelist,
                isLowSpaceHeal: false
            )

            guard regularCandidates.count == 1 && regularCandidates.first?.id == itemSafe.id else {
                return false
            }

            // 低空间自愈模式下，同样绝不放行正在运行、近期使用或白名单项
            let healCandidates = AutoCleanService.filterEligibleCandidates(
                items: [itemSafe, itemInUse, itemRecent, itemWhitelisted],
                whitelist: whitelist,
                isLowSpaceHeal: true
            )

            return healCandidates.count == 1 && healCandidates.first?.id == itemSafe.id
        }

        check("AutoClean 互斥保护与执行链路：无头自测模拟运行正常退出") {
            let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macclean_lock_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            AutoCleanService.lockFileURLOverride = tmpDir.appendingPathComponent("autoclean.lock")
            defer { AutoCleanService.lockFileURLOverride = nil }

            // 模拟高空间（常规模式）执行
            AutoCleanService.mockAvailableBytes = 100_000_000_000 // 100 GB > 15 GB
            defer { AutoCleanService.mockAvailableBytes = nil }

            let code = AutoCleanService.run()
            return code == 0
        }
    }
}
