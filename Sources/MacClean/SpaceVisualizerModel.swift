import Foundation
import SwiftUI
import CoreGraphics

// MARK: - 空间可视化节点数据模型

/// 空间层级节点（通用树结构）
struct SpaceNode: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: String?
    let size: Int64
    let color: Color
    let icon: String?
    let category: CleanCategory?
    var children: [SpaceNode]

    init(
        id: UUID = UUID(),
        name: String,
        path: String? = nil,
        size: Int64,
        color: Color,
        icon: String? = nil,
        category: CleanCategory? = nil,
        children: [SpaceNode] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.color = color
        self.icon = icon
        self.category = category
        self.children = children
    }

    var isLeaf: Bool {
        children.isEmpty
    }

    var formattedSize: String {
        size.byteStringCN
    }

    func percentage(of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(size) / Double(total)))
    }

    func percentageString(of total: Int64) -> String {
        let pct = percentage(of: total) * 100.0
        if pct >= 10.0 {
            return String(format: "%.1f%%", pct)
        } else if pct >= 0.1 {
            return String(format: "%.1f%%", pct)
        } else if pct > 0 {
            return "<0.1%"
        } else {
            return "0%"
        }
    }
}

// MARK: - 空间层级构建引擎

enum SpaceHierarchyBuilder {
    /// 调色板定义（纯正 Apple 原生 HIG 质感）
    static let palette: [Color] = [
        Color(red: 0.18, green: 0.50, blue: 0.98), // Royal Blue
        Color(red: 0.36, green: 0.32, blue: 0.86), // Indigo
        Color(red: 0.12, green: 0.72, blue: 0.65), // Teal
        Color(red: 0.20, green: 0.78, blue: 0.45), // Emerald
        Color(red: 0.98, green: 0.62, blue: 0.15), // Amber
        Color(red: 0.95, green: 0.35, blue: 0.32), // Coral
        Color(red: 0.68, green: 0.35, blue: 0.92), // Purple
        Color(red: 0.45, green: 0.55, blue: 0.65)  // Slate
    ]

    /// 构建全盘存储空间概览树
    static func buildDiskOverview(app: AppState) -> SpaceNode {
        let total = max(1, app.diskTotal)
        var children: [SpaceNode] = []

        // 1. 已扫描的各大清理分类
        var scannedCleanableTotal: Int64 = 0
        for cat in CleanCategory.allCases {
            let st = app.state(for: cat)
            if st.totalSize > 0 {
                scannedCleanableTotal += st.totalSize
                let subNodes = buildCategorySubnodes(category: cat, state: st)
                children.append(SpaceNode(
                    name: cat.title,
                    path: nil,
                    size: st.totalSize,
                    color: cat.accentColor,
                    icon: cat.icon,
                    category: cat,
                    children: subNodes
                ))
            }
        }

        // 2. 重复文件多余占用
        let dupWasted = app.duplicateState.totalWastedBytes
        if dupWasted > 0 {
            scannedCleanableTotal += dupWasted
            var dupChildren: [SpaceNode] = []
            for grp in app.duplicateState.groups.prefix(8) {
                if grp.wastedBytes > 0 {
                    dupChildren.append(SpaceNode(
                        name: grp.items.first?.name ?? "重复组",
                        path: grp.items.first?.path,
                        size: grp.wastedBytes,
                        color: Color.purple.opacity(0.8),
                        icon: "doc.on.doc"
                    ))
                }
            }
            children.append(SpaceNode(
                name: "重复与相似文件",
                path: nil,
                size: dupWasted,
                color: Color.purple,
                icon: "doc.on.doc",
                children: dupChildren
            ))
        }

        // 3. 系统核心与其它应用占用
        let systemAndOther = max(0, app.diskUsed - scannedCleanableTotal)
        if systemAndOther > 0 {
            children.append(SpaceNode(
                name: "系统与应用在用数据",
                path: "/System",
                size: systemAndOther,
                color: Color(nsColor: .systemGray).opacity(0.7),
                icon: "internaldrive.fill",
                children: [
                    SpaceNode(name: "macOS 系统组件与框架", path: "/System", size: systemAndOther * 4 / 10, color: Color(nsColor: .systemGray).opacity(0.55), icon: "apple.logo"),
                    SpaceNode(name: "已安装应用程序本体", path: "/Applications", size: systemAndOther * 35 / 100, color: Color(nsColor: .systemGray).opacity(0.65), icon: "app.dashed"),
                    SpaceNode(name: "用户个人文稿与媒体", path: NSHomeDirectory(), size: systemAndOther * 25 / 100, color: Color(nsColor: .systemGray).opacity(0.75), icon: "folder.fill")
                ]
            ))
        }

        // 4. 可用空间 (Free)
        if app.diskAvailable > 0 {
            children.append(SpaceNode(
                name: "可用空间",
                path: nil,
                size: app.diskAvailable,
                color: Color(nsColor: .separatorColor).opacity(0.35),
                icon: "circle.dashed",
                children: []
            ))
        }

        // 排序：按体积降序
        children.sort { $0.size > $1.size }

        return SpaceNode(
            name: "Macintosh HD",
            path: "/",
            size: total,
            color: Theme.actionBlue,
            icon: "internaldrive",
            children: children
        )
    }

