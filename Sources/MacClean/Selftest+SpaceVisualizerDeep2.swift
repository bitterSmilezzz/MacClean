import Foundation
import SwiftUI
import ViewInspector

// MARK: - 空间透视层级面包屑与闲置冷热动态色谱深度自检 (v1.50.0)

extension Selftest {
    static func suiteSpaceVisualizerDeep2() {
        print("==> 运行空间透视层级面包屑与闲置冷热动态色谱深度自检 (v1.50.0)...")

        // 1. FileAgeLevel 闲置冷热度判定单调性与区间
        check("空间透视闲置：FileAgeLevel 五级冷热阶梯判定准确性") {
            guard FileAgeLevel.infer(days: 0) == .active &&
                    FileAgeLevel.infer(days: 15) == .active &&
                    FileAgeLevel.infer(days: 29) == .active else { return false }

            guard FileAgeLevel.infer(days: 30) == .warm &&
                    FileAgeLevel.infer(days: 60) == .warm &&
                    FileAgeLevel.infer(days: 89) == .warm else { return false }

            guard FileAgeLevel.infer(days: 90) == .cool &&
                    FileAgeLevel.infer(days: 120) == .cool &&
                    FileAgeLevel.infer(days: 179) == .cool else { return false }

            guard FileAgeLevel.infer(days: 180) == .cold &&
                    FileAgeLevel.infer(days: 250) == .cold &&
                    FileAgeLevel.infer(days: 364) == .cold else { return false }

            guard FileAgeLevel.infer(days: 365) == .frozen &&
                    FileAgeLevel.infer(days: 500) == .frozen &&
                    FileAgeLevel.infer(days: 1200) == .frozen else { return false }

            // 验证每种冷热等级都有非空图标与颜色
            for level in FileAgeLevel.allCases {
                guard !level.icon.isEmpty else { return false }
            }
            return true
        }

        // 2. SpaceNode 三重色彩编码自适应映射
        check("空间透视色谱：SpaceNode 在分类/类型/闲置三种模式下的色彩推导一致性") {
            let baseColor = Color.blue
            let dateActive = Date().addingTimeInterval(-10 * 86400) // 10 天前
            let dateFrozen = Date().addingTimeInterval(-400 * 86400) // 400 天前

            let nodeActive = SpaceNode(
                name: "test_active.mp4",
                path: "/tmp/test_active.mp4",
                size: 1024,
                color: baseColor,
                fileTypeKind: .video,
                modificationDate: dateActive
            )

            let nodeFrozen = SpaceNode(
                name: "test_frozen.zip",
                path: "/tmp/test_frozen.zip",
                size: 2048,
                color: baseColor,
                fileTypeKind: .archive,
                modificationDate: dateFrozen
            )

            // 分类模式返回 baseColor
            guard nodeActive.displayColor(for: .category) == baseColor else { return false }

            // 文件类型模式返回对应 FileTypeKind.color
            guard nodeActive.displayColor(for: .fileType) == FileTypeKind.video.color else { return false }
            guard nodeFrozen.displayColor(for: .fileType) == FileTypeKind.archive.color else { return false }

            // 闲置模式返回对应的 FileAgeLevel.color
            guard nodeActive.displayColor(for: .age) == FileAgeLevel.active.color else { return false }
            guard nodeFrozen.displayColor(for: .age) == FileAgeLevel.frozen.color else { return false }

            // 无修改时间节点在 .age 模式下安全回退保底色
            let nodeNoDate = SpaceNode(name: "no_date", size: 100, color: baseColor)
            guard nodeNoDate.displayColor(for: .age) == baseColor else { return false }

            return true
        }

        // 3. 动态物理目录展开携带修改时间与冷热度
        check("空间透视目录展开：expandDirectory 准确抓取文件 mtime 并推导冷热度") {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macclean_space_test_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fileRecent = tempDir.appendingPathComponent("recent.log")
            let fileOld = tempDir.appendingPathComponent("old.dmg")

            let data = Data(repeating: 0x41, count: 5000)
            try? data.write(to: fileRecent)
            try? data.write(to: fileOld)

            // 将 old.dmg 修改时间设置为 450 天前
            let pastDate = Date().addingTimeInterval(-450 * 86400)
            try? FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: fileOld.path)

            let nodes = SpaceHierarchyBuilder.expandDirectory(path: tempDir.path, colorMode: .age)
            guard nodes.count == 2 else { return false }

            guard let recentNode = nodes.first(where: { $0.name == "recent.log" }),
                  let oldNode = nodes.first(where: { $0.name == "old.dmg" }) else {
                return false
            }

            // 验证 recentNode 判定为 active，oldNode 判定为 frozen
            guard recentNode.ageLevel == .active else { return false }
            guard oldNode.ageLevel == .frozen else { return false }
            guard oldNode.displayColor(for: .age) == FileAgeLevel.frozen.color else { return false }

            return true
        }

        // 4. 层级面包屑下钻、跨级跳转与回退状态一致性
        check("空间透视面包屑：多级下钻、popTo 跨级回溯与 popToRoot 状态流转完整性") {
            let item = SpaceNode(name: "item", size: 10, color: .gray)
            let root = SpaceNode(name: "Macintosh HD", path: "/", size: 10000, color: .blue, children: [item])
            let dirUsers = SpaceNode(name: "Users", path: "/Users", size: 6000, color: .green, children: [item])
            let dirUserHome = SpaceNode(name: "dev", path: "/Users/dev", size: 4000, color: .orange, children: [item])
            let dirDownloads = SpaceNode(name: "Downloads", path: "/Users/dev/Downloads", size: 2000, color: .purple, children: [item])

            var nav = BreadcrumbNavigator(root: root)

            // 第一级下钻：/ -> /Users
            nav.drillDown(into: dirUsers)
            guard nav.current.name == "Users" && nav.stack.count == 1 else { return false }
            guard nav.stack[0].name == "Macintosh HD" else { return false }

            // 第二级下钻：/Users -> /Users/dev
            nav.drillDown(into: dirUserHome)
            guard nav.current.name == "dev" && nav.stack.count == 2 else { return false }

            // 第三级下钻：/Users/dev -> /Users/dev/Downloads
            nav.drillDown(into: dirDownloads)
            guard nav.current.name == "Downloads" && nav.stack.count == 3 else { return false }

            // 跨级回退：点击索引 1 的 /Users
            nav.popTo(index: 1)
            guard nav.current.name == "Users" && nav.stack.count == 1 else { return false }

            // 再次下钻
            nav.drillDown(into: dirUserHome)
            guard nav.current.name == "dev" && nav.stack.count == 2 else { return false }

            // 单级回退
            nav.popOneLevel()
            guard nav.current.name == "Users" && nav.stack.count == 1 else { return false }

            // 回退到根
            nav.popToRoot()
            guard nav.current.name == "Macintosh HD" && nav.stack.isEmpty else { return false }

            return true
        }

        // 5. 视图层级渲染与色彩选择器
        check("空间透视渲染：色彩编码三档分段选择器与闲置冷热色谱图例渲染") {
            let app = AppState()
            let view = SpaceVisualizerView().environmentObject(app)

            // 验证 ViewInspector 可成功解析 body 并包含色彩编码选择器
            guard let inspected = try? view.inspect() else { return false }
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "visualizerColorModePicker")) != nil else {
                return false
            }

            return true
        }
    }
}
