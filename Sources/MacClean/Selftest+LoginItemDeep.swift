import Foundation

// MARK: - 已卸载应用登录项与自启残存治理深度自检 (v1.67.0)

extension Selftest {
    static func suiteLoginItemDeep() {
        print("--- [Suite] 已卸载应用登录项与自启残存治理深度自检 (v1.67.0) ---")

        // 1. 分类枚举与问题状态判定
        check("LoginItem: 分类枚举与问题状态判定") {
            guard LoginItemKind.launchAgent.icon == "person.crop.circle" else { return false }
            guard LoginItemKind.globalAgent.icon == "globe" else { return false }
            guard LoginItemKind.globalDaemon.icon == "gearshape.2" else { return false }

            guard LoginItemIssue.executableMissing.isOrphan == true else { return false }
            guard LoginItemIssue.validActive.isOrphan == false else { return false }

            return true
        }

        // 2. 概要指标统计与容量精算
        check("LoginItem: 概要指标统计与容量精算") {
            let item1 = LoginItemEntry(id: "1", name: "app1", path: "/p1", targetPath: "/t1", kind: .launchAgent, issue: .executableMissing, size: 500, isSelected: true)
            let item2 = LoginItemEntry(id: "2", name: "app2", path: "/p2", targetPath: "/t2", kind: .globalAgent, issue: .executableMissing, size: 800, isSelected: true)
            let item3 = LoginItemEntry(id: "3", name: "app3", path: "/p3", targetPath: "/t3", kind: .launchAgent, issue: .validActive, size: 300, isSelected: false)

            let summary = LoginItemSummary(
                items: [item1, item2, item3],
                orphanCount: 2,
                totalSize: 1600
            )

            guard summary.totalSize == 1600 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.selectedSize == 1300 else { return false }
            guard summary.selectedCount == 2 else { return false }

            return true
        }

        // 3. Apple 官方服务白名单保护防线
        check("LoginItem: Apple 官方服务白名单保护防线") {
            // Apple 官方服务不判定为孤儿
            let (target, isOrphan) = LoginItemCleaner.inspectPlist(at: "/non_existent", name: "com.apple.metadata.mdworker")
            guard target == nil && isOrphan == false else { return false }

            // 尝试清理 Apple 官方项应被拦截
            let appleItem = LoginItemEntry(
                id: "/tmp/com.apple.test.plist", name: "com.apple.test",
                path: "/tmp/com.apple.test.plist", targetPath: nil, kind: .launchAgent,
                issue: .validActive, size: 100, isSelected: true
            )
            let resApple = LoginItemCleaner.shared.clean(items: [appleItem], toTrash: true)
            guard resApple.cleanedCount == 0 && resApple.errorCount > 0 else { return false }

            // 尝试清理系统目录应被拦截
            let sysItem = LoginItemEntry(
                id: "/System/Library/LaunchDaemons/sys.plist", name: "sys",
                path: "/System/Library/LaunchDaemons/sys.plist", targetPath: nil, kind: .globalDaemon,
                issue: .validActive, size: 100, isSelected: true
            )
            let resSys = LoginItemCleaner.shared.clean(items: [sysItem], toTrash: true)
            guard resSys.cleanedCount == 0 && resSys.errorCount > 0 else { return false }

            return true
        }

        // 4. 模拟 LaunchAgent plist 解析与死链检测
        check("LoginItem: 模拟 LaunchAgent plist 解析与死链检测") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Scan"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let plistPath = (testDir as NSString).appendingPathComponent("com.example.ghosthelper.plist")
            let missingAppPath = "/Applications/NonExistentTestApp_12345.app/Contents/MacOS/helper"

            let plistContent: [String: Any] = [
                "Label": "com.example.ghosthelper",
                "Program": missingAppPath,
                "RunAtLoad": true
            ]
            let plistData = try? PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try? plistData?.write(to: URL(fileURLWithPath: plistPath))

            let summary = LoginItemCleaner.shared.scan(customDirectories: [
                .launchAgent: [testDir]
            ])

            guard summary.items.count == 1 else { return false }
            guard summary.orphanCount == 1 else { return false }

            let item = summary.items.first
            guard let item, item.issue == .executableMissing, item.targetPath == missingAppPath, item.isSelected == true else {
                return false
            }

            return true
        }

        // 5. 模拟死链启动项安全清理核验
        check("LoginItem: 模拟死链启动项安全清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let p1 = (testDir as NSString).appendingPathComponent("com.test.dangling.plist")
            try? "dummy_plist".data(using: .utf8)?.write(to: URL(fileURLWithPath: p1))

            let item = LoginItemEntry(
                id: p1, name: "com.test.dangling", path: p1,
                targetPath: "/NonExistent", kind: .launchAgent, issue: .executableMissing,
                size: 11, isSelected: true
            )

            let res = LoginItemCleaner.shared.clean(items: [item], toTrash: false)
            guard res.cleanedCount == 1 && res.freedBytes == 11 && res.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: p1) else { return false }

            return true
        }

        // 6. 空目录与非法路径鲁棒性断言
        check("LoginItem: 空目录与非法路径鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Empty"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let summary = LoginItemCleaner.shared.scan(customDirectories: [
                .launchAgent: [testDir, "/non_existent_folder_path"]
            ])

            guard summary.items.isEmpty && summary.orphanCount == 0 else { return false }

            return true
        }
    }
}
