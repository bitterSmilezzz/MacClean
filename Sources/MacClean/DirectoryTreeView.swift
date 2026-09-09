import SwiftUI
import AppKit

/// 交互式目录树状勾选与分支筛选面板
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
            Divider().overlay(Theme.hairline)

            toolbar
            Divider().overlay(Theme.hairline)

            if treeNodes.isEmpty {
                emptyView
            } else {
                treeListView
            }

            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 680, height: 560)
        .background(Theme.canvas)
        .onAppear {
            selectedFilterPath = activeFilterPath
            reloadTree()
        }
    }

    // MARK: - 顶栏
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.actionBlue.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Theme.actionBlue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.displayFont(15, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                Text("按磁盘目录层级查看文件分布，支持分支独立筛选、批量勾选清理与扫描范围定制。")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelSecondary)
            }

            Spacer()

            Button("完成") {
                onApplyFilter(selectedFilterPath)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Theme.actionBlue)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("directoryTreeDoneButton")
        }
        .padding(.horizontal, Theme.spaceLg)
        .padding(.vertical, Theme.spaceSm)
        .background(Theme.parchment)
    }

    // MARK: - 工具栏
    private var toolbar: some View {
        HStack(spacing: 10) {
            // 搜索过滤
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.labelTertiary)
                TextField("按目录名或路径检索…", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.bodyFont(12))
                if !searchQuery.isEmpty {
                    Button {
                        searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.labelTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
            .frame(maxWidth: 240)

            Spacer()

            if selectedFilterPath != nil {
                Button {
                    selectedFilterPath = nil
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                        Text("清除分支筛选")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.warningOrange)
            }

            Button {
                expandAll()
            } label: {
                Label("全部展开", systemImage: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                collapseAll()
            } label: {
                Label("全部收起", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                addCustomFolder()
            } label: {
                Label("添加扫描目录…", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("addCustomScanFolderButton")
            .help("选择 macOS 本机文件夹加入扫描监控")
        }
        .padding(.horizontal, Theme.spaceLg)
        .padding(.vertical, 8)
        .background(Theme.parchment.opacity(0.6))
    }

    // MARK: - 目录树列表
    private var treeListView: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
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
            .padding(.vertical, 8)
            .padding(.horizontal, Theme.spaceSm)
        }
    }

    // MARK: - 空态
    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.minus")
                .font(.system(size: 38, weight: .light))
                .foregroundColor(Theme.labelTertiary)
            Text("暂无目录数据")
                .font(Theme.bodyFont(13, weight: .medium))
                .foregroundColor(Theme.labelSecondary)
            Text("扫描完成后将自动解析出包含大文件或重复副本的各级目录。")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.labelTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底栏
    private var footer: some View {
        let totalFiles = entries.count
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.size }
        let selectedBytes = entries.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.size }

        return HStack(spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .foregroundColor(Theme.labelTertiary)
                Text("共 \(countAllNodes(treeNodes)) 个目录 · \(totalFiles) 个文件 (\(totalBytes.byteStringCN))")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelSecondary)
            }

            Spacer()

            Text("已勾选清理：\(selectedBytes.byteStringCN)")
                .font(Theme.monoFont(11, weight: .medium))
                .foregroundColor(selectedBytes > 0 ? Theme.actionBlue : Theme.labelTertiary)

            if let filter = selectedFilterPath {
                HStack(spacing: 4) {
                    Text("当前筛选：")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                    Text(displayShortPath(filter))
                        .font(Theme.monoFont(11, weight: .semibold))
                        .foregroundColor(Theme.warningOrange)
                }
            }
        }
        .padding(.horizontal, Theme.spaceLg)
        .padding(.vertical, 10)
        .background(Theme.parchment)
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

/// 目录树单行视图
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
        HStack(spacing: 8) {
            // 缩进与展开箭头
            HStack(spacing: 0) {
                Spacer().frame(width: CGFloat(depth * 20))

                if !node.children.isEmpty {
                    Button {
                        onToggleExpand()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.labelSecondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 16)
                }
            }

            // 三态 Checkbox
            Button {
                onToggleCheck()
            } label: {
                checkIcon
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("批量勾选或取消此目录下全部文件")

            // 文件夹图标与名称
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "folder.fill" : "folder")
                    .font(.system(size: 13))
                    .foregroundColor(isCurrentFilterTarget ? Theme.warningOrange : Theme.actionBlue)

                Text(node.displayName)
                    .font(Theme.bodyFont(12, weight: depth == 0 ? .semibold : .medium))
                    .foregroundColor(isCurrentFilterTarget ? Theme.warningOrange : Theme.labelPrimary)
                    .lineLimit(1)

                if isCurrentFilterTarget {
                    Text("当前筛选")
                        .font(Theme.bodyFont(9, weight: .semibold))
                        .foregroundColor(Theme.warningOrange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.warningOrange.opacity(0.12)))
                }

                if isExcludedFromScan {
                    Text("排除扫描")
                        .font(Theme.bodyFont(9, weight: .medium))
                        .foregroundColor(Theme.labelTertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
            }

            Spacer()

            // 统计指标胶囊
            HStack(spacing: 8) {
                Text("\(node.fileCount) 项")
                    .font(Theme.bodyFont(10))
                    .foregroundColor(Theme.labelTertiary)

                Text(node.totalBytes.byteStringCN)
                    .font(Theme.monoFont(11, weight: .medium))
                    .foregroundColor(Theme.labelSecondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }

            // 悬停/常驻快捷过滤按钮
            Button {
                onSelectFilter()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: isCurrentFilterTarget ? "checkmark.circle.fill" : "arrow.right.circle")
                    Text(isCurrentFilterTarget ? "取消筛选" : "仅看此目录")
                }
                .font(Theme.bodyFont(10, weight: .medium))
                .foregroundColor(isCurrentFilterTarget ? Theme.warningOrange : Theme.actionBlue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill((isCurrentFilterTarget ? Theme.warningOrange : Theme.actionBlue).opacity(0.1))
                )
            }
            .buttonStyle(.plain)
            .opacity(isHovering || isCurrentFilterTarget ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isCurrentFilterTarget ? Theme.warningOrange.opacity(0.08) : (isHovering ? Color.primary.opacity(0.035) : Color.clear))
        )
        .onHover { isHovering = $0 }
        .contextMenu {
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
    }

    @ViewBuilder
    private var checkIcon: some View {
        switch node.checkState {
        case .all:
            Image(systemName: "checkmark.square.fill")
                .foregroundColor(Theme.actionBlue)
        case .none:
            Image(systemName: "square")
                .foregroundColor(Theme.labelTertiary)
        case .mixed:
            Image(systemName: "minus.square.fill")
                .foregroundColor(Theme.actionBlue.opacity(0.8))
        }
    }
}

/// 目录筛选激活徽标气泡（用于主视图展示当前激活的目录过滤）
struct DirectoryFilterBadge: View {
    let path: String
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundColor(Theme.warningOrange)

            Text(shorten(path))
                .font(Theme.monoFont(11, weight: .medium))
                .foregroundColor(Theme.labelPrimary)
                .lineLimit(1)

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.labelSecondary)
            }
            .buttonStyle(.plain)
            .help("清除目录筛选，查看全部")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Theme.warningOrange.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(Theme.warningOrange.opacity(0.25), lineWidth: 0.5)
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
