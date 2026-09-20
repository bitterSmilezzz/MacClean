import Foundation
import SwiftUI
import ViewInspector

// 自检套件：开发工程构建产物深度智能排查与按项目治理 (v1.57.0)
extension Selftest {
    static func suiteDevProjectDeep() {
        check("DevProject 数据模型与状态判定 (DevProjectModels)") {
            // 1. 技术栈枚举完整性
            let allTypes = DevProjectType.allCases
            guard allTypes.count >= 7 else { return false }
            guard DevProjectType.xcode.iconName == "hammer.fill" else { return false }
            guard DevProjectType.rust.iconName == "gearshape.2.fill" else { return false }
            guard DevProjectType.swiftpm.iconName == "swift" else { return false }

            // 2. 产物白名单名称
            let allowed = DevArtifactKind.allowedDirNames
            guard allowed.contains("target") else { return false }
            guard allowed.contains(".build") else { return false }
            guard allowed.contains("node_modules") else { return false }
            guard allowed.contains(".next") else { return false }
            guard allowed.contains("build") else { return false }
            guard allowed.contains(".venv") else { return false }

            // 3. 活跃度判定：<=7 天活跃 vs >=30 天陈旧 vs 孤儿
            let now = Date()
            let activeProject = DevProject(
                name: "ActiveApp",
                path: "/Users/dev/ActiveApp",
                types: [.swiftpm],
                lastModified: now.addingTimeInterval(-2 * 86400),
                isOrphan: false,
                artifacts: [
                    DevProjectArtifact(name: ".build", path: "/Users/dev/ActiveApp/.build", size: 1024 * 1024 * 100, kind: .swiftpmBuild, isSelected: false)
                ]
            )
            guard activeProject.isActive == true else { return false }
            guard activeProject.isStale == false else { return false }
            guard activeProject.daysInactive == 2 else { return false }

            let staleProject = DevProject(
                name: "OldApp",
                path: "/Users/dev/OldApp",
                types: [.rust],
                lastModified: now.addingTimeInterval(-45 * 86400),
                isOrphan: false,
                artifacts: [
                    DevProjectArtifact(name: "target", path: "/Users/dev/OldApp/target", size: 1024 * 1024 * 500, kind: .rustTarget, isSelected: true)
                ]
            )
            guard staleProject.isActive == false else { return false }
            guard staleProject.isStale == true else { return false }
            guard staleProject.daysInactive == 45 else { return false }

            let orphanProject = DevProject(
                name: "DeletedApp",
                path: "/Users/dev/NonExistent",
                types: [.xcode],
                lastModified: now.addingTimeInterval(-100 * 86400),
                isOrphan: true,
                artifacts: [
                    DevProjectArtifact(name: "DerivedData", path: "/DerivedData/DeletedApp", size: 1024 * 1024 * 200, kind: .derivedData, isSelected: true)
                ]
            )
            guard orphanProject.isOrphan == true else { return false }
            guard orphanProject.isActive == false else { return false }
            guard orphanProject.isStale == true else { return false }

            // 4. 体积与全选状态
            guard activeProject.totalArtifactSize == 1024 * 1024 * 100 else { return false }
            guard activeProject.selectedArtifactSize == 0 else { return false }
            guard staleProject.isAllSelected == true else { return false }
            guard staleProject.isPartiallySelected == false else { return false }

            return true
        }

        check("Xcode DerivedData info.plist 解析与源工程反查") {
            let tempDir = NSTemporaryDirectory() + "MacCleanTest_DerivedData_" + UUID().uuidString
            let projSubdir = tempDir + "/MySampleApp-abcedfghijklmnop"
            try? FileManager.default.createDirectory(atPath: projSubdir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempDir) }

            // 构造真实的 info.plist
            let infoPlistPath = projSubdir + "/info.plist"
            let dummyWorkspace = NSTemporaryDirectory() + "MySampleApp.xcodeproj"
            try? FileManager.default.createDirectory(atPath: dummyWorkspace, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dummyWorkspace) }

