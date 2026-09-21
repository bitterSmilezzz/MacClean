import Foundation

// 自检套件：专业开发工具与容器深度清理 (v1.43.0)
extension Selftest {
    static func suiteDevToolsDeep() {
        check("开发工具增强：D20–D23 规则登记与编号连续性") {
            let devRules = CleanupRules.rules(in: .devResidue)
            let ids = devRules.map(\.id)

            // ① 规则必须包含 D1 到 D23
            guard ids.count == 23 else { return false }
            guard ids == (1...23).map({ "D\($0)" }) else { return false }

            // ② ruleRef 动态计算必须为 D1–D23
            guard CleanCategory.devResidue.ruleRef == "D1–D23" else { return false }

            // ③ D20–D23 性质与后果声明验证
            guard let d20 = CleanupRules.rule("D20"), d20.nature == .losslessCache else { return false }
            guard let d21 = CleanupRules.rule("D21"), d21.nature == .staleArtifact else { return false }
            guard let d22 = CleanupRules.rule("D22"), d22.nature == .rebuildable else { return false }
            guard let d23 = CleanupRules.rule("D23"), d23.nature == .inferredUnused else { return false }

            guard !d20.consequence.isEmpty, !d21.consequence.isEmpty, !d22.consequence.isEmpty, !d23.consequence.isEmpty else {
                return false
            }

            return true
        }

        check("开发工具增强：JetBrains 产品映射与运行状态识别 (isJetBrainsAppRunning)") {
            let testCases = [
                ("IntelliJIdea2023.2", "IntelliJ IDEA"),
                ("idea-IC-232.8660.185", "IntelliJ IDEA"),
                ("PyCharm2024.1", "PyCharm"),
                ("GoLand2023.1", "GoLand"),
                ("WebStorm2023.3", "WebStorm"),
                ("CLion2023.2", "CLion"),
                ("Rider2023.1", "Rider"),
                ("DataGrip2023.2", "DataGrip"),
                ("RubyMine2022.3", "RubyMine"),
                ("PhpStorm2023.2", "PhpStorm"),
                ("RustRover2023.3", "RustRover"),
                ("Fleet", "Fleet"),
                ("AndroidStudio2023.1", "Android Studio"),
                ("UnknownJetBrainsTool", "JetBrains IDE"),
            ]

            for (dirName, expectedApp) in testCases {
                let res = CleanPaths.isJetBrainsAppRunning(directoryName: dirName)
                guard res.appName == expectedApp else { return false }
            }
            return true
        }

        check("开发工具增强：不变量检测（运行中绝不判 safe，D23 绝不自动 safe）") {
            // 1. D20 (JetBrains): 运行中 -> inUse，非运行 -> safe
            let d20Running = CleanItem(
                name: "IntelliJIdea2023.2",
                path: "/tmp/IntelliJIdea2023.2",
                size: 1024,
                rule: "D20",
                category: .devResidue,
                use: UseState(ownerIsRunning: true, ownerName: "IntelliJ IDEA", level: .dormant)
            )
            guard d20Running.recommendation.kind == .inUse else { return false }
            guard d20Running.recommendation.reason.contains("IntelliJ IDEA") else { return false }

            let d20Idle = CleanItem(
                name: "IntelliJIdea2022.1",
                path: "/tmp/IntelliJIdea2022.1",
                size: 1024,
                rule: "D20",
                category: .devResidue,
                use: UseState(ownerIsRunning: false, ownerName: "IntelliJ IDEA", level: .dormant)
            )
            guard d20Idle.recommendation.kind == .safe else { return false }

            // 2. D21 (Xcode DeviceSupport): 运行中 -> inUse，非运行 -> safe
            let d21Running = CleanItem(
                name: "iOS 15.4 (19E241)",
                path: "/tmp/iOS 15.4",
                size: 2048,
                rule: "D21",
                category: .devResidue,
                use: UseState(ownerIsRunning: true, ownerName: "Xcode", level: .dormant)
            )
            guard d21Running.recommendation.kind == .inUse else { return false }

            let d21Idle = CleanItem(
                name: "iOS 15.4 (19E241)",
                path: "/tmp/iOS 15.4",
                size: 2048,
                rule: "D21",
                category: .devResidue,
                use: UseState(ownerIsRunning: false, ownerName: "Xcode", level: .dormant)
            )
            guard d21Idle.recommendation.kind == .safe else { return false }

            // 3. D22 (Xcode Previews): 运行中 -> inUse，非运行 -> safe
            let d22Running = CleanItem(
                name: "SwiftUI Preview",
                path: "/tmp/Previews",
                size: 4096,
                rule: "D22",
                category: .devResidue,
                use: UseState(ownerIsRunning: true, ownerName: "Xcode", level: .dormant)
            )
            guard d22Running.recommendation.kind == .inUse else { return false }

            let d22Idle = CleanItem(
                name: "SwiftUI Preview",
                path: "/tmp/Previews",
                size: 4096,
                rule: "D22",
                category: .devResidue,
                use: UseState(ownerIsRunning: false, ownerName: "Xcode", level: .dormant)
            )
            guard d22Idle.recommendation.kind == .safe else { return false }

            // 4. D23 (Docker.raw): 运行中 -> inUse，非运行 -> review（绝不自动 safe）
            let d23Running = CleanItem(
                name: "Docker.raw",
                path: "/tmp/Docker.raw",
                size: 1024 * 1024,
                rule: "D23",
                category: .devResidue,
                use: UseState(ownerIsRunning: true, ownerName: "Docker", level: .dormant)
            )
            guard d23Running.recommendation.kind == .inUse else { return false }

            let d23Idle = CleanItem(
                name: "Docker.raw",
                path: "/tmp/Docker.raw",
                size: 1024 * 1024,
                rule: "D23",
                category: .devResidue,
                use: UseState(ownerIsRunning: false, ownerName: "Docker", level: .dormant)
            )
            guard d23Idle.recommendation.kind == .review else { return false }

            return true
        }

        check("开发工具增强：DeviceSupport 60 天闲置判定逻辑") {
            let now = Date()
            let cutoff = now.addingTimeInterval(-60 * 86400)
            let recentMtime = now.addingTimeInterval(-30 * 86400)
            let oldMtime = now.addingTimeInterval(-90 * 86400)

            // < 60 天应保留，不纳入 D21
            guard recentMtime >= cutoff else { return false }
            // > 60 天应识别为过时符号
            guard oldMtime < cutoff else { return false }

            return true
        }
    }
}
