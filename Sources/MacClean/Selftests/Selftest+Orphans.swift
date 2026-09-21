import SwiftUI
import ViewInspector
import Darwin

// 自检套件：孤儿残留排查（Orphan Finder）
extension Selftest {
    static func suiteOrphans() {
        check("孤儿排查：系统组件与白名单绝不识别为孤儿") {
            let mockDB = OrphanScanner.InstalledDatabase(
                bundleIDs: ["com.example.activeapp"],
                bundlePrefixes: ["com.example"],
                normalizedNames: ["activeapp"],
                executableNames: ["activeapp"],
                runningBundleIDs: []
            )

            // 系统前缀
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.apple.Safari", db: mockDB) else { return false }
            guard OrphanScanner.isInstalledOrProtected(identifier: "group.com.apple.notes", db: mockDB) else { return false }
            // 系统单段守护进程
            guard OrphanScanner.isInstalledOrProtected(identifier: "nsurlsessiond", db: mockDB) else { return false }
            guard OrphanScanner.isInstalledOrProtected(identifier: "sharedfilelistd", db: mockDB) else { return false }
            // 已安装应用
            guard OrphanScanner.isInstalledOrProtected(identifier: "com.example.activeapp", db: mockDB) else { return false }
            // 未安装的第三方应用应返回 false（即候选孤儿）
            guard !OrphanScanner.isInstalledOrProtected(identifier: "com.unknown.deletedapp", db: mockDB) else { return false }

            return true
        }

        check("孤儿排查：应用名称推导与归一化") {
            let n1 = OrphanScanner.deriveDisplayName("com.bohemiancoding.sketch3")
            guard n1 == "Sketch3" || n1.contains("sketch") || n1.contains("Sketch") else { return false }

            let n2 = OrphanScanner.deriveDisplayName("group.com.tencent.xinWeChat")
            guard n2 == "XinWeChat" || n2.contains("WeChat") else { return false }

            let norm = OrphanScanner.normalize("Google Chrome")
            guard norm == "googlechrome" else { return false }

            return true
        }

        check("孤儿排查：多目录残留向 OrphanApp 聚合与容量累加") {
            let i1 = OrphanItem(name: "com.test.ghost", path: "/tmp/c1", size: 1024 * 1024, kind: .container)
            let i2 = OrphanItem(name: "com.test.ghost.plist", path: "/tmp/p1", size: 2048, kind: .preferences)
            let i3 = OrphanItem(name: "com.test.ghost.savedState", path: "/tmp/s1", size: 4096, kind: .savedState)

            var app = OrphanApp(name: "GhostApp", bundleID: "com.test.ghost", items: [i1, i2, i3])
            guard app.items.count == 3 else { return false }
            guard app.totalSize == (1024 * 1024 + 2048 + 4096) else { return false }
            guard app.selectedCount == 0 else { return false }

            // 勾选测试
            app.items[0].isSelected = true
            guard app.selectedCount == 1 else { return false }
            guard app.selectedSize == 1024 * 1024 else { return false }
            guard !app.allSelected else { return false }

            app.items[1].isSelected = true
            app.items[2].isSelected = true
            guard app.allSelected else { return false }

            return true
        }

        check("孤儿排查：执行安全清理移入废纸篓") {
            let tmpDir = "/private/tmp/macclean-orphan-test-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            let testFile = tmpDir + "/ghost.data"
            FileManager.default.createFile(atPath: testFile, contents: Data(repeating: 0xAA, count: 4096))
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            guard FileManager.default.fileExists(atPath: testFile) else { return false }

            let item = OrphanItem(name: "ghost.data", path: testFile, size: 4096, kind: .other, isSelected: true)
            let result = OrphanScanner.clean(items: [item], permanently: false) { _ in }

            // 文件应已被移走且成功计数为 1
            let existsAfter = FileManager.default.fileExists(atPath: testFile)
            return result.succeeded == 1 && !existsAfter
        }

        check("孤儿排查：UI 模式分段与组件渲染") {
            let state = AppState()
            let view = UninstallerView().environmentObject(state)

            // 检查 Picker 存在
            let picker = try? view.inspect().find(viewWithAccessibilityIdentifier: "uninstallerTabPicker")
            guard picker != nil else { return false }

            // 检查默认模式为已安装应用
            guard state.uninstaller.currentTab == .apps else { return false }

            // 切换为孤儿排查模式
            state.uninstaller.currentTab = .orphans
            let viewOrphans = UninstallerView().environmentObject(state)
            guard (try? viewOrphans.inspect()) != nil else { return false }

            return true
        }
    }
}
