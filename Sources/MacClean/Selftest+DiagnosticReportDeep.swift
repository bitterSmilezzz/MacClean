import Foundation
import Darwin
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

        // v1.74.0 安全加固自检 ------------------------------------------------

        // 7. 权限读不到的报告根 → 报"结果不完整"，绝不报"没有异常报告"
        check("DiagnosticReport: 报告目录读不到时降级为结果不完整") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_DiagDenied_" + UUID().uuidString
            let locked = base + "/GlobalReports"
            let readable = base + "/UserReports"
            try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: readable, withIntermediateDirectories: true)
            try? "{\"app_name\":\"Reader\"}".write(toFile: readable + "/Reader_2026.ips",
                                                  atomically: true, encoding: .utf8)
            defer {
                chmod(locked, 0o755)
                try? fm.removeItem(atPath: base)
            }
            guard chmod(locked, 0o000) == 0 else { return true }   // root 跑自检时造不出读不到
            guard FileSystem.isPermissionDenied(locked) else { return false }

            let scanner = DiagnosticReportScanner.shared
            // ① 读不到的根：0 项 + 一条权限问题
            let denied = scanner.scanReport(dirs: [locked], inventory: diagSelftestInventory())
            guard denied.items.isEmpty else { return false }
            guard denied.issues.count == 1, denied.issues.first?.kind == .permissionDenied else {
                print("    ❌ 权限不足的目录没有留下证据源问题记录")
                return false
            }
            let banner = GovernanceEvidenceIssue.incompleteBanner(denied.issues)
            guard banner.contains("不完整"), banner.contains("权限不足"),
                  banner.contains("不代表系统干净") else {
                print("    ❌ 不完整提示没有如实说明：<\(banner)>")
                return false
            }

            // ② 读得到的根：结果完整，说明确实是"权限"造成的差异
            let ok = scanner.scanReport(dirs: [readable], inventory: diagSelftestInventory())
            guard ok.issues.isEmpty, ok.items.count == 1 else {
                print("    ❌ 读得到的目录被误报为不完整")
                return false
            }
            return true
        }

        // 8. 已安装清单不完整时绝不判孤儿、绝不默选（「读不到」≠「可以删」）
        check("DiagnosticReport: 清单不完整时降级为需确认且不默选不执行删除") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_DiagOrphan_" + UUID().uuidString
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            let reportPath = base + "/GhostApp_2026-09-01.ips"
            try? "{\"app_name\":\"GhostApp\"}\n{ \"procName\" : \"GhostApp\", \"coalitionName\" : \"com.ghost.app\" }"
                .write(toFile: reportPath, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: base) }

            let scanner = DiagnosticReportScanner.shared
            // 清单里有根目录读不到 → 不能再据"不在清单里"判宿主已卸载
            let incomplete = AppInventory.Snapshot(
                bundleIDs: ["com.apple.safari"], bundlePrefixes: ["com.apple"],
                normalizedNames: [], executableNames: [], runningBundleIDs: [],
                appPaths: [], unreadableRoots: ["/Applications"])
            guard let unsure = scanner.parseReport(at: reportPath, inventory: incomplete) else { return false }
            guard unsure.needsConfirmation, !unsure.isOrphan, !unsure.isSelected else {
                print("    ❌ 清单不完整时仍把崩溃判成孤儿并默选")
                return false
            }
            guard unsure.note?.contains("确认") == true else { return false }
            // 需确认项在网关里也删不掉
            let blocked = scanner.cleanOutcome([unsure], permanently: true, journal: .none)
            guard blocked.cleanedCount == 0, blocked.errorCount > 0 else { return false }
            guard blocked.rejected.first?.reason == .blockedByBaseGate else { return false }
            guard FileManager.default.fileExists(atPath: reportPath) else {
                print("    ❌ 需确认的诊断报告被删除了")
                return false
            }

            // 清单完整且确实不匹配 → 才允许判孤儿并默选
            guard let orphan = scanner.parseReport(at: reportPath, inventory: diagSelftestInventory())
            else { return false }
            guard orphan.isOrphan, !orphan.needsConfirmation, orphan.isSelected else { return false }
            // com.apple.* 永不判孤儿
            guard scanner.evaluateOrphan(appName: "Safari", bundleID: "com.apple.Safari",
                                        inventory: incomplete).isOrphan == false else { return false }
            // 正在运行的 App 也算已安装
            let withRunning = AppInventory.Snapshot(
                bundleIDs: ["com.ghost.app"], bundlePrefixes: ["com.ghost"], normalizedNames: [],
                executableNames: [], runningBundleIDs: ["com.ghost.app"], appPaths: [],
                unreadableRoots: ["/Applications"])
            guard scanner.evaluateOrphan(appName: "GhostApp", bundleID: "com.ghost.app",
                                        inventory: withRunning).isOrphan == false else { return false }
            return true
        }

        // 9. 全局报告走 .diagnosticReportsGlobal 域：越界与无权限都删不动
        check("DiagnosticReport: 全局报告走治理域且不自建字符串护栏") {
            let domain = GovernanceDomain.byID["diagnostics.globalReports"]
            guard let domain, domain.root == DiagnosticReportScanner.globalReportsDir else { return false }
            guard domain.minDepthBelowRoot == 1 else { return false }
            // 禁删域根自身（整棵报告目录）
            guard case .rejected(let rootReason) = FileSystem.governanceVerdict(domain.root, domain: domain),
                  rootReason == .tooShallowForDomain else { return false }
            // 真机实测该位置普通用户无权 unlink
            guard FileSystem.canUnlink(DiagnosticReportScanner.globalReportsDir) == false else {
                return true   // 以 root 或特殊授权跑的环境，跳过这条而不是误报
            }
            // 全局条目必须映射到该域
            let globalItem = DiagnosticReportItem(
                fileName: "x.ips", path: "/Library/Logs/DiagnosticReports/x.ips", size: 1,
                appName: "X", isGlobalScope: true)
            guard globalItem.governanceDomain == .diagnosticReportsGlobal else { return false }
            // 用户域条目走主目录护栏（domain == nil）
            let userItem = DiagnosticReportItem(
                fileName: "y.ips", path: CleanPaths.expand("~/Library/Logs/DiagnosticReports/y.ips"),
                size: 1, appName: "Y")
            guard userItem.governanceDomain == nil else { return false }
            // 把 /tmp fixture 伪造成"全局条目"：域判定必须直接拒（不认调用方自报的字符串前缀）
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_DiagDomain_" + UUID().uuidString
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            let fake = base + "/Fake_2026.ips"
            try? "{\"app_name\":\"Fake\"}".write(toFile: fake, atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(atPath: base) }
            let forged = DiagnosticReportItem(fileName: "Fake_2026.ips", path: fake, size: 4,
                                             appName: "Fake", isGlobalScope: true)
            let res = DiagnosticReportScanner.shared.cleanOutcome([forged], permanently: true, journal: .none)
            guard res.cleanedCount == 0, res.errorCount > 0 else { return false }
            guard res.rejected.first?.reason == .outsideDomain else { return false }
            guard fm.fileExists(atPath: fake) else { return false }
            return true
        }

        // 10. 白名单 / G6 硬排除 / 非诊断产物 / 越界路径一律被拒且文件仍在
        check("DiagnosticReport: 白名单与硬排除及非诊断产物必被拒") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_DiagWL_" + UUID().uuidString
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: base) }
            let scanner = DiagnosticReportScanner.shared
            let complete = diagSelftestInventory()

            // ① 用户白名单里的 .ips
            let wlPath = base + "/Whitelisted_2026.ips"
            try? "{\"app_name\":\"WL\"}".write(toFile: wlPath, atomically: true, encoding: .utf8)
            let savedRules = WhitelistManager.shared.rules
            defer { WhitelistManager.shared.rules = savedRules }
            WhitelistManager.shared.removeAllRules()
            WhitelistManager.shared.addPathRule(wlPath, comment: "自检保护")
            let wlItem = DiagnosticReportItem(fileName: "Whitelisted_2026.ips", path: wlPath,
                                             size: 1, appName: "WL")
            let wl = scanner.cleanOutcome([wlItem], permanently: true, journal: .none)
            guard wl.cleanedCount == 0, wl.errorCount > 0 else { return false }
            guard wl.rejected.first?.reason == .userWhitelisted else { return false }
            guard fm.fileExists(atPath: wlPath) else {
                print("    ❌ 白名单里的诊断报告被删除")
                return false
            }

            // ② G6：藏在照片图库里的 .ips（自管理容器，一个字节都不许碰）
            let insideLibrary = CleanPaths.expand("~/Pictures/Photos Library.photoslibrary/crash.ips")
            let g6 = scanner.cleanOutcome(
                [DiagnosticReportItem(fileName: "crash.ips", path: insideLibrary, size: 1, appName: "C")],
                permanently: true, journal: .none)
            guard g6.cleanedCount == 0, g6.errorCount > 0 else { return false }
            guard g6.rejected.first?.reason == .hardExcluded else { return false }

            // ③ 非诊断扩展名与目录形态
            let source = base + "/MyCode.swift"
            try? "let x = 1".write(toFile: source, atomically: true, encoding: .utf8)
            let swift = scanner.cleanOutcome(
                [DiagnosticReportItem(fileName: "MyCode.swift", path: source, size: 1, appName: "S")],
                permanently: true, journal: .none)
            guard swift.cleanedCount == 0, swift.errorCount > 0 else { return false }
            guard swift.rejected.first?.reason == .notDeletable else { return false }
            guard fm.fileExists(atPath: source) else { return false }

            let dirShape = base + "/FakeDir.ips"
            try? fm.createDirectory(atPath: dirShape, withIntermediateDirectories: true)
            let dirRes = scanner.cleanOutcome(
                [DiagnosticReportItem(fileName: "FakeDir.ips", path: dirShape, size: 1, appName: "D")],
                permanently: true, journal: .none)
            guard dirRes.cleanedCount == 0, dirRes.errorCount > 0 else { return false }
            guard fm.fileExists(atPath: dirShape) else {
                print("    ❌ 诊断目录被整个删掉了")
                return false
            }

            // ④ 授权根之外（主目录内的普通文件）
            let outside = CleanPaths.expand("~/Documents/selftest-evidence.ips")
            let outRes = scanner.cleanOutcome(
                [DiagnosticReportItem(fileName: "selftest-evidence.ips", path: outside, size: 1, appName: "O")],
                permanently: true, journal: .none)
            guard outRes.cleanedCount == 0, outRes.errorCount > 0 else { return false }
            guard outRes.rejected.first?.reason == .missing else { return false }
            return true
        }

        // 11. 删除失败一个字节都不许记（旧实现读不到体积也照样上报成功）
        check("DiagnosticReport: 删除失败不计入成功数与释放量") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_DiagFail_" + UUID().uuidString
            try? fm.createDirectory(atPath: base, withIntermediateDirectories: true)
            let reportPath = base + "/Stuck_2026.ips"
            try? "{\"app_name\":\"Stuck\"}".write(toFile: reportPath, atomically: true, encoding: .utf8)
            defer {
                lchflags(reportPath, 0)
                try? fm.removeItem(atPath: base)
            }
            guard lchflags(reportPath, UInt32(UF_IMMUTABLE)) == 0 else { return true }

            let item = DiagnosticReportItem(fileName: "Stuck_2026.ips", path: reportPath,
                                           size: 999_999, appName: "Stuck", isSelected: true)
            let outcome = DiagnosticReportScanner.shared.cleanOutcome([item], permanently: true,
                                                                     journal: .none)
            guard outcome.cleanedCount == 0, outcome.freedBytes == 0 else {
                print("    ❌ 删除失败却记了 \(outcome.cleanedCount)/\(outcome.freedBytes)")
                return false
            }
            guard outcome.errorCount > 0, outcome.failed.count == 1 else { return false }
            let single = DiagnosticReportScanner.shared.cleanReport(item, permanently: true)
            guard single.success == false, single.freedBytes == 0 else { return false }
            let batch = DiagnosticReportScanner.shared.cleanReports([item], permanently: true)
            guard batch.successCount == 0, batch.freedBytes == 0 else { return false }
            guard fm.fileExists(atPath: reportPath) else { return false }
            return true
        }
    }
}

/// 自检用的"完整可信"已安装清单：不注入的话，孤儿判定会随本机装了哪些 App 翻转。
private func diagSelftestInventory() -> AppInventory.Snapshot {
    AppInventory.Snapshot(
        bundleIDs: ["com.apple.safari"], bundlePrefixes: ["com.apple"],
        normalizedNames: [], executableNames: [], runningBundleIDs: [],
        appPaths: [], unreadableRoots: [])
}
