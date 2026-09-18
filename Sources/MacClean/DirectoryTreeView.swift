import SwiftUI
import AppKit

/// 交互式目录树状勾选与分支筛选面板。
///
/// 重写要点：
///  - 顶栏的"圆形色块 + 图标"标头和那句自我介绍式副标题一起去掉：标题就是标题，
///    装饰性说明不携带任何可操作信息。
///  - 手搓的 `TextField` + 背景 + 描边换成 `SearchField` 原语；四个等权描边按钮降级为
///    无边框工具动作，减少工具栏的视觉重量。
///  - "当前筛选 / 排除扫描"的胶囊徽标改成着色小字：行内不再堆色块，颜色只用来标记
///    真正需要注意的状态。
///  - 三态勾选仍用方框图标（已选 / 半选 / 未选），语义不变。
struct DirectoryTreeSheet: View {
    let title: String
    let entries: [DirectoryTreeBuilder.FileEntry]
    let activeFilterPath: String?
    var onApplyFilter: (String?) -> Void
    var onToggleBatchSelection: (String, Bool) -> Void
    var onDismiss: () -> Void

    @StateObject private var scopeManager = DirectoryScopeManager.shared
    @State private var searchQuery: String = ""
    @State private var treeNodes: [DirectoryTreeNode] = []
    @State private var expandedPaths: Set<String> = []
    @State private var selectedFilterPath: String? = nil

