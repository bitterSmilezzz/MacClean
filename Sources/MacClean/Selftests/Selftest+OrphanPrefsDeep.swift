import Foundation

// 自检套件：偏好碎片与系统垃圾多角度扫描增强 (v1.44.0)
extension Selftest {
    static func suiteOrphanPrefsDeep() {
        check("偏好碎片与系统垃圾增强：A4/A5 与 L7 规则登记与编号连续性") {
            let appRules = CleanupRules.rules(in: .appResidue)
            let appIds = appRules.map(\.id)
            guard appIds == (1...5).map({ "A\($0)" }) else { return false }
            guard CleanCategory.appResidue.ruleRef == "A1–A5" else { return false }

            let logRules = CleanupRules.rules(in: .logsAndTemp)
            let logIds = logRules.map(\.id)
            guard logIds == (1...7).map({ "L\($0)" }) else { return false }
            guard CleanCategory.logsAndTemp.ruleRef == "L1–L7" else { return false }

            guard let a4 = CleanupRules.rule("A4"), a4.nature == .orphanedResidue else { return false }
            guard let a5 = CleanupRules.rule("A5"), a5.nature == .orphanedResidue else { return false }
            guard let l7 = CleanupRules.rule("L7"), l7.nature == .staleArtifact else { return false }

            guard !a4.consequence.isEmpty, !a5.consequence.isEmpty, !l7.consequence.isEmpty else {
                return false
            }
            return true
        }

        check("偏好碎片与系统垃圾增强：ByHost UUID 剥离与识别 (extractBundleFromByHostFilename)") {
            let testCases: [(String, String?)] = [
                ("com.apple.loginwindow.00000000-0000-1000-8000-0017F2039234.plist", "com.apple.loginwindow"),
                ("com.google.Chrome.12345678-ABCD-EF01-2345-6789ABCDEF01.plist", "com.google.Chrome"),
                ("com.tencent.xinWeChat.0123456789abcdef0123456789abcdef.plist", "com.tencent.xinWeChat"),
                ("org.mozilla.firefox.A1B2C3D4-E5F6-7890-ABCD-EF1234567890.plist", "org.mozilla.firefox"),
                ("normal_file_without_uuid.plist", nil),
                ("com.example.app.plist", nil),
                ("not_a_plist.txt", nil)
            ]

            for (filename, expectedBundle) in testCases {
                let actual = CleanPaths.extractBundleFromByHostFilename(filename)
                guard actual == expectedBundle else {
                    print("      ByHost UUID 解析不符：\(filename) => \(String(describing: actual)), 预期 \(String(describing: expectedBundle))")
                    return false
                }
            }
            return true
        }

        check("偏好碎片与系统垃圾增强：CleanPaths 路径定义有效性") {
            guard CleanPaths.crashReporter.contains("Application Support/CrashReporter") else { return false }
            guard CleanPaths.preferencesByHost.contains("Preferences/ByHost") else { return false }
            guard CleanPaths.savedApplicationState.contains("Saved Application State") else { return false }
            return true
        }

        check("偏好碎片与系统垃圾增强：AppResidueFilterKind 细分匹配") {
            let itemA1 = CleanItem(name: "TestA1", path: "/Users/test/Library/Application Support/Foo", size: 100, rule: "A1", category: .appResidue)
            let itemA2 = CleanItem(name: "TestA2", path: "/Users/test/Library/Preferences/com.foo.plist", size: 100, rule: "A2", category: .appResidue)
            let itemA3 = CleanItem(name: "TestA3", path: "/Users/test/Library/LaunchAgents/com.foo.agent.plist", size: 100, rule: "A3", category: .appResidue)
            let itemA4 = CleanItem(name: "TestA4", path: "/Users/test/Library/Saved Application State/com.foo.savedState", size: 100, rule: "A4", category: .appResidue)
            let itemA5 = CleanItem(name: "TestA5", path: "/Users/test/Library/Preferences/ByHost/com.foo.UUID.plist", size: 100, rule: "A5", category: .appResidue)

            guard AppResidueFilterKind.all.matches(item: itemA1) && AppResidueFilterKind.all.matches(item: itemA4) else { return false }
            guard AppResidueFilterKind.appSupport.matches(item: itemA1) && !AppResidueFilterKind.appSupport.matches(item: itemA2) else { return false }
            guard AppResidueFilterKind.preferences.matches(item: itemA2) && AppResidueFilterKind.preferences.matches(item: itemA5) else { return false }
            guard !AppResidueFilterKind.preferences.matches(item: itemA1) && !AppResidueFilterKind.preferences.matches(item: itemA4) else { return false }
            guard AppResidueFilterKind.launchAgents.matches(item: itemA3) && !AppResidueFilterKind.launchAgents.matches(item: itemA4) else { return false }
            guard AppResidueFilterKind.savedState.matches(item: itemA4) && !AppResidueFilterKind.savedState.matches(item: itemA1) else { return false }

            return true
        }

        check("偏好碎片与系统垃圾增强：LogsFilterKind 细分匹配") {
            let itemL1 = CleanItem(name: "L1.log", path: "/tmp/l1.log", size: 100, rule: "L1", category: .logsAndTemp)
            let itemL2 = CleanItem(name: "L2.diag", path: "/tmp/l2.diag", size: 100, rule: "L2", category: .logsAndTemp)
            let itemL3 = CleanItem(name: "L3.tmp", path: "/tmp/l3.tmp", size: 100, rule: "L3", category: .logsAndTemp)
            let itemL4 = CleanItem(name: "L4.tmp", path: "/tmp/l4.tmp", size: 100, rule: "L4", category: .logsAndTemp)
            let itemL5 = CleanItem(name: "L5.log", path: "/tmp/l5.log", size: 100, rule: "L5", category: .logsAndTemp)
            let itemL6 = CleanItem(name: "ShipIt", path: "/tmp/ShipIt", size: 100, rule: "L6", category: .logsAndTemp)
            let itemL7 = CleanItem(name: "L7.crash", path: "/tmp/l7.crash", size: 100, rule: "L7", category: .logsAndTemp)

            guard LogsFilterKind.all.matches(item: itemL1) && LogsFilterKind.all.matches(item: itemL7) else { return false }
            guard LogsFilterKind.logs.matches(item: itemL1) && LogsFilterKind.logs.matches(item: itemL5) else { return false }
            guard !LogsFilterKind.logs.matches(item: itemL2) && !LogsFilterKind.logs.matches(item: itemL7) else { return false }
            guard LogsFilterKind.diagnostics.matches(item: itemL2) && LogsFilterKind.diagnostics.matches(item: itemL7) else { return false }
            guard !LogsFilterKind.diagnostics.matches(item: itemL3) else { return false }
            guard LogsFilterKind.temporary.matches(item: itemL3) && LogsFilterKind.temporary.matches(item: itemL4) else { return false }
            guard LogsFilterKind.shipIt.matches(item: itemL6) && !LogsFilterKind.shipIt.matches(item: itemL1) else { return false }

            return true
        }

        check("偏好碎片与系统垃圾增强：不变量检测（运行中绝不判 safe，A4/A5 孤儿判定）") {
            // A4 窗口状态：如果所属 app 运行中 -> safe 绝不成立
            let a4Running = CleanItem(
                name: "com.example.running.savedState",
                path: "/tmp/com.example.running.savedState",
                size: 2048,
                rule: "A4",
                category: .appResidue,
                use: UseState(ownerIsRunning: true, ownerName: "ExampleApp", lastUsed: nil, level: .active)
            )
            guard a4Running.recommendation.kind != .safe else { return false }

            // A5 ByHost 偏好：已卸载应用的偏好残留属于 orphanedResidue，推荐判定为 review（需确认，防止用户误删配置）
            let a5Orphan = CleanItem(
                name: "com.example.uninstalled.UUID.plist",
                path: "/tmp/com.example.uninstalled.UUID.plist",
                size: 1024,
                rule: "A5",
                category: .appResidue,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: nil, level: .unknown)
            )
            guard a5Orphan.recommendation.kind == .review else { return false }

            // L7 CrashReporter：历史崩溃日志属 staleArtifact，未运行 -> safe
            let l7Old = CleanItem(
                name: "OldApp_2024-01-01.crash",
                path: "/tmp/CrashReporter/OldApp_2024-01-01.crash",
                size: 4096,
                rule: "L7",
                category: .logsAndTemp,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: nil, level: .unknown)
            )
            // v2 步骤 3 起 L7 是 T2：崩溃报告是用户向 Apple/开发者取证的唯一凭据，
            // 属不可重建的历史事实，不再报「可清理」。
            guard l7Old.recommendation.kind == .review else { return false }

            return true
        }
    }
}
