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

        // v1.72 性能：`scanApps` 原先串行对每个 `.app` 做一次全量递归算体积，
        // 本机 28 个第三方 App 冷启动实测 2013 ms——打开卸载器就卡在那。现改为并行。
        //
        // 这一条从前是墙钟上界 `elapsed < 5.0`。它在别人占 CPU 时会翻红：2026-09-28 两次
        // 全量自检一次 34、一次 35 条失败，多出来的就是它（当时 Qoder/MiniMax 各占 90%/82%）。
        // 而发版门禁现在按**失败名集**与基线逐条比对，这种假红会直接拦下发版。
        // 它真正要守的两件事都是**结构**性的：① 别退回串行；② 别变成每个 App 重扫一次。
        // 所以判据换成负载无关的结构检查，耗时仍然打印，只是不再当断言。
        check("卸载器：清单取体积是并行且每条目只求一次（结构判据，不用墙钟上界）") {
            guard let src = SelftestSource.read("Uninstaller") else {
                print("      Uninstaller.swift 源码不可读"); return false
            }
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            guard let head = code.range(of: "staticfuncscanApps()->[InstalledApp]{") else {
                print("      找不到 scanApps 定义（签名改了？判据要跟着改，别删）"); return false
            }
            // 大括号深度精确截这一个函数体（取窗会被相邻定义背书，见 RELEASE-CHECKLIST §活性证据）
            var depth = 1
            var i = head.upperBound
            var endIdx = code.endIndex
            while i < code.endIndex {
                let c = code[i]
                if c == "{" { depth += 1 }
                else if c == "}" {
                    depth -= 1
                    if depth == 0 { endIdx = i; break }
                }
                i = code.index(after: i)
            }
            let body = String(code[head.upperBound..<endIdx])

            FileSystem.beginMeasurementSession()
            let start = Date()
            let apps = UninstallerScanner.scanApps()
            let elapsed = Date().timeIntervalSince(start)
            print("      scanApps：\(apps.count) 个第三方 App，\(String(format: "%.0f", elapsed * 1000)) ms（仅打印，不作断言）")

            var bad: [String] = []
            guard let cp = body.range(of: "concurrentPerform(iterations:") else {
                bad.append("scanApps 里没有 concurrentPerform——已退回串行，打开卸载器就是卡住的那形状")
                print("      " + bad.joined(separator: "\n      "))
                return false
            }
            // 求体积必须**只在并行区内**发生一次：并行块之前出现 = 先串行算过一遍；
            // 出现多次 = 每个 App 被重扫（当年 2013 ms 就是这么来的）。
            let before = String(body[body.startIndex..<cp.lowerBound])
            let after = String(body[cp.lowerBound..<body.endIndex])
            if before.components(separatedBy: "FileSystem.size(at:").count - 1 != 0 {
                bad.append("concurrentPerform 之前就有求体积调用：并行没覆盖全部条目")
            }
            let sizeCalls = after.components(separatedBy: "FileSystem.size(at:").count - 1
            if sizeCalls != 1 {
                bad.append("并行区内求体积 \(sizeCalls) 次，应为 1 次/条目（多次 = N 次重扫）")
            }
            if apps.isEmpty {
                bad.append("这台机器一个第三方 App 都没扫到：结构判据仍要跑，但请把数字核对一遍")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }
    }
}
