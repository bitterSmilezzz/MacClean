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

        // MARK: 删除必须经统一网关（v1.73 安全收敛）

        func devFixture(_ tag: String) -> String {
            let dir = "/private/tmp/macclean_dev_\(tag)_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return dir
        }
        func devArtifact(_ name: String, _ path: String, _ kind: DevArtifactKind = .rustTarget) -> DevProjectArtifact {
            DevProjectArtifact(name: name, path: path, size: 0, kind: kind)
        }

        check("构建产物清理：非产物/同名文件/伪 DerivedData 一律拦下，合法产物按实测计") {
            let fm = FileManager.default
            let root = devFixture("policy")
            defer { try? fm.removeItem(atPath: root) }

            // 1. 源码文件应被拒绝
            let sourceFile = root + "/main.swift"
            try? "print(\"hello\")".write(toFile: sourceFile, atomically: true, encoding: .utf8)
            // 2. 与产物同名但其实是**文件**（`build`、`dist` 都可能是脚本文件名）
            let fileNamedBuild = root + "/build"
            try? "#!/bin/sh".write(toFile: fileNamedBuild, atomically: true, encoding: .utf8)
            // 3. 工程里一个恰好在 `DerivedData/` 下的目录：旧实现只看
            //    `path.contains("/DerivedData/")`，这种也放行了
            try? fm.createDirectory(atPath: root + "/DerivedData/junk", withIntermediateDirectories: true)
            try? "keepme".write(toFile: root + "/DerivedData/junk/notes.txt", atomically: true, encoding: .utf8)
            // 4. 合法产物目录
            let validTarget = root + "/target"
            try? fm.createDirectory(atPath: validTarget, withIntermediateDirectories: true)
            try? Data(repeating: 0x41, count: 6000).write(to: URL(fileURLWithPath: validTarget + "/a.o"))
            let expectedSize = FileSystem.size(at: validTarget)

            let res = DevProjectScanner.shared.cleanOutcome([
                devArtifact("main.swift", sourceFile),
                devArtifact("build", fileNamedBuild, .generalBuild),
                devArtifact("junk", root + "/DerivedData/junk", .derivedData),
                devArtifact("target", validTarget),
            ], permanently: true, journal: .none)

            guard res.cleanedCount == 1, res.failed.isEmpty else { return false }
            guard fm.fileExists(atPath: sourceFile), fm.fileExists(atPath: fileNamedBuild),
                  fm.fileExists(atPath: root + "/DerivedData/junk/notes.txt") else { return false }
            guard !fm.fileExists(atPath: validTarget) else { return false }
            // 记账诚实：只有被删那一项的实测体积进账
            guard res.freedBytes == expectedSize, expectedSize > 0 else { return false }
            // 三项拦截都必须带上可展示的原因，不能静默吞掉
            guard res.rejected.count == 3, res.rejected.allSatisfy({ !$0.message.isEmpty }) else { return false }
            return res.rejected.contains { $0.path == fileNamedBuild }
                && res.rejected.contains { $0.path == root + "/DerivedData/junk" }
        }

        check("构建产物清理：写历史与撤销快照，journal .none 时不留任何痕迹") {
            guard MacCleanState.isIsolated else {
                print("      MACCLEAN_STATE_DIR 未生效，跳过写入断言")
                return false
            }
            let fm = FileManager.default
            // 只比对新记录的**身份**，不比绝对条数：历史与撤销会话各有截断上限，
            // 攒满之后新增一条并不会让 count 变大，条数断言会在跑得久的机器上假红。
            let historyBefore = HistoryStore.load()
            let undoBefore = UndoManagerStore.load()
            let headBefore = historyBefore.first?.id

            let root = devFixture("journal")
            defer { try? fm.removeItem(atPath: root) }
            try? fm.createDirectory(atPath: root + "/silent/target", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: root + "/loud/target", withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: 2048).write(to: URL(fileURLWithPath: root + "/loud/target/b.o"))
            let loudSize = FileSystem.size(at: root + "/loud/target")

            // 静默模式：删得掉，但绝不往历史里记
            let silent = DevProjectScanner.shared.cleanOutcome(
                [devArtifact("target", root + "/silent/target")], permanently: true, journal: .none)
            guard silent.cleanedCount == 1,
                  HistoryStore.load().first?.id == headBefore,
                  UndoManagerStore.load().count == undoBefore.count else { return false }

            // 废纸篓模式：不传 journal，锁住**生产默认值**——界面走的就是这条路径，
            // 默认值被改成 .none 时用户清完几十 GB 依然无痕可查。
            let loud = DevProjectScanner.shared.cleanOutcome(
                [devArtifact("target", root + "/loud/target")])
            guard loud.cleanedCount == 1 else { return false }
            let historyAfter = HistoryStore.load()
            let newRecord = historyAfter.first
            guard newRecord?.categoryName == "开发工程产物",
                  newRecord?.itemCount == 1, newRecord?.mode == "废纸篓",
                  newRecord?.bytes == loudSize, newRecord?.id != headBefore,
                  headBefore == nil || historyAfter.contains(where: { $0.id == headBefore }) else { return false }
            let session = UndoManagerStore.load().first { $0.recordID == newRecord?.id }
            guard let entries = session?.entries, entries.count == 1,
                  entries.first?.originalPath.hasSuffix("/loud/target") == true,
                  entries.first?.size == loudSize, loudSize > 0,
                  entries.first?.trashPath.isEmpty == false else { return false }

            // 收尾：别在用户废纸篓与历史里留下自测残留
            for snapshot in loud.trashedSnapshots { try? fm.removeItem(atPath: snapshot.trashPath) }
            HistoryStore.replaceAllForSelftest(historyBefore)
            UndoManagerStore.replaceAllForSelftest(undoBefore)
            return true
        }

        check("构建产物清理：源码接线——无裸删除、界面走网关且保留记账") {
            guard let scannerSrc = SelftestSource.read("DevProjectScanner") else { return false }
            guard scannerSrc.contains("ResidueDeletionGate.execute") else { return false }
            // 只认调用形态的字面量，注释里提旧实现不算复活
            guard !scannerSrc.contains("FileManager.default.removeItem"),
                  !scannerSrc.contains("FileManager.default.trashItem") else { return false }
            guard !scannerSrc.contains(".hasPrefix(home)") else { return false }
            // 「永不授权删域根本身」：这里只能做形态断言——拿真实的 DerivedData 根当候选去
            // 跑行为断言，一旦判错就是把用户整棵 DerivedData 删掉，不能这么测。
            guard !scannerSrc.contains("real == derivedDataRoot") else { return false }

            guard let viewSrc = SelftestSource.read("DevProjectInspectorView") else { return false }
            guard viewSrc.contains("cleanOutcome("), viewSrc.contains("pruneCleanedArtifacts(") else { return false }
            // 界面侧绝不能传 .none：那等于把刚接上的历史与撤销又关掉
            guard !viewSrc.contains("journal: .none") else { return false }
            // 确认框同时提供彻底删除时，不能再承诺"随时找回"
            guard !viewSrc.contains("可在废纸篓中随时找回") else { return false }
            return true
        }

        check("构建产物清理：列表按网关返回的真实路径剪枝，未删项保留") {
            let fm = FileManager.default
            let root = devFixture("prune")
            defer { try? fm.removeItem(atPath: root) }
            try? fm.createDirectory(atPath: root + "/gone/target", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: root + "/kept/target", withIntermediateDirectories: true)
            let gonePath = root + "/gone/target"
            let keptPath = root + "/kept/target"

            let saved = DevProjectScanner.shared.projects
            defer { DevProjectScanner.shared.projects = saved }
            DevProjectScanner.shared.projects = [
                DevProject(name: "Gone", path: root + "/gone", types: [.rust],
                           lastModified: nil, isOrphan: false,
                           artifacts: [devArtifact("target", gonePath)]),
                DevProject(name: "Kept", path: root + "/kept", types: [.rust],
                           lastModified: nil, isOrphan: false,
                           artifacts: [devArtifact("target", keptPath)]),
            ]

            let res = DevProjectScanner.shared.cleanOutcome(
                [devArtifact("target", gonePath)], permanently: true, journal: .none)
            DevProjectScanner.shared.pruneCleanedArtifacts(res.cleanedPaths)

            guard res.cleanedCount == 1 else { return false }
            let names = DevProjectScanner.shared.projects.map(\.name)
            // 旧实现拿字面路径比对，网关回的是解析后的真实路径 → 一条都剪不掉
            guard names == ["Kept"] else { return false }
            guard DevProjectScanner.shared.projects.first?.artifacts.map(\.path) == [keptPath] else { return false }
            return fm.fileExists(atPath: keptPath)
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
