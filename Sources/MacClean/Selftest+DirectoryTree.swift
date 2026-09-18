import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：目录树
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1547–1651）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteDirectoryTree() {
        check("目录树：路径解析与体积累加建树") {
            let home = CleanPaths.expand("~")
            let entries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/ubuntu.iso", size: 4_000_000_000, isSelected: true),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/fedora.iso", size: 2_000_000_000, isSelected: false),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/clip.mp4", size: 1_000_000_000, isSelected: false),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Pictures/Wallpapers/mountain.jpg", size: 50_000_000, isSelected: true)
            ]

            let tree = DirectoryTreeBuilder.buildTree(from: entries)
            guard tree.count >= 2 else { return false }

            guard let dlNode = tree.first(where: { $0.path.contains("Downloads") }) else { return false }
            guard dlNode.totalBytes == 7_000_000_000 else { return false }
            guard dlNode.fileCount == 3 else { return false }

            guard let isoNode = dlNode.children.first(where: { $0.path.contains("ISO") }) else { return false }
            guard isoNode.totalBytes == 6_000_000_000 else { return false }
            guard isoNode.fileCount == 2 else { return false }

            guard let picNode = tree.first(where: { $0.path.contains("Pictures") }) else { return false }
            guard picNode.totalBytes == 50_000_000 else { return false }
            guard picNode.fileCount == 1 else { return false }

            return true
        }

        check("目录树：三态勾选与级联状态判定") {
            let home = CleanPaths.expand("~")
            let mixedEntries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/1.iso", size: 100, isSelected: true),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/2.iso", size: 100, isSelected: false)
            ]
            let treeMixed = DirectoryTreeBuilder.buildTree(from: mixedEntries)
            guard let dlMixed = treeMixed.first(where: { $0.path.contains("Downloads") }) else { return false }
            guard dlMixed.checkState == .mixed else { return false }

            let allEntries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Documents/Doc/a.pdf", size: 100, isSelected: true),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Documents/Doc/b.pdf", size: 100, isSelected: true)
            ]
            let treeAll = DirectoryTreeBuilder.buildTree(from: allEntries)
            guard let docAll = treeAll.first(where: { $0.path.contains("Documents") }) else { return false }
            guard docAll.checkState == .all else { return false }

            let noneEntries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Desktop/Tmp/a.tmp", size: 100, isSelected: false)
            ]
            let treeNone = DirectoryTreeBuilder.buildTree(from: noneEntries)
            guard let dtNone = treeNone.first(where: { $0.path.contains("Desktop") }) else { return false }
            guard dtNone.checkState == .none else { return false }

            return true
        }

        check("目录树：范围管理与子路径排除") {
            let mgr = DirectoryScopeManager.shared
            let testDir = "/tmp/macclean_scope_test_\(UUID().uuidString)"
            let testSub = "\(testDir)/excluded_sub"

            mgr.setPathExcluded(testSub, excluded: true)
            defer { mgr.setPathExcluded(testSub, excluded: false) }

            guard mgr.isPathExcluded("\(testSub)/file.iso") else { return false }
            guard !mgr.isPathExcluded("\(testDir)/allowed_sub/file.iso") else { return false }

            return true
        }

        check("目录树组件：DirectoryTreeSheet 与 DirectoryFilterBadge 渲染") {
            var cleared = false
            let badge = DirectoryFilterBadge(path: "~/Downloads/Videos") {
                cleared = true
            }
            _ = try badge.inspect()
            // 触发清除闭包验证
            badge.onClear()
            guard cleared else { return false }

            var dismissed = false
            var appliedFilter: String? = nil
            let entries = [
                DirectoryTreeBuilder.FileEntry(path: "/tmp/a/test.mov", size: 1000, isSelected: true)
            ]
            let sheet = DirectoryTreeSheet(
                title: "测试目录树",
                entries: entries,
                activeFilterPath: "/tmp/a",
                onApplyFilter: { filter in
                    appliedFilter = filter
                },
                onToggleBatchSelection: { _, _ in },
                onDismiss: {
                    dismissed = true
                }
            )

            let doneBtn = try button("directoryTreeDoneButton", in: sheet)
            try doneBtn.tap()
            guard dismissed else { return false }
            guard appliedFilter == "/tmp/a" else { return false }

            return true
        }

    }
}
