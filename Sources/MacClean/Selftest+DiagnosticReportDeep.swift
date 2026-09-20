import Foundation
import SwiftUI
import ViewInspector

// MARK: - 自检套件：系统核心转储与废弃诊断报告智能排查与治理 (v1.58.0)

extension Selftest {
    static func suiteDiagnosticReportDeep() {
        print("==> 运行系统核心转储与废弃诊断报告智能排查自检 (v1.58.0)...")

        check("DiagnosticReport 数据模型与状态判定 (DiagnosticReportModels)") {
            let now = Date()
            let staleDate = now.addingTimeInterval(-40 * 86400) // 40 天前
            let recentDate = now.addingTimeInterval(-2 * 86400) // 2 天前

            let itemOrphan = DiagnosticReportItem(
                fileName: "Slack_2026-08-01.ips",
                path: "/Users/test/Library/Logs/DiagnosticReports/Slack_2026-08-01.ips",
                size: 10240,
                creationDate: staleDate,
                ageDays: 40,
                appName: "Slack",
                bundleID: "com.tinyspeck.slackmacgap",
                kind: .crash,
                isOrphan: true,
                isSelected: true
            )
            guard itemOrphan.isOrphan == true else { return false }
            guard itemOrphan.isStale == true else { return false }
            guard itemOrphan.isRecent == false else { return false }
            guard itemOrphan.statusBadgeText.contains("孤儿") else { return false }

            let itemRecent = DiagnosticReportItem(
                fileName: "Xcode_2026-09-18.ips",
                path: "/Users/test/Library/Logs/DiagnosticReports/Xcode_2026-09-18.ips",
                size: 20480,
                creationDate: recentDate,
                ageDays: 2,
                appName: "Xcode",
                bundleID: "com.apple.dt.Xcode",
                kind: .crash,
                isOrphan: false,
                isSelected: false
            )
            guard itemRecent.isOrphan == false else { return false }
            guard itemRecent.isStale == false else { return false }
            guard itemRecent.isRecent == true else { return false }
            guard itemRecent.statusBadgeText.contains("近期") else { return false }

            return true
        }

        check("现代 IPS JSON 与传统 Crash 报告头深度解析 (parseHeaderMetadata)") {
            let scanner = DiagnosticReportScanner.shared

            // 1. 模拟现代 IPS JSON
            let ipsContent = """
            {"app_name":"Figma","timestamp":"2026-09-10 10:00:00.00 +0800","app_version":"116.15","bug_type":"309","name":"Figma"}
            {
              "procName" : "Figma",
              "coalitionName" : "com.figma.Desktop",
              "exception" : {"codes":"0x1","type":"EXC_CRASH","signal":"SIGABRT"},
              "termination" : {"code":6,"namespace":"SIGNAL"}
            }
            """
            var app1 = ""
            var bid1: String?
            var kind1: DiagnosticReportKind = .diagnostics
            var ex1: String?
            scanner.parseHeaderMetadata(headerText: ipsContent, ext: "ips", appName: &app1, bundleID: &bid1, kind: &kind1, exceptionSummary: &ex1)

            guard app1 == "Figma" else { return false }
            guard bid1 == "com.figma.Desktop" else { return false }
            guard kind1 == .crash else { return false }
            guard ex1 == "EXC_CRASH" else { return false }

            // 2. 模拟传统 .crash 纯文本
            let crashContent = """
            Process:               Sketch [4512]
            Path:                  /Applications/Sketch.app/Contents/MacOS/Sketch
            Identifier:            com.bohemiancoding.sketch3
            Exception Type:        EXC_BAD_ACCESS (SIGSEGV)
            Termination Reason:    Namespace SIGNAL, Code 11 Segmentation fault: 11
            """
            var app2 = ""
            var bid2: String?
            var kind2: DiagnosticReportKind = .crash
            var ex2: String?
            scanner.parseHeaderMetadata(headerText: crashContent, ext: "crash", appName: &app2, bundleID: &bid2, kind: &kind2, exceptionSummary: &ex2)

            guard app2 == "Sketch" else { return false }
            guard bid2 == "com.bohemiancoding.sketch3" else { return false }
            guard ex2?.contains("EXC_BAD_ACCESS") == true else { return false }

            return true
        }

        check("孤儿崩溃报告反查与系统官方应用保护 (evaluateOrphanStatus)") {
            let scanner = DiagnosticReportScanner.shared

            // 1. 苹果官方系统应用永远不作为孤儿
            let isAppleOrphan = scanner.evaluateOrphanStatus(
                appName: "Safari",
                bundleID: "com.apple.Safari",
                installedBundles: ["com.apple.Safari", "com.google.Chrome"]
            )
            guard isAppleOrphan == false else { return false }

            // 2. 系统核心守护进程保护
            let isDaemonOrphan = scanner.evaluateOrphanStatus(
                appName: "WindowServer",
                bundleID: nil,
                installedBundles: nil
            )
            guard isDaemonOrphan == false else { return false }

            // 3. 已卸载的第三方应用标记为孤儿
            let isUninstalledOrphan = scanner.evaluateOrphanStatus(
                appName: "OldTool",
                bundleID: "com.unknown.oldtool",
                installedBundles: ["com.apple.Safari", "com.google.Chrome"]
            )
            guard isUninstalledOrphan == true else { return false }

            // 4. 当前已安装的应用不应标记为孤儿
            let isInstalledOrphan = scanner.evaluateOrphanStatus(
                appName: "Google Chrome",
                bundleID: "com.google.Chrome",
                installedBundles: ["com.apple.Safari", "com.google.Chrome"]
            )
            guard isInstalledOrphan == false else { return false }

            return true
        }

        check("卡死、无响应与核心转储类型判定 (DiagnosticReportKind)") {
            let scanner = DiagnosticReportScanner.shared

            // 1. Spin/Hang 日志识别 (bug_type 301)
            let spinIps = "{\"app_name\":\"HeavyApp\",\"bug_type\":\"301\"}\n{\"procName\":\"HeavyApp\"}"
            var app1 = ""
            var bid1: String?
            var kind1: DiagnosticReportKind = .diagnostics
            var ex1: String?
            scanner.parseHeaderMetadata(headerText: spinIps, ext: "ips", appName: &app1, bundleID: &bid1, kind: &kind1, exceptionSummary: &ex1)
            guard kind1 == .spinHang else { return false }

            // 2. 后缀识别：.spin 与 .core
            let testDir = "/tmp/MacCleanTest_DiagKind_" + UUID().uuidString
            try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: testDir) }

