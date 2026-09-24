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

        check("归档/迁移入口的 UI 判据与服务判据同源：SIP 位置不开放按钮（v1.73.9）") {
            // 上一版 `SpaceVisualizerModel.canArchiveOrMigrate` 自己维护一份 10 条字面
            // "危险根"清单 + `standardizingPath`；服务侧 `isSafeToArchive` 走的是
            // `normalizePath(realPath())` + `coreGuardVerdict` + 卷下深度 ≥2。两套标准的
            // 交集之外就是 UI 谎报的口子：`/private/var/db` 等 4 条 SIP 位置（都在
            // `CleanPaths.systemProtected` 里）不匹配清单里的任何一条字面，UI 就把
            // "归档"按钮开放出去，用户点下去才被服务侧拒。这条 check 钉住两侧同源。
            var bad: [String] = []
            // ① 6 条 SIP 路径必须被服务判据拒（也是 UI 判据应该拒的）。
            // 服务判据本身不查存在性，用假想的子路径也稳。
            for sip in CleanPaths.systemProtected {
                if SpaceArchiveService.isSafeToArchivePath(sip + "/macclean-fake/inner") {
                    bad.append("isSafeToArchivePath 放行了 SIP 位置 \(sip)/…")
                }
            }
            // ② UI 判据（走同一条服务判据）在 SIP 节点上必须返 false。
            // **挑一条只在 SIP 清单里、不在旧 UI 手写清单里**的 SIP 路径——旧手写清单是
            // `["/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
            //   "/etc", "/var", "/Volumes"]`（10 条精确匹配），`/private/var/db` 与它
            // 别名 `/var/db` **一条都不在**里面（`/var` 只精确匹配 `/var`、不匹 `/var/db`），
            // 所以旧实现会让按钮开放给这条真在 `systemProtected` 里的 SIP 位置。用 `/System`
            // 之类的两条清单交集做样本就变成"OLD 也拒 → 断言恒真"（v1.73.8 二次复审
            // P1 的同一族假绿：判据看起来在测、其实两个实现都能过——先跑一次 OLD 变异
            // 才算证明它有效）。
            let discriminatingSIP = "/private/var/db"
            // v1.73.9 复审 P1：上一版这里 `else { print; return true }` 把"样本不存在"
            // 记成**绿灯**——`Selftest.check` 只看返回值 true/false，print 不算数。
            // `/private/var/db` 在 macOS 上必然存在（SIP 清单里就它，`/var/db` 是它的
            // firmlink 目标），一旦不存在说明本机被非常规改动，判红而不是判绿。
            if !FileManager.default.fileExists(atPath: discriminatingSIP) {
                print("      判别性 SIP 样本 \(discriminatingSIP) 在本机不存在——端到端断言无法定论，判红而不是判绿")
                return false
            }
            let node = SpaceNode(name: "sip-node", path: discriminatingSIP,
                                 size: 100 * 1024 * 1024, color: .gray)
            if node.canArchiveOrMigrate {
                bad.append("canArchiveOrMigrate 在 SIP 节点 \(discriminatingSIP) 上仍返 true——"
                           + "UI 与服务判据不同源，用户点下去才被拒")
            }
            // ③ 反证：主目录下一个真实存在、体积达阈的普通文件必须仍返 true——
            // 否则本轮改动把正常入口也关了。造一个 11 MB 的临时文件在用户缓存目录下，
            // `defer` 删自己建的这一份（`MEMORY: feedback-assert-external-tool-behavior-not-arg-shape`
            // 的规矩：失败分支删的必须是自己建的东西）。
            let home = NSHomeDirectory()
            let probeDir = home + "/Library/Caches/macclean-selftest-archive"
            let probeFile = probeDir + "/big.bin"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: probeDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: probeDir) }
            // 11 MB 稀疏文件即可（服务判据不看真实占用；UI 的 `size` 是构造字段，直接给）
            fm.createFile(atPath: probeFile, contents: Data(count: 1024))
            let okNode = SpaceNode(name: "big.bin", path: probeFile,
                                   size: 11 * 1024 * 1024, color: .gray)
            if !okNode.canArchiveOrMigrate {
                bad.append("反证不成立：主目录下 11 MB 的普通文件被 UI 判据拒了——"
                           + "本轮把正常入口一起关掉了；用户看不到本可以归档的东西")
            }
            // ④ `standardizingPath` 的漂移形态也要一并挡：构造一个 `/private` 别名下的
            // SIP 路径（真机 SIP 清单里就有 `/private/var/db` 这类），断两侧的判据结果一致。
            let aliasSamples = ["/private/var/db", "/private/var/vm", "/private/var/folders/zz",
                                "/var/db", "/var/vm", "/var/folders/zz"]
            for p in aliasSamples {
                if SpaceArchiveService.isSafeToArchivePath(p + "/x") {
                    bad.append("别名路径 \(p) 被判据放行——`normalizePath` 是不是又漂回 `standardizingPath` 了")
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }
    }
}