    init(
        title: String,
        entries: [DirectoryTreeBuilder.FileEntry],
        activeFilterPath: String?,
        onApplyFilter: @escaping (String?) -> Void,
        onToggleBatchSelection: @escaping (String, Bool) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.title = title
        self.entries = entries
        self.activeFilterPath = activeFilterPath
        self.onApplyFilter = onApplyFilter
        self.onToggleBatchSelection = onToggleBatchSelection
        self.onDismiss = onDismiss
        _selectedFilterPath = State(initialValue: activeFilterPath)
        let built = DirectoryTreeBuilder.buildTree(from: entries, defaultExpandedLevel: 2)
        _treeNodes = State(initialValue: built)
        var paths = Set<String>()
        func collect(nodes: [DirectoryTreeNode]) {
            for n in nodes {
                if n.isExpanded {
                    paths.insert(n.path)
                    collect(nodes: n.children)
                }
            }
        }
        collect(nodes: built)
        _expandedPaths = State(initialValue: paths)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            toolbar
            Hairline()

            if treeNodes.isEmpty {
                emptyView
            } else {
                treeListView
            }

            Hairline()
            footer
        }
        .frame(width: 680, height: 560)
        .background(Surface.window)
        .onAppear {
            selectedFilterPath = activeFilterPath
            reloadTree()
        }
    }

    // MARK: - 顶栏
    private var header: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "folder.badge.gearshape", size: 15, weight: .medium,
                     color: Ink.secondary, width: 18)

            Text(title)
                .font(Typo.title)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)

            Spacer(minLength: Space.sm)

            Button("完成") {
                onApplyFilter(selectedFilterPath)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("directoryTreeDoneButton")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(Surface.window)
    }

    // MARK: - 工具栏
    private var toolbar: some View {
        HStack(spacing: Space.xs) {
            SearchField(placeholder: "按目录名或路径检索…", text: $searchQuery, width: 240)

            Spacer(minLength: Space.xs)

            if selectedFilterPath != nil {
                Button {
                    selectedFilterPath = nil
                } label: {
                    Label("清除分支筛选", systemImage: "xmark.circle")
                        .font(Typo.row)
                }
                .buttonStyle(.borderless)
                .pressable()
                .foregroundStyle(Signal.caution)
                .help("取消当前目录分支筛选，恢复显示全部目录")
            }

            Button {
                expandAll()
            } label: {
                Label("全部展开", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(Typo.row)
            }
            .buttonStyle(.borderless)
            .pressable()
            .foregroundStyle(Ink.secondary)
            .help("展开全部目录分支")

            Button {
                collapseAll()
            } label: {
                Label("全部收起", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(Typo.row)
            }
            .buttonStyle(.borderless)
            .pressable()
            .foregroundStyle(Ink.secondary)
            .help("收起全部目录分支")

            Button {
                addCustomFolder()
            } label: {
                Label("添加扫描目录…", systemImage: "plus")
                    .font(Typo.row)
            }
            .buttonStyle(.borderless)
            .pressable()
            .foregroundStyle(Accent.tint)
            .accessibilityIdentifier("addCustomScanFolderButton")
            .help("选择 macOS 本机文件夹加入扫描监控")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .background(Surface.window)
    }

    // MARK: - 目录树列表
    private var treeListView: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(visibleNodes(from: treeNodes, depth: 0)) { item in
                    DirectoryTreeNodeRow(
                        node: item.node,
                        depth: item.depth,
                        isExpanded: expandedPaths.contains(item.node.path),
                        isCurrentFilterTarget: selectedFilterPath == item.node.path,
                        isExcludedFromScan: scopeManager.isPathExcluded(item.node.path),
                        onToggleExpand: {
                            toggleExpand(path: item.node.path)
                        },
                        onToggleCheck: {
                            let target = item.node.checkState != .all
                            onToggleBatchSelection(item.node.path, target)
                            // 延时重载树结构勾选状态
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                reloadTree()
                            }
                        },
                        onSelectFilter: {
                            if selectedFilterPath == item.node.path {
                                selectedFilterPath = nil
                            } else {
                                selectedFilterPath = item.node.path
                            }
                        },
                        onToggleScanExclude: {
                            scopeManager.togglePathExcluded(item.node.path)
                        }
                    )
                }
            }
            .padding(.vertical, Space.xxs)
            .padding(.horizontal, Space.xs)
        }
    }

    // MARK: - 空态
    private var emptyView: some View {
        VStack(spacing: 0) {
            Spacer()
            EmptyState(
                icon: "folder.badge.minus",
                title: "暂无目录数据",
                message: "扫描完成后将自动解析出包含大文件或重复副本的各级目录。"
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底栏
    private var footer: some View {
        let totalFiles = entries.count
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let selectedBytes = entries.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.size }

        return HStack(spacing: Space.md) {
            Text("共 \(countAllNodes(treeNodes)) 个目录 · \(totalFiles) 个文件（\(totalBytes.byteStringCN)）")
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()

            Spacer(minLength: Space.sm)

            Text("已勾选清理 \(selectedBytes.byteStringCN)")
                .font(.mcNumeric(11, weight: .medium))
                .foregroundStyle(selectedBytes > 0 ? Accent.tint : Ink.tertiary)
                .motionSafeNumericTransition()

            if let filter = selectedFilterPath {
                HStack(spacing: Space.xxs) {
                    Text("当前筛选")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                    Text(displayShortPath(filter))
                        .font(.mcNumeric(11, weight: .medium))
                        .foregroundStyle(Signal.caution)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .background(Surface.window)
    }

    // MARK: - 数据处理与辅助
    private func reloadTree() {
        let built = DirectoryTreeBuilder.buildTree(from: entries, defaultExpandedLevel: 2)
        self.treeNodes = built
        if expandedPaths.isEmpty {
            collectDefaultExpanded(nodes: built)
        }
    }

    private func collectDefaultExpanded(nodes: [DirectoryTreeNode]) {
        for node in nodes {
            if node.isExpanded {
                expandedPaths.insert(node.path)
                collectDefaultExpanded(nodes: node.children)
            }
        }
    }

    private func expandAll() {
        var allPaths: Set<String> = []
        func collect(nodes: [DirectoryTreeNode]) {
            for n in nodes {
                if !n.children.isEmpty {
                    allPaths.insert(n.path)
                    collect(nodes: n.children)
                }
            }
        }
        collect(nodes: treeNodes)
        expandedPaths = allPaths
    }

    private func collapseAll() {
        expandedPaths.removeAll()
    }

    private func toggleExpand(path: String) {
        if expandedPaths.contains(path) {
            expandedPaths.remove(path)
        } else {
            expandedPaths.insert(path)
        }
    }

    private struct FlattenedItem: Identifiable {
        var id: String { node.path }
        let node: DirectoryTreeNode
        let depth: Int
    }

    private func visibleNodes(from nodes: [DirectoryTreeNode], depth: Int) -> [FlattenedItem] {
        var result: [FlattenedItem] = []
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        for node in nodes {
            let matchesSearch = query.isEmpty || node.displayName.lowercased().contains(query) || node.path.lowercased().contains(query)
            if matchesSearch {
                result.append(FlattenedItem(node: node, depth: depth))
            }

            // 如果该节点已展开或处于搜索过滤状态下，递归下钻
            if (!query.isEmpty || expandedPaths.contains(node.path)) && !node.children.isEmpty {
                result.append(contentsOf: visibleNodes(from: node.children, depth: depth + 1))
            }
        }
        return result
    }

    private func countAllNodes(_ nodes: [DirectoryTreeNode]) -> Int {
        var count = nodes.count
        for n in nodes {
            count += countAllNodes(n.children)
        }
        return count
    }

    private func addCustomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "选择扫描目录"
        panel.message = "选择要加入 MacClean 扫描范围的文件夹"
        if panel.runModal() == .OK {
            for url in panel.urls {
                scopeManager.addRootPath(url.path)
            }
        }
    }

    private func displayShortPath(_ path: String) -> String {
        let home = CleanPaths.expand("~")
        if path.hasPrefix(home) {
            return path.replacingOccurrences(of: home, with: "~")
        }
        return path
    }
}

/// 目录树单行视图。密集数据行：缩进 + 展开箭头 + 三态勾选框 + 名称 + 右对齐统计。
struct DirectoryTreeNodeRow: View {
    let node: DirectoryTreeNode
    let depth: Int
    let isExpanded: Bool
    let isCurrentFilterTarget: Bool
    let isExcludedFromScan: Bool
    var onToggleExpand: () -> Void
    var onToggleCheck: () -> Void
    var onSelectFilter: () -> Void
    var onToggleScanExclude: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.xs) {
            // 缩进与展开箭头
            disclosureControl

            // 三态 Checkbox：已选 / 半选 / 未选
            checkToggle

            // 文件夹图标与名称
            nameColumn

            Spacer(minLength: Space.xs)

            // 统计列：条目数 / 体积，右对齐便于纵向比较
            statColumns

            // 悬停/常驻快捷过滤按钮：仅一个动作，不带底色
            filterActionButton
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(isCurrentFilterTarget ? Signal.caution.opacity(0.10) : Color.clear)
        )
        .rowHover()
        .onHover { isHovering = $0 }
        .contextMenu {
            rowContextMenu
        }
    }

    /// 缩进占位 + 展开/收起箭头；叶子节点只留占位。
    private var disclosureControl: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: CGFloat(depth * 20))

            if !node.children.isEmpty {
                Button {
                    onToggleExpand()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .motionSafe(Motion.micro, value: isExpanded)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pressable()
                .help(isExpanded ? "收起此目录" : "展开此目录")
                .accessibilityLabel(isExpanded ? "收起此目录" : "展开此目录")
            } else {
                Spacer().frame(width: 16)
            }
        }
    }

    /// 三态勾选框：批量勾选或取消此目录下全部文件。
    private var checkToggle: some View {
        Button {
            onToggleCheck()
        } label: {
            checkIcon
                .font(.system(size: 14))
                .frame(width: 18, height: 18, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .help("批量勾选或取消此目录下全部文件")
    }

    /// 文件夹图标 + 名称 + 「当前筛选 / 排除扫描」标记。
    private var nameColumn: some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(isCurrentFilterTarget ? Signal.caution : Ink.secondary)

            Text(node.displayName)
                .font(depth == 0 ? Typo.rowStrong : Typo.row)
                .foregroundStyle(isCurrentFilterTarget ? Signal.caution : Ink.primary)
                .lineLimit(1)

            if isCurrentFilterTarget {
                Text("当前筛选")
                    .font(Typo.micro)
                    .foregroundStyle(Signal.caution)
            }

            if isExcludedFromScan {
                Text("排除扫描")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    /// 统计列：条目数 / 体积，右对齐便于纵向比较。
    @ViewBuilder
    private var statColumns: some View {
        Text("\(node.fileCount) 项")
            .font(.mcNumeric(11))
            .foregroundStyle(Ink.tertiary)
            .frame(width: 56, alignment: .trailing)

        Text(node.totalBytes.byteStringCN)
            .font(.mcNumeric(11, weight: .medium))
            .foregroundStyle(Ink.secondary)
            .frame(minWidth: 64, alignment: .trailing)
    }

    /// 悬停/常驻的快捷过滤按钮：仅一个动作，不带底色。
    private var filterActionButton: some View {
        Button {
            onSelectFilter()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: isCurrentFilterTarget ? "checkmark.circle.fill" : "arrow.right.circle")
                Text(isCurrentFilterTarget ? "取消筛选" : "仅看此目录")
            }
            .font(Typo.caption)
            .foregroundStyle(isCurrentFilterTarget ? Signal.caution : Accent.tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .opacity(isHovering || isCurrentFilterTarget ? 1.0 : 0.0)
        .motionSafe(Motion.micro, value: isHovering)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        } label: {
            Label("在访达中显示", systemImage: "folder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        } label: {
            Label("拷贝绝对路径", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            onSelectFilter()
        } label: {
            Label(isCurrentFilterTarget ? "取消此目录筛选" : "在主列表中仅查看此目录", systemImage: "line.3.horizontal.decrease.circle")
        }

        Button {
            onToggleScanExclude()
        } label: {
            Label(isExcludedFromScan ? "重新纳入扫描范围" : "从后续扫描中排除此目录", systemImage: isExcludedFromScan ? "checkmark.circle" : "nosign")
        }
    }

    @ViewBuilder
    private var checkIcon: some View {
        switch node.checkState {
        case .all:
            Image(systemName: "checkmark.square.fill")
                .foregroundStyle(Accent.tint)
        case .none:
            Image(systemName: "square")
                .foregroundStyle(Ink.tertiary)
        case .mixed:
            Image(systemName: "minus.square.fill")
                .foregroundStyle(Accent.tint)
        }
    }
}

/// 目录筛选激活徽标气泡（用于主视图展示当前激活的目录过滤）
struct DirectoryFilterBadge: View {
    let path: String
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Signal.caution)

            Text(shorten(path))
                .font(.mcNumeric(11, weight: .medium))
                .foregroundStyle(Ink.primary)
                .lineLimit(1)

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pressable()
            .help("清除目录筛选，查看全部")
            .accessibilityLabel("清除目录筛选，查看全部")
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Signal.caution.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(Signal.caution.opacity(0.25), lineWidth: 0.5)
        )
    }

    private func shorten(_ fullPath: String) -> String {
        let home = CleanPaths.expand("~")
        if fullPath.hasPrefix(home) {
            return fullPath.replacingOccurrences(of: home, with: "~")
        }
        return fullPath
    }
}