    /// 构建仅针对已扫描清理项的深入透视树
    static func buildCleanableDetail(app: AppState) -> SpaceNode {
        var children: [SpaceNode] = []
        var total: Int64 = 0

        for cat in CleanCategory.allCases {
            let st = app.state(for: cat)
            if st.totalSize > 0 {
                total += st.totalSize
                let subNodes = buildCategorySubnodes(category: cat, state: st)
                children.append(SpaceNode(
                    name: cat.title,
                    path: nil,
                    size: st.totalSize,
                    color: cat.accentColor,
                    icon: cat.icon,
                    category: cat,
                    children: subNodes
                ))
            }
        }

        let dupWasted = app.duplicateState.totalWastedBytes
        if dupWasted > 0 {
            total += dupWasted
            var dupChildren: [SpaceNode] = []
            for grp in app.duplicateState.groups.prefix(12) {
                if grp.wastedBytes > 0 {
                    dupChildren.append(SpaceNode(
                        name: grp.items.first?.name ?? "重复文件",
                        path: grp.items.first?.path,
                        size: grp.wastedBytes,
                        color: Color.purple.opacity(0.8),
                        icon: "doc.on.doc"
                    ))
                }
            }
            children.append(SpaceNode(
                name: "重复与相似文件",
                path: nil,
                size: dupWasted,
                color: Color.purple,
                icon: "doc.on.doc",
                children: dupChildren
            ))
        }

        children.sort { $0.size > $1.size }

        return SpaceNode(
            name: "已扫描可清理项",
            path: nil,
            size: max(1, total),
            color: Theme.actionBlue,
            icon: "sparkles",
            children: children
        )
    }

    /// 根据分类项自底向上提取子节点
    private static func buildCategorySubnodes(category: CleanCategory, state: CategoryState) -> [SpaceNode] {
        guard !state.items.isEmpty else { return [] }

        // 取出最大的前 15 项展示，其余合并为「其他小型项目」
        let sorted = state.items.sorted { $0.size > $1.size }
        let topCount = min(12, sorted.count)
        var subNodes: [SpaceNode] = []

        var topTotal: Int64 = 0
        for i in 0..<topCount {
            let it = sorted[i]
            topTotal += it.size
            let colorIdx = i % palette.count
            subNodes.append(SpaceNode(
                name: it.name,
                path: it.path,
                size: it.size,
                color: palette[colorIdx],
                icon: category.icon,
                category: category
            ))
        }

        let remaining = state.totalSize - topTotal
        if remaining > 0 && sorted.count > topCount {
            subNodes.append(SpaceNode(
                name: "其他 \(sorted.count - topCount) 个项目",
                path: nil,
                size: remaining,
                color: Color(nsColor: .tertiaryLabelColor).opacity(0.5),
                icon: "ellipsis.circle",
                category: category
            ))
        }

        return subNodes
    }
}

// MARK: - Squarified 矩形树图布局引擎

/// 渲染图元：节点与其在画布中的绝对布局矩形
struct TreemapTile: Identifiable, Equatable {
    let id: UUID
    let node: SpaceNode
    let rect: CGRect

    init(node: SpaceNode, rect: CGRect) {
        self.id = node.id
        self.node = node
        self.rect = rect
    }
}

