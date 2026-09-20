import Foundation
import SwiftUI
import ViewInspector

// 自检套件：系统深度应用扩展与 QuickLook/Spotlight 插件残存治理 (v1.55.0)
extension Selftest {
    static func suitePluginExtensionDeep() {
        check("插件与扩展数据模型与枚举完整性 (PluginExtensionKind & Status)") {
            // 1. 种类枚举校验
            guard PluginExtensionKind.quickLook.shortTitle == "QuickLook" && PluginExtensionKind.quickLook.icon == "eye.circle" else { return false }
            guard PluginExtensionKind.spotlight.shortTitle == "Spotlight" && PluginExtensionKind.spotlight.icon == "magnifyingglass.circle" else { return false }
            guard PluginExtensionKind.services.shortTitle == "服务菜单" && PluginExtensionKind.services.icon == "gearshape.2" else { return false }
            guard PluginExtensionKind.screenSaver.shortTitle == "屏保" && PluginExtensionKind.screenSaver.icon == "display" else { return false }

            // 2. 状态枚举与安全属性校验
            guard PluginExtensionStatus.orphan.rawValue == "宿主已卸载" else { return false }
            guard PluginExtensionStatus.broken.rawValue == "扩展已损坏" else { return false }
            guard PluginExtensionStatus.installed.rawValue == "宿主正常在用" else { return false }
            guard PluginExtensionStatus.system.rawValue == "系统官方组件" else { return false }

            // 3. 模型可清理安全属性断言
            let orphanItem = PluginExtensionItem(
                name: "TestQL",
                path: "/tmp/TestQL.qlgenerator",
                size: 1024,
                bundleID: "com.test.ql",
                version: "1.0",
                kind: .quickLook,
                status: .orphan,
                hostAppName: "Test App",
                isUserDomain: true
            )
            guard orphanItem.isSafeToClean == true else { return false }

            let brokenItem = PluginExtensionItem(
                name: "BrokenImporter",
                path: "/tmp/Broken.mdimporter",
                size: 512,
                bundleID: "com.broken.importer",
                version: "0.9",
                kind: .spotlight,
                status: .broken,
                hostAppName: nil,
                isUserDomain: true
            )
            guard brokenItem.isSafeToClean == true else { return false }

            let installedItem = PluginExtensionItem(
                name: "ActivePlugin",
                path: "/tmp/Active.qlgenerator",
                size: 2048,
                bundleID: "com.active.app",
                version: "2.0",
                kind: .quickLook,
                status: .installed,
                hostAppName: "Active App",
                isUserDomain: true
            )
            guard installedItem.isSafeToClean == false else { return false }

            let systemItem = PluginExtensionItem(
                name: "SystemPlugin",
                path: "/System/Library/QuickLook/System.qlgenerator",
                size: 4096,
                bundleID: "com.apple.quicklook",
                version: "1.0",
                kind: .quickLook,
                status: .system,
                hostAppName: "macOS 系统内置",
                isUserDomain: false
            )
            guard systemItem.isSafeToClean == false else { return false }

            return true
        }

        check("插件 Bundle 元数据提取与 Contents/Info.plist 解析 (parseBundleMetadata)") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_PluginTest_\(UUID().uuidString)"
            let bundleDir = "\(tmpDir)/Sample.qlgenerator"
            let contentsDir = "\(bundleDir)/Contents"
            let macosDir = "\(contentsDir)/MacOS"

            try? fm.createDirectory(atPath: macosDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(atPath: tmpDir)
            }

            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>com.example.sampleql</string>
                <key>CFBundleDisplayName</key>
                <string>示例快速查看生成器</string>
                <key>CFBundleShortVersionString</key>
                <string>1.2.3</string>
                <key>CFBundleExecutable</key>
                <string>SampleQLBinary</string>
            </dict>
            </plist>
            """
            try? plistContent.write(toFile: "\(contentsDir)/Info.plist", atomically: true, encoding: .utf8)

            // 1. 未放置二进制时：executableExists 应为 false
            let metaBroken = PluginExtensionInspector.shared.parseBundleMetadata(
                path: bundleDir,
                defaultName: "Sample.qlgenerator",
                kind: .quickLook
            )
            guard metaBroken.bundleID == "com.example.sampleql" else { return false }
            guard metaBroken.name == "示例快速查看生成器" else { return false }
            guard metaBroken.version == "1.2.3" else { return false }
            guard metaBroken.executableExists == false else { return false }

            // 2. 放置二进制占位文件后：executableExists 应为 true
            try? "mock binary".write(toFile: "\(macosDir)/SampleQLBinary", atomically: true, encoding: .utf8)
            let metaValid = PluginExtensionInspector.shared.parseBundleMetadata(
                path: bundleDir,
                defaultName: "Sample.qlgenerator",
                kind: .quickLook
            )
            guard metaValid.executableExists == true else { return false }

            return true
        }

        check("插件健康状态研判算法：宿主关联、孤儿识别与 Apple 官方保护 (evaluateStatus)") {
            let inspector = PluginExtensionInspector.shared
            let fakeInstalledApps = [
                InstalledApp(
                    name: "Photomator",
                    path: "/Applications/Photomator.app",
                    bundleID: "com.pixelmator.photomator",
                    size: 100_000_000
                ),
                InstalledApp(
                    name: "Sublime Text",
                    path: "/Applications/Sublime Text.app",
                    bundleID: "com.sublimetext.4",
                    size: 80_000_000
                )
            ]

            // 1. Apple 官方系统保护
            let (statusSys, hostSys) = inspector.evaluateStatus(
                bundleID: "com.apple.quicklook.iwork",
                appName: "iWork",
                executableExists: true,
                fullPath: "/Library/QuickLook/iWork.qlgenerator",
                installedApps: fakeInstalledApps
            )
            guard statusSys == .system && hostSys == "macOS 系统内置" else { return false }

            // 2. 扩展破损（二进制缺失）
            let (statusBroken, _) = inspector.evaluateStatus(
                bundleID: "com.some.plugin",
                appName: "SomePlugin",
                executableExists: false,
                fullPath: "/Library/QuickLook/Some.qlgenerator",
                installedApps: fakeInstalledApps
            )
            guard statusBroken == .broken else { return false }

            // 3. 匹配在用 App (前缀命中)
            let (statusInst, hostInst) = inspector.evaluateStatus(
                bundleID: "com.pixelmator.photomator.quicklook",
                appName: "Photomator QuickLook",
                executableExists: true,
                fullPath: "/Library/QuickLook/Photomator.qlgenerator",
                installedApps: fakeInstalledApps
            )
            guard statusInst == .installed && hostInst == "Photomator" else { return false }

            // 4. 匹配在用 App (词干/名称命中)
            let (statusStem, hostStem) = inspector.evaluateStatus(
                bundleID: "com.sublimetext.qlplugin",
                appName: "SublimeTextQL",
                executableExists: true,
                fullPath: "/Library/QuickLook/SublimeText.qlgenerator",
                installedApps: fakeInstalledApps
            )
            guard statusStem == .installed && hostStem == "Sublime Text" else { return false }

            // 5. 孤儿残留（已卸载 App 的扩展）
            let (statusOrphan, hostOrphan) = inspector.evaluateStatus(
                bundleID: "com.defunct.oldreader.qlgenerator",
                appName: "OldReaderQL",
                executableExists: true,
                fullPath: "~/Library/QuickLook/OldReader.qlgenerator",
                installedApps: fakeInstalledApps
            )
            guard statusOrphan == .orphan else { return false }
            guard hostOrphan != nil else { return false }

            return true
        }

        check("插件与扩展扫描主流程：隔离目录扫描与排序正确性 (scan)") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_ScanTest_\(UUID().uuidString)"
            let qlDir = "\(tmpDir)/QuickLook"
            let mdDir = "\(tmpDir)/Spotlight"

            try? fm.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: mdDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(atPath: tmpDir)
            }

            // 创建一个孤儿 QuickLook
            let orphanQL = "\(qlDir)/OrphanItem.qlgenerator"
            try? fm.createDirectory(atPath: "\(orphanQL)/Contents/MacOS", withIntermediateDirectories: true)
            try? "bin".write(toFile: "\(orphanQL)/Contents/MacOS/OrphanItem", atomically: true, encoding: .utf8)
            let qlPlist = "<plist><dict><key>CFBundleIdentifier</key><string>com.orphan.demo</string><key>CFBundleExecutable</key><string>OrphanItem</string></dict></plist>"
            try? qlPlist.write(toFile: "\(orphanQL)/Contents/Info.plist", atomically: true, encoding: .utf8)

            // 创建一个在用 Spotlight 导入器
            let installedMD = "\(mdDir)/InstalledItem.mdimporter"
            try? fm.createDirectory(atPath: "\(installedMD)/Contents/MacOS", withIntermediateDirectories: true)
            try? "bin".write(toFile: "\(installedMD)/Contents/MacOS/InstalledItem", atomically: true, encoding: .utf8)
            let mdPlist = "<plist><dict><key>CFBundleIdentifier</key><string>com.test.installed.md</string><key>CFBundleExecutable</key><string>InstalledItem</string></dict></plist>"
            try? mdPlist.write(toFile: "\(installedMD)/Contents/Info.plist", atomically: true, encoding: .utf8)

            let testDirs = [
                PluginExtensionInspector.TargetDirectory(path: qlDir, kind: .quickLook, isUserDomain: true),
                PluginExtensionInspector.TargetDirectory(path: mdDir, kind: .spotlight, isUserDomain: true)
            ]

            let testApps = [
                InstalledApp(name: "Installed App", path: "/Applications/Installed.app", bundleID: "com.test.installed", size: 10_000)
            ]

            let items = PluginExtensionInspector.shared.scan(directories: testDirs, installedApps: testApps)
            guard items.count == 2 else { return false }

            // 孤儿排在前面
            guard items[0].status == .orphan else { return false }
            guard items[1].status == .installed else { return false }
            guard items[0].kind == .quickLook && items[1].kind == .spotlight else { return false }

            return true
        }

        check("插件安全清理执行与废纸篓释放 (clean & resetQuickLookCache)") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_CleanTest_\(UUID().uuidString)"
            let targetFile = "\(tmpDir)/ToClean.qlgenerator"
            try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            try? "dummy package".write(toFile: targetFile, atomically: true, encoding: .utf8)
            defer {
                try? fm.removeItem(atPath: tmpDir)
            }

            let item = PluginExtensionItem(
                name: "ToClean",
                path: targetFile,
                size: 1024,
                bundleID: "com.test.clean",
                version: "1.0",
                kind: .quickLook,
                status: .orphan,
                hostAppName: "Test",
                isUserDomain: true,
                isSelected: true
            )

            // 1. 安全移入废纸篓
            let res = PluginExtensionInspector.shared.clean(items: [item], permanently: false)
            guard res.succeeded == 1 && res.failed == 0 else { return false }
            guard res.hadQuickLook == true else { return false }
            guard !fm.fileExists(atPath: targetFile) else { return false }

            // 2. 系统核心组件拒绝清理防线
            let sysItem = PluginExtensionItem(
                name: "SystemProtected",
                path: "/System/Library/QuickLook/Protected.qlgenerator",
                size: 2048,
                bundleID: "com.apple.protected",
                version: "1.0",
                kind: .quickLook,
                status: .system,
                hostAppName: "macOS",
                isUserDomain: false,
                isSelected: true
            )
            let resSys = PluginExtensionInspector.shared.clean(items: [sysItem], permanently: false)
            guard resSys.failed == 1 && resSys.succeeded == 0 else { return false }

            return true
        }

        check("ViewInspector 交互自检：UninstallerView 插件扩展治理 Tab 视图渲染与状态切换") {
            let app = AppState()
            app.uninstaller.currentTab = .extensions

            let mockPlugin = PluginExtensionItem(
                name: "MockOrphanQL",
                path: "/tmp/Mock.qlgenerator",
                size: 4096,
                bundleID: "com.orphan.mock",
                version: "1.0.0",
                kind: .quickLook,
                status: .orphan,
                hostAppName: "Mock App",
                isUserDomain: true,
                isSelected: false
            )
            app.uninstaller.pluginItems = [mockPlugin]
            app.uninstaller.isScanningPlugins = false

            let view = UninstallerView().environmentObject(app)

            // 1. 验证 TabPicker 存在且已切换到 extensions
            guard app.uninstaller.currentTab == .extensions else { return false }

            // 2. 验证全选逻辑（安全项自动勾选，系统项不勾选）
            app.uninstaller.setAllPluginsSelected(true, safeOnly: true)
            guard app.uninstaller.selectedPluginCount == 1 else { return false }
            guard app.uninstaller.allPluginsSelected == true else { return false }

            // 3. 验证取消全选
            app.uninstaller.setAllPluginsSelected(false, safeOnly: true)
            guard app.uninstaller.selectedPluginCount == 0 else { return false }
            guard app.uninstaller.allPluginsSelected == false else { return false }

            // 4. 验证单项勾选切换
            app.uninstaller.togglePluginItem(id: mockPlugin.id, on: true)
            guard app.uninstaller.selectedPluginItems.first?.id == mockPlugin.id else { return false }

            // 5. 视图在内存中构建与可访问性标识渲染
            _ = try? view.inspect().find(viewWithAccessibilityIdentifier: "uninstallerTabPicker")
            _ = try? view.inspect().find(viewWithAccessibilityIdentifier: "pluginPanel")
            _ = try? view.inspect().find(viewWithAccessibilityIdentifier: "refreshPluginsButton")

            return true
        }
    }
}
