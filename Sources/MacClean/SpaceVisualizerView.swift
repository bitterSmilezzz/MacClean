import SwiftUI
import AppKit

/// 可视化展示模式
enum VisualizerMode: String, CaseIterable, Identifiable {
    case treemap = "矩形树图 (Treemap)"
    case sunburst = "旭日图 (Sunburst)"

    var id: String { rawValue }
}

/// 可视化维度范围
enum VisualizerScope: String, CaseIterable, Identifiable {
    case disk = "全盘存储概览"
    case cleanable = "已扫描可清理项"

    var id: String { rawValue }
}

/// 太阳花扇区形状
struct SunburstArcShape: Shape {
    let startAngle: Double
    let endAngle: Double
    let innerRadius: Double
    let outerRadius: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: Angle(radians: startAngle),
            endAngle: Angle(radians: endAngle),
            clockwise: false
        )
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: Angle(radians: endAngle),
            endAngle: Angle(radians: startAngle),
            clockwise: true
        )
        path.closeSubpath()
        return path
    }
}

/// 磁盘空间占用 Treemap / 太阳花旭日图可视化主视图
struct SpaceVisualizerView: View {
    @EnvironmentObject private var app: AppState

    @State var mode: VisualizerMode = .treemap
    @State var scope: VisualizerScope = .disk

    @State var rootNode: SpaceNode
    @State var currentNode: SpaceNode
    @State var breadcrumbStack: [SpaceNode] = []
    @State var hoveredNode: SpaceNode? = nil

    init(app: AppState? = nil) {
        let initialRoot: SpaceNode
        if let appState = app {
            initialRoot = SpaceHierarchyBuilder.buildDiskOverview(app: appState)
        } else {
            // 临时根，在 onAppear 或首轮中与环境 app 结合
            initialRoot = SpaceNode(name: "Macintosh HD", size: 1, color: Theme.actionBlue)
        }
        self._rootNode = State(initialValue: initialRoot)
        self._currentNode = State(initialValue: initialRoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶栏控制栏 (模式、维度、下钻返回)
            topBar

            Divider().overlay(Theme.separator)

            // MARK: - 面包屑路径条
            breadcrumbBar

            Divider().overlay(Theme.separator.opacity(0.5))

            // MARK: - 主图表画布区 (Treemap / Sunburst)
            ZStack {
                if mode == .treemap {
                    treemapSection
                } else {
                    sunburstSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)

            Divider().overlay(Theme.separator)

            // MARK: - 底部悬停探查器卡片
            detailInspector
        }
        .background(Theme.canvas)
        .onAppear {
            reloadHierarchy()
        }
        .onChange(of: scope) { _ in
            breadcrumbStack.removeAll()
            reloadHierarchy()
        }
    }

    // MARK: - 顶栏
    private var topBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "square.split.bottomrightquarter")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.actionBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("空间透视与图表分析")
                        .font(Theme.displayFont(15, weight: .bold))
                        .foregroundColor(Theme.labelPrimary)

