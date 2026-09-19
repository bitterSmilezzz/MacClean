import SwiftUI
import AppKit
import QuickLook

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
///
/// 重写要点：
///  - 图表本身就是数据可视化，分类色照旧（`SpaceNode.color` 来自 `ChartPalette`）；
///    但图表**周围**的一切——标题栏、面包屑、探查条、图例——全部收回到单一强调色与文本灰阶，
///    否则六种分类色会从画布溢出成整页的装饰色。
///  - 顶部标题区删掉「通过交互式 Treemap…宏观洞察」这类装饰性副标题：它不携带信息，
///    只是把标题行撑满。当前层级的体积是真实数据，留在面包屑条右侧。
///  - `Divider().overlay(...)` 统一换成 `Hairline`，避免各处分隔线深浅不一。
///  - 探查条上的三个等高描边按钮减为一个主操作 + 两个文本动作，降低视觉噪声。
struct SpaceVisualizerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var app: AppState

    @State var mode: VisualizerMode = .treemap
    @State var scope: VisualizerScope = .disk
    @State var colorMode: ColorCodingMode = .fileType

    @State var rootNode: SpaceNode
    @State var currentNode: SpaceNode
    @State var breadcrumbStack: [SpaceNode] = []
    @State var hoveredNode: SpaceNode? = nil
    @State var isExpandingDir: Bool = false
    @State var quickLookURL: URL? = nil

    init(app: AppState? = nil) {
        let initialRoot: SpaceNode
        if let appState = app {
            initialRoot = SpaceHierarchyBuilder.buildDiskOverview(app: appState)
        } else {
            // 临时根，在 onAppear 或首轮中与环境 app 结合
            initialRoot = SpaceNode(name: "Macintosh HD", size: 1, color: Accent.tint)
        }
        self._rootNode = State(initialValue: initialRoot)
        self._currentNode = State(initialValue: initialRoot)
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶栏控制栏 (模式、维度、刷新)
            topBar

            Hairline()

            // MARK: - 面包屑路径条
            breadcrumbBar

            Hairline()

            // MARK: - 主图表画布区 (Treemap / Sunburst)
            ZStack {
                if mode == .treemap {
                    treemapSection
                } else {
                    sunburstSection
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Surface.window)

            Hairline()

            // MARK: - 底部悬停探查条
            detailInspector
        }
        .background(Surface.window)
        .quickLookPreview($quickLookURL)
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
        HStack(spacing: Space.sm) {
            Text("空间透视")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Spacer(minLength: Space.sm)

            // 范围选择器
            Picker("透视范围", selection: $scope) {
                Text("全盘存储").tag(VisualizerScope.disk)
                Text("可清理细分").tag(VisualizerScope.cleanable)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)
            .controlSize(.small)

            // 色彩编码选择器
            Picker("色彩编码", selection: $colorMode) {
                Text("按类型").tag(ColorCodingMode.fileType)
                Text("按分类").tag(ColorCodingMode.category)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            .controlSize(.small)
            .accessibilityIdentifier("visualizerColorModePicker")

            // 模式选择器
            Picker("图表形态", selection: $mode) {
                Text("矩形树图").tag(VisualizerMode.treemap)
                Text("旭日图").tag(VisualizerMode.sunburst)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .controlSize(.small)

            Button {
                app.scanAll()
                reloadHierarchy()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(Typo.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("重新扫描并刷新空间树")
            .accessibilityLabel("重新扫描并刷新空间树")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
    }

    // MARK: - 面包屑导航栏
    private var breadcrumbBar: some View {
        HStack(spacing: Space.xs) {
            Button {
                popToRoot()
            } label: {
                HStack(spacing: Space.xxs) {
                    IconSlot(
                        systemName: rootNode.icon ?? "internaldrive",
                        size: 11,
                        color: breadcrumbStack.isEmpty ? Ink.primary : Ink.secondary,
                        width: 14
                    )
                    Text(rootNode.name)
                        .font(breadcrumbStack.isEmpty ? Typo.rowStrong : Typo.row)
                        .foregroundStyle(breadcrumbStack.isEmpty ? Ink.primary : Ink.secondary)
                }
                .contentShape(Rectangle())
            }
            .pressable()

            ForEach(breadcrumbStack.indices, id: \.self) { idx in
                Image(systemName: "chevron.right")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.quaternary)

                Button {
                    popTo(index: idx)
                } label: {
                    Text(breadcrumbStack[idx].name)
                        .font(Typo.row)
                        .foregroundStyle(Ink.secondary)
                        .contentShape(Rectangle())
                }
                .pressable()
            }

            if !breadcrumbStack.isEmpty {
                Image(systemName: "chevron.right")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.quaternary)

                Text(currentNode.name)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
            }

            if isExpandingDir {
                HStack(spacing: Space.xxs) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在测算目录…")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(.leading, Space.xs)
            }

            Spacer(minLength: Space.sm)

            if !breadcrumbStack.isEmpty {
                Button {
                    popOneLevel()
                } label: {
                    Label("返回上一层", systemImage: "arrow.uturn.backward")
                        .font(Typo.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: Space.xxs) {
                Text("当前层级总计")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                Text(currentNode.formattedSize)
                    .font(.mcNumeric(11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .motionSafeNumericTransition()
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, 7)
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
        .padding(Space.xs)
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
        let displayColor = tile.node.displayColor(for: colorMode)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .fill(displayColor.opacity(isHovered ? 0.95 : 0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .stroke(isHovered ? Color.white.opacity(0.9) : Surface.hairline, lineWidth: isHovered ? 1.5 : 0.5)
                )

            // 内部文本（空间足够时才展示，避免重叠溢出）
            if width >= 50 && height >= 32 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xxs) {
                        if let icon = tile.node.icon {
                            Image(systemName: icon)
                                .font(Typo.micro)
                        }
                        Text(tile.node.name)
                            .font(Typo.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }

                    Text(tile.node.formattedSize)
                        .font(.mcNumeric(10, weight: .medium))

                    if height >= 52 {
                        Text(tile.node.percentageString(of: currentNode.size))
                            .font(.mcNumeric(10))
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(displayColor.readableForeground(for: colorScheme))
                .padding(6)
            }
        }
        .frame(width: max(0, width), height: max(0, height))
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(Motion.micro) {
                hoveredNode = hovering ? tile.node : nil
            }
        }
        .onTapGesture {
            if hasChildren {
                drillDown(into: tile.node)
            } else if tile.node.isExpandableDir {
                expandAndDrillDown(tile.node)
            } else if let p = tile.node.path, !p.isEmpty {
                quickLookURL = URL(fileURLWithPath: CleanPaths.expand(p))
            }
        }
        .contextMenu {
            nodeContextMenu(for: tile.node)
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
                    .fill(Surface.group)
                    .frame(width: CGFloat(maxRadius * 0.54), height: CGFloat(maxRadius * 0.54))
                    .overlay(
                        Circle()
                            .stroke(Surface.hairline, lineWidth: 0.5)
                    )
                    .overlay(
                        VStack(spacing: 2) {
                            Image(systemName: currentNode.icon ?? "chart.pie.fill")
                                .font(Typo.title)
                                .foregroundStyle(Ink.secondary)

                            Text(currentNode.name)
                                .font(Typo.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)

                            Text(currentNode.formattedSize)
                                .font(.mcNumeric(12, weight: .semibold))
                                .foregroundStyle(Ink.secondary)
                        }
                        .padding(Space.xs)
                    )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Space.xs)
    }

    private func sunburstSectorView(sector: SunburstSector, center: CGPoint) -> some View {
        let isHovered = hoveredNode?.id == sector.node.id
        let displayColor = sector.node.displayColor(for: colorMode)
        let shape = SunburstArcShape(
            startAngle: sector.startAngle,
            endAngle: sector.endAngle,
            innerRadius: sector.innerRadius,
            outerRadius: sector.outerRadius
        )

        return shape
            .fill(displayColor.opacity(isHovered ? 0.95 : (sector.level == 1 ? 0.82 : 0.65)))
            .overlay(
                shape
                    .stroke(isHovered ? Color.white : Surface.window.opacity(0.8), lineWidth: isHovered ? 2.0 : 1.0)
            )
            .contentShape(shape)
            .onHover { hovering in
                withAnimation(Motion.micro) {
                    hoveredNode = hovering ? sector.node : nil
                }
            }
            .onTapGesture {
                if !sector.node.children.isEmpty {
                    drillDown(into: sector.node)
                } else if sector.node.isExpandableDir {
                    expandAndDrillDown(sector.node)
                } else if let p = sector.node.path, !p.isEmpty {
                    quickLookURL = URL(fileURLWithPath: CleanPaths.expand(p))
                }
            }
            .contextMenu {
                nodeContextMenu(for: sector.node)
            }
    }

    // MARK: - 底部悬停探查条
    //
    // 左侧是"当前指向的节点"的读数：色点（对应画布里的序列色）+ 图标 + 名称 + 体积 + 占比 + 路径。
    // 读数用 `.mcNumeric` 等宽数字，鼠标扫过画布时数字不会左右跳动。
    private var detailInspector: some View {
        let target = hoveredNode ?? currentNode
        let targetColor = target.displayColor(for: colorMode)
        return HStack(spacing: Space.sm) {
            // 序列色点：与画布中该节点的填充色一一对应
            Circle()
                .fill(targetColor)
                .frame(width: 7, height: 7)

            IconSlot(systemName: target.icon ?? "folder", size: 12, color: Ink.secondary, width: 16)

            Text(target.name)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)

            Text(target.formattedSize)
                .font(.mcNumeric(12, weight: .semibold))
                .foregroundStyle(Ink.primary)

            Text(target.percentageString(of: currentNode.size))
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)

            if let p = target.path, !p.isEmpty {
                Rectangle()
                    .fill(Surface.hairline.opacity(0.6))
                    .frame(width: 0.5, height: 14)

                Text(p)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.sm)

            // 动作：快捷预览与在访达中显示
            if let p = target.path, !p.isEmpty {
                let expanded = CleanPaths.expand(p)
                Button {
                    quickLookURL = URL(fileURLWithPath: expanded)
                } label: {
                    Label("快速预览", systemImage: "eye")
                        .font(Typo.caption)
                        .contentShape(Rectangle())
                }
                .pressable()
                .foregroundStyle(Accent.tint)
                .accessibilityIdentifier("visualizerQuickLookButton")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .font(Typo.caption)
                        .contentShape(Rectangle())
                }
                .pressable()
                .foregroundStyle(Accent.tint)
                .accessibilityIdentifier("visualizerFinderButton")
            }

            if let cat = target.category {
                Button {
                    app.destination = .category(cat)
                } label: {
                    Label("前往清理", systemImage: "arrow.right.circle")
                        .font(Typo.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if !target.children.isEmpty && target.id != currentNode.id {
                Button {
                    drillDown(into: target)
                } label: {
                    Label("下钻透视", systemImage: "plus.magnifyingglass")
                        .font(Typo.caption)
                        .contentShape(Rectangle())
                }
                .pressable()
                .foregroundStyle(Accent.tint)
            } else if target.isExpandableDir && target.id != currentNode.id {
                Button {
                    expandAndDrillDown(target)
                } label: {
                    Label("展开下钻", systemImage: "plus.magnifyingglass")
                        .font(Typo.caption)
                        .contentShape(Rectangle())
                }
                .pressable()
                .foregroundStyle(Accent.tint)
                .disabled(isExpandingDir)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .background(Surface.group)
    }

    // MARK: - 右键上下文菜单构建
    @ViewBuilder
    private func nodeContextMenu(for node: SpaceNode) -> some View {
        if let p = node.path, !p.isEmpty {
            let expanded = CleanPaths.expand(p)
            let url = URL(fileURLWithPath: expanded)

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                quickLookURL = url
            } label: {
                Label("快速预览", systemImage: "eye")
            }

            if !node.children.isEmpty {
                Button {
                    drillDown(into: node)
                } label: {
                    Label("下钻深入此目录", systemImage: "plus.magnifyingglass")
                }
            } else if node.isExpandableDir {
                Button {
                    expandAndDrillDown(node)
                } label: {
                    Label("展开下钻此目录", systemImage: "plus.magnifyingglass")
                }
            }

            Divider()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(expanded, forType: .string)
            } label: {
                Label("拷贝完整路径", systemImage: "doc.on.doc")
            }

            Button {
                app.addPathToWhitelist(expanded, comment: node.name)
            } label: {
                Label("加入白名单排除", systemImage: "shield.slash")
            }
        }
    }

    // MARK: - 下钻与导航

    func drillDown(into node: SpaceNode) {
        guard !node.children.isEmpty else { return }
        withAnimation(Motion.standard) {
            breadcrumbStack.append(currentNode)
            currentNode = node
            hoveredNode = nil
        }
    }

    func expandAndDrillDown(_ node: SpaceNode) {
        guard let p = node.path, !p.isEmpty, !isExpandingDir else { return }
        isExpandingDir = true
        DispatchQueue.global(qos: .userInitiated).async {
            let subNodes = SpaceHierarchyBuilder.expandDirectory(path: p, colorMode: self.colorMode)
            DispatchQueue.main.async {
                self.isExpandingDir = false
                guard !subNodes.isEmpty else { return }
                var expandedNode = node
                expandedNode.children = subNodes
                self.drillDown(into: expandedNode)
            }
        }
    }

    func popOneLevel() {
        guard let parent = breadcrumbStack.popLast() else { return }
        withAnimation(Motion.standard) {
            currentNode = parent
            hoveredNode = nil
        }
    }

    func popTo(index: Int) {
        guard breadcrumbStack.indices.contains(index) else { return }
        let target = breadcrumbStack[index]
        withAnimation(Motion.standard) {
            breadcrumbStack = Array(breadcrumbStack.prefix(index))
            currentNode = target
            hoveredNode = nil
        }
    }

    func popToRoot() {
        withAnimation(Motion.standard) {
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