            let plistDict: [String: Any] = [
                "WorkspacePath": dummyWorkspace,
                "LastAccessedDate": Date().addingTimeInterval(-10 * 86400)
            ]
            let plistData = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0)
            try? plistData?.write(to: URL(fileURLWithPath: infoPlistPath))

            // 写入虚拟产物文件使体积 > 0
            let dummyBuildFile = projSubdir + "/build_output.bin"
            let dummyData = Data(repeating: 0x55, count: 4096)
            try? dummyData.write(to: URL(fileURLWithPath: dummyBuildFile))

            // 验证读取字典并能反查工程名与路径
            let dict = NSDictionary(contentsOfFile: infoPlistPath)
            guard let ws = dict?["WorkspacePath"] as? String, ws == dummyWorkspace else { return false }
            guard let lastAccess = dict?["LastAccessedDate"] as? Date else { return false }
            guard Date().timeIntervalSince(lastAccess) > 8 * 86400 else { return false }

            return true
        }

        check("工作区多语言工程根目录特征与构建产物探测 (scanWorkspaceRoots)") {
            let tempRoot = "/tmp/MacCleanTest_Workspace_" + UUID().uuidString
            try? FileManager.default.createDirectory(atPath: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempRoot) }

            // 1. 模拟 Rust 工程
            let rustDir = tempRoot + "/RustApp"
            let rustTarget = rustDir + "/target"
            try? FileManager.default.createDirectory(atPath: rustTarget, withIntermediateDirectories: true)
            try? "fn main() {}".write(toFile: rustDir + "/Cargo.toml", atomically: true, encoding: .utf8)
            try? Data(count: 2048).write(to: URL(fileURLWithPath: rustTarget + "/app.bin"))

            // 2. 模拟 SwiftPM 工程
            let swiftDir = tempRoot + "/SwiftTool"
            let swiftBuild = swiftDir + "/.build"
            try? FileManager.default.createDirectory(atPath: swiftBuild, withIntermediateDirectories: true)
            try? "// swift-tools-version: 5.9".write(toFile: swiftDir + "/Package.swift", atomically: true, encoding: .utf8)
            try? Data(count: 4096).write(to: URL(fileURLWithPath: swiftBuild + "/debug.bin"))

            // 3. 模拟 Node 前端工程
            let nodeDir = tempRoot + "/WebProject"
            let nodeModules = nodeDir + "/node_modules"
            let nextCache = nodeDir + "/.next"
            try? FileManager.default.createDirectory(atPath: nodeModules, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: nextCache, withIntermediateDirectories: true)
            try? "{\"name\": \"web\"}".write(toFile: nodeDir + "/package.json", atomically: true, encoding: .utf8)
            try? Data(count: 8192).write(to: URL(fileURLWithPath: nodeModules + "/pkg.js"))
            try? Data(count: 1024).write(to: URL(fileURLWithPath: nextCache + "/cache.bin"))

            let scanner = DevProjectScanner.shared
            let discovered = scanner.scanWorkspaceRoots([tempRoot])

            guard discovered.count == 3 else { return false }

            guard let rustProj = discovered.first(where: { $0.name == "RustApp" }) else { return false }
            guard rustProj.types.contains(.rust) else { return false }
            guard rustProj.artifacts.contains(where: { $0.kind == .rustTarget }) else { return false }

            guard let swiftProj = discovered.first(where: { $0.name == "SwiftTool" }) else { return false }
            guard swiftProj.types.contains(.swiftpm) else { return false }
            guard swiftProj.artifacts.contains(where: { $0.kind == .swiftpmBuild }) else { return false }

            guard let webProj = discovered.first(where: { $0.name == "WebProject" }) else { return false }
            guard webProj.types.contains(.node) else { return false }
            guard webProj.artifacts.contains(where: { $0.kind == .nodeModules }) else { return false }
            guard webProj.artifacts.contains(where: { $0.kind == .frontendCache }) else { return false }

            return true
        }

        check("构建产物安全清理防线与非产物保护 (cleanArtifact)") {
            let tempDir = "/tmp/MacCleanTest_Safety_" + UUID().uuidString
            try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tempDir) }

            let scanner = DevProjectScanner.shared

            // 1. 企图清理源码文件应被拒绝
            let sourceFile = tempDir + "/main.swift"
            try? "print(\"hello\")".write(toFile: sourceFile, atomically: true, encoding: .utf8)
            let badArtifact = DevProjectArtifact(
                name: "main.swift",
                path: sourceFile,
                size: 100,
                kind: .rustTarget
            )
            let badRes = scanner.cleanArtifact(badArtifact, permanently: true)
            guard badRes.success == false else { return false }
            guard FileManager.default.fileExists(atPath: sourceFile) == true else { return false }

            // 2. 清理合法的 target 目录应被允许
            let validTarget = tempDir + "/target"
            try? FileManager.default.createDirectory(atPath: validTarget, withIntermediateDirectories: true)
            try? "dummy".write(toFile: validTarget + "/dummy.txt", atomically: true, encoding: .utf8)

            let goodArtifact = DevProjectArtifact(
                name: "target",
                path: validTarget,
                size: 100,
                kind: .rustTarget
            )
            let goodRes = scanner.cleanArtifact(goodArtifact, permanently: true)
            guard goodRes.success == true else { return false }
            guard FileManager.default.fileExists(atPath: validTarget) == false else { return false }

            return true
        }

        check("开发残留分类二级细分匹配逻辑 (DevResidueFilterKind)") {
            let itemD1 = CleanItem(name: "DerivedData", path: "/DerivedData", size: 1000, rule: "D1", category: .devResidue)
            let itemD4 = CleanItem(name: "npm cache", path: "/.npm", size: 2000, rule: "D4", category: .devResidue)
            let itemD20 = CleanItem(name: "JetBrains", path: "/JetBrains", size: 3000, rule: "D20", category: .devResidue)
            let itemD17 = CleanItem(name: "Docker buildx", path: "/Docker", size: 4000, rule: "D17", category: .devResidue)

            guard DevResidueFilterKind.all.matches(item: itemD1) == true else { return false }
            guard DevResidueFilterKind.buildArtifacts.matches(item: itemD1) == true else { return false }
            guard DevResidueFilterKind.buildArtifacts.matches(item: itemD4) == false else { return false }

            guard DevResidueFilterKind.packageCaches.matches(item: itemD4) == true else { return false }
            guard DevResidueFilterKind.packageCaches.matches(item: itemD20) == false else { return false }

            guard DevResidueFilterKind.ideCaches.matches(item: itemD20) == true else { return false }
            guard DevResidueFilterKind.environments.matches(item: itemD17) == true else { return false }

            return true
        }

        check("ViewInspector 交互自检：DevProjectInspectorCard 渲染与批量治理控件") {
            let app = AppState()
            var closed = false
            let card = DevProjectInspectorCard(onClose: { closed = true })
                .environmentObject(app)

            // 1. 查找重新扫描按钮
            let rescanBtn = try? card.inspect().find(viewWithAccessibilityIdentifier: "rescanDevProjectsButton")
            guard rescanBtn != nil else { return false }

            // 2. 查找智能勾选陈旧项按钮
            let smartBtn = try? card.inspect().find(viewWithAccessibilityIdentifier: "smartSelectStaleDevProjectsButton")
            guard smartBtn != nil else { return false }

            // 3. 查找一键批量清理按钮
            let cleanBtn = try? card.inspect().find(viewWithAccessibilityIdentifier: "cleanAllSelectedDevArtifactsButton")
            guard cleanBtn != nil else { return false }

            // 4. 查找关闭按钮并触发点击
            let closeBtn = try? card.inspect().find(viewWithAccessibilityIdentifier: "closeDevProjectCardButton")
            guard closeBtn != nil else { return false }
            try? closeBtn?.button().tap()
            guard closed == true else { return false }

            return true
        }
    }
}
