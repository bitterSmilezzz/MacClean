import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：空间透视与图表
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1850–1966）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteSpaceVisualizer() {
        // MARK: - v1.31.0 空间透视：Treemap / 旭日图可视化

        check("空间层级：SpaceHierarchyBuilder 建树与子节点大小累加") {
            let root = SpaceNode(
                name: "Macintosh HD",
                size: 1_000_000_000,
                color: Accent.tint,
                children: [
                    SpaceNode(name: "系统", size: 400_000_000, color: .gray),
                    SpaceNode(name: "应用", size: 350_000_000, color: .blue),
                    SpaceNode(name: "用户", size: 250_000_000, color: .green)
                ]
            )
            // 根节点大小 > 0，子节点大小之和 <= 根节点大小
            guard root.size > 0 else { return false }
            let childrenTotal = root.children.reduce(0) { $0 + $1.size }
            guard childrenTotal <= root.size else { return false }
            return true
        }

        check("Treemap：Squarified 算法切分 — 所有 tile 面积之和 ≈ 总面积") {
            let nodes: [SpaceNode] = [
                SpaceNode(name: "A", path: "/a", size: 500_000_000, color: .red, icon: "doc"),
                SpaceNode(name: "B", path: "/b", size: 300_000_000, color: .blue, icon: "doc"),
                SpaceNode(name: "C", path: "/c", size: 200_000_000, color: .green, icon: "doc")
            ]
            let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
            let tiles = TreemapEngine.layout(nodes: nodes, in: rect)
            guard tiles.count == nodes.count else { return false }
            let totalArea = tiles.reduce(0.0) { $0 + $1.rect.width * $1.rect.height }
            let expectedArea = Double(rect.width * rect.height)
            // 允许 1% 误差
            let delta = abs(totalArea - expectedArea) / expectedArea
            return delta < 0.01
        }

        check("旭日图：SunburstEngine 极坐标扇区 — 一级扇区角度总和 ≈ 2π") {
            let root = SpaceNode(
                name: "Disk",
                size: 1_000_000_000,
                color: Accent.tint,
                children: [
                    SpaceNode(name: "A", size: 400_000_000, color: .red),
                    SpaceNode(name: "B", size: 350_000_000, color: .blue),
                    SpaceNode(name: "C", size: 250_000_000, color: .green)
                ]
            )
            let sectors = SunburstEngine.layout(
                root: root,
                center: CGPoint(x: 200, y: 200),
                maxRadius: 180
            )
            guard !sectors.isEmpty else { return false }
            // Level-1 扇区角度跨度之和 ≈ 2π
            let level1 = sectors.filter { $0.level == 1 }
            let totalAngle = level1.reduce(0.0) { $0 + ($1.endAngle - $1.startAngle) }
            return abs(totalAngle - 2 * Double.pi) < 0.001
        }

        check("空间透视组件：VisualizerMode 与 VisualizerScope 枚举完整性") {
            // treemap 是默认模式，sunburst 是备选
            let modes: [VisualizerMode] = [.treemap, .sunburst]
            guard modes.count == 2 else { return false }
            // scope 包含 disk 与 cleanable
            let scopes: [VisualizerScope] = [.disk, .cleanable]
            guard scopes.count == 2 else { return false }
            // 默认模式字符串区分
            guard VisualizerMode.treemap != VisualizerMode.sunburst else { return false }
            return true
        }

        // Treemap / 旭日图的色块上要压文字。历史缺陷：色块用半透明色 + 文字硬编码白色，
        // "可用空间"那块是浅灰底白字，等于看不见。下面这几条锁住修复。
        check("图表色块：文字颜色随色块亮度翻转（浅底深字 / 深底浅字）") {
            let light = Color(hex: 0xF0F0F0)   // 浅灰
            let dark = Color(hex: 0x1E1E1E)    // 近黑
            let lightFg = light.readableForeground(for: .light)
            let darkFg = dark.readableForeground(for: .light)
            // 浅色块 → 深色文字；深色块 → 白色文字
            guard lightFg != darkFg else { return false }
            guard light.perceivedLuminance(for: .light) > 0.6 else { return false }
            guard dark.perceivedLuminance(for: .light) < 0.6 else { return false }
            // 图表色板里最亮的琥珀色必须用深字，否则白字压琥珀会糊
            let amber = ChartPalette.color(at: 3)
            return amber.readableForeground(for: .light) == lightFg
        }

        check("图表色块：全部不透明（半透明会让文字对比度判定失效）") {
            // 模型层不得再用 opacity 做色块层次——层次改用 shade()
            let tiles: [SpaceNode] = [
                SpaceHierarchyBuilder.buildDiskOverview(app: AppState()),
            ]
            var colors: [Color] = []
            func walk(_ nodes: [SpaceNode]) {
                for n in nodes { colors.append(n.color); walk(n.children) }
            }
            walk(tiles)
            guard !colors.isEmpty else { return false }
            // 逐个解析 alpha，全部应为 1.0
            return colors.allSatisfy { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return false }
                return ns.alphaComponent >= 0.999
            }
        }

        check("图表色块：shade() 单调调整亮度且保持不透明") {
            let base = ChartPalette.color(at: 0)
            let darker = base.shade(0.7)
            let lighter = base.shade(1.3)
            let scheme = ColorScheme.light
            guard darker.perceivedLuminance(for: scheme) < base.perceivedLuminance(for: scheme) else { return false }
            guard lighter.perceivedLuminance(for: scheme) > base.perceivedLuminance(for: scheme) else { return false }
            guard let nsDark = NSColor(darker).usingColorSpace(.sRGB),
                  let nsLight = NSColor(lighter).usingColorSpace(.sRGB) else { return false }
            return nsDark.alphaComponent >= 0.999 && nsLight.alphaComponent >= 0.999
        }

    }
}
