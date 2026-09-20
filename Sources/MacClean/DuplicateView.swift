import SwiftUI
import QuickLook

/// 重复文件查找与去重视图。
///
/// 重写要点：
///  - 顶栏的"图标 + 两行文案"压成一行标题。那句「基于 SHA-256 分块哈希、感知哈希 (dHash)
///    与智能词干识别」是自我介绍，不携带任何可操作信息，删掉。
///  - 匹配类型的三种彩色胶囊（蓝 / 紫 / 橙）换成同一套中性的「图标 + 文字」。匹配类型是
///    分类，不是信号，不该占用语义色；全 App 只留一个强调色。
///  - 每组一张描边 + 投影的浮空卡片 → `GroupBox` inset 分组：中性底 + 发丝分隔线，
///    组内的建议说明降级为分组 footer。
///  - 行右侧的"紫底对比按钮 + 灰底预览按钮"砍掉：对比是组级动作，留在组头；预览收进
///    右键菜单与空格快捷键。行内只保留复选框，密度回到数据本身。
///  - 组头改成表格式对齐：匹配类型、文件名、份数、可节省体积各占一列，右侧留给实时数据。
struct DuplicateView: View {
    @EnvironmentObject private var app: AppState
    @State private var showConfirmSheet = false
    @State private var permanentMode = false
    @State private var showSettingsPopover = false
    @State private var showDirectoryTreeSheet = false
    @State private var comparingGroup: DuplicateGroup? = nil
    @State private var comparingFileGroup: DuplicateGroup? = nil
    @State private var quickLookURL: URL?
    @State private var showHud = false
    @State private var hudMessage = ""

    private var dup: DuplicateState { app.duplicateState }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if !dup.groups.isEmpty && !dup.isScanning {
                filterBar
                Hairline()
            }

            if dup.isScanning {
                scanningView
            } else if dup.groups.isEmpty {
                emptyView
            } else if dup.filteredGroups.isEmpty {
                emptyFilterView
            } else {
                duplicateListView
            }

            Spacer(minLength: 0)