                    Text("通过交互式 Treemap 矩形树图与极坐标旭日图，宏观洞察磁盘占用分布")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                }
            }

            Spacer()

            // 范围选择器
            Picker("透视范围", selection: $scope) {
                Text("全盘存储").tag(VisualizerScope.disk)
                Text("可清理细分").tag(VisualizerScope.cleanable)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .controlSize(.small)

            // 模式选择器
            Picker("图表形态", selection: $mode) {
                Text("矩形树图").tag(VisualizerMode.treemap)
                Text("旭日图").tag(VisualizerMode.sunburst)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            .controlSize(.small)

            Button {
                app.scanAll()
                reloadHierarchy()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("重新扫描并刷新空间树")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.parchment)
    }

    // MARK: - 面包屑导航栏
    private var breadcrumbBar: some View {
        HStack(spacing: 8) {
            Button {
                popToRoot()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: rootNode.icon ?? "internaldrive")
                        .font(.system(size: 11))
                    Text(rootNode.name)
                        .font(Theme.bodyFont(12, weight: breadcrumbStack.isEmpty ? .bold : .regular))
                }
                .foregroundColor(breadcrumbStack.isEmpty ? Theme.actionBlue : Theme.labelSecondary)
            }
            .buttonStyle(.plain)

            ForEach(breadcrumbStack.indices, id: \.self) { idx in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.labelTertiary)

                Button {
                    popTo(index: idx)
                } label: {
                    Text(breadcrumbStack[idx].name)
                        .font(Theme.bodyFont(12, weight: .regular))
                        .foregroundColor(Theme.labelSecondary)
                }
                .buttonStyle(.plain)
            }

            if !breadcrumbStack.isEmpty {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.labelTertiary)

                Text(currentNode.name)
                    .font(Theme.bodyFont(12, weight: .bold))
                    .foregroundColor(Theme.actionBlue)
            }

            Spacer()

            if !breadcrumbStack.isEmpty {
                Button {
                    popOneLevel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                        Text("返回上一层")
                            .font(Theme.bodyFont(11, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("当前层级总计：\(currentNode.formattedSize)")
                .font(Theme.monoFont(11, weight: .medium))
                .foregroundColor(Theme.labelSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Treemap 矩形树图部分
    private var treemapSection: some View {
        GeometryReader { proxy in
            let tiles = computeTreemapTiles(in: proxy.size)
            ZStack(alignment: .topLeading) {
                ForEach(tiles) { tile in
                    treemapTileView(tile: tile)
                        .position(x: tile.rect.midX, y: tile.rect.midY)
                }
            }
        }
        .padding(8)
    }

    private func computeTreemapTiles(in size: CGSize) -> [TreemapTile] {
        let bounds = CGRect(origin: .zero, size: size)
        let displayNodes = currentNode.children.isEmpty ? [currentNode] : currentNode.children
        return TreemapEngine.layout(nodes: displayNodes, in: bounds)
    }

    private func treemapTileView(tile: TreemapTile) -> some View {
        let isHovered = hoveredNode?.id == tile.node.id
        let hasChildren = !tile.node.children.isEmpty
        let width = tile.rect.width - 2
        let height = tile.rect.height - 2

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tile.node.color.opacity(isHovered ? 0.92 : 0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isHovered ? Color.white.opacity(0.9) : Theme.hairline, lineWidth: isHovered ? 1.5 : 0.5)
                )

            // 内部文本（空间足够时才展示，避免重叠溢出）
            if width >= 50 && height >= 32 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let icon = tile.node.icon {
                            Image(systemName: icon)
                                .font(.system(size: 10))
                        }
                        Text(tile.node.name)
                            .font(Theme.bodyFont(11, weight: .bold))
                            .lineLimit(1)
                    }

                    Text(tile.node.formattedSize)
                        .font(Theme.monoFont(10, weight: .medium))

                    if height >= 52 {
                        Text(tile.node.percentageString(of: currentNode.size))
                            .font(Theme.monoFont(9))
                            .opacity(0.85)
                    }
                }
                .foregroundColor(.white)
                .padding(6)
            }
        }
        .frame(width: max(0, width), height: max(0, height))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                hoveredNode = hovering ? tile.node : nil
            }
        }
        .onTapGesture {
            if hasChildren {
                drillDown(into: tile.node)
            }
        }
    }

    // MARK: - 太阳花旭日图部分
    private var sunburstSection: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2.0, y: proxy.size.height / 2.0)
            let maxRadius = Double(min(proxy.size.width, proxy.size.height) / 2.0) - 16.0
            let sectors = SunburstEngine.layout(root: currentNode, center: center, maxRadius: max(40, maxRadius))

            ZStack {
                // 外层扇区渲染
                ForEach(sectors) { sector in
                    sunburstSectorView(sector: sector, center: center)
                }

                // 中心核心圆盘 (Level 0 当前层级)
                Circle()
                    .fill(Theme.parchment)
                    .frame(width: CGFloat(maxRadius * 0.54), height: CGFloat(maxRadius * 0.54))
                    .overlay(
                        Circle()
                            .stroke(Theme.hairline, lineWidth: 0.5)
                    )
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: currentNode.icon ?? "chart.pie.fill")
                                .font(.system(size: 16))
                                .foregroundColor(Theme.actionBlue)

                            Text(currentNode.name)
                                .font(Theme.bodyFont(11, weight: .bold))
                                .foregroundColor(Theme.labelPrimary)
                                .lineLimit(1)

                            Text(currentNode.formattedSize)
                                .font(Theme.monoFont(12, weight: .semibold))
                                .foregroundColor(Theme.labelSecondary)
                        }
                        .padding(8)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(8)
    }

    private func sunburstSectorView(sector: SunburstSector, center: CGPoint) -> some View {
        let isHovered = hoveredNode?.id == sector.node.id
        let shape = SunburstArcShape(
            startAngle: sector.startAngle,
            endAngle: sector.endAngle,
            innerRadius: sector.innerRadius,
            outerRadius: sector.outerRadius
        )

        return shape
            .fill(sector.node.color.opacity(isHovered ? 0.95 : (sector.level == 1 ? 0.82 : 0.65)))
            .overlay(
                shape
                    .stroke(isHovered ? Color.white : Theme.canvas.opacity(0.8), lineWidth: isHovered ? 2.0 : 1.0)
            )
            .contentShape(shape)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    hoveredNode = hovering ? sector.node : nil
                }
            }
            .onTapGesture {
                if !sector.node.children.isEmpty {
                    drillDown(into: sector.node)
                }
            }
    }

    // MARK: - 底部悬停探查器卡片
    private var detailInspector: some View {
        let target = hoveredNode ?? currentNode
        return HStack(spacing: 12) {
            // 图标与色彩
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(target.color)
                    .frame(width: 14, height: 14)

                Image(systemName: target.icon ?? "folder")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.labelPrimary)

                Text(target.name)
                    .font(Theme.bodyFont(13, weight: .bold))
                    .foregroundColor(Theme.labelPrimary)
            }

            Text("·")
                .foregroundColor(Theme.labelTertiary)

            Text(target.formattedSize)
                .font(Theme.monoFont(13, weight: .semibold))
                .foregroundColor(Theme.actionBlue)

            Text("(\(target.percentageString(of: currentNode.size)))")
                .font(Theme.monoFont(11))
                .foregroundColor(Theme.labelSecondary)

            if let p = target.path, !p.isEmpty {
                Text("·")
                    .foregroundColor(Theme.labelTertiary)

                Text(p)
                    .font(Theme.monoFont(10))
                    .foregroundColor(Theme.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // 快捷操作按钮
            if let p = target.path, !p.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: CleanPaths.expand(p))])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .font(Theme.bodyFont(11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let cat = target.category {
                Button {
                    app.destination = .category(cat)
                } label: {
                    Label("前往清理", systemImage: "arrow.right.circle")
                        .font(Theme.bodyFont(11))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.actionBlue)
                .controlSize(.small)
            }

            if !target.children.isEmpty && target.id != currentNode.id {
                Button {
                    drillDown(into: target)
                } label: {
                    Label("下钻透视", systemImage: "plus.magnifyingglass")
                        .font(Theme.bodyFont(11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.parchment)
    }

    // MARK: - 下钻与导航

    func drillDown(into node: SpaceNode) {
        guard !node.children.isEmpty else { return }
        withAnimation(Theme.smoothTransition) {
            breadcrumbStack.append(currentNode)
            currentNode = node
            hoveredNode = nil
        }
    }

    func popOneLevel() {
        guard let parent = breadcrumbStack.popLast() else { return }
        withAnimation(Theme.smoothTransition) {
            currentNode = parent
            hoveredNode = nil
        }
    }

    func popTo(index: Int) {
        guard breadcrumbStack.indices.contains(index) else { return }
        let target = breadcrumbStack[index]
        withAnimation(Theme.smoothTransition) {
            breadcrumbStack = Array(breadcrumbStack.prefix(index))
            currentNode = target
            hoveredNode = nil
        }
    }

    func popToRoot() {
        withAnimation(Theme.smoothTransition) {
            breadcrumbStack.removeAll()
            currentNode = rootNode
            hoveredNode = nil
        }
    }

    func reloadHierarchy() {
        let newRoot: SpaceNode
        if scope == .disk {
            newRoot = SpaceHierarchyBuilder.buildDiskOverview(app: app)
        } else {
            newRoot = SpaceHierarchyBuilder.buildCleanableDetail(app: app)
        }
        self.rootNode = newRoot
        self.currentNode = newRoot
    }
}
