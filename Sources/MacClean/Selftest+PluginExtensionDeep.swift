import Foundation
import SwiftUI
import ViewInspector

// 自检套件：系统深度应用扩展与 QuickLook/Spotlight 插件残存治理 (v1.55.0 · v1.73.0 加固)
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
            // 「读不到」既不是孤儿也不是损坏，而是需确认
            guard PluginExtensionStatus.needsReview.rawValue.contains("需确认") else { return false }
            guard !PluginExtensionStatus.needsReview.providesDeletionVerdict
                    && !PluginExtensionStatus.installed.providesDeletionVerdict
                    && !PluginExtensionStatus.system.providesDeletionVerdict else { return false }
            guard PluginExtensionStatus.orphan.providesDeletionVerdict else { return false }

            // 3. 模型判据属性：**新名字**，明确它只是"结论"而不是"已受保护"
            let orphanItem = PluginExtensionItem(
                name: "TestQL", path: "/tmp/TestQL.qlgenerator", size: 1024,
                bundleID: "com.test.ql", version: "1.0", kind: .quickLook,
                status: .orphan, hostAppName: "Test App", isUserDomain: true
            )
            guard orphanItem.isDeletableVerdict == true else { return false }

            let brokenItem = PluginExtensionItem(
                name: "BrokenImporter", path: "/tmp/Broken.mdimporter", size: 512,
                bundleID: "com.broken.importer", version: "0.9", kind: .spotlight,
                status: .broken, hostAppName: nil, isUserDomain: true
            )
            guard brokenItem.isDeletableVerdict == true else { return false }

            let installedItem = PluginExtensionItem(
                name: "ActivePlugin", path: "/tmp/Active.qlgenerator", size: 2048,
                bundleID: "com.active.app", version: "2.0", kind: .quickLook,
                status: .installed, hostAppName: "Active App", isUserDomain: true
            )
            guard installedItem.isDeletableVerdict == false else { return false }

            let systemItem = PluginExtensionItem(
                name: "SystemPlugin", path: "/System/Library/QuickLook/System.qlgenerator",
                size: 4096, bundleID: "com.apple.quicklook", version: "1.0", kind: .quickLook,
                status: .system, hostAppName: "macOS 系统内置", isUserDomain: false
            )
            guard systemItem.isDeletableVerdict == false else { return false }

            // 用户创作物：即便结论是"孤儿"也不给删除判据
            let authored = PluginExtensionItem(
                name: "MyService", path: "/Users/test/Library/Services/MyService.workflow",
                size: 4096, bundleID: nil, version: nil, kind: .services,
                status: .orphan, hostAppName: nil, isUserDomain: true,
                isUserAuthoredContent: true
            )
            guard authored.isDeletableVerdict == false else { return false }
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

            // 1. 未放置二进制时：executableExists 应为 false，且 Info.plist 确实读到了
            let metaBroken = PluginExtensionInspector.shared.parseBundleMetadata(
                path: bundleDir, defaultName: "Sample.qlgenerator", kind: .quickLook
            )
            guard metaBroken.bundleID == "com.example.sampleql" else { return false }
            guard metaBroken.name == "示例快速查看生成器" else { return false }
            guard metaBroken.version == "1.2.3" else { return false }
            guard metaBroken.executableExists == false else { return false }
            guard metaBroken.hasInfoPlist else { return false }

            // 2. 放置二进制占位文件后：executableExists 应为 true
            try? "mock binary".write(toFile: "\(macosDir)/SampleQLBinary", atomically: true, encoding: .utf8)
            let metaValid = PluginExtensionInspector.shared.parseBundleMetadata(
                path: bundleDir, defaultName: "Sample.qlgenerator", kind: .quickLook
            )
            guard metaValid.executableExists == true else { return false }

            // 3. 完全没有 Info.plist：hasInfoPlist=false，executableExists 只是占位真值
            let noPlistDir = "\(tmpDir)/Loose.bundle"
            try? fm.createDirectory(atPath: noPlistDir, withIntermediateDirectories: true)
            let metaLoose = PluginExtensionInspector.shared.parseBundleMetadata(
                path: noPlistDir, defaultName: "Loose.bundle", kind: .other
            )
            guard metaLoose.hasInfoPlist == false, metaLoose.bundleID == nil else { return false }
            return true
        }

        check("插件健康状态研判算法：宿主关联、孤儿识别与 Apple 官方保护 (evaluateStatus)") {
            let inspector = PluginExtensionInspector.shared
            let fakeInstalledApps = [
                InstalledApp(name: "Photomator", path: "/Applications/Photomator.app",
                             bundleID: "com.pixelmator.photomator", size: 100_000_000),
                InstalledApp(name: "Sublime Text", path: "/Applications/Sublime Text.app",
                             bundleID: "com.sublimetext.4", size: 80_000_000)
            ]
            let complete = AppInventory.Snapshot(
                bundleIDs: ["com.pixelmator.photomator", "com.sublimetext.4"],
                bundlePrefixes: ["com.pixelmator", "com.sublimetext"],
                normalizedNames: ["photomator", "sublimetext"],
                executableNames: ["photomator", "sublime_text"],
                runningBundleIDs: [], appPaths: [], unreadableRoots: [])
            let evaluate = { (bundleID: String?, appName: String, exec: Bool, plist: Bool,
                              path: String, kind: PluginExtensionKind, user: Bool) in
                inspector.evaluateStatus(bundleID: bundleID, appName: appName, executableExists: exec,
                                         hasInfoPlist: plist, fullPath: path, kind: kind,
                                         isUserDomain: user, installedApps: fakeInstalledApps,
                                         inventory: complete)
            }

            // 1. Apple 官方系统保护
            let sys = evaluate("com.apple.quicklook.iwork", "iWork", true, true,
                               "/Library/QuickLook/iWork.qlgenerator", .quickLook, false)
            guard sys.status == .system && sys.host == "macOS 系统内置" else { return false }

            // 2. 扩展破损（二进制缺失）
            let broken = evaluate("com.some.plugin", "SomePlugin", false, true,
                                  "/Library/QuickLook/Some.qlgenerator", .quickLook, false)
            guard broken.status == .broken else { return false }

            // 3. 匹配在用 App (前缀命中)
            let inst = evaluate("com.pixelmator.photomator.quicklook", "Photomator QuickLook", true, true,
                                "/Library/QuickLook/Photomator.qlgenerator", .quickLook, false)
            guard inst.status == .installed && inst.host == "Photomator" else { return false }

            // 4. 匹配在用 App (词干/名称命中)
            let stem = evaluate("com.sublimetext.qlplugin", "SublimeTextQL", true, true,
                                "/Library/QuickLook/SublimeText.qlgenerator", .quickLook, false)
            guard stem.status == .installed && stem.host == "Sublime Text" else { return false }

            // 5. 孤儿残留（已卸载 App 的扩展）：清单可信 + 确有 bundle id 才敢判
            let orphan = evaluate("com.defunct.oldreader.qlgenerator", "OldReaderQL", true, true,
                                  "/Users/test/Library/QuickLook/OldReader.qlgenerator", .quickLook, true)
            guard orphan.status == .orphan, orphan.host != nil else { return false }

            // 6. 无 Info.plist（证据缺失）不得判损坏，也不得判孤儿
            let noPlist = evaluate(nil, "LooseThing", true, false,
                                   "/Users/test/Library/QuickLook/LooseThing", .other, true)
            guard noPlist.status == .needsReview else {
                print("    ❌ 无 Info.plist 被判成 \(noPlist.status.rawValue)")
                return false
            }

            // 7. G8 系统保护位置内的组件即便"二进制丢失"也算系统组件
            let inSystem = evaluate("com.third.plugin", "X", false, true,
                                    "/System/Library/QuickLook/X.qlgenerator", .quickLook, false)
            guard inSystem.status == .system else { return false }
            return true
        }

        check("插件与扩展扫描主流程：隔离目录扫描与排序正确性 (scan)") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_ScanTest_\(UUID().uuidString)"
            let qlDir = "\(tmpDir)/QuickLook"
            let mdDir = "\(tmpDir)/Spotlight"

            try? fm.createDirectory(atPath: qlDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: mdDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: tmpDir) }
            let savedInventory = AppInventory.snapshotOverride
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: ["com.test.installed"], bundlePrefixes: ["com.test"],
                normalizedNames: ["installed"], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: [])
            defer { AppInventory.snapshotOverride = savedInventory }

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
                InstalledApp(name: "Installed App", path: "/Applications/Installed.app",
                             bundleID: "com.test.installed", size: 10_000)
            ]

            let items = PluginExtensionInspector.shared.scan(directories: testDirs, installedApps: testApps)
            guard items.count == 2 else { return false }

            // 孤儿排在前面
            guard items[0].status == .orphan else { return false }
            guard items[1].status == .installed else { return false }
            guard items[0].kind == .quickLook && items[1].kind == .spotlight else { return false }
            // 扫描阶段一律不默认勾选
            guard items.allSatisfy({ !$0.isSelected }) else { return false }
            // 自定义 TargetDirectory 不传 domain 也能编译（默认 nil = 主目录护栏）
            guard testDirs[0].domain == nil && testDirs[0].isUserAuthoredRoot == false else { return false }
            return true
        }

        check("插件安全清理执行与废纸篓释放 (clean & resetQuickLookCache)") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_CleanTest_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            let targetFile = "\(tmpDir)/ToClean.qlgenerator"
            try? "dummy package".write(toFile: targetFile, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: tmpDir) }

            let savedRunner = SafeProcess.runner
            let savedQLPath = PluginExtensionInspector.qlmanagePath
            defer {
                SafeProcess.runner = savedRunner
                PluginExtensionInspector.qlmanagePath = savedQLPath
            }
            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }

            let item = PluginExtensionItem(
                name: "ToClean", path: targetFile, size: 1024, bundleID: "com.test.clean",
                version: "1.0", kind: .quickLook, status: .orphan, hostAppName: "Test",
                isUserDomain: true, isSelected: true
            )

            // 1. 安全移入废纸篓
            let res = PluginExtensionInspector.shared.clean(items: [item], permanently: false, journal: .none)
            guard res.succeeded == 1 && res.failed == 0 else { return false }
            guard res.hadQuickLook == true else { return false }
            guard res.attemptedQuickLookReset else { return false }
            guard !fm.fileExists(atPath: targetFile) else { return false }
            // qlmanage 必须走 SafeProcess，且参数与旧实现一致
            guard seen.map(\.0).allSatisfy({ $0 == "/usr/bin/qlmanage" }),
                  seen.map(\.1) == [["-r"], ["-r", "cache"]] else {
                print("    ❌ qlmanage 调用不符: \(seen)")
                return false
            }

            // 2. 系统核心组件拒绝清理防线
            let sysItem = PluginExtensionItem(
                name: "SystemProtected", path: "/System/Library/QuickLook/Protected.qlgenerator",
                size: 2048, bundleID: "com.apple.protected", version: "1.0", kind: .quickLook,
                status: .system, hostAppName: "macOS", isUserDomain: false, isSelected: true
            )
            let resSys = PluginExtensionInspector.shared.clean(items: [sysItem], permanently: false, journal: .none)
            guard resSys.failed == 1 && resSys.succeeded == 0 else { return false }
            guard resSys.rejected.first?.message.contains("官方组件") == true else { return false }

            // 3. 命令失败时不得宣称"已自动刷新 QuickLook 缓存"
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 1, output: "denied") }
            let second = "\(tmpDir)/Another.qlgenerator"
            try? "dummy".write(toFile: second, atomically: true, encoding: .utf8)
            let item2 = PluginExtensionItem(
                name: "Another", path: second, size: 5, bundleID: "com.test.clean2",
                version: nil, kind: .quickLook, status: .orphan, hostAppName: "Test",
                isUserDomain: true, isSelected: true)
            // 彻底删除：自检反复跑也不该往用户废纸篓里堆测试件
            let res2 = PluginExtensionInspector.shared.clean(items: [item2], permanently: true, journal: .none)
            guard res2.succeeded == 1, res2.hadQuickLook == false, res2.attemptedQuickLookReset else { return false }
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

        // ── v1.73.0 安全加固：以下 6 条锁住本轮修复的 P0 ──

        // 7. 用户创作物（~/Library/Services/*.workflow）绝不被判孤儿，也绝不被删
        check("PluginExtension: 用户 Automator 服务无宿主证据时降级需确认且拒绝删除") {
            let fm = FileManager.default
            let testDir = "/tmp/MacClean_PluginAuthored_\(UUID().uuidString)"
            let servicesDir = testDir + "/Services"
            try? fm.createDirectory(atPath: servicesDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 真实家目录里的用户服务路径（只作为字符串断言，绝不在真实 ~/Library 下造文件）
            let home = FileSystem.normalizePath(NSHomeDirectory())
            guard PluginExtensionInspector.isUserAuthoredContent(
                path: home + "/Library/Services/Open in Editor.workflow",
                kind: .services, isUserDomain: true) else { return false }
            guard !PluginExtensionInspector.isUserAuthoredContent(
                path: "/Library/QuickLook/Third.qlgenerator", kind: .quickLook,
                isUserDomain: false) else { return false }

            // 造一条 fixture 用户 workflow：CFBundleExecutable 为空是 Automator 服务的常态
            let fixture = servicesDir + "/MacCleanSelfTest.workflow"
            try? fm.createDirectory(atPath: fixture + "/Contents", withIntermediateDirectories: true)
            try? "<plist><dict><key>CFBundleIdentifier</key><string>6A2B9F00-1111-2222-3333-usercreated</string><key>CFBundleExecutable</key><string></string></dict></plist>"
                .write(toFile: fixture + "/Contents/Info.plist", atomically: true, encoding: .utf8)

            let savedInventory = AppInventory.snapshotOverride
            // 清单完整，但**没有任何**已安装应用与这条服务相关
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: ["com.some.other"], bundlePrefixes: ["com.some"],
                normalizedNames: ["other"], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: [])
            defer { AppInventory.snapshotOverride = savedInventory }

            let dirs = [PluginExtensionInspector.TargetDirectory(
                path: servicesDir, kind: .services, isUserDomain: true,
                domain: nil, isUserAuthoredRoot: true)]
            let items = PluginExtensionInspector.shared.scan(directories: dirs, installedApps: [])
            guard let mine = items.first(where: { $0.path == fixture }) else { return false }
            guard mine.status != .orphan && mine.status != .broken else {
                print("    ❌ 用户创作物被判成 \(mine.status.rawValue)")
                return false
            }
            guard mine.status == .needsReview, mine.isUserAuthoredContent else { return false }
            guard mine.isDeletableVerdict == false else { return false }
            guard mine.note?.contains("宿主是 macOS 本身") == true else { return false }

            // 对照组：同一 fixture 根下、**未被标为创作物根**的第三方扩展仍会被判孤儿
            let qlDir = testDir + "/QuickLook"
            let third = qlDir + "/Third.qlgenerator"
            try? fm.createDirectory(atPath: third + "/Contents/MacOS", withIntermediateDirectories: true)
            try? "b".write(toFile: third + "/Contents/MacOS/Third", atomically: true, encoding: .utf8)
            try? "<plist><dict><key>CFBundleIdentifier</key><string>com.defunct.third</string><key>CFBundleExecutable</key><string>Third</string></dict></plist>"
                .write(toFile: third + "/Contents/Info.plist", atomically: true, encoding: .utf8)
            let contrast = [PluginExtensionInspector.TargetDirectory(
                path: qlDir, kind: .quickLook, isUserDomain: true)]
            let rescan = PluginExtensionInspector.shared.scan(directories: contrast, installedApps: [])
            guard rescan.count == 1, rescan.first?.status == .orphan else {
                print("    ❌ 对照组第三方扩展未判孤儿: \(rescan.map { $0.status.rawValue })")
                return false
            }

            // 即使强行勾选，模块判据也必须把它挡在网关之前
            var forced = mine
            forced.isSelected = true
            let res = PluginExtensionInspector.shared.clean(items: [forced], permanently: false, journal: .none)
            guard res.succeeded == 0 && res.failed == 1 else { return false }
            guard res.rejected.first?.message.contains("你自己创建的扩展") == true else { return false }
            guard fm.fileExists(atPath: fixture) else { return false }

            // .broken 判据也不得覆盖用户域创作物（二进制丢失的 workflow 仍需确认）
            let (status, _, _) = PluginExtensionInspector.shared.evaluateStatus(
                bundleID: "6A2B9F00-1111-2222-3333-usercreated", appName: "MacCleanSelfTest",
                executableExists: false, hasInfoPlist: true, fullPath: fixture,
                kind: .services, isUserDomain: true, inUserAuthoredRoot: true,
                installedApps: [], inventory: AppInventory.current())
            guard status == .needsReview else {
                print("    ❌ 用户 workflow 二进制丢失被判成 \(status.rawValue)")
                return false
            }
            return true
        }

        // 8. 已安装应用清单不可信时绝不判孤儿（「读不到」≠「可以删」）
        check("PluginExtension: 清单读不到时降级需确认，清单完整时才允许孤儿结论") {
            let inspector = PluginExtensionInspector.shared
            let blind = AppInventory.Snapshot(
                bundleIDs: [], bundlePrefixes: [], normalizedNames: [], executableNames: [],
                runningBundleIDs: [], appPaths: [], unreadableRoots: ["/Applications"])
            guard blind.isComplete == false else { return false }

            let blindVerdict = inspector.evaluateStatus(
                bundleID: "com.defunct.gone.quicklook", appName: "GoneQL",
                executableExists: true, hasInfoPlist: true,
                fullPath: "/Users/test/Library/QuickLook/Gone.qlgenerator",
                kind: .quickLook, isUserDomain: true, installedApps: [], inventory: blind)
            guard blindVerdict.status == .needsReview else {
                print("    ❌ 清单不完整仍被判成 \(blindVerdict.status.rawValue)")
                return false
            }
            guard blindVerdict.note?.contains("不能据") == true else { return false }

            let good = AppInventory.Snapshot(
                bundleIDs: ["com.keep.alive"], bundlePrefixes: ["com.keep"],
                normalizedNames: ["alive"], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: [])
            guard good.isComplete else { return false }
            let goodVerdict = inspector.evaluateStatus(
                bundleID: "com.defunct.gone.quicklook", appName: "GoneQL",
                executableExists: true, hasInfoPlist: true,
                fullPath: "/Users/test/Library/QuickLook/Gone.qlgenerator",
                kind: .quickLook, isUserDomain: true, installedApps: [], inventory: good)
            guard goodVerdict.status == .orphan else { return false }
            return true
        }

        // 9. 全局 /Library/* 扩展根逐个声明治理域，主目录内的走主目录护栏
        check("PluginExtension: 全局扩展根与治理域一一对应，未登记位置不得有域") {
            let pairs: [(String, GovernanceDomain)] = [
                ("/Library/QuickLook/Foo.qlgenerator", .quickLookGlobal),
                ("/Library/Spotlight/Foo.mdimporter", .spotlightImportersGlobal),
                ("/Library/Internet Plug-Ins/Foo.plugin", .internetPlugInsGlobal),
                ("/Library/Contextual Menu Items/Foo.cmplugin", .contextualMenuGlobal),
                ("/Library/Screen Savers/Foo.saver", .screenSaversGlobal),
                ("/Library/Input Methods/Foo.app", .inputMethodsGlobal),
                ("/Library/ColorPickers/Foo.colorpicker", .colorPickersGlobal),
            ]
            for (path, domain) in pairs {
                guard PluginExtensionInspector.governanceDomain(forPath: path) == domain else {
                    print("    ❌ \(path) 未映射到 \(domain.id)")
                    return false
                }
                // 默认扫描目录里必须真的带上这个域
                guard PluginExtensionInspector.defaultDirectories().contains(where: {
                    FileSystem.normalizePath($0.path) == domain.normalizedRoot && $0.domain == domain
                }) else {
                    print("    ❌ 默认扫描目录未声明 \(domain.id)")
                    return false
                }
            }
            let home = FileSystem.normalizePath(NSHomeDirectory())
            guard PluginExtensionInspector.governanceDomain(forPath: "\(home)/Library/QuickLook/A.qlgenerator") == nil else { return false }
            // 未登记的系统位置不得有域（由基础护栏拒绝）
            guard PluginExtensionInspector.governanceDomain(forPath: "/Library/Developer/Xcode/B.plist") == nil else { return false }
            guard PluginExtensionInspector.governanceDomain(forPath: "/System/Library/QuickLook/C.qlgenerator") == nil else { return false }
            // 主目录内的用户 Services 根必须被标记为用户创作物根
            let services = PluginExtensionInspector.defaultDirectories().first { $0.kind == .services }
            guard let services, services.isUserAuthoredRoot, services.isUserDomain else { return false }
            return true
        }

        // 10. 白名单 / G6 / G8 路径在插件模块下必被拒且文件完好
        check("PluginExtension: 白名单与硬排除路径经网关必被拦下且文件完好") {
            let fm = FileManager.default
            let testDir = "/tmp/MacClean_PluginGuard_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: testDir + "/protected", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: testDir + "/plain", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let savedInventory = AppInventory.snapshotOverride
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: ["com.keep.alive"], bundlePrefixes: ["com.keep"],
                normalizedNames: [], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: [])
            defer { AppInventory.snapshotOverride = savedInventory }
            let savedRunner = SafeProcess.runner
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let wm = WhitelistManager.shared
            wm.removeAllRules()
            defer { wm.removeAllRules() }
            let whitelisted = testDir + "/protected/Keep.qlgenerator"
            try? "pkg".write(toFile: whitelisted, atomically: true, encoding: .utf8)
            wm.addPathRule(testDir + "/protected", comment: "插件网关自检")

            let home = FileSystem.normalizePath(NSHomeDirectory())
            let targets: [(String, String)] = [
                ("Keep.qlgenerator", whitelisted),
                ("Mail.qlgenerator", home + "/Library/Mail/V9/Keep.qlgenerator"),
                ("Apple.qlgenerator", "/System/Library/QuickLook/Apple.qlgenerator"),
            ]
            let items = targets.map { name, path in
                PluginExtensionItem(name: name, path: path, size: 3, bundleID: "com.gone.demo",
                                    version: nil, kind: .quickLook, status: .orphan,
                                    hostAppName: "Gone", isUserDomain: true, isSelected: true)
            }
            let res = PluginExtensionInspector.shared.clean(items: items, permanently: false, journal: .none)
            guard res.succeeded == 0 && res.failed > 0 && res.releasedBytes == 0 else { return false }
            let reasons = Set(res.rejected.map { $0.reason })
            guard reasons.contains(.userWhitelisted) || reasons.contains(.hardExcluded) else {
                print("    ❌ 未见白名单/硬排除拒绝: \(res.rejected.map { $0.reason })")
                return false
            }
            guard reasons.contains(.systemProtected) else { return false }
            guard fm.fileExists(atPath: whitelisted) else { return false }
            return true
        }

        // 11. 软链跳板：扩展目录里指向系统位置的软链必被网关拒绝
        check("PluginExtension: 软链跳板扩展被网关拒绝，真身未被删除") {
            let fm = FileManager.default
            let testDir = "/tmp/MacClean_PluginLink_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: testDir + "/QuickLook", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: testDir + "/outside", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let savedRunner = SafeProcess.runner
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let victim = testDir + "/outside/Real.qlgenerator"
            try? "real bundle".write(toFile: victim, atomically: true, encoding: .utf8)
            let link = testDir + "/QuickLook/Escape.qlgenerator"
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: victim)

            let item = PluginExtensionItem(name: "Escape", path: link, size: 11,
                                           bundleID: "com.gone.escape", version: nil,
                                           kind: .quickLook, status: .orphan, hostAppName: "Gone",
                                           isUserDomain: true, isSelected: true)
            let res = PluginExtensionInspector.shared.clean(items: [item], permanently: false, journal: .none)
            guard res.succeeded == 0 && res.failed == 1 else { return false }
            guard res.rejected.first?.reason == .symlinkJump else {
                print("    ❌ 未按软链跳板拒绝: \(res.rejected.map { $0.reason })")
                return false
            }
            guard fm.fileExists(atPath: victim), fm.fileExists(atPath: link) else { return false }
            return true
        }

        // 12. 删除失败/目标不存在不得计入清理数与释放量
        check("PluginExtension: 目标不存在与删除失败不计入 succeeded 与 releasedBytes") {
            let fm = FileManager.default
            let testDir = "/tmp/MacClean_PluginFail_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let savedRunner = SafeProcess.runner
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let gone = testDir + "/Gone.mdimporter"
            try? "x".write(toFile: gone, atomically: true, encoding: .utf8)
            let live = testDir + "/Live.mdimporter"
            try? "abcd".write(toFile: live, atomically: true, encoding: .utf8)

            // 扫描时虚报 5 MB 的体积，网关删除前实测：只有 4 字节被算作释放
            let goneItem = PluginExtensionItem(name: "Gone", path: gone, size: 5_000_000,
                                               bundleID: "com.gone.one", version: nil,
                                               kind: .spotlight, status: .orphan, hostAppName: "Gone",
                                               isUserDomain: true, isSelected: true)
            let liveItem = PluginExtensionItem(name: "Live", path: live, size: 5_000_000,
                                               bundleID: "com.gone.two", version: nil,
                                               kind: .spotlight, status: .broken, hostAppName: nil,
                                               isUserDomain: true, isSelected: true)
            try? fm.removeItem(atPath: gone)

            let res = PluginExtensionInspector.shared.clean(items: [goneItem, liveItem],
                                                            permanently: true, journal: .none)
            guard res.succeeded == 1 else { return false }
            guard res.outcome.freedBytes == 4 else {
                print("    ❌ 释放量未按删除前实测: \(res.outcome.freedBytes)")
                return false
            }
            guard res.failed == 1, res.rejected.first?.reason == .missing else { return false }
            guard !fm.fileExists(atPath: live) else { return false }
            return true
        }
    }
}