            let spinFile = testDir + "/App.spin"
            let coreFile = testDir + "/core.5120.dmp"
            try? "spin data".write(toFile: spinFile, atomically: true, encoding: .utf8)
            try? "core dump data".write(toFile: coreFile, atomically: true, encoding: .utf8)

            let itemSpin = scanner.parseReportFile(at: spinFile)
            let itemCore = scanner.parseReportFile(at: coreFile)

            guard itemSpin?.kind == .spinHang else { return false }
            guard itemCore?.kind == .coreDump else { return false }

            return true
        }

        check("诊断报告安全清理防线与非诊断文件防误删 (cleanReport)") {
            let testDir = "/tmp/MacCleanTest_DiagSafety_" + UUID().uuidString
            try? FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: testDir) }

            let scanner = DiagnosticReportScanner.shared

            // 1. 尝试删除非诊断扩展名（如 .swift, .png）应被底层安全防线直接拦截
            let dangerousFile = testDir + "/MySourceCode.swift"
            try? "let x = 10".write(toFile: dangerousFile, atomically: true, encoding: .utf8)
            let badReport = DiagnosticReportItem(
                fileName: "MySourceCode.swift",
                path: dangerousFile,
                size: 100,
                appName: "Source",
                kind: .crash
            )
            let badRes = scanner.cleanReport(badReport, permanently: true)
            guard badRes.success == false else { return false }
            guard FileManager.default.fileExists(atPath: dangerousFile) == true else { return false }

            // 2. 允许安全删除合法的 .ips 诊断报告
            let validReportPath = testDir + "/AppCrash.ips"
            try? "{\"app_name\":\"Test\"}".write(toFile: validReportPath, atomically: true, encoding: .utf8)
            let goodReport = DiagnosticReportItem(
                fileName: "AppCrash.ips",
                path: validReportPath,
                size: 24,
                appName: "Test",
                kind: .crash
            )
            let goodRes = scanner.cleanReport(goodReport, permanently: true)
            guard goodRes.success == true else { return false }
            guard FileManager.default.fileExists(atPath: validReportPath) == false else { return false }

            return true
        }

        check("ViewInspector 交互自检：DiagnosticReportCard 渲染与批量治理控件") {
            let scanner = DiagnosticReportScanner.shared
            scanner.reports = [
                DiagnosticReportItem(
                    id: "/tmp/fake1.ips",
                    fileName: "TestApp_1.ips",
                    path: "/tmp/fake1.ips",
                    size: 4096,
                    creationDate: Date(),
                    ageDays: 1,
                    appName: "TestApp",
                    bundleID: "com.test.app",
                    kind: .crash,
                    isOrphan: true,
                    isSelected: true
                ),
                DiagnosticReportItem(
                    id: "/tmp/fake2.ips",
                    fileName: "OldApp_2.ips",
                    path: "/tmp/fake2.ips",
                    size: 8192,
                    creationDate: Date().addingTimeInterval(-45 * 86400),
                    ageDays: 45,
                    appName: "OldApp",
                    bundleID: "com.old.app",
                    kind: .spinHang,
                    isOrphan: false,
                    isSelected: false
                )
            ]

            let appState = AppState()
            let card = DiagnosticReportCard(onClose: {})
                .environmentObject(appState)

            // 验证视图可以成功构造且能提取文本
            guard let view = try? card.inspect() else { return false }
            guard (try? view.find(text: "系统崩溃与诊断报告治理透视")) != nil else { return false }
            guard (try? view.find(text: "全部报告")) != nil else { return false }

            return true
        }
    }
}