            if !dup.groups.isEmpty {
                Hairline()
                footer
            }
        }
        .background(Surface.window)
        .quickLookPreview($quickLookURL)
        .toast(isPresented: $showHud, text: hudMessage)
        .sheet(isPresented: $showConfirmSheet) {
            confirmCleanSheet
        }
        .sheet(isPresented: $showDirectoryTreeSheet) {
            DirectoryTreeSheet(
                title: "重复与相似文件目录树",
                entries: dup.allFileEntries,
                activeFilterPath: dup.activeDirectoryFilter,
                onApplyFilter: { newFilter in
                    dup.activeDirectoryFilter = newFilter
                },
                onToggleBatchSelection: { path, select in
                    dup.toggleDirectorySelection(path: path, select: select)
                },
                onDismiss: {
                    showDirectoryTreeSheet = false
                }
            )
        }
        .sheet(item: $comparingGroup) { grp in
            PhotoCompareSheet(group: grp, dupState: dup) {
                comparingGroup = nil
            }
        }
        .sheet(item: $comparingFileGroup) { grp in
            FileCompareSheet(group: grp, dupState: dup) {
                comparingFileGroup = nil
            }
        }
    }

    // MARK: - 顶栏
    //
    // 一个主动作（扫描/重扫）+ 三个无边框次要动作。等权描边按钮排成一行是仪表盘的做法，
    // macOS 工具条只让一个动作变重。
    private var header: some View {
        HStack(spacing: Space.xs) {
            Text("重复与相似文件")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)

            Spacer(minLength: Space.sm)

            if !dup.groups.isEmpty && !dup.isScanning {
                exportMenu
                batchSelectMenu
                directoryTreeButton
            }

            if dup.isScanning {
                stopScanButton
            }

            scanButton
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(Surface.window)
    }

    /// 导出清单菜单：CSV 表格与文本报告两个动作。
    private var exportMenu: some View {
        Menu {
            Button {
                exportDuplicatesCSV()
            } label: {
                Label("导出为 CSV 表格…", systemImage: "tablecells")
            }
            Button {
                exportDuplicatesReport()
            } label: {
                Label("导出为文本报告…", systemImage: "doc.text")
            }
        } label: {
            Label("导出清单", systemImage: "square.and.arrow.up")
                .font(Typo.row)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityIdentifier("exportDuplicatesButton")
        .help("导出重复/相似大文件排查清单为 CSV 或 Markdown 格式")
    }

    /// 批量选择菜单：智能勾选副本 / 较旧副本 / 较新副本 / 下载目录 / 取消勾选。
    private var batchSelectMenu: some View {
        Menu {
            Button("智能推荐勾选副本") {
                dup.autoSelectDuplicates()
            }
            Button("勾选较旧版本（保留最新）") {
                dup.selectOlderDuplicates()
            }
            Button("勾选较新版本（保留最早）") {
                dup.selectNewerDuplicates()
            }
            Button("勾选下载目录副本（保留文稿/工作区）") {
                dup.selectDownloadsDuplicates()
            }
            Divider()
            Button("取消所有勾选") {
                dup.deselectAll()
            }
        } label: {
            Label("批量选择", systemImage: "checklist")
                .font(Typo.row)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("支持智能推荐、按修改时间先后（保留最新/最早）、按下载目录等维度批量勾选")
    }

    /// 目录树入口；已应用目录筛选时改用警示色提示。
    private var directoryTreeButton: some View {
        Button {
            showDirectoryTreeSheet = true
        } label: {
            Label(
                dup.activeDirectoryFilter != nil ? "目录树 · 已筛选" : "目录树",
                systemImage: dup.activeDirectoryFilter != nil ? "folder.fill.badge.gearshape" : "folder.badge.gearshape"
            )
            .font(Typo.row)
        }
        .buttonStyle(.borderless)
        .pressable()
        .foregroundStyle(dup.activeDirectoryFilter != nil ? Signal.caution : Ink.secondary)
        .accessibilityIdentifier("duplicateDirectoryTreeButton")
        .help("按磁盘目录树逐层展开、批量勾选副本或分支筛选")
    }

    /// 扫描进行中时，主按钮变成「停止」。
    /// 重复扫描要对每个候选文件做全量 SHA-256，大盘上动辄几分钟；
    /// 此前没有任何中断途径，用户只能干等，而且再次点扫描会被静默丢弃。
    private var stopScanButton: some View {
        Button {
            dup.cancelScan()
        } label: {
            Label("停止", systemImage: "stop.fill")
                .font(Typo.rowStrong)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityIdentifier("duplicateCancelButton")
        .help("停止当前扫描；已扫描出的上一次结果会保留")
    }

    /// 扫描主按钮：无结果时启动，有结果时重扫。
    private var scanButton: some View {
        Button {
            dup.startScan()
        } label: {
            Label(dup.groups.isEmpty ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise")
                .font(Typo.rowStrong)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(dup.isScanning)
        .accessibilityIdentifier("duplicateScanButton")
    }

    private func exportDuplicatesCSV() {
        let content = HistoryExporter.generateDuplicatesCSV(groups: dup.filteredGroups)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_Duplicates", ext: "csv")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "csv") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private func exportDuplicatesReport() {
        let content = HistoryExporter.generateDuplicatesReport(groups: dup.filteredGroups)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_Duplicates_Report", ext: "md")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "md") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    // MARK: - 分类过滤栏
    private var filterBar: some View {
        HStack(spacing: Space.sm) {
            Picker("查看分类", selection: Binding(
                get: { dup.filterKind },
                set: { dup.filterKind = $0 }
            )) {
                Text("全部 (\(dup.groups.count))").tag(DuplicateGroupFilter.all)
                Text("完全一致 (\(dup.exactGroupsCount))").tag(DuplicateGroupFilter.exact)
                Text("相似衍生 (\(dup.similarGroupsCount))").tag(DuplicateGroupFilter.similar)
                Text("相似图片 (\(dup.similarImageGroupsCount))").tag(DuplicateGroupFilter.similarImage)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 440)

            if let dirFilter = dup.activeDirectoryFilter {
                DirectoryFilterBadge(path: dirFilter) {
                    dup.activeDirectoryFilter = nil
                }
            }

            Spacer(minLength: Space.sm)

            Text("浪费总计 \(dup.totalWastedBytes.byteStringCN)")
                .font(.mcNumeric(11, weight: .medium))
                .foregroundStyle(Ink.secondary)
                .motionSafeNumericTransition()
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .background(Surface.window)
    }

    // MARK: - 分类过滤空态
    private var emptyFilterView: some View {
        VStack(spacing: 0) {
            Spacer()
            EmptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: "当前分类暂无文件",
                message: nil,
                actionTitle: "查看全部",
                action: { dup.filterKind = .all }
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 扫描中视图
    private var scanningView: some View {
        VStack(spacing: Space.md) {
            Spacer()
            ProgressView(value: dup.progressFraction)
                .progressViewStyle(.linear)
                .frame(width: 320)
                .tint(Accent.tint)

            Text(dup.scanProgressMessage)
                .font(Typo.body)
                .foregroundStyle(Ink.secondary)
                .monospacedDigit()
                .motionSafeNumericTransition()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空态视图
    private var emptyView: some View {
        VStack(spacing: 0) {
            Spacer()
            EmptyState(
                icon: "doc.on.doc",
                title: "未发现重复文件",
                message: "扫描范围：\(dup.searchPaths.joined(separator: " · "))\n点击上方「开始扫描」检测重复占用。"
            )
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 重复列表
    private var duplicateListView: some View {
        ScrollView {
            LazyVStack(spacing: Space.sm) {
                ForEach(dup.filteredGroups) { group in
                    DuplicateGroupCard(
                        group: group,
                        onPreview: { url in
                            quickLookURL = url
                        },
                        onCompare: { grp in
                            comparingGroup = grp
                        },
                        onCompareFiles: { grp in
                            comparingFileGroup = grp
                        }
                    )
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
    }

    // MARK: - 底栏统计与清理
    private var footer: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                if let summary = dup.lastSummary {
                    HStack(spacing: Space.xxs) {
                        IconSlot(systemName: "checkmark.circle", size: 12, color: Signal.positive, width: 14)
                        Text(summary)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
                if let cacheStats = dup.cacheStatsSummary {
                    HStack(spacing: Space.xxs) {
                        IconSlot(systemName: "bolt.fill", size: 12, color: Accent.tint, width: 14)
                        Text(cacheStats)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(dup.selectedCount) 个副本 · 可释放")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                Text(dup.selectedBytes.byteStringCN)
                    .font(.mcNumeric(17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            // 硬链接无损去重（保留路径与访问，释放物理空间）
            Button {
                _ = dup.dedupSelectedWithHardlink()
                app.refreshDisk()
            } label: {
                Label("硬链接无损去重", systemImage: "link")
                    .font(Typo.rowStrong)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(dup.selectedCount == 0 || dup.isScanning)
            .help("将选中的完全相同副本替换为 APFS 硬链接：保留原有文件路径，但释放底层物理空间")
            .accessibilityIdentifier("duplicateHardlinkDedupButton")

            Button {
                showConfirmSheet = true
            } label: {
                Label("清理已选副本", systemImage: "trash")
                    .font(Typo.rowStrong)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(dup.selectedCount == 0 || dup.isScanning)
            .accessibilityIdentifier("duplicateCleanButton")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(Surface.window)
    }

    private var confirmCleanSheet: some View {
        CleanConfirmSheet(
            count: dup.selectedCount,
            size: dup.selectedBytes,
            hasPermanent: false,
            hasDanger: false,
            permanent: $permanentMode,
            recentlyUsedCount: 0
        ) { permanent in
            let beforeAvailable = app.diskAvailable
            let result = dup.cleanSelected(permanently: permanent)
            if result.releasedBytes > 0 || result.succeeded > 0 {
                app.refreshDisk()
                app.recordClean(
                    categoryName: "重复文件",
                    itemCount: result.succeeded,
                    bytes: result.releasedBytes,
                    mode: permanent ? "彻底删除" : "废纸篓",
                    failures: result.failures.count
                )
                app.lastCleanResult = CleanResultSnapshot(
                    title: "重复文件清理完成",
                    releasedBytes: result.releasedBytes,
                    itemCount: result.succeeded,
                    failureCount: result.failures.count,
                    mode: permanent ? "彻底删除" : "废纸篓",
                    beforeAvailable: beforeAvailable,
                    afterAvailable: app.diskAvailable,
                    breakdown: [.largeFiles: result.releasedBytes],
                    timestamp: Date()
                )
                app.showCleanResultSheet = true
            }
        }
    }
}

/// 单组重复文件。一个 inset 分组：组头（表格式对齐的元数据）+ 若干文件行 + 可选说明 footer。
struct DuplicateGroupCard: View {
    @EnvironmentObject private var app: AppState
    let group: DuplicateGroup
    var onPreview: ((URL) -> Void)? = nil
    var onCompare: ((DuplicateGroup) -> Void)? = nil
    var onCompareFiles: ((DuplicateGroup) -> Void)? = nil
    private var dup: DuplicateState { app.duplicateState }

    private var isImageGroup: Bool {
        group.matchKind == .similarImage || (!group.items.isEmpty && group.items.allSatisfy { ImageHash.isImageFile(path: $0.path) })
    }

    var body: some View {
        GroupBox(footer: group.suggestionNote.isEmpty ? nil : group.suggestionNote) {
            GroupedRow(isLast: group.items.isEmpty, padding: Space.xs) {
                groupHeader
            }

            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                GroupedRow(isLast: idx == group.items.count - 1, padding: 5) {
                    DuplicateFileRow(group: group, item: item, onPreview: onPreview, onCompare: onCompare, onCompareFiles: onCompareFiles)
                }
            }
        }
    }

    /// 组头。匹配类型 / 文件名 / 份数 / 可节省体积各自成列，纵向可比较。
    private var groupHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: matchIcon, size: 12, color: Ink.tertiary, width: 15)

            Text(group.matchKind.rawValue)
                .font(Typo.micro)
                .foregroundStyle(Ink.secondary)
                .frame(width: 56, alignment: .leading)

            Text(group.items.first?.name ?? "未知文件")
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: Space.xs)

            if isImageGroup && group.items.count >= 2 {
                Button {
                    onCompare?(group)
                } label: {
                    Label("对比照片与 EXIF", systemImage: "square.split.2x1")
                        .font(Typo.caption)
                        .foregroundStyle(Accent.tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pressable()
                .help("双栏对比组内照片视觉细节与 EXIF 快门曝光参数")
            } else if !isImageGroup && group.items.count >= 2 {
                Button {
                    onCompareFiles?(group)
                } label: {
                    Label("双栏比对文件", systemImage: "arrow.left.and.right.square")
                        .font(Typo.caption)
                        .foregroundStyle(Accent.tint)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pressable()
                .help("双栏并排比对两份副本的属性差异、首部内容与快捷决策")
            }

            Text(countText)
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .monospacedDigit()
                .lineLimit(1)

            VStack(alignment: .trailing, spacing: 0) {
                Text("可节省 \(group.wastedBytes.byteStringCN)")
                    .font(.mcNumeric(12, weight: .medium))
                    .foregroundStyle(Ink.primary)
                    .frame(minWidth: 108, alignment: .trailing)
                    .motionSafeNumericTransition()
                // 组内含硬链接时如实说明：这些路径删掉不释放空间，所以没有计入"可节省"。
                // 不解释的话，用户会疑惑"为什么三份文件只算一份的空间"。
                if group.hardLinkCount > 0 {
                    Text("\(group.hardLinkCount) 条为硬链接，未计入")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
        }
    }

    private var matchIcon: String {
        switch group.matchKind {
        case .exact: return "equal.square"
        case .similar: return "doc.on.doc"
        case .similarImage: return "photo.on.rectangle.angled"
        }
    }

    private var countText: String {
        switch group.matchKind {
        case .exact:
            return "每份 \(group.fileSize.byteStringCN) · 共 \(group.items.count) 份"
        case .similar:
            return "共 \(group.items.count) 个相似副本"
        case .similarImage:
            return "共 \(group.items.count) 张相似图片"
        }
    }
}

/// 缩略图视图（图片文件优先下采样显示微缩图，其余使用系统图标）
struct DuplicateThumbnailView: View {
    let path: String
    let isImage: Bool

    var body: some View {
        Group {
            if isImage, let img = generateThumbnail(for: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
            }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .strokeBorder(Surface.hairline.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func generateThumbnail(for filePath: String) -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImg, size: NSSize(width: 26, height: 26))
    }
}

/// 单个副本行。密集数据行：复选框 + 缩略图 + 名称/原因 + 路径/体积/时间。
/// 右侧不再挂两个带底色的图标按钮——对比与预览都在右键菜单里，预览另有空格快捷键。
struct DuplicateFileRow: View {
    @EnvironmentObject private var app: AppState
    let group: DuplicateGroup
    let item: DuplicateFileItem
    var onPreview: ((URL) -> Void)? = nil
    var onCompare: ((DuplicateGroup) -> Void)? = nil
    var onCompareFiles: ((DuplicateGroup) -> Void)? = nil

    var body: some View {
        HStack(spacing: Space.xs) {
            selectionToggle

            DuplicateThumbnailView(path: item.path, isImage: ImageHash.isImageFile(path: item.path))

            fileIdentityColumn

            Spacer(minLength: Space.xs)

            previewButton
        }
        .rowHover()
        .overlay(spaceKeyPreviewShortcut)
        .contextMenu {
            rowContextMenu
        }
    }

    /// 行首复选框：勾选此副本等待清理。
    private var selectionToggle: some View {
        Button {
            app.duplicateState.toggleItem(groupID: group.id, itemID: item.id)
        } label: {
            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
                .frame(width: 18, height: 18, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .help(item.isSelected ? "取消勾选此副本" : "勾选此副本等待清理")
        .accessibilityLabel(item.isSelected ? "取消勾选此副本" : "勾选此副本等待清理")
    }

    /// 名称 / 推荐理由 + 路径 / 体积 / 修改时间两行。
    private var fileIdentityColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            nameLine
            pathMetadataLine
        }
    }

    private var nameLine: some View {
        HStack(spacing: Space.xs) {
            Text(item.name)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            if item.isOriginal {
                Text(item.recommendationReason ?? "推荐保留")
                    .font(Typo.micro)
                    .foregroundStyle(Signal.positive)
                    .lineLimit(1)
            } else if let reason = item.recommendationReason {
                Text(reason)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var pathMetadataLine: some View {
        HStack(spacing: 5) {
            Text(item.path)
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("·")
                .font(Typo.caption)
                .foregroundStyle(Ink.quaternary)

            Text(item.size.byteStringCN)
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.secondary)

            if let mtime = item.modificationDate {
                Text("·")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.quaternary)
                Text(Date.usageFormatter.string(from: mtime))
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
            }
        }
    }

    /// 行尾预览按钮：与右键菜单、空格快捷键走同一条预览路径。
    private var previewButton: some View {
        Button {
            let url = URL(fileURLWithPath: item.path)
            onPreview?(url)
        } label: {
            Image(systemName: "eye")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 20, height: 20, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pressable()
        .help("按快速查看 (Quick Look) 预览文件内容")
        .accessibilityLabel("按快速查看 (Quick Look) 预览文件内容")
    }

    /// 空格键快速预览快捷键（零尺寸透明按钮，挂在行上）。
    private var spaceKeyPreviewShortcut: some View {
        Button("") {
            let url = URL(fileURLWithPath: item.path)
            onPreview?(url)
        }
        .keyboardShortcut(.space, modifiers: [])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        if ImageHash.isImageFile(path: item.path) && group.items.count >= 2 {
            Button {
                onCompare?(group)
            } label: {
                Label("双栏对比照片与 EXIF 参数", systemImage: "square.split.2x1")
            }

            Divider()
        } else if !ImageHash.isImageFile(path: item.path) && group.items.count >= 2 {
            Button {
                onCompareFiles?(group)
            } label: {
                Label("双栏比对文件差异与首部内容", systemImage: "arrow.left.and.right.square")
            }

            Divider()
        }

        Button {
            let url = URL(fileURLWithPath: item.path)
            onPreview?(url)
        } label: {
            Label("快速查看 (Quick Look)", systemImage: "eye")
        }

        Divider()

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        } label: {
            Label("在访达中显示", systemImage: "folder")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.path, forType: .string)
        } label: {
            Label("拷贝路径", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            app.addPathToWhitelist(item.path, comment: item.name)
        } label: {
            Label("加入白名单排除", systemImage: "shield.slash")
        }

        let ext = (item.path as NSString).pathExtension.lowercased()
        if !ext.isEmpty {
            Button {
                app.addExtensionToWhitelist(ext, comment: "排除 .\(ext) 文件")
            } label: {
                Label("排除所有 .\(ext) 格式（不再扫描）", systemImage: "doc.badge.gearshape")
            }
        }
    }
}
