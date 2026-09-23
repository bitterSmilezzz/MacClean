import Foundation
import SwiftUI
import ViewInspector

// 自检套件：已卸载应用深度偏好碎片智能反查 (v1.53.0)
extension Selftest {
    static func suitePreferenceResidueDeep() {
        check("偏好碎片逆向匹配：ByHost 硬件 UUID 与 .plist 后缀剥离 (extractBundleID)") {
            // 1. 标准 plist 后缀剥离
            let std = PreferenceResidueInspector.extractBundleID(from: "com.tencent.xinwechat.plist")
            guard std == "com.tencent.xinwechat" else { return false }

            // 2. ByHost 硬件 UUID 剥离 (标准 36 位 UUID)
            let byHost1 = PreferenceResidueInspector.extractBundleID(
                from: "cn.trae.app.ShipIt.CB35EDB2-7D1B-559A-8EA9-A4DC0191D25F.plist"
            )
            guard byHost1 == "cn.trae.app.ShipIt" else { return false }

            let byHost2 = PreferenceResidueInspector.extractBundleID(
                from: "com.google.Chrome.12345678-ABCD-EF01-2345-6789ABCDEF01.plist"
            )
            guard byHost2 == "com.google.Chrome" else { return false }

            // 3. 无后缀与特殊命名
            let raw = PreferenceResidueInspector.extractBundleID(from: "simple.test.app")
            guard raw == "simple.test.app" else { return false }

            return true
        }

        check("偏好碎片逆向匹配：应用名称智能推导与 ShipIt 组件识别 (deriveDisplayName)") {
            // 1. 知名应用映射
            guard PreferenceResidueInspector.deriveDisplayName(from: "com.tencent.xinwechat") == "微信 (WeChat)" else { return false }
            guard PreferenceResidueInspector.deriveDisplayName(from: "com.microsoft.vscode") == "Visual Studio Code" else { return false }
            guard PreferenceResidueInspector.deriveDisplayName(from: "com.google.chrome") == "Google Chrome" else { return false }

            // 2. ShipIt 自动更新组件推导
            let shipItName = PreferenceResidueInspector.deriveDisplayName(from: "cn.trae.app.ShipIt")
            guard shipItName.contains("Trae") && shipItName.contains("更新组件") else { return false }

            // 3. 通用格式化推导
            let generic = PreferenceResidueInspector.deriveDisplayName(from: "io.github.somedev.awesomeapp")
            guard generic.contains("Awesomeapp") || generic.contains("Somedev") else { return false }

            return true
        }

        check("偏好碎片安全保护：系统核心白名单与模型数据不变量") {
            // 1. 系统核心服务永不误伤
            let db = OrphanScanner.InstalledDatabase.build()
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.finder", db: db) == true else { return false }
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.Safari", db: db) == true else { return false }
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.dock", db: db) == true else { return false }

            // 2. 模型结构完整性
            let dummy = OrphanPreferenceItem(
                appName: "TestApp",
                bundleID: "com.test.dummy",
                fileName: "com.test.dummy.plist",
                path: "/tmp/com.test.dummy.plist",
                size: 2048,
                lastModified: Date(),
                ageDays: 14,
                location: .standard,
                isSelected: true
            )
            guard dummy.appName == "TestApp" && dummy.bundleID == "com.test.dummy" else { return false }
            guard dummy.ageDays == 14 && dummy.location == .standard && dummy.isSelected == true else { return false }
            guard PreferenceLocationKind.byHost.shortTitle == "ByHost" else { return false }
            guard PreferenceLocationKind.synced.icon == "arrow.triangle.2.circlepath" else { return false }

            return true
        }

        check("偏好碎片扫描引擎：合成环境下的孤儿偏好发现与 7 天缓冲期过滤") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_PrefTest_\(UUID().uuidString)"
            let prefDir = "\(tmpDir)/Library/Preferences"
            let byHostDir = "\(prefDir)/ByHost"

            try? fm.createDirectory(atPath: byHostDir, withIntermediateDirectories: true)
            defer {
                try? fm.removeItem(atPath: tmpDir)
            }

            // 1. 模拟最近修改的文件（< 7 天）：应当被缓冲期保护，不作为孤儿偏好报出
            let recentFile = "\(prefDir)/com.test.recentorphannotinstalled.plist"
            try? "recent data".write(toFile: recentFile, atomically: true, encoding: .utf8)
            let recentAttrs: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-2 * 86400)] // 2 天前
            try? fm.setAttributes(recentAttrs, ofItemAtPath: recentFile)

            // 2. 模拟陈旧孤儿偏好（> 7 天，例如 30 天前修改）：应当被正确识别
            let oldOrphanFile = "\(prefDir)/com.defunct.oldsoftware.plist"
            try? "old config".write(toFile: oldOrphanFile, atomically: true, encoding: .utf8)
            let oldAttrs: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-30 * 86400)] // 30 天前
            try? fm.setAttributes(oldAttrs, ofItemAtPath: oldOrphanFile)

            // 3. 模拟 ByHost 机器硬件级孤儿偏好（带 UUID，45 天前修改）：应当被识别且剥离 UUID
            let byHostOrphanFile = "\(byHostDir)/com.abandoned.game.12345678-1234-1234-1234-123456789abc.plist"
            try? "game host pref".write(toFile: byHostOrphanFile, atomically: true, encoding: .utf8)
            let byHostAttrs: [FileAttributeKey: Any] = [.modificationDate: Date().addingTimeInterval(-45 * 86400)]
            try? fm.setAttributes(byHostAttrs, ofItemAtPath: byHostOrphanFile)

            // 4. 模拟系统偏好文件（即使陈旧也受白名单保护）
            let systemOldFile = "\(prefDir)/com.apple.ancientcore.plist"
            try? "apple system".write(toFile: systemOldFile, atomically: true, encoding: .utf8)
            try? fm.setAttributes(oldAttrs, ofItemAtPath: systemOldFile)

            // 执行反查扫描 (指定 7 天缓冲期)
            let inspector = PreferenceResidueInspector.shared
            let results = inspector.scanOrphanPreferences(home: tmpDir, minAgeDays: 7)

            // 验证 1：近期修改未满 7 天的文件未入选
            guard !results.contains(where: { $0.bundleID == "com.test.recentorphannotinstalled" }) else { return false }

            // 验证 2：系统 apple 前缀文件未入选
            guard !results.contains(where: { $0.bundleID.contains("com.apple.") }) else { return false }

            // 验证 3：陈旧孤儿偏好成功入选
            guard let oldFound = results.first(where: { $0.bundleID == "com.defunct.oldsoftware" }) else { return false }
            guard oldFound.location == .standard && oldFound.ageDays >= 29 else { return false }

            // 验证 4：ByHost 孤儿偏好成功入选且 UUID 准确剥离
            guard let byHostFound = results.first(where: { $0.bundleID == "com.abandoned.game" }) else { return false }
            guard byHostFound.location == .byHost && byHostFound.ageDays >= 44 else { return false }

            return true
        }

        check("偏好碎片清理：源码接线——无裸删除、卸载器保留记账") {
            guard let src = SelftestSource.read("PreferenceResidueInspector") else { return false }
            guard src.contains("ResidueDeletionGate.execute") else { return false }
            // 只认带接收者的完整调用形，注释里提旧实现不算复活（RELEASE-CHECKLIST 那条）
            guard !src.contains("FileManager.default.removeItem"),
                  !src.contains("FileManager.default.trashItem") else { return false }
            // 调用方（App 卸载器）不许把刚接上的记账又关掉
            guard let caller = SelftestSource.read("Uninstaller") else { return false }
            guard caller.contains("cleanPreferences(items:"),
                  !caller.contains("journal: .none") else { return false }
            return true
        }

        check("偏好碎片清理：走统一网关（登记根/白名单/目录伪装/实测记账）") {
            guard MacCleanState.isIsolated else {
                print("      MACCLEAN_STATE_DIR 未生效，跳过白名单写入断言")
                return false
            }
            let fm = FileManager.default
            let home = "/private/tmp/macclean_pref_\(UUID().uuidString)"
            defer { try? fm.removeItem(atPath: home) }
            let prefDir = home + "/Library/Preferences"
            let byHostDir = prefDir + "/ByHost"
            try? fm.createDirectory(atPath: byHostDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: home + "/Library/SyncedPreferences", withIntermediateDirectories: true)
            func put(_ path: String, _ bytes: Int) -> String {
                try? Data(repeating: 0x50, count: bytes).write(to: URL(fileURLWithPath: path))
                return path
            }

            let gone1 = put(prefDir + "/com.gone.one.plist", 3000)
            let gone2 = put(byHostDir + "/com.gone.two.plist", 5000)
            let size1 = FileSystem.size(at: gone1)
            let size2 = FileSystem.size(at: gone2)
            // 旧实现连白名单都不查，这条是它最要命的一处
            let protected = put(prefDir + "/com.keep.three.plist", 400)
            let notPlist = put(prefDir + "/notes.txt", 40)
            let dirMasquerading = prefDir + "/com.dir.plist"
            try? fm.createDirectory(atPath: dirMasquerading, withIntermediateDirectories: true)
            let outsideRoot = put(home + "/com.outside.plist", 40)

            let wm = WhitelistManager.shared
            wm.removeAllRules()
            wm.addPathRule(protected, comment: "偏好碎片白名单自检")
            defer { wm.removeAllRules() }

            // 每一项的 size 都故意填 1：记账若沿用扫描缓存，freedBytes 就是 6 而不是实测和
            func item(_ file: String, _ path: String) -> OrphanPreferenceItem {
                OrphanPreferenceItem(appName: "Ghost", bundleID: "com.ghost", fileName: file,
                                     path: path, size: 1, lastModified: nil, ageDays: 90,
                                     location: .standard)
            }
            let res = PreferenceResidueInspector.shared.cleanPreferences(items: [
                item("com.gone.one.plist", gone1),
                item("com.gone.two.plist", gone2),
                item("com.keep.three.plist", protected),
                item("notes.txt", notPlist),
                item("com.dir.plist", dirMasquerading),
                item("com.outside.plist", outsideRoot),
            ], toTrash: false, home: home, journal: .none)

            guard res.successCount == 2, res.failCount == 4 else { return false }
            guard res.freedBytes == size1 + size2, size1 >= 3000, size2 >= 5000 else { return false }
            guard !fm.fileExists(atPath: gone1), !fm.fileExists(atPath: gone2) else { return false }
            return fm.fileExists(atPath: protected) && fm.fileExists(atPath: notPlist)
                && fm.fileExists(atPath: dirMasquerading) && fm.fileExists(atPath: outsideRoot)
        }

        check("偏好碎片清理：默认记账写历史与撤销快照（旧实现一条都不留）") {
            guard MacCleanState.isIsolated else { return false }
            let fm = FileManager.default
            let home = "/private/tmp/macclean_pref_journal_\(UUID().uuidString)"
            defer { try? fm.removeItem(atPath: home) }
            let prefDir = home + "/Library/Preferences"
            try? fm.createDirectory(atPath: prefDir, withIntermediateDirectories: true)
            let target = prefDir + "/com.gone.journal.plist"
            try? Data(repeating: 0x5A, count: 1024).write(to: URL(fileURLWithPath: target))
            let measured = FileSystem.size(at: target)

            let headBefore = HistoryStore.load().first?.id
            // 不传 journal：锁住生产默认值，卸载器吃的就是它
            let outcome = PreferenceResidueInspector.shared.cleanOutcome(
                items: [OrphanPreferenceItem(appName: "Ghost", bundleID: "com.ghost",
                                             fileName: "com.gone.journal.plist", path: target,
                                             size: 0, lastModified: nil, ageDays: 90,
                                             location: .standard)],
                toTrash: true, home: home)
            guard outcome.cleanedCount == 1 else { return false }

            let record = HistoryStore.load().first
            guard record?.categoryName == "偏好残留", record?.itemCount == 1,
                  record?.mode == "废纸篓", record?.bytes == measured,
                  record?.id != headBefore else { return false }
            let session = UndoManagerStore.load().first { $0.recordID == record?.id }
            guard session?.entries.first?.originalPath.hasSuffix("/com.gone.journal.plist") == true,
                  (session?.entries.first?.trashPath.isEmpty ?? true) == false else { return false }

            for snapshot in outcome.trashedSnapshots { try? fm.removeItem(atPath: snapshot.trashPath) }
            HistoryStore.save(HistoryStore.load().filter { $0.id != record?.id })
            UndoManagerStore.save(UndoManagerStore.load().filter { $0.recordID != record?.id })
            return true
        }

        check("偏好碎片视图联动：UninstallerView 三段式 Tab 与偏好反查面板 ViewInspector 检验") {
            let app = AppState()
            app.uninstaller.currentTab = .preferences

            // 预置一项测试数据验证面板渲染
            app.uninstaller.preferenceItems = [
                OrphanPreferenceItem(
                    appName: "Test Orphan App",
                    bundleID: "com.test.orphanapp",
                    fileName: "com.test.orphanapp.plist",
                    path: "/tmp/com.test.orphanapp.plist",
                    size: 1024,
                    lastModified: Date(),
                    ageDays: 35,
                    location: .standard,
                    isSelected: false
                )
            ]

            let view = UninstallerView().environmentObject(app)
            guard let inspected = try? view.inspect() else { return false }

            // 1. 验证三段式模式选择器
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "uninstallerTabPicker")) != nil else {
                return false
            }

            // 2. 验证偏好面板根容器
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferencePanel")) != nil else {
                return false
            }

            // 3. 验证全选按钮与操作按钮
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferenceSelectAllButton")) != nil else {
                return false
            }
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferencePermanentButton")) != nil else {
                return false
            }
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "preferenceTrashButton")) != nil else {
                return false
            }

            return true
        }
    }
}
