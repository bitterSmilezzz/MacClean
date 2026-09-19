import Foundation

// MARK: - 启动项与后台守护全景治理深度自检 (v1.47.0)

extension Selftest {
    static func suiteStartupItemsDeep() {
        print("==> 运行启动项与后台服务治理深度自检 (v1.47.0)...")

        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacCleanStartupTest_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        let mockHome = tempDir.appendingPathComponent("UserHome")
        let userAgentsDir = mockHome.appendingPathComponent("Library/LaunchAgents")
        let globalAgentsDir = tempDir.appendingPathComponent("GlobalAgents")
        let globalDaemonsDir = tempDir.appendingPathComponent("GlobalDaemons")

        try? fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: globalAgentsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: globalDaemonsDir, withIntermediateDirectories: true)

        let manager = StartupItemManager()
        manager.overrideHomeDirectory = mockHome.path
        manager.overrideGlobalAgentsDir = globalAgentsDir.path
        manager.overrideGlobalDaemonsDir = globalDaemonsDir.path

        // 创建一个真实存在的 dummy 可执行文件
        let binDir = tempDir.appendingPathComponent("bin")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let validBin = binDir.appendingPathComponent("valid_tool")
        try? "echo hello".write(to: validBin, atomically: true, encoding: .utf8)

        // 1. Plist 属性解析与状态诊断
        check("启动项深度：Program 与 ProgramArguments 解析及正常激活判定") {
            let plistContent: [String: Any] = [
                "Label": "com.test.validagent",
                "Program": validBin.path,
                "RunAtLoad": true,
                "KeepAlive": true
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.test.validagent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.test.validagent.plist", location: .userAgent) else {
                return false
            }

            return item.label == "com.test.validagent" &&
                item.programPath == validBin.path &&
                item.runAtLoad == true &&
                item.keepAlive == true &&
                item.status == .valid &&
                item.isDisabled == false
        }

        // 2. 幽灵启动项识别（可执行文件缺失）
        check("启动项深度：目标可执行文件不存在判定为幽灵残留 (missingExecutable)") {
            let plistContent: [String: Any] = [
                "Label": "com.test.ghostagent",
                "ProgramArguments": ["/usr/local/bin/non_existent_ghost_binary", "--daemon"],
                "RunAtLoad": true
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.test.ghostagent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.test.ghostagent.plist", location: .userAgent) else {
                return false
            }

            return item.status == .missingExecutable &&
                item.status.isDangling == true &&
                item.programPath == "/usr/local/bin/non_existent_ghost_binary"
        }

        // 3. 宿主 App 已被卸载识别 (orphanedApp)
        check("启动项深度：宿主应用包已被卸载判定为 orphanedApp") {
            let plistContent: [String: Any] = [
                "Label": "com.uninstalled.app.helper",
                "ProgramArguments": ["/Applications/DeletedFakeApp.app/Contents/MacOS/Helper"],
                "RunAtLoad": true
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.uninstalled.app.helper.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.uninstalled.app.helper.plist", location: .userAgent) else {
                return false
            }

            return item.status == .orphanedApp &&
                item.status.isDangling == true
        }

        // 4. 系统受保护启动项
        check("启动项深度：com.apple 前缀判定为系统受保护 (systemProtected)") {
            let plistContent: [String: Any] = [
                "Label": "com.apple.coreservices.agent",
                "Program": "/usr/bin/true"
            ]
            let plistURL = globalAgentsDir.appendingPathComponent("com.apple.coreservices.agent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.apple.coreservices.agent.plist", location: .globalAgent) else {
                return false
            }

            return item.status == .systemProtected &&
                item.vendor == "Apple 原生/系统"
        }

        // 5. 禁用与恢复状态机 (toggleDisabled)
        check("启动项深度：通过重命名 .disabled 实现平滑停用与恢复") {
            let plistContent: [String: Any] = [
                "Label": "com.test.toggleagent",
                "Program": validBin.path
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.test.toggleagent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.test.toggleagent.plist", location: .userAgent) else {
                return false
            }

            // 1) 停用
            guard let disabledItem = try? manager.toggleDisabled(item: item) else {
                return false
            }
            guard disabledItem.isDisabled == true &&
                disabledItem.path.hasSuffix(".disabled") &&
                fm.fileExists(atPath: disabledItem.path) &&
                !fm.fileExists(atPath: plistURL.path) else {
                return false
            }

            // 2) 恢复
            guard let restoredItem = try? manager.toggleDisabled(item: disabledItem) else {
                return false
            }
            return restoredItem.isDisabled == false &&
                restoredItem.status == .valid &&
                !restoredItem.path.hasSuffix(".disabled") &&
                fm.fileExists(atPath: plistURL.path)
        }

        // 6. 全局扫描与幽灵残留排序
        check("启动项深度：scanAll 全局聚合与幽灵项优先排序") {
            let allItems = manager.scanAll()
            guard !allItems.isEmpty else { return false }

            // 幽灵项应排在前面
            if let first = allItems.first {
                return first.status.isDangling
            }
            return true
        }
    }
}
