import SwiftUI
import ViewInspector
import Darwin

// 自检套件：应用程序卸载器深度扫描增强（v1.39.0）
extension Selftest {
    static func suiteUninstallerDeep() {
        check("卸载深度扫描：ByHost 偏好设置与硬件哈希 plist 关联识别") {
            let mockHome = "/private/tmp/macclean-uninstaller-byhost-\(UUID().uuidString)"
            let prefsDir = mockHome + "/Library/Preferences"
            let byHostDir = prefsDir + "/ByHost"
            try? FileManager.default.createDirectory(atPath: byHostDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: mockHome) }

            let bundle = "com.macclean.testapp"
            let stdPlist = prefsDir + "/\(bundle).plist"
            let byHostPlist = byHostDir + "/\(bundle).1A2B3C4D-5E6F.plist"
            let otherPlist = byHostDir + "/com.other.app.1A2B3C4D-5E6F.plist"

            FileManager.default.createFile(atPath: stdPlist, contents: Data("std".utf8))
            FileManager.default.createFile(atPath: byHostPlist, contents: Data("byhost".utf8))
            FileManager.default.createFile(atPath: otherPlist, contents: Data("other".utf8))

            let app = InstalledApp(name: "TestApp", path: "/Applications/TestApp.app", bundleID: bundle, size: 1024)
            let related = UninstallerScanner.relatedFiles(for: app, home: mockHome)

            guard related.count == 2 else { return false }
            guard related.contains(where: { $0.path == stdPlist && $0.fileKind == .preferences }) else { return false }
            guard related.contains(where: { $0.path == byHostPlist && $0.fileKind == .preferences }) else { return false }
            guard !related.contains(where: { $0.path == otherPlist }) else { return false }

            return true
        }

        check("卸载深度扫描：DiagnosticReports 崩溃与诊断日志精准关联且防止误伤") {
            let mockHome = "/private/tmp/macclean-uninstaller-diag-\(UUID().uuidString)"
            let diagDir = mockHome + "/Library/Logs/DiagnosticReports"
            try? FileManager.default.createDirectory(atPath: diagDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: mockHome) }

            let bundle = "com.macclean.testapp"
            let appIps = diagDir + "/TestApp_2026-09-19-123456_Mac.ips"
            let bundleCrash = diagDir + "/\(bundle)_2026-09-19.crash"
            let otherIps = diagDir + "/OtherApp_2026-09-19-123456_Mac.ips"

            FileManager.default.createFile(atPath: appIps, contents: Data("ips".utf8))
            FileManager.default.createFile(atPath: bundleCrash, contents: Data("crash".utf8))
            FileManager.default.createFile(atPath: otherIps, contents: Data("other".utf8))

            let app = InstalledApp(name: "TestApp", path: "/Applications/TestApp.app", bundleID: bundle, size: 1024)
            let related = UninstallerScanner.relatedFiles(for: app, home: mockHome)

            guard related.count == 2 else { return false }
            guard related.contains(where: { $0.path == appIps && $0.fileKind == .crashReports }) else { return false }
            guard related.contains(where: { $0.path == bundleCrash && $0.fileKind == .crashReports }) else { return false }
            guard !related.contains(where: { $0.path == otherIps }) else { return false }