enum TreemapEngine {
    /// 计算 Squarified 矩形树图布局
    static func layout(nodes: [SpaceNode], in targetRect: CGRect) -> [TreemapTile] {
        guard targetRect.width > 2 && targetRect.height > 2 else { return [] }

        // 过滤空尺寸并降序
        let validNodes = nodes.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        guard !validNodes.isEmpty else { return [] }

        let totalSize = validNodes.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return [] }

        // 映射为面积 (像素平方)
        let totalArea = Double(targetRect.width * targetRect.height)
        let areas = validNodes.map { (Double($0.size) / Double(totalSize)) * totalArea }

        var tiles: [TreemapTile] = []
        squarify(
            nodes: validNodes,
            areas: areas,
            currentRow: [],
            rowAreaSum: 0,
            rect: targetRect,
            tiles: &tiles
        )

        return tiles
    }

    private static func squarify(
        nodes: [SpaceNode],
        areas: [Double],
        currentRow: [SpaceNode],
        rowAreaSum: Double,
        rect: CGRect,
        tiles: inout [TreemapTile]
    ) {
        guard !nodes.isEmpty else {
            if !currentRow.isEmpty {
                layoutRow(currentRow, areaSum: rowAreaSum, in: rect, tiles: &tiles)
            }
            return
        }

        guard rect.width > 1 && rect.height > 1 else { return }

        let shortestEdge = Double(min(rect.width, rect.height))
        guard shortestEdge > 0 else { return }

        let nextNode = nodes[0]
        let nextArea = areas[0]

        let remainingNodes = Array(nodes.dropFirst())
        let remainingAreas = Array(areas.dropFirst())

        if currentRow.isEmpty {
            // 开启新行
            squarify(
                nodes: remainingNodes,
                areas: remainingAreas,
                currentRow: [nextNode],
                rowAreaSum: nextArea,
                rect: rect,
                tiles: &tiles
            )
        } else {
            let currentWorst = worstAspectRatio(rowAreas: currentRowAreas(currentRow, totalSum: rowAreaSum), length: shortestEdge)
            let newRow = currentRow + [nextNode]
            let newAreaSum = rowAreaSum + nextArea
            let newWorst = worstAspectRatio(rowAreas: currentRowAreas(newRow, totalSum: newAreaSum), length: shortestEdge)

            if newWorst <= currentWorst {
                // 加入此行并继续优化
                squarify(
                    nodes: remainingNodes,
                    areas: remainingAreas,
                    currentRow: newRow,
                    rowAreaSum: newAreaSum,
                    rect: rect,
                    tiles: &tiles
                )
            } else {
                // 冻结当前行，裁剪剩余区域并开启新行
                let remainingRect = layoutRow(currentRow, areaSum: rowAreaSum, in: rect, tiles: &tiles)
                squarify(
                    nodes: nodes,
                    areas: areas,
                    currentRow: [],
                    rowAreaSum: 0,
                    rect: remainingRect,
                    tiles: &tiles
                )
            }
        }
    }

    private static func worstAspectRatio(rowAreas: [Double], length: Double) -> Double {
        guard length > 0, !rowAreas.isEmpty else { return Double.infinity }
        let s = rowAreas.reduce(0, +)
        guard s > 0 else { return Double.infinity }
        let l2 = length * length
        var maxRatio: Double = 0
        for r in rowAreas {
            guard r > 0 else { continue }
            let ratio = max((l2 * r) / (s * s), (s * s) / (l2 * r))
            if ratio > maxRatio { maxRatio = ratio }
        }
        return maxRatio
    }

    private static func currentRowAreas(_ row: [SpaceNode], totalSum: Double) -> [Double] {
        let totalSize = row.reduce(0) { $0 + $1.size }
        guard totalSize > 0 else { return row.map { _ in 0.0 } }
        return row.map { (Double($0.size) / Double(totalSize)) * totalSum }
    }

    /// 布局一行并返回剩余可用矩形
    @discardableResult
    private static func layoutRow(
        _ row: [SpaceNode],
        areaSum: Double,
        in rect: CGRect,
        tiles: inout [TreemapTile]
    ) -> CGRect {
        guard !row.isEmpty, areaSum > 0 else { return rect }

        let isHorizontal = rect.width >= rect.height
        let totalRowSize = row.reduce(0) { $0 + $1.size }
        guard totalRowSize > 0 else { return rect }

        if isHorizontal {
            // 水平切割：这一行占用的宽度为 areaSum / height
            let rowWidth = min(rect.width, CGFloat(areaSum / Double(rect.height)))
            var currentY = rect.minY

            for node in row {
                let fraction = Double(node.size) / Double(totalRowSize)
                let itemHeight = CGFloat(Double(rect.height) * fraction)
                let tileRect = CGRect(x: rect.minX, y: currentY, width: rowWidth, height: itemHeight)
                tiles.append(TreemapTile(node: node, rect: tileRect))
                currentY += itemHeight
            }

            return CGRect(
                x: rect.minX + rowWidth,
                y: rect.minY,
                width: max(0, rect.width - rowWidth),
                height: rect.height
            )
        } else {
            // 垂直切割：这一行占用的高度为 areaSum / width
            let rowHeight = min(rect.height, CGFloat(areaSum / Double(rect.width)))
            var currentX = rect.minX

            for node in row {
                let fraction = Double(node.size) / Double(totalRowSize)
                let itemWidth = CGFloat(Double(rect.width) * fraction)
                let tileRect = CGRect(x: currentX, y: rect.minY, width: itemWidth, height: rowHeight)
                tiles.append(TreemapTile(node: node, rect: tileRect))
                currentX += itemWidth
            }

            return CGRect(
                x: rect.minX,
                y: rect.minY + rowHeight,
                width: rect.width,
                height: max(0, rect.height - rowHeight)
            )
        }
    }
}

