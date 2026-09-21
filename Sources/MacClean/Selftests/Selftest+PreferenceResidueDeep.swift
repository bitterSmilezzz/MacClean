import Foundation
import SwiftUI
import ViewInspector

// 自检套件：已卸载应用深度偏好碎片智能反查 (v1.53.0)
extension Selftest {
    static func suitePreferenceResidueDeep() {
        check("偏好碎片逆向匹配：ByHost 硬件 UUID 与 .plist 后缀剥离 (extractBundleID)") {
            // 1. 标准 plist 后缀剥离
            let std = PreferenceResidueInspector.extractBundleID(from: "com.tencent.xinwechat.plist")
            guard std == "com.tencent.xinwechat" else { return false }

            // 2. ByHost 硬件 UUID 剥离 (标准 36 位 UUID)
            let byHost1 = PreferenceResidueInspector.extractBundleID(
                from: "cn.trae.app.ShipIt.CB35EDB2-7D1B-559A-8EA9-A4DC0191D25F.plist"
            )
            guard byHost1 == "cn.trae.app.ShipIt" else { return false }

            let byHost2 = PreferenceResidueInspector.extractBundleID(
                from: "com.google.Chrome.12345678-ABCD-EF01-2345-6789ABCDEF01.plist"
            )
            guard byHost2 == "com.google.Chrome" else { return false }

            // 3. 无后缀与特殊命名
            let raw = PreferenceResidueInspector.extractBundleID(from: "simple.test.app")
            guard raw == "simple.test.app" else { return false }

            return true
        }

        check("偏好碎片逆向匹配：应用名称智能推导与 ShipIt 组件识别 (deriveDisplayName)") {
            // 1. 知名应用映射
            guard PreferenceResidueInspector.deriveDisplayName(from: "com.tencent.xinwechat") == "微信 (WeChat)" else { return false }
            guard PreferenceResidueInspector.deriveDisplayName(from: "com.microsoft.vscode") == "Visual Studio Code" else { return false }
            guard PreferenceResidueInspector.deriveDisplayName(from: "com.google.chrome") == "Google Chrome" else { return false }

            // 2. ShipIt 自动更新组件推导
            let shipItName = PreferenceResidueInspector.deriveDisplayName(from: "cn.trae.app.ShipIt")
            guard shipItName.contains("Trae") && shipItName.contains("更新组件") else { return false }

            // 3. 通用格式化推导
            let generic = PreferenceResidueInspector.deriveDisplayName(from: "io.github.somedev.awesomeapp")
            guard generic.contains("Awesomeapp") || generic.contains("Somedev") else { return false }

            return true
        }

        check("偏好碎片安全保护：系统核心白名单与模型数据不变量") {
            // 1. 系统核心服务永不误伤
            let db = OrphanScanner.InstalledDatabase.build()
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.finder", db: db) == true else { return false }
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.Safari", db: db) == true else { return false }
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.dock", db: db) == true else { return false }

            // 2. 模型结构完整性
            let dummy = OrphanPreferenceItem(
                appName: "TestApp",
                bundleID: "com.test.dummy",
                fileName: "com.test.dummy.plist",
                path: "/tmp/com.test.dummy.plist",
                size: 2048,
                lastModified: Date(),
                ageDays: 14,
                location: .standard,
                isSelected: true
            )
            guard dummy.appName == "TestApp" && dummy.bundleID == "com.test.dummy" else { return false }
            guard dummy.ageDays == 14 && dummy.location == .standard && dummy.isSelected == true else { return false }
            guard PreferenceLocationKind.byHost.shortTitle == "ByHost" else { return false }
            guard PreferenceLocationKind.synced.icon == "arrow.triangle.2.circlepath" else { return false }

            return true
        }

        check("偏好碎片扫描引擎：合成环境下的孤儿偏好发现与 7 天缓冲期过滤") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_PrefTest_\(UUID().uuidString)"
            let prefDir = "\(tmpDir)/Library/Preferences"
            let byHostDir = "\(prefDir)/ByHost"

            try? fm.createDirectory(atPath: byHostDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(atPath: tmpDir)
            }

            // 1. 模拟最近修改的文件（< 7 天）：应当被缓冲期保护，不作为孤儿偏好报出
            let recentFile = "\(prefDir)/com.test.recentorphannotinstalled.plist"
            try? "recent data".write(toFile: recentFile, atomically: true, encoding: .utf8)
            let recentAttrs: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-2 * 86400)] // 2 天前
            try? fm.setAttributes(recentAttrs, ofItemAtPath: recentFile)

            // 2. 模拟陈旧孤儿偏好（> 7 天，例如 30 天前修改）：应当被正确识别
            let oldOrphanFile = "\(prefDir)/com.defunct.oldsoftware.plist"
            try? "old config".write(toFile: oldOrphanFile, atomically: true, encoding: .utf8)
            let oldAttrs: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-30 * 86400)] // 30 天前
            try? fm.setAttributes(oldAttrs, ofItemAtPath: oldOrphanFile)

            // 3. 模拟 ByHost 机器硬件级孤儿偏好（带 UUID，45 天前修改）：应当被识别且剥离 UUID
            let byHostOrphanFile = "\(byHostDir)/com.abandoned.game.12345678-1234-1234-1234-123456789abc.plist"
            try? "game host pref".write(toFile: byHostOrphanFile, atomically: true, encoding: .utf8)
            let byHostAttrs: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-45 * 86400)]
            try? fm.setAttributes(byHostAttrs, ofItemAtPath: byHostOrphanFile)

            // 4. 模拟系统偏好文件（即使陈旧也受白名单保护）
            let systemOldFile = "\(prefDir)/com.apple.ancientcore.plist"
            try? "apple system".write(toFile: systemOldFile, atomically: true, encoding: .utf8)
            try? fm.setAttributes(oldAttrs, ofItemAtPath: systemOldFile)

            // 执行反查扫描 (指定 7 天缓冲期)
            let inspector = PreferenceResidueInspector.shared
            let results = inspector.scanOrphanPreferences(home: tmpDir, minAgeDays: 7)

            // 验证 1：近期修改未满 7 天的文件未入选
            guard !results.contains(where: { $0.bundleID == "com.test.recentorphannotinstalled" }) else { return false }

            // 验证 2：系统 apple 前缀文件未入选
            guard !results.contains(where: { $0.bundleID.contains("com.apple.") }) else { return false }

            // 验证 3：陈旧孤儿偏好成功入选
            guard let oldFound = results.first(where: { $0.bundleID == "com.defunct.oldsoftware" }) else { return false }
            guard oldFound.location == .standard && oldFound.ageDays >= 29 else { return false }

            // 验证 4：ByHost 孤儿偏好成功入选且 UUID 准确剥离
            guard let byHostFound = results.first(where: { $0.bundleID == "com.abandoned.game" }) else { return false }
            guard byHostFound.location == .byHost && byHostFound.ageDays >= 44 else { return false }

            return true
        }

        check("偏好碎片安全清理：永久删除与结果计数核验") {
            let fm = FileManager.default
            let tmpDir = NSTemporaryDirectory() + "MacClean_PrefCleanTest_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(atPath: tmpDir)
            }

            let file1 = "\(tmpDir)/test1.plist"
            let file2 = "\(tmpDir)/test2.plist"
            try? "data1".write(toFile: file1, atomically: true, encoding: .utf8)
            try? "data2".write(toFile: file2, atomically: true, encoding: .utf8)

            let size1 = FileSystem.size(at: file1)
            let size2 = FileSystem.size(at: file2)

            let items = [
                OrphanPreferenceItem(
                    appName: "App1",
                    bundleID: "com.app1",
                    fileName: "test1.plist",
                    path: file1,
                    size: size1,
                    lastModified: nil,
                    ageDays: 10,
                    location: .standard
                ),
                OrphanPreferenceItem(
                    appName: "App2",
                    bundleID: "com.app2",
                    fileName: "test2.plist",
                    path: file2,
                    size: size2,
                    lastModified: nil,
                    ageDays: 12,
                    location: .byHost
                )
            ]

            let res = PreferenceResidueInspector.shared.cleanPreferences(items: items, toTrash: false)
            guard res.successCount == 2 && res.failCount == 0 else { return false }
            guard res.freedBytes == (size1 + size2) else { return false }
            guard !fm.fileExists(atPath: file1) && !fm.fileExists(atPath: file2) else { return false }

            return true
        }

        check("偏好碎片视图联动：UninstallerView 三段式 Tab 与偏好反查面板 ViewInspector 检验") {
            let app = AppState()
            app.uninstaller.currentTab = .preferences

            // 预置一项测试数据验证面板渲染
            app.uninstaller.preferenceItems = [
                OrphanPreferenceItem(
                    appName: "Test Orphan App",
                    bundleID: "com.test.orphanapp",
                    fileName: "com.test.orphanapp.plist",
                    path: "/tmp/com.test.orphanapp.plist",
                    size: 1024,
                    lastModified: Date(),
                    ageDays: 35,
                    location: .standard,
                    isSelected: false
                )
            ]

            let view = UninstallerView().environmentObject(app)
            guard let inspected = try? view.inspect() else { return false }

            // 1. 验证三段式模式选择器
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "uninstallerTabPicker")) != nil else {
                return false
            }

            // 2. 验证偏好面板根容器
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferencePanel")) != nil else {
                return false
            }

            // 3. 验证全选按钮与操作按钮
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferenceSelectAllButton")) != nil else {
                return false
            }
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferencePermanentButton")) != nil else {
                return false
            }
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferenceTrashButton")) != nil else {
                return false
            }

            return true
        }
    }
}