            return true
        }

        check("卸载深度扫描：WebKit 独立隔离存储与 Cookie 关联") {
            let mockHome = "/private/tmp/macclean-uninstaller-webkit-\(UUID().uuidString)"
            let webKitDir = mockHome + "/Library/WebKit/com.macclean.testapp"
            let cookiesDir = mockHome + "/Library/Cookies"
            try? FileManager.default.createDirectory(atPath: webKitDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: cookiesDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: mockHome) }

            let bundle = "com.macclean.testapp"
            let webKitPayload = webKitDir + "/data.db"
            let cookiesFile = cookiesDir + "/\(bundle).binarycookies"

            FileManager.default.createFile(atPath: webKitPayload, contents: Data("db".utf8))
            FileManager.default.createFile(atPath: cookiesFile, contents: Data("cookie".utf8))

            let app = InstalledApp(name: "TestApp", path: "/Applications/TestApp.app", bundleID: bundle, size: 1024)
            let related = UninstallerScanner.relatedFiles(for: app, home: mockHome)

            guard related.count == 2 else { return false }
            guard related.contains(where: { $0.path == webKitDir && $0.fileKind == .webKitAndCookies }) else { return false }
            guard related.contains(where: { $0.path == cookiesFile && $0.fileKind == .webKitAndCookies }) else { return false }

            return true
        }

        check("卸载深度扫描：Application Scripts 与 LaunchAgents 直配识别") {
            let mockHome = "/private/tmp/macclean-uninstaller-scripts-\(UUID().uuidString)"
            let scriptsDir = mockHome + "/Library/Application Scripts/com.macclean.testapp"
            let launchAgentsDir = mockHome + "/Library/LaunchAgents"
            try? FileManager.default.createDirectory(atPath: scriptsDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: mockHome) }

            let bundle = "com.macclean.testapp"
            let scriptPayload = scriptsDir + "/script.scpt"
            let agentPlist = launchAgentsDir + "/\(bundle).helper.plist"
            let unrelatedAgentPlist = launchAgentsDir + "/com.unrelated.job.plist"

            FileManager.default.createFile(atPath: scriptPayload, contents: Data("scpt".utf8))
            FileManager.default.createFile(atPath: agentPlist, contents: Data("plist".utf8))
            FileManager.default.createFile(atPath: unrelatedAgentPlist, contents: Data("unrelated".utf8))

            let app = InstalledApp(name: "TestApp", path: "/Applications/TestApp.app", bundleID: bundle, size: 1024)
            let related = UninstallerScanner.relatedFiles(for: app, home: mockHome)

            guard related.contains(where: { $0.path == scriptsDir && $0.fileKind == .appScripts }) else { return false }
            guard related.contains(where: { $0.path == agentPlist && $0.fileKind == .launchAgents }) else { return false }
            guard !related.contains(where: { $0.path == unrelatedAgentPlist }) else { return false }

            return true
        }

        check("卸载深度扫描：N5 规则保证不越界误伤厂商母目录") {
            let mockHome = "/private/tmp/macclean-uninstaller-n5-\(UUID().uuidString)"
            let chromeDir = mockHome + "/Library/Application Support/Google/Chrome"
            let driveDir = mockHome + "/Library/Application Support/Google/Drive"
            try? FileManager.default.createDirectory(atPath: chromeDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: driveDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: mockHome) }

            FileManager.default.createFile(atPath: chromeDir + "/profile.json", contents: Data("chrome".utf8))
            FileManager.default.createFile(atPath: driveDir + "/sync.db", contents: Data("drive".utf8))

            let chrome = InstalledApp(name: "Google Chrome", path: "/Applications/Google Chrome.app",
                                      bundleID: "com.google.Chrome", size: 1024)
            let related = UninstallerScanner.relatedFiles(for: chrome, home: mockHome)

            guard related.contains(where: { $0.path == chromeDir && $0.fileKind == .appSupport }) else { return false }
            let parentGoogle = mockHome + "/Library/Application Support/Google"
            guard !related.contains(where: { $0.path == parentGoogle }) else { return false }
            guard !related.contains(where: { $0.path == driveDir }) else { return false }

            return true
        }

        check("卸载深度扫描：幽灵 App 零误判") {
            let ghost = InstalledApp(
                name: "GhostApp_\(UUID().uuidString.prefix(8))",
                path: "/Applications/NonExistentGhost_\(UUID().uuidString).app",
                bundleID: "com.ghost.\(UUID().uuidString)",
                size: 0
            )
            let files = UninstallerScanner.relatedFiles(for: ghost)
            return files.isEmpty
        }

        check("卸载深度扫描：RelatedFileRow UI 渲染与图标分类胶囊展示") {
            let file = RelatedFile(
                name: "TestCrash.ips",
                path: "/Users/test/Library/Logs/DiagnosticReports/TestCrash.ips",
                size: 2048,
                kind: "崩溃诊断报告",
                fileKind: .crashReports,
                isSelected: true
            )
            let state = AppState()
            let view = RelatedFileRow(file: file).environmentObject(state)

            guard let inspected = try? view.inspect() else { return false }
            // 验证是否展示了对应类别文字徽标
            let textViews = inspected.findAll(ViewType.Text.self)
            guard textViews.contains(where: { (try? $0.string()) == RelatedFileKind.crashReports.rawValue }) else {
                return false
            }
            // 验证是否包含该类别专属 SF Symbol
            let imageViews = inspected.findAll(ViewType.Image.self)
            guard imageViews.contains(where: { (try? $0.actualImage().name()) == RelatedFileKind.crashReports.icon }) else {
                return false
            }

            return true
        }
    }
}