// MARK: - 太阳花旭日图 (Sunburst) 几何引擎

/// 单个极坐标扇区图元
struct SunburstSector: Identifiable, Equatable {
    let id: UUID
    let node: SpaceNode
    let level: Int
    let startAngle: Double // 弧度 (0 ~ 2π)
    let endAngle: Double   // 弧度
    let innerRadius: Double
    let outerRadius: Double

    var angularSpan: Double {
        endAngle - startAngle
    }
}

enum SunburstEngine {
    /// 计算旭日图几何分块
    static func layout(root: SpaceNode, center: CGPoint, maxRadius: Double) -> [SunburstSector] {
        guard maxRadius > 20 else { return [] }

        var sectors: [SunburstSector] = []

        // 中心圆半径 (Level 0)
        let hubRadius = maxRadius * 0.28
        // 环宽
        let ringWidth = (maxRadius - hubRadius) / 2.0
        let level1Inner = hubRadius + 6.0
        let level1Outer = level1Inner + ringWidth - 4.0
        let level2Inner = level1Outer + 4.0
        let level2Outer = maxRadius

        let children = root.children.filter { $0.size > 0 }
        let total = children.reduce(0) { $0 + $1.size }
        guard total > 0 else { return [] }

        var currentAngle: Double = -Double.pi / 2.0 // 从正上方 12 点钟开始

        for child in children {
            let fraction = Double(child.size) / Double(total)
            let span = fraction * 2.0 * Double.pi
            let childStart = currentAngle
            let childEnd = currentAngle + span

            // Level 1 扇区
            sectors.append(SunburstSector(
                id: child.id,
                node: child,
                level: 1,
                startAngle: childStart,
                endAngle: childEnd,
                innerRadius: level1Inner,
                outerRadius: level1Outer
            ))

            // Level 2 扇区 (该子节点的下级目录/文件)
            let subChildren = child.children.filter { $0.size > 0 }
            let subTotal = subChildren.reduce(0) { $0 + $1.size }
            if subTotal > 0 {
                var subAngle = childStart
                for sub in subChildren {
                    let subFraction = Double(sub.size) / Double(subTotal)
                    let subSpan = subFraction * span
                    sectors.append(SunburstSector(
                        id: sub.id,
                        node: sub,
                        level: 2,
                        startAngle: subAngle,
                        endAngle: subAngle + subSpan,
                        innerRadius: level2Inner,
                        outerRadius: level2Outer
                    ))
                    subAngle += subSpan
                }
            }

            currentAngle = childEnd
        }

        return sectors
    }
}
