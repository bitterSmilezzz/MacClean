import SwiftUI
import QuickLook

/// 分类详情页：扫描结果列表 + 勾选 + 清理
struct CategoryDetailView: View {
    @EnvironmentObject private var app: AppState
    let category: CleanCategory

    @State private var showCleanSheet = false
    @State private var permanentMode = false
    @State private var filterQuery = ""
    @State private var selectedTypeFilter: LargeFileTypeFilter = .all
    @State private var selectedAgeFilter: LargeFileAgeFilter = .all
    @State private var selectedSortOrder: LargeFileSortOrder = .recommended
    @State private var selectedAppResidueFilter: AppResidueFilterKind = .all
    @State private var selectedLogsFilter: LogsFilterKind = .all
    @State private var activeDirectoryFilter: String? = nil
    @State private var activeYearFilter: String? = nil
    @State private var showPivotCard = false
    @State private var showDirectoryTreeSheet = false
    @State private var showHud = false
    @State private var hudMessage = ""
    @State private var quickLookURL: URL?

    private var st: CategoryState { app.state(for: category) }

    /// 过滤后的列表（支持文本子串匹配、大文件类型细分、闲置时间跨度、排序机制与目录树分支筛选，大小写不敏感）。
    ///
    /// **一次 body 求值只算一次**：此前它是无缓存的计算属性，一帧里被引用约 12 次
    /// （分组循环里就占 4 次），每次都重跑一遍全量过滤。实测 548 项 + 目录筛选时
    /// 单帧仅过滤就花掉 9.3 ms —— 60fps 的预算是 16.7 ms，等于一半帧预算没了。
    /// 现在由 `body` 计算一次，再把结果传给 `header` / `itemList` / `footer`。
    private func computeFilteredItems() -> [CleanItem] {
        var result = st.items
        if category == .largeFiles && selectedTypeFilter != .all {
            result = result.filter { selectedTypeFilter.matches(item: $0) }
        }
        if category == .largeFiles && selectedAgeFilter != .all {
            result = result.filter { selectedAgeFilter.matches(item: $0) }
        }
        if category == .largeFiles, let yearFilter = activeYearFilter, !yearFilter.isEmpty {
            result = result.filter { item in
                PivotAnalyzer.yearLabel(for: item.modificationDate) == yearFilter
            }
        }
        if category == .appResidue && selectedAppResidueFilter != .all {
            result = result.filter { selectedAppResidueFilter.matches(item: $0) }
        }
        if category == .logsAndTemp && selectedLogsFilter != .all {
            result = result.filter { selectedLogsFilter.matches(item: $0) }
        }
        if category == .largeFiles, let dirFilter = activeDirectoryFilter, !dirFilter.isEmpty {
            let expDir = CleanPaths.expand(dirFilter)
            result = result.filter { item in
                let itemExp = CleanPaths.expand(item.path)
                return itemExp == expDir || itemExp.hasPrefix(expDir + "/")
            }
        }
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            result = result.filter {
                $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                    || $0.path.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        if category == .largeFiles {
            switch selectedSortOrder {
            case .recommended:
                break
            case .sizeDescending:
                result.sort { $0.size > $1.size }
            case .ageOldest:
                result.sort { ($0.modificationDate ?? Date.distantPast) < ($1.modificationDate ?? Date.distantPast) }
            case .ageNewest:
                result.sort { ($0.modificationDate ?? Date.distantPast) > ($1.modificationDate ?? Date.distantPast) }
            case .bitrateDescending:
                result.sort { a, b in
                    let bA = MediaMetadataParser.cachedOrParse(path: a.path, fileSize: a.size)?.bitrateKbps ?? 0
                    let bB = MediaMetadataParser.cachedOrParse(path: b.path, fileSize: b.size)?.bitrateKbps ?? 0
                    if bA != bB { return bA > bB }
                    return a.size > b.size
                }
            case .durationDescending:
                result.sort { a, b in
                    let dA = MediaMetadataParser.cachedOrParse(path: a.path, fileSize: a.size)?.durationSeconds ?? 0
                    let dB = MediaMetadataParser.cachedOrParse(path: b.path, fileSize: b.size)?.durationSeconds ?? 0
                    if dA != dB { return dA > dB }
                    return a.size > b.size
                }
            }
        }
        return result
    }

    var body: some View {
        // 过滤与分组都只做一次，结果沿视图树向下传递。
        let filtered = computeFilteredItems()
        // 单次遍历完成分组（原先是对每个分组各 filter 一遍，4 次全量扫描）
        let grouped = Dictionary(grouping: filtered) { $0.recommendation.kind }
        let visibleSelectedCount = filtered.reduce(0) { $0 + ($1.isSelected ? 1 : 0) }

        return VStack(spacing: 0) {
            header(filtered: filtered)
            Divider().overlay(Surface.hairline)
            statusBanners
            subCategoryFilterBarIfNeeded
            contentArea(filtered: filtered, grouped: grouped)
            footer(filtered: filtered, visibleSelectedCount: visibleSelectedCount)
        }
        .background(Surface.window)
        .quickLookPreview($quickLookURL)
        .onChange(of: app.lastCleanSummary) { summary in
            if let summary, !summary.isEmpty {
                hudMessage = summary
                showHud = true
            }
        }
        .toast(isPresented: $showHud, text: hudMessage)
        .sheet(isPresented: $showCleanSheet) {
            cleanConfirmSheet(filtered: filtered)
        }
        .sheet(isPresented: $showDirectoryTreeSheet) {
            directoryTreeSheet
        }
    }

    // MARK: - 状态横幅
    //
    // 三组横幅原本内联在 body 里，占了 body 近一半篇幅，把主结构淹没了。
    // 它们的共同职责是"如实说明扫描/AI 的当前状态"，抽出来自成一节更好读。

    @ViewBuilder
    private var statusBanners: some View {
        scanErrorBanner
        scanIssuesBanner
        aiReviewBanner
    }

    /// 扫描失败横幅（P4 健壮性：失败不静默）
    @ViewBuilder
    private var scanErrorBanner: some View {
        if let err = st.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Signal.critical)
                Text(err)
                    .font(Typo.rowStrong)
                    .foregroundColor(Signal.critical)
                Spacer()
                Button("重试") { app.scan(category) }
                    .buttonStyle(.borderless)
                    .font(Typo.rowStrong)
                    .foregroundColor(Accent.tint)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Signal.critical.opacity(0.12))
            .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// 扫描完整度横幅：根目录读不到时必须显式说明。
    ///
    /// 这条横幅存在的唯一理由，是阻止"读不到"被读成"很干净"——
    /// 缺「完全磁盘访问权限」时，废纸篓会稳定返回 0 项，
    /// 而界面上和"废纸篓是空的"完全一样。
    @ViewBuilder
    private var scanIssuesBanner: some View {
        if !st.issues.isEmpty {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Signal.caution)
                    Text("本次结果不完整：\(st.issues.count) 个位置读不到")
                        .font(Typo.rowStrong)
                        .foregroundColor(Ink.primary)
                    Spacer()
                    Button("重新扫描") { app.scan(category) }
                        .buttonStyle(.borderless)
                        .font(Typo.rowStrong)
                        .foregroundColor(Accent.tint)
                }
                ForEach(st.issues.prefix(3)) { issue in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(issue.message)
                            .font(Typo.caption)
                            .foregroundColor(Ink.secondary)
                        if let remedy = issue.remedy {
                            Text(remedy)
                                .font(Typo.caption)
                                .foregroundColor(Ink.tertiary)
                        }
                    }
                    .padding(.leading, 20)
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Signal.caution.opacity(0.10))
            .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("scanIssuesBanner")
        }
    }

    /// AI 再筛查状态横幅（进度 / 错误 / 完成摘要）
    @ViewBuilder
    private var aiReviewBanner: some View {
        if app.aiReview.isReviewing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(Accent.tint)
                Text(app.aiReview.progressText ?? "AI 筛查中…")
                    .font(Typo.rowStrong)
                    .foregroundColor(Ink.primary.opacity(0.8))
                Spacer()
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Accent.tint.opacity(0.10))
            .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
        } else if let reviewError = app.aiReview.lastError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Signal.caution)
                Text("AI 筛查失败：\(reviewError)")
                    .font(Typo.rowStrong)
                    .foregroundColor(Signal.caution)
                Spacer()
                Button("重试") { app.aiReview.review(items: st.items) }
                    .buttonStyle(.borderless)
                    .font(Typo.rowStrong)
                    .foregroundColor(Accent.tint)
                    .disabled(st.items.isEmpty)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Signal.caution.opacity(0.12))
            .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
        } else {
            let reviewSummary = app.aiReview.summary(for: st.items)
            if !reviewSummary.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 12))
                        .foregroundColor(Accent.tint)
                    Text("AI 再筛查：\(reviewSummary)")
                        .font(Typo.rowStrong)
                        .foregroundColor(Ink.primary.opacity(0.8))
                    Spacer()
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Accent.tint.opacity(0.10))
                .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    /// 分类细分筛选条（大文件、应用残留与日志临时）
    @ViewBuilder
    private var subCategoryFilterBarIfNeeded: some View {
        if category == .largeFiles && st.isScanned && !st.items.isEmpty {
            VStack(spacing: 0) {
                largeFileTypeFilterBar
                if showPivotCard {
                    CrossPivotCard(
                        matrix: PivotAnalyzer.analyze(items: st.items),
                        selectedType: $selectedTypeFilter,
                        selectedYear: $activeYearFilter,
                        onClose: {
                            withAnimation(Motion.standard) {
                                showPivotCard = false
                            }
                        }
                    )
                    .padding(.horizontal, Space.gutter)
                    .padding(.vertical, Space.xs)
                    .background(Surface.window)
                    .motionSafeTransition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        } else if category == .appResidue && st.isScanned && !st.items.isEmpty {
            appResidueFilterBar
        } else if category == .logsAndTemp && st.isScanned && !st.items.isEmpty {
            logsFilterBar
        } else if category == .browserAndSystem {
            SystemDeepStorageView()
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.xs)
        }
    }

    // MARK: - 内容区

    /// 主内容区：按"扫描中 / 未扫描 / 无结果 / 过滤无匹配 / 正常列表"五态择一。
    @ViewBuilder
    private func contentArea(filtered: [CleanItem],
                             grouped: [Recommendation.Kind: [CleanItem]]) -> some View {
        Group {
            if st.isScanning {
                scanningView
            } else if !st.isScanned {
                emptyView
            } else if st.items.isEmpty {
                emptyResultView
            } else if filtered.isEmpty {
                // 有扫描结果但过滤无匹配
                noFilterMatchView
            } else {
                itemList(filtered: filtered, grouped: grouped)
            }
        }
        .motionSafeTransition(.opacity)
        .motionSafe(Motion.micro, value: st.isScanning)
    }

    // MARK: - 弹窗

    /// 清理确认弹窗。
    /// 过滤激活且有隐藏已选时，显示全量口径并附提示（二轮 #4）
    private func cleanConfirmSheet(filtered: [CleanItem]) -> some View {
        let hasFilter = !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (category == .largeFiles && (selectedTypeFilter != .all || activeDirectoryFilter != nil))
        let hiddenSelected = hasFilter ? max(0, st.selectedCount - filtered.filter(\.isSelected).count) : 0
        return CleanConfirmSheet(
            count: st.selectedCount,
            size: st.selectedSize,
            hasPermanent: st.selectedItems.contains { $0.permanentDelete },
            hasDanger: st.selectedItems.contains { $0.recommendation.kind == .keep },
            permanent: $permanentMode,
            hint: hiddenSelected > 0 ? "含隐藏已选 \(hiddenSelected) 项" : nil,
            recentlyUsedCount: st.selectedItems.filter { $0.usage.isRecentlyUsed }.count
        ) { permanent in
            app.cleanSelected(in: category, permanently: permanent)
        }
    }

    /// 大文件目录树面板
    private var directoryTreeSheet: some View {
        let entries = st.items.map {
            DirectoryTreeBuilder.FileEntry(path: $0.path, size: $0.size, isSelected: $0.isSelected)
        }
        return DirectoryTreeSheet(
            title: "大文件分布目录树",
            entries: entries,
            activeFilterPath: activeDirectoryFilter,
            onApplyFilter: { newFilter in
                activeDirectoryFilter = newFilter
            },
            onToggleBatchSelection: { path, select in
                let exp = CleanPaths.expand(path)
                for item in st.items {
                    let itemExp = CleanPaths.expand(item.path)
                    if itemExp == exp || itemExp.hasPrefix(exp + "/") {
                        st.setSelected(item.id, select)
                    }
                }
            },
            onDismiss: {
                showDirectoryTreeSheet = false
            }
        )
    }

    // MARK: - Header

    /// 标题下的一行。把"扫描状态 / 条目数与体积 / 分类说明 / 规则来源"合并成一句，
    /// 取代原先散落在标题、副标题、统计条三处的重复信息。
    private var headerSubtitle: String {
        var parts: [String] = []
        if st.isScanning {
            parts.append("正在扫描")
        } else if st.isScanned {
            parts.append("\(st.items.count) 项 · \(st.totalSize.byteStringCN)")
        } else {
            parts.append("未扫描")
        }
        parts.append(category.subtitle)
        if !category.ruleRef.isEmpty {
            parts.append("规则 \(category.ruleRef)")
        }
        return parts.joined(separator: " · ")
    }

    private func header(filtered: [CleanItem]) -> some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(Typo.title)
                    .foregroundColor(Ink.primary)
                Text(headerSubtitle)
                    .font(Typo.caption)
                    .foregroundColor(Ink.secondary)
                    .monospacedDigit()
                    .motionSafeNumericTransition()
            }
            Spacer()

            headerActions(filtered: filtered)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
    }

    /// 工具栏动作。原先这里是「全选 + 扫描 + AI 再筛查 + 导出 + 过滤框」五个并列控件，
    /// 每个都带边框或底色，一行里挤了五种视觉重量。改成一个主按钮（扫描）+ 一个文字动作
    /// （AI 再筛查）+ 一个溢出菜单承载低频的导出，过滤框收敛成统一外观。
    private func headerActions(filtered: [CleanItem]) -> some View {
        HStack(spacing: Space.xs) {
            if st.isScanned && !st.items.isEmpty {
                SearchField(placeholder: "过滤", text: $filterQuery, width: 148)
                    .accessibilityIdentifier("filterField")
            }

            // 三巡：过滤无匹配（filtered 为空）时隐藏，避免空集 allSatisfy=true 误显示"取消全选"
            if st.isScanned && !st.items.isEmpty && !filtered.isEmpty {
                let smartItems = filtered.filter { $0.recommendation.isSafe && ($0.recommendationScore.tier == .high || $0.recommendationScore.tier == .medium) }
                if !smartItems.isEmpty && smartItems.count < filtered.filter({ $0.recommendation.isSafe }).count {
                    Button {
                        selectSmartInVisible(visible: filtered)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10))
                            Text("仅选推荐 (\(smartItems.count))")
                        }
                        .font(Typo.row)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Accent.tint)
                    .help("仅勾选长期闲置、高收益的精选推荐项")
                }

                Button {
                    toggleAllVisible(visible: filtered)
                } label: {
                    Text(filtered.allSatisfy(\.isSelected) ? "取消全选" : "全选可清理项")
                        .font(Typo.row)
                }
                .buttonStyle(.borderless)
                .help("只勾选结论为「可清理」的项；「使用中」与「需确认」需要你在对应分组里显式勾选")
                .disabled(!filtered.contains { $0.recommendation.isSafe }
                          || filtered.allSatisfy(\.isSelected))
            }

            if st.isScanned && !st.items.isEmpty {
                Button {
                    app.aiReview.review(items: st.items)
                } label: {
                    HStack(spacing: 5) {
                        if app.aiReview.isReviewing {
                            ProgressView().controlSize(.small)
                            Text("筛查中")
                        } else {
                            Image(systemName: "checkmark.seal")
                            Text("AI 再筛查")
                        }
                    }
                    .font(Typo.row)
                }
                .buttonStyle(.borderless)
                .foregroundColor(Accent.tint)
                .accessibilityIdentifier("aiReviewButton")
                .disabled(app.aiReview.isReviewing || st.isScanning)
                .help("用 AI 对已扫描结果逐项二次判断：可删 / 谨慎 / 不建议删")
                .accessibilityLabel("用 AI 对已扫描结果逐项二次判断：可删 / 谨慎 / 不建议删")

                Menu {
                    if category == .largeFiles {
                        Button { exportLargeFilesCSV(items: filtered) } label: {
                            Label("导出大文件 CSV 表格（含闲置分析）…", systemImage: "tablecells")
                        }
                        Button { exportLargeFilesReport(items: filtered) } label: {
                            Label("导出大文件分布洞察报告 (Markdown)…", systemImage: "doc.text")
                        }
                        Button { exportLargeFilesMoveScript(items: filtered) } label: {
                            Label("生成外接盘迁移脚本 (Shell)…", systemImage: "terminal")
                        }
                        Divider()
                    }
                    Button { exportItemsCSV(items: filtered) } label: {
                        Label("导出为 CSV 表格…", systemImage: "tablecells")
                    }
                    Button { exportItemsReport(items: filtered) } label: {
                        Label("导出为文本报告…", systemImage: "doc.text")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier("exportItemsButton")
                .help("导出当前分类扫描清单为 CSV 或 Markdown 文本报告")
                .accessibilityLabel("导出当前分类扫描清单为 CSV 或 Markdown 文本报告")
            }

            Button {
                app.scan(category)
            } label: {
                Label(st.isScanned ? "重新扫描" : "扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("scanButton")
            .disabled(st.isScanning)
        }
    }

    /// 全选 / 取消全选。
    ///
    /// **只勾选结论为「可清理」的项**（`selectAllSafe`）。历史行为是无条件勾选全部，
    /// 包括"使用中"和"不建议删除"，这是最容易造成误删的入口。
    /// 过滤激活时只作用于可见项（M5）。
    private func toggleAllVisible(visible: [CleanItem]) {
        let target = !visible.allSatisfy(\.isSelected)
        if target {
            let safeIDs = Set(visible.filter { $0.recommendation.isSafe }.map(\.id))
            guard !safeIDs.isEmpty else { return }
            for item in visible {
                st.setSelected(item.id, safeIDs.contains(item.id))
            }
        } else {
            for item in visible {
                st.setSelected(item.id, false)
            }
        }
    }

    /// 仅勾选当前可见的智能推荐项（评分高、高价值安全项）
    private func selectSmartInVisible(visible: [CleanItem]) {
        let smartIDs = Set(visible.filter {
            $0.recommendation.isSafe && ($0.recommendationScore.tier == .high || $0.recommendationScore.tier == .medium)
        }.map(\.id))
        for item in visible {
            st.setSelected(item.id, smartIDs.contains(item.id))
        }
    }



    private func exportItemsCSV(items: [CleanItem]) {
        let content = HistoryExporter.generateItemsCSV(items: items, categoryTitle: category.title)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_\(category.id)", ext: "csv")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "csv") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private func exportItemsReport(items: [CleanItem]) {
        let content = HistoryExporter.generateItemsReport(items: items, categoryTitle: category.title)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_\(category.id)_Report", ext: "md")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "md") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private func exportLargeFilesCSV(items: [CleanItem]) {
        let content = HistoryExporter.generateLargeFilesCSV(items: items)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_LargeFiles", ext: "csv")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "csv") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private func exportLargeFilesReport(items: [CleanItem]) {
        let content = HistoryExporter.generateLargeFilesReport(items: items)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_LargeFiles_Report", ext: "md")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "md") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private func exportLargeFilesMoveScript(items: [CleanItem]) {
        let content = HistoryExporter.generateLargeFilesMoveScript(items: items)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_MoveLargeFiles", ext: "sh")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "sh") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    // MARK: - 状态视图

    private var scanningView: some View {
        VStack(spacing: Space.sm) {
            ProgressView()
                .controlSize(.large)
            Text("正在扫描…")
                .font(Typo.body)
                .foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyState(
            icon: category.icon,
            title: "尚未扫描此分类",
            message: "将按固化规则 \(category.ruleRef) 发现可清理项",
            actionTitle: "开始扫描"
        ) {
            app.scan(category)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyResultView: some View {
        EmptyState(
            icon: "checkmark.circle",
            title: "没有发现可清理项",
            message: "此分类当前是干净的。"
        )
        .frame(maxHeight: .infinity)
    }

    private var noFilterMatchView: some View {
        EmptyState(
            icon: "line.3.horizontal.decrease.circle",
            title: "没有与「\(filterQuery)」匹配的项",
            message: "清除过滤条件可查看全部 \(st.items.count) 项。",
            actionTitle: "清除过滤"
        ) {
            filterQuery = ""
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 结果列表（按风险分组，macOS 原生 Grouped List 规范）

    private func itemList(filtered: [CleanItem],
                          grouped: [Recommendation.Kind: [CleanItem]]) -> some View {
        ScrollView {
            LazyVStack(spacing: Space.lg) {
                // 按结论分组：可清理 / 使用中 / 需确认 / 不建议删除
                ForEach(VerdictGroup.allCases, id: \.self) { group in
                    let groupItems = grouped[group.kind] ?? []
                    if !groupItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            // 分组标题
                            HStack(spacing: 8) {
                                Circle().fill(group.color).frame(width: 7, height: 7)
                                Text(group.title)
                                    .font(Typo.section)
                                    .foregroundColor(Ink.secondary)
                                Text(group.subtitle)
                                    .font(Typo.caption)
                                    .foregroundColor(Ink.tertiary)
                                Text("\(groupItems.count) 项 · \(groupItems.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                                    .font(Font.mcNumeric(11))
                                    .foregroundColor(Ink.tertiary)
                                    .monospacedDigit()
                                Spacer()
                                // 组级快捷勾选：只有"可清理"组开放。
                                // "使用中"不给一键勾选——那正是用户最容易被误伤的一档。
                                if group.allowsBulkSelection {
                                    Button(groupItems.allSatisfy(\.isSelected) ? "取消本组" : "勾选本组") {
                                        let target = !groupItems.allSatisfy(\.isSelected)
                                        for item in groupItems {
                                            st.setSelected(item.id, target)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .font(Typo.micro)
                                    .foregroundColor(Accent.tint)
                                }
                            }
                            .padding(.horizontal, 4)

                            // 原生分组容器（组内各行由精细分割线隔开）
                            let displayItems = group.kind == .safe ? groupItems.sorted { a, b in
                                if a.recommendationScore.tier != b.recommendationScore.tier {
                                    return a.recommendationScore.tier > b.recommendationScore.tier
                                }
                                return a.recommendationScore.totalScore > b.recommendationScore.totalScore
                            } : groupItems

                            VStack(spacing: 0) {
                                ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 {
                                        Divider()
                                            .overlay(Surface.hairline.opacity(0.35))
                                            .padding(.leading, 38)
                                    }
                                    ItemRowView(
                                        item: item,
                                        isSelected: item.isSelected,
                                        onToggle: { selected in st.setSelected(item.id, selected) },
                                        onAskAI: { app.ai.askAbout(item: item) },
                                        isDisabled: app.ai.isLoading,
                                        aiReview: app.aiReview.review(for: item),
                                        onAddToWhitelist: { app.addPathToWhitelist(item.path, comment: item.name) },
                                        onAddExtensionToWhitelist: { ext in app.addExtensionToWhitelist(ext, comment: "排除 .\(ext) 文件") },
                                        onPreview: { url in quickLookURL = url }
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(Space.md)
        }
        .background(Surface.window)
    }

    /// 结论分组。四档，与 `Recommendation.Kind` 一一对应——**不再有独立的"使用频率"分组**，
    /// 因为"在用"是结论的输入而不是并列的第二结论。
    private enum VerdictGroup: CaseIterable {
        case safe, inUse, review, keep

        var kind: Recommendation.Kind {
            switch self {
            case .safe: return .safe
            case .inUse: return .inUse
            case .review: return .review
            case .keep: return .keep
            }
        }

        var title: String {
            switch self {
            case .safe: return "可清理"
            case .inUse: return "使用中，建议稍后"
            case .review: return "需确认"
            case .keep: return "不建议删除"
            }
        }

        var subtitle: String {
            switch self {
            case .safe: return "删除后无损失"
            case .inUse: return "相关应用正在运行或近期用过"
            case .review: return "删前请看一眼说明"
            case .keep: return "关键组件，删了会坏功能"
            }
        }

        var color: Color {
            Signal.tint(for: kind)
        }

        /// 是否允许"勾选本组"整组批量选中。
        ///
        /// 允许在读到该组说明后整组勾选（含"使用中""需确认"），但**永远不允许**批量勾选
        /// "不建议删除"——那一档的每一项都需要单独看过。
        var allowsBulkSelection: Bool {
            self != .keep
        }
    }

    // MARK: - Footer（清理栏）

    private func footer(filtered: [CleanItem], visibleSelectedCount: Int) -> some View {
        // M5：过滤激活时统计口径切换为可见项，并提示隐藏已选
        let filtering = !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (category == .largeFiles && (selectedTypeFilter != .all || activeDirectoryFilter != nil))
        let hiddenSelectedCount = st.selectedCount - visibleSelectedCount
        let shownCount = filtering ? visibleSelectedCount : st.selectedCount
        let shownSize = filtering
            ? filtered.reduce(Int64(0)) { $0 + ($1.isSelected ? $1.size : 0) }
            : st.selectedSize

        return HStack(spacing: Space.md) {
            if let summary = app.lastCleanSummary {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.positive)
                    Text(summary)
                        .font(Typo.row)
                        .foregroundStyle(Ink.secondary)
                }
            }
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text("已选 \(shownCount) 项" + (filtering && hiddenSelectedCount > 0 ? "（另有 \(hiddenSelectedCount) 项隐藏已选）" : ""))
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                    .motionSafeNumericTransition()
                Text(shownSize.byteStringCN)
                    .font(.mcNumeric(15, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            Button {
                showCleanSheet = true
            } label: {
                Label("清理", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("cleanButton")
            .disabled(st.selectedCount == 0 || app.isCleaning)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
        .overlay(alignment: .top) { Hairline() }
    }
}

/// 单个清理项行（macOS 原生数据行：整洁、紧凑、支持行悬停）
struct ItemRowView: View {
    let item: CleanItem
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    var onAskAI: (() -> Void)? = nil
    var isDisabled: Bool = false   // LOW-2：AI 请求在途时禁用行内的问 AI 按钮
    /// AI 再筛查结论（无则 nil）
    var aiReview: ItemReview? = nil
    var onAddToWhitelist: (() -> Void)? = nil
    var onAddExtensionToWhitelist: ((String) -> Void)? = nil
    var onPreview: ((URL) -> Void)? = nil

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                selectionCheckbox
                titleColumn
                Spacer()
                sizeLabel
                rowActions
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .rowHover(cornerRadius: 0)
            .overlay(spaceKeyPreviewShortcut)
            .contextMenu { contextMenuItems }
        }
    }

    // MARK: - 行内元素

    private var selectionCheckbox: some View {
        Button(action: { onToggle(!isSelected) }) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundColor(isSelected ? Accent.tint : Ink.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("itemToggle")
        .accessibilityLabel(isSelected ? "已勾选" : "未勾选")
    }

    /// 名称 + 结论徽标 + （展开后的）详情
    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.name)
                    .font(Typo.rowStrong)
                    .foregroundColor(Ink.primary)
                    .lineLimit(1)
                // 一枚徽标，一个结论。历史上这里是"风险徽标 + 使用频率徽标"两枚并列，
                // 于是必然出现「安全」和「频繁使用中」互相打架的组合。
                VerdictBadge(recommendation: item.recommendation)
                SmartRecommendationBadge(tier: item.recommendationScore.tier)
                if let aiReview {
                    ReviewBadge(verdict: aiReview.verdict)
                }
                if item.category == .largeFiles, let mtime = item.modificationDate {
                    let days = HistoryExporter.idleDays(for: mtime)
                    Text(days >= 365 ? "闲置 \(days / 365) 年" : "闲置 \(days) 天")
                        .font(Typo.micro)
                        .foregroundStyle(days >= 180 ? Signal.caution : Ink.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(days >= 180 ? Signal.caution.opacity(0.12) : Surface.sunken)
                        )
                }
                if item.category == .largeFiles,
                   MediaMetadataParser.isMediaFile(path: item.path),
                   let meta = MediaMetadataParser.cachedOrParse(path: item.path, fileSize: item.size) {
                    Text(meta.badgeText)
                        .font(Typo.micro)
                        .foregroundColor(Accent.tint)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Accent.tint.opacity(0.12))
                        )
                }
            }
            if isExpanded { expandedDetail }
        }
    }

    /// 展开后显示路径、结论依据、智能推荐打分、最近写入、AI 理由与备注
    @ViewBuilder
    private var expandedDetail: some View {
        Text(item.path)
            .font(Font.mcNumeric(11))
            .foregroundColor(Ink.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        Text(item.recommendation.reason)
            .font(Typo.caption)
            .foregroundColor(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        let score = item.recommendationScore
        if score.tier == .high || score.tier == .medium {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(Accent.tint)
                Text("智能推荐评分 \(Int(score.totalScore)) 分 · \(score.summary)")
                    .font(Typo.caption)
                    .foregroundColor(Accent.tint)
            }
        }
        if let lastUsed = item.lastUsed {
            Text("最近写入：\(Date.usageFormatter.string(from: lastUsed))（\(lastUsed.relativeUsage)）")
                .font(Typo.caption)
                .foregroundColor(Ink.tertiary)
        }
        if item.category == .largeFiles,
           MediaMetadataParser.isMediaFile(path: item.path),
           let meta = MediaMetadataParser.cachedOrParse(path: item.path, fileSize: item.size) {
            HStack(spacing: 4) {
                Image(systemName: "film")
                    .font(.system(size: 10))
                    .foregroundColor(Accent.tint)
                Text(meta.detailedSummary)
                    .font(Typo.caption)
                    .foregroundColor(Ink.secondary)
            }
        }
        if let aiReview, !aiReview.reason.isEmpty {
            Text("AI 建议：\(aiReview.reason)")
                .font(Typo.micro)
                .foregroundColor(aiReview.verdict == .keep ? Signal.critical
                                : aiReview.verdict == .caution ? Signal.caution
                                : Accent.tint)
                .lineLimit(2)
        }
        if !item.note.isEmpty {
            Text(item.note)
                .font(Typo.caption)
                .foregroundColor(Ink.tertiary.opacity(0.8))
                .lineLimit(2)
        }
    }

    private var sizeLabel: some View {
        Text(item.size.byteStringCN)
            .font(Font.mcNumeric(12, weight: .medium))
            .foregroundColor(Ink.primary)
            .monospacedDigit()
    }

    /// 行尾动作：Quick Look 预览、展开/收起、问 AI
    @ViewBuilder
    private var rowActions: some View {
        // 原生 Quick Look 快速预览
        if let onPreview {
            RowActionButton(
                systemName: "eye",
                identifier: "itemQuickLookButton",
                accessibilityText: "快速查看 (Quick Look)",
                help: "原生 Quick Look 快速预览文件"
            ) {
                onPreview(URL(fileURLWithPath: item.path))
            }
        }

        // 展开/收起路径备注（平滑旋转动效）
        Button {
            withAnimation(Motion.micro) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Ink.tertiary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("itemExpandButton")
        .accessibilityLabel(isExpanded ? "收起路径" : "显示路径")
        .help(isExpanded ? "收起路径" : "显示路径")

        // 问 AI：针对该项提问
        if let onAskAI {
            RowActionButton(
                systemName: "questionmark.bubble",
                identifier: "askAIButton",
                accessibilityText: "问 AI",
                help: isDisabled ? "AI 回复中，请稍候" : "问 AI：这个是什么？能删吗？",
                tint: Accent.tint,
                isDisabled: isDisabled
            ) {
                onAskAI()
            }
        }
    }

    /// 空格键快速预览快捷键（当悬停或交互该行时）
    private var spaceKeyPreviewShortcut: some View {
        Button("") {
            if let onPreview {
                onPreview(URL(fileURLWithPath: item.path))
            }
        }
        .keyboardShortcut(.space, modifiers: [])
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// 右键菜单
    @ViewBuilder
    private var contextMenuItems: some View {
        if let onPreview {
            Button {
                onPreview(URL(fileURLWithPath: item.path))
            } label: {
                Label("快速查看 (Quick Look)", systemImage: "eye")
            }

            Divider()
        }

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
            onToggle(!isSelected)
        } label: {
            Label(isSelected ? "取消勾选" : "勾选", systemImage: isSelected ? "square" : "checkmark.square")
        }

        Divider()

        // 白名单动作只在有回调时出现。
        //
        // 这里原先有一条 `else { WhitelistManager.shared.addPathRule(...) }` 的兜底：
        // 视图绕过 `AppState` 直接去改单例。而 `AppState` 的白名单 API 除了加规则，
        // 还会**立刻把命中项从各分类结果里摘掉**（并清理卸载器与重复项）。
        // 走兜底路径就只加了规则、没摘结果 —— 用户点了"加入白名单"，
        // 条目却还杵在列表里，和同一条菜单在别处的表现对不上。
        // 这正是不该让视图直连单例的原因：绕过 API 就会丢掉 API 的副作用。
        if let onAddToWhitelist {
            Button {
                onAddToWhitelist()
            } label: {
                Label("加入白名单排除（不再扫描）", systemImage: "shield.slash")
            }
        }

        let ext = (item.path as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let onAddExtensionToWhitelist {
            Button {
                onAddExtensionToWhitelist(ext)
            } label: {
                Label("排除所有 .\(ext) 格式（不再扫描）", systemImage: "doc.badge.gearshape")
            }
        }
    }
}
/// 结论徽标：一个项目只有一枚，展示唯一结论。
///
/// 取代了历史上的 `RiskBadge`（风险）+ `UsageBadge`（使用频率）两枚并列徽标——
/// 那两枚各自"正确"却互相矛盾，是用户不敢用这个工具的直接原因。
struct VerdictBadge: View {
    let recommendation: Recommendation

    var body: some View {
        Text(recommendation.label)
            .font(Typo.micro)
            .foregroundColor(Signal.tint(for: recommendation.kind))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Signal.tint(for: recommendation.kind).opacity(0.13))
            )
            .accessibilityLabel("结论：\(recommendation.label)")
    }
}

/// 智能清理推荐徽标（仅在属于 high 或 medium 推荐级别时展示）
struct SmartRecommendationBadge: View {
    let tier: RecommendationTier

    var body: some View {
        if tier == .high || tier == .medium {
            HStack(spacing: 3) {
                Image(systemName: tier == .high ? "sparkles" : "hand.thumbsup.fill")
                    .font(.system(size: 8))
                Text(tier == .high ? "首选推荐" : "建议清理")
                    .font(Typo.micro)
            }
            .foregroundColor(tier == .high ? Accent.tint : Ink.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(tier == .high ? Accent.tint.opacity(0.12) : Surface.hairline.opacity(0.6))
            )
            .accessibilityLabel("智能推荐：\(tier.title)")
        }
    }
}

/// AI 再筛查结论徽标（AI 扫描：可删/谨慎/不建议删）
struct ReviewBadge: View {
    let verdict: ReviewVerdict

    private var color: Color {
        switch verdict {
        case .delete: return Signal.positive
        case .caution: return Signal.caution
        case .keep: return Signal.critical
        case .unknown: return Ink.tertiary
        }
    }

    var body: some View {
        Text("AI·\(verdict.label)")
            .font(Typo.micro)
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(color.opacity(0.13))
            )
            .accessibilityLabel("AI 结论：\(verdict.label)")
    }
}

// MARK: - 应用残留细分类型过滤

enum AppResidueFilterKind: String, CaseIterable, Identifiable {
    case all = "全部残留"
    case appSupport = "应用数据 (A1)"
    case preferences = "偏好设置 (A2/A5)"
    case launchAgents = "自启代理 (A3)"
    case savedState = "窗口状态 (A4)"

    var id: String { rawValue }

    func matches(item: CleanItem) -> Bool {
        switch self {
        case .all: return true
        case .appSupport: return item.rule == "A1" || item.path.contains("/Application Support/")
        case .preferences: return item.rule == "A2" || item.rule == "A5" || item.path.contains("/Preferences/")
        case .launchAgents: return item.rule == "A3" || item.path.contains("/LaunchAgents/")
        case .savedState: return item.rule == "A4" || item.path.contains("/Saved Application State/")
        }
    }
}

// MARK: - 日志与临时细分类型过滤

enum LogsFilterKind: String, CaseIterable, Identifiable {
    case all = "全部日志与临时"
    case logs = "应用日志 (L1/L5)"
    case diagnostics = "崩溃与诊断 (L2/L7)"
    case temporary = "临时文件 (L3/L4)"
    case shipIt = "更新残留 (L6)"

    var id: String { rawValue }

    func matches(item: CleanItem) -> Bool {
        switch self {
        case .all: return true
        case .logs: return item.rule == "L1" || item.rule == "L5"
        case .diagnostics: return item.rule == "L2" || item.rule == "L7"
        case .temporary: return item.rule == "L3" || item.rule == "L4"
        case .shipIt: return item.rule == "L6"
        }
    }
}

// MARK: - 大文件细分类型过滤

enum LargeFileTypeFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case installer = "安装包"
    case archive = "压缩包"
    case media = "音视频"
    case rawMedia = "RAW相机与设计原稿"
    case diskImage = "虚拟机与镜像"
    case codeArchive = "项目归档与开发包"
    case simulator = "模拟器与备份"
    case other = "其他"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .installer: return "shippingbox"
        case .archive: return "doc.zipper"
        case .media: return "film"
        case .rawMedia: return "camera"
        case .diskImage: return "internaldrive"
        case .codeArchive: return "chevron.left.forwardslash.chevron.right"
        case .simulator: return "iphone"
        case .other: return "doc"
        }
    }

    func matches(item: CleanItem) -> Bool {
        let name = item.name.lowercased()
        let path = item.path.lowercased()
        let ext = (name as NSString).pathExtension.lowercased()

        switch self {
        case .all:
            return true
        case .installer:
            let installerExts = ["pkg", "dmg", "app"]
            return installerExts.contains(ext) || name.contains("installer") || item.note.contains("安装")
        case .archive:
            let archiveExts = ["zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz"]
            return archiveExts.contains(ext)
        case .media:
            let mediaExts = ["mp4", "mov", "mkv", "avi", "wmv", "mp3", "flac", "wav", "aac", "m4a", "webm"]
            return mediaExts.contains(ext)
        case .rawMedia:
            // 相机专业 RAW 与大型设计原稿
            let rawExts = ["cr2", "cr3", "nef", "arw", "dng", "rw2", "orf", "raw", "psd", "psb", "ai", "sketch", "blend", "c4d", "prproj"]
            return rawExts.contains(ext)
        case .diskImage:
            // 虚拟机磁盘与系统镜像文件（排除常见仅用于安装 macOS App 的 dmg）
            let imageExts = ["iso", "img", "vdi", "vmdk", "qcow2", "hdd", "parallels", "vmwarevm"]
            return imageExts.contains(ext) || path.contains("parallels") || path.contains("vmware") || path.contains("virtualbox")
        case .codeArchive:
            // 开发者归档、工程打包与编译输出（排除单一独立客户端安装包）
            let codeExts = ["xcarchive", "apk", "aab", "whl", "gem", "bundle"]
            return codeExts.contains(ext) || name.contains("node_modules") || name.contains("deriveddata") || path.contains("xcode/archives")
        case .simulator:
            return path.contains("devices") || path.contains("mobilesync") || item.note.contains("模拟器") || item.note.contains("备份")
        case .other:
            return !LargeFileTypeFilter.installer.matches(item: item)
                && !LargeFileTypeFilter.archive.matches(item: item)
                && !LargeFileTypeFilter.media.matches(item: item)
                && !LargeFileTypeFilter.rawMedia.matches(item: item)
                && !LargeFileTypeFilter.diskImage.matches(item: item)
                && !LargeFileTypeFilter.codeArchive.matches(item: item)
                && !LargeFileTypeFilter.simulator.matches(item: item)
        }
    }
}

extension CategoryDetailView {
    /// 大文件类型细分与时间/排序过滤栏
    var largeFileTypeFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xxs) {
                ForEach(LargeFileTypeFilter.allCases, id: \.self) { filter in
                    typeFilterChip(filter)
                }

                Rectangle()
                    .fill(Surface.hairline.opacity(0.6))
                    .frame(width: 0.5, height: 14)
                    .padding(.horizontal, Space.xxs)

                // 闲置时间过滤 Picker
                Picker("闲置时间", selection: $selectedAgeFilter) {
                    ForEach(LargeFileAgeFilter.allCases) { age in
                        Text(age.rawValue).tag(age)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 105)
                .accessibilityIdentifier("largeFileAgePicker")

                // 排序 Picker
                Picker("排序", selection: $selectedSortOrder) {
                    ForEach(LargeFileSortOrder.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 135)
                .accessibilityIdentifier("largeFileSortPicker")

                Rectangle()
                    .fill(Surface.hairline.opacity(0.6))
                    .frame(width: 0.5, height: 14)
                    .padding(.horizontal, Space.xxs)

                pivotMatrixChip

                if let yearFilter = activeYearFilter {
                    YearFilterBadge(year: yearFilter) {
                        activeYearFilter = nil
                    }
                }

                directoryTreeChip

                if let dirFilter = activeDirectoryFilter {
                    DirectoryFilterBadge(path: dirFilter) {
                        activeDirectoryFilter = nil
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.xs)
        }
        .background(Surface.window)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// 类型筛选片。选中态用强调色实底，未选中态不加底色也不加边框。
    private func typeFilterChip(_ filter: LargeFileTypeFilter) -> some View {
        let isSelected = selectedTypeFilter == filter
        let count = filter == .all ? st.items.count : st.items.filter { filter.matches(item: $0) }.count

        return Button {
            withAnimation(Motion.micro) { selectedTypeFilter = filter }
        } label: {
            HStack(spacing: 4) {
                if filter != .all {
                    Image(systemName: filter.icon)
                        .font(.system(size: 9))
                }
                Text(filter.rawValue)
                    .font(isSelected ? Typo.rowStrong : Typo.row)
                Text("\(count)")
                    .font(.mcNumeric(10))
                    .opacity(0.65)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isSelected ? Accent.tint : Color.clear)
            )
            .foregroundStyle(isSelected ? Color.white : Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 交叉透视矩阵开关胶囊
    private var pivotMatrixChip: some View {
        Button(action: {
            withAnimation(Motion.standard) {
                showPivotCard.toggle()
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 10))
                Text("交叉透视")
                    .font(Typo.micro)
                if activeYearFilter != nil {
                    Circle()
                        .fill(Accent.tint)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 4)
            .background(showPivotCard ? Accent.tint.opacity(0.18) : Surface.sunken)
            .foregroundColor(showPivotCard ? Accent.tint : Ink.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pivotMatrixToggle")
        .help("展开/收起年份与类型多维空间占用透视矩阵")
    }

    private var directoryTreeChip: some View {
        let isActive = activeDirectoryFilter != nil

        return Button {
            showDirectoryTreeSheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isActive ? "folder.fill.badge.gearshape" : "folder.badge.gearshape")
                    .font(.system(size: 11, weight: .medium))
                Text(isActive ? "目录树 · 已筛选" : "目录树")
                    .font(isActive ? Typo.rowStrong : Typo.row)
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(isActive ? Signal.caution : Color.clear)
            )
            .foregroundStyle(isActive ? Color.white : Ink.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("largeFilesDirectoryTreeButton")
    }

    /// 应用残留细分过滤栏
    var appResidueFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xxs) {
                ForEach(AppResidueFilterKind.allCases) { filter in
                    let isSelected = selectedAppResidueFilter == filter
                    let count = filter == .all ? st.items.count : st.items.filter { filter.matches(item: $0) }.count

                    Button {
                        withAnimation(Motion.micro) { selectedAppResidueFilter = filter }
                    } label: {
                        HStack(spacing: 5) {
                            Text(filter.rawValue)
                                .font(isSelected ? Typo.rowStrong : Typo.row)
                            Text("\(count)")
                                .font(.mcNumeric(10))
                                .opacity(0.65)
                        }
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(isSelected ? Accent.tint : Color.clear)
                        )
                        .foregroundStyle(isSelected ? Color.white : Ink.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("appResidueFilter_\(filter.id)")
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.xs)
        }
        .background(Surface.window)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// 日志与临时细分过滤栏
    var logsFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.xxs) {
                ForEach(LogsFilterKind.allCases) { filter in
                    let isSelected = selectedLogsFilter == filter
                    let count = filter == .all ? st.items.count : st.items.filter { filter.matches(item: $0) }.count

                    Button {
                        withAnimation(Motion.micro) { selectedLogsFilter = filter }
                    } label: {
                        HStack(spacing: 5) {
                            Text(filter.rawValue)
                                .font(isSelected ? Typo.rowStrong : Typo.row)
                            Text("\(count)")
                                .font(.mcNumeric(10))
                                .opacity(0.65)
                        }
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                .fill(isSelected ? Accent.tint : Color.clear)
                        )
                        .foregroundStyle(isSelected ? Color.white : Ink.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("logsFilter_\(filter.id)")
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.xs)
        }
        .background(Surface.window)
        .overlay(alignment: .bottom) { Hairline() }
    }
}

// MARK: - 大文件闲置时间过滤

enum LargeFileAgeFilter: String, CaseIterable, Identifiable {
    case all = "全部时间"
    case withinMonth = "30天内活跃"
    case oneToThreeMonths = "1-3个月"
    case threeToSixMonths = "3-6个月"
    case sixMonthsToOneYear = "半年至1年"
    case overOneYear = "1年以上闲置"

    var id: String { rawValue }

    func matches(item: CleanItem) -> Bool {
        let days = HistoryExporter.idleDays(for: item.modificationDate)
        switch self {
        case .all:
            return true
        case .withinMonth:
            return days < 30
        case .oneToThreeMonths:
            return days >= 30 && days < 90
        case .threeToSixMonths:
            return days >= 90 && days < 180
        case .sixMonthsToOneYear:
            return days >= 180 && days < 365
        case .overOneYear:
            return days >= 365
        }
    }
}

// MARK: - 大文件排序方式

enum LargeFileSortOrder: String, CaseIterable, Identifiable {
    case recommended = "推荐排序"
    case sizeDescending = "体积从大到小"
    case ageOldest = "修改时间最旧优先"
    case ageNewest = "修改时间最新优先"
    case bitrateDescending = "媒体码率最高优先"
    case durationDescending = "媒体时长最长优先"

    var id: String { rawValue }
}
