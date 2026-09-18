import AppKit
import Combine
import Foundation

/// 全局 App 状态：磁盘信息、分类状态、清理任务、卸载器、历史
final class AppState: ObservableObject {
    @Published var diskTotal: Int64 = 0
    @Published var diskAvailable: Int64 = 0
    /// 全局检索查询词（三巡：提升到 AppState 持久化，导航离开/返回不丢）
    @Published var searchQuery = ""
    @Published var destination: Destination = .dashboard {
        didSet {
            // Q7 切换即换：离开当前列表/条目时作废旧 AI 上下文
            if oldValue != destination {
                ai.clearContext()
            }
        }
    }
    @Published var categories: [CategoryState] = CleanCategory.allCases.map { CategoryState(category: $0) }
    @Published var isCleaning = false
    @Published var lastCleanSummary: String?
    @Published var lastCleanResult: CleanResultSnapshot?
    @Published var showCleanResultSheet: Bool = false
    @Published var history: [CleanRecord] = []
    let uninstaller = UninstallerState()
    var ai = AIState()   // 需为 var：Binding（$app.ai.xxx）不能穿过 let 属性
    /// AI 再筛查状态（AI 扫描）：脚本扫描之外的 AI 二次判断
    let aiReview = AIReviewState()
    /// 磁盘低空间与定时巡检监控器
    var diskMonitor = DiskMonitor.shared
    /// 用户自定义白名单管理中心
    var whitelist = WhitelistManager.shared
    /// 重复文件扫描与清理状态
    var duplicateState = DuplicateState()

    // MARK: - 风险检查（电脑风险提醒）
    @Published var riskItems: [RiskItem] = []
    @Published var isRiskScanning = false
    @Published var riskScanned = false
    @Published var riskLastError: String?

    // MARK: - 并发扫描进度（v1.33.0）
    /// 是否正在执行整轮全量扫描
    @Published var isScanningAll = false
    /// 整轮扫描进度 (0.0 ~ 1.0)，每完成一个分类步进 1/6
    @Published var scanProgress: Double = 0
    /// 上一轮整轮扫描耗时（秒），供 Dashboard 展示
    @Published var lastScanDuration: TimeInterval?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // 关键：把每个 CategoryState 的变更转发到 AppState，
        // 否则勾选状态变化不会触发 CategoryDetailView 重绘（@Published 不监听嵌套对象）
        for state in categories {
            state.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        // 卸载器状态同样转发
        uninstaller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // AI 对话状态同样转发
        ai.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // AI 再筛查状态同样转发
        aiReview.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 磁盘巡检监控器同样转发
        diskMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 白名单管理器同样转发
        whitelist.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 重复文件管理器同样转发
        duplicateState.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ai.app = self   // 弱引用：列表级提问需访问当前分类状态
        aiReview.app = self
        diskMonitor.app = self

        // 监听分类可清理项目总数变化，异步更新 Dock 徽标
        objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                NotificationManager.shared.updateDockBadge(count: self.searchableItems.count)
            }
            .store(in: &cancellables)

        history = HistoryStore.load()
        refreshDisk()
    }

    var diskUsed: Int64 { max(0, diskTotal - diskAvailable) }
    var usedRatio: Double { diskTotal > 0 ? min(1.0, Double(diskUsed) / Double(diskTotal)) : 0 }

    func refreshDisk() {
        if let v = DiskInfo.volumes() {
            diskTotal = v.total
            diskAvailable = v.available
            diskMonitor.checkDiskSpaceAlert(availableBytes: v.available)
        }
    }

    func state(for cat: CleanCategory) -> CategoryState {
        categories.first { $0.category == cat } ?? CategoryState(category: cat)
    }

    // MARK: - 全局检索数据聚合（只读）
    /// 全部已扫描项（供 GlobalSearch 内存过滤）
    var searchableItems: [CleanItem] {
        categories.flatMap { $0.items }
    }

    /// 侧边栏统计：已扫描分类数 / 可清理总量
    var scannedCount: Int { categories.filter { $0.isScanned }.count }
    var totalCleanable: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    var totalSelected: Int64 { categories.reduce(0) { $0 + $1.selectedSize } }
    var totalSelectedCount: Int { categories.reduce(0) { $0 + $1.selectedCount } }

    /// 各风险级汇总（Dashboard 风险分布）
    /// 全部分类累计的扫描问题。非空即代表"当前结果不完整"，界面要如实说明。
    var allScanIssues: [ScanIssue] { categories.flatMap(\.issues) }

    /// 结论构成：各结论档位的可清理体积。
    ///
    /// 取代了历史上的 `riskTotals`（按"风险等级"汇总）。注意与 `riskCounts` / `riskItems`
    /// 区分：后者是"电脑风险提醒"模块的安全检查结果，与本处的清理结论是两回事。
    var verdictTotals: [Recommendation.Kind: Int64] {
        var totals: [Recommendation.Kind: Int64] = [:]
        for item in searchableItems {
            totals[item.recommendation.kind, default: 0] += item.size
        }
        return totals
    }

    func scan(_ cat: CleanCategory) {
        scan(cat, resetMeasurementSession: true)
    }

    /// - Parameter resetMeasurementSession: 是否顺带开启新的测量会话。
    ///   **批量扫描时必须为 false**：`scanAll` 会把 6 个分类并发丢进全局队列，
    ///   若每个分类开工都清一次共享的测量缓存，它们会互相把对方正在用的缓存清掉，
    ///   缓存复用彻底失效（实测让整轮扫描慢一倍）。会话边界由 `scanAll` 统一划定一次。
    private func scan(_ cat: CleanCategory, resetMeasurementSession: Bool) {
        let st = state(for: cat)
        guard !st.isScanning else { return }
        st.isScanning = true
        st.lastError = nil
        // 重新扫描后该分类旧 AI 结论失效（item id 变化）——仅清当前分类的筛查结果
        let oldIDs = Set(st.items.map(\.id))
        aiReview.removeReviews(for: oldIDs)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if resetMeasurementSession { FileSystem.beginMeasurementSession() }
            // 走 scanDetailed：除了结果项，还要拿回"哪些根目录这次读不到"。
            // 少了这一步，缺「完全磁盘访问权限」时整类会安静地返回 0 项，
            // 用户读成"这里很干净"——而废纸篓里可能躺着几十 GB。
            let outcome = Scanner.scanDetailed(cat)
            DispatchQueue.main.async {
                st.items = outcome.items
                st.issues = outcome.issues
                st.isScanned = true
                st.isScanning = false
                self?.refreshDisk()
                NotificationManager.shared.notifyScanCompleted(
                    categoryName: cat.title,
                    itemCount: outcome.items.count,
                    totalBytes: outcome.items.reduce(Int64(0)) { $0 + $1.size }
                )
            }
        }
    }

    /// 扫描全部分类（侧边栏「全部扫描」）
    ///
    /// **v1.33.0 重构**：改用 `DispatchGroup` + `Scanner.scanAllCategoriesWithProgress`
    /// 实现真正的多核并发扫描。每个分类完成后立即刷新对应 UI（渐进式），
    /// 而不是等全部做完才一次性显示。同时记录整轮扫描耗时供 Dashboard 展示。
    func scanAll() {
        guard !isScanningAll else { return }

        // 重置进度状态
        isScanningAll = true
        scanProgress = 0
        lastScanDuration = nil

        // 准备阶段（主线程）：标记所有分类为扫描中、清旧 AI 结论
        let allCats = CleanCategory.allCases
        var categoryStates: [CleanCategory: CategoryState] = [:]
        for cat in allCats {
            let st = state(for: cat)
            st.isScanning = true
            st.lastError = nil
            let oldIDs = Set(st.items.map(\.id))
            aiReview.removeReviews(for: oldIDs)
            categoryStates[cat] = st
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let totalCategories = Double(allCats.count)

        // 并发扫描（后台线程），每个分类完成后回调主线程渐进刷新
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Scanner.scanAllCategoriesWithProgress(callbackQueue: .main) { cat, outcome in
                guard let self else { return }
                if let st = categoryStates[cat] {
                    st.items = outcome.items
                    st.issues = outcome.issues
                    st.isScanned = true
                    st.isScanning = false
                    NotificationManager.shared.notifyScanCompleted(
                        categoryName: cat.title,
                        itemCount: outcome.items.count,
                        totalBytes: outcome.items.reduce(Int64(0)) { $0 + $1.size }
                    )
                }
                self.scanProgress = min(1.0, self.scanProgress + 1.0 / totalCategories)

                // 当所有分类都完成时收尾
                let allDone = self.categories.allSatisfy { $0.isScanned && !$0.isScanning }
                if allDone {
                    self.lastScanDuration = CFAbsoluteTimeGetCurrent() - startTime
                    self.isScanningAll = false
                    self.refreshDisk()
                }
            }
        }
    }

    /// 将指定路径加入白名单并立刻从当前已扫描项目中移除
    func addPathToWhitelist(_ path: String, comment: String = "") {
        whitelist.addPathRule(path, comment: comment)
        for cat in categories {
            cat.items.removeAll { item in
                whitelist.isWhitelisted(path: item.path) || item.paths.contains(where: { whitelist.isWhitelisted(path: $0) })
            }
        }
        uninstaller.related.removeAll { f in
            whitelist.isWhitelisted(path: f.path)
        }
        uninstaller.orphanApps = uninstaller.orphanApps.compactMap { app in
            let remaining = app.items.filter { !self.whitelist.isWhitelisted(path: $0.path) }
            guard !remaining.isEmpty else { return nil }
            var updated = app
            updated.items = remaining
            return updated
        }
    }

    /// 将指定文件扩展名加入排除白名单并立刻从当前已扫描项目中移除
    func addExtensionToWhitelist(_ ext: String, comment: String = "") {
        whitelist.addExtensionRule(ext, comment: comment)
        for cat in categories {
            cat.items.removeAll { item in
                whitelist.isExtensionWhitelisted(path: item.path) || item.paths.contains(where: { whitelist.isExtensionWhitelisted(path: $0) })
            }
        }
        uninstaller.related.removeAll { f in
            whitelist.isExtensionWhitelisted(path: f.path)
        }
        uninstaller.orphanApps = uninstaller.orphanApps.compactMap { app in
            let remaining = app.items.filter { !self.whitelist.isExtensionWhitelisted(path: $0.path) }
            guard !remaining.isEmpty else { return nil }
            var updated = app
            updated.items = remaining
            return updated
        }
        duplicateState.groups = duplicateState.groups.compactMap { group in
            let filtered = group.items.filter { !whitelist.isExtensionWhitelisted(path: $0.path) }
            guard filtered.count >= 2 else { return nil }
            var updated = group
            updated.items = filtered
            return updated
        }
    }

    // MARK: - 键盘快捷键响应操作

    /// ⌘R 智能刷新当前上下文（按当前页面自适应）
    func refreshCurrentContext() {
        switch destination {
        case .dashboard, .history, .search:
            scanAll()
        case .category(let cat):
            scan(cat)
        case .uninstaller:
            uninstaller.loadApps()
        case .riskCheck:
            scanRisks()
        case .duplicates:
            duplicateState.startScan()
        case .spaceTreemap:
            break
        }
    }

    /// ⌘K 聚焦快速检索
    func focusSearch() {
        destination = .search
    }

    // MARK: - 风险检查（电脑风险提醒）

    /// 执行电脑风险检查（只读，不删除任何文件）
    func scanRisks() {
        guard !isRiskScanning else { return }
        isRiskScanning = true
        riskLastError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = RiskScanner.scan { _ in }
            DispatchQueue.main.async {
                self?.riskItems = items
                self?.riskScanned = true
                self?.isRiskScanning = false
            }
        }
    }

    /// 风险统计：各严重度数量
    var riskCounts: [RiskSeverity: Int] {
        var counts: [RiskSeverity: Int] = [:]
        for item in riskItems {
            counts[item.severity, default: 0] += 1
        }
        return counts
    }

    var totalRiskCount: Int { riskItems.count }

    func cleanSelected(in cat: CleanCategory, permanently: Bool) {
        let st = state(for: cat)
        let selected = st.selectedItems
        guard !selected.isEmpty, !isCleaning else { return }
        // M3：清理前实时校验运行态——扫描后新启动的浏览器项要跳过
        // LOW-1（终检）：部分跳过时记录被跳项，完成回调取消勾选并提示
        let runningBlocked = selected.filter { Self.browserNowRunning($0) }
        let items = selected.filter { !Self.browserNowRunning($0) }
        guard !items.isEmpty else {
            st.lastError = "所选项对应 App 正在运行，已跳过；请关闭后重试"
            return
        }
        // M3：快照本次清理的 item id，避免清理期间新勾选项被误移出
        let cleaningIDs = Set(items.map(\.id))
        let beforeAvailable = diskAvailable
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Cleaner.clean(items, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self = self else { return }
                st.releasedBytes += result.releasedBytes
                // M4：仅移除清理快照中成功删净的项；失败项保留并取消勾选
                // #1（二轮）：filter 保留快照外的新勾选项
                let done = result.succeededItemIDs
                st.items = st.items.map { item in
                    guard item.isSelected, cleaningIDs.contains(item.id) else { return item }
                    if !done.contains(item.id) {
                        var copy = item
                        copy.isSelected = false
                        return copy
                    }
                    return item
                }.filter { !$0.isSelected || !cleaningIDs.contains($0.id) }
                // LOW-1：运行态被跳项取消勾选（避免"还勾着却删不掉"困惑）
                if !runningBlocked.isEmpty {
                    st.items = st.items.map { item in
                        guard runningBlocked.contains(where: { $0.id == item.id }) else { return item }
                        var copy = item
                        copy.isSelected = false
                        return copy
                    }
                }
                st.isScanned = true
                self.isCleaning = false
                self.refreshDisk()
                self.recordClean(categoryName: cat.title,
                                 itemCount: result.succeeded,
                                 bytes: result.releasedBytes,   // N8：历史记录用实际释放量，而非计划量
                                 mode: permanently ? "彻底删除" : "废纸篓",
                                 failures: result.failures.count)
                var parts = ["已释放 \(result.releasedBytes.byteStringCN)"]
                if !result.failures.isEmpty {
                    parts.append("\(result.failures.count) 项失败")
                }
                if !runningBlocked.isEmpty {
                    parts.append("\(runningBlocked.count) 项因 App 正在运行已跳过")
                }
                self.lastCleanSummary = parts.joined(separator: "，")
                if result.releasedBytes > 0 || result.succeeded > 0 {
                    self.lastCleanResult = CleanResultSnapshot(
                        title: "\(cat.title) 清理完成",
                        releasedBytes: result.releasedBytes,
                        itemCount: result.succeeded,
                        failureCount: result.failures.count,
                        mode: permanently ? "彻底删除" : "废纸篓",
                        beforeAvailable: beforeAvailable,
                        afterAvailable: self.diskAvailable,
                        breakdown: [cat: result.releasedBytes],
                        timestamp: Date()
                    )
                    self.showCleanResultSheet = true
                }
                NotificationManager.shared.notifyCleanCompleted(
                    releasedBytes: result.releasedBytes,
                    failureCount: result.failures.count
                )
            }
        }
    }

    /// 跨分类聚合清理（H2 修复）：一次 Cleaner.clean 处理所有分类的勾选项，
    /// 避免逐分类调用时 isCleaning 短路导致"只清第一个分类"
    func cleanSelectedAcrossCategories(permanently: Bool) {
        let allSelected = categories.flatMap { $0.selectedItems }
        guard !allSelected.isEmpty, !isCleaning else { return }
        // M3：跨分类同样实时过滤运行态浏览器项 + 快照本次清理 id
        // LOW-1（终检）：记录被跳项，完成回调取消勾选并提示
        let runningBlocked = allSelected.filter { Self.browserNowRunning($0) }
        let items = allSelected.filter { !Self.browserNowRunning($0) }
        guard !items.isEmpty else {
            // 二轮 #5：全部被运行态过滤时给出明确反馈，避免静默
            lastCleanSummary = "没有可清理项：所选项对应 App 正在运行，请关闭后重试"
            return
        }
        let cleaningIDs = Set(items.map(\.id))
        // LOW-3（终检）：快照贡献分类，避免清理期间用户取消勾选导致分类被漏记/漏清理
        let contributingCategories = categories.filter { cat in
            items.contains { $0.category == cat.category && cleaningIDs.contains($0.id) }
        }
        let beforeAvailable = diskAvailable
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Cleaner.clean(items, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let breakdown = self.applyCleanBookkeeping(for: contributingCategories,
                                                           result: result,
                                                           cleaningIDs: cleaningIDs,
                                                           runningBlocked: runningBlocked)
                self.isCleaning = false
                self.refreshDisk()
                self.reportAggregateCleanOutcome(result: result,
                                                 breakdown: breakdown,
                                                 runningBlocked: runningBlocked,
                                                 beforeAvailable: beforeAvailable,
                                                 permanently: permanently)
            }
        }
    }

    /// 聚合清理的逐分类记账：按成功项累计实际释放量、移除已清理项、取消被跳过项勾选。
    /// - Returns: 各贡献分类实际释放的字节数（结果弹窗的分类明细）
    private func applyCleanBookkeeping(for contributingCategories: [CategoryState],
                                       result: Cleaner.Result,
                                       cleaningIDs: Set<UUID>,
                                       runningBlocked: [CleanItem]) -> [CleanCategory: Int64] {
        let done = result.succeededItemIDs
        var breakdown: [CleanCategory: Int64] = [:]
        // #7（二轮）：按成功项逐分类记账，而非全记到第一个贡献分类
        for st in contributingCategories {
            // LOW-4：用 Cleaner 逐 item 实际释放字节记账（与全局 releasedBytes 口径一致），
            // 避免"全部路径已不存在仍按 item.size 计"的偏差
            let originalItems = st.items
            let releasedHere = originalItems
                .filter { cleaningIDs.contains($0.id) && done.contains($0.id) }
                .reduce(Int64(0)) { $0 + (result.releasedBytesByItem[$1.id] ?? 0) }
            if releasedHere > 0 {
                breakdown[st.category] = releasedHere
            }
            // #1（二轮）：filter 保留快照外新勾选项
            st.items = originalItems.map { item in
                guard item.isSelected, cleaningIDs.contains(item.id) else { return item }
                if !done.contains(item.id) {
                    var copy = item
                    copy.isSelected = false
                    return copy
                }
                return item
            }.filter { !$0.isSelected || !cleaningIDs.contains($0.id) }
            // LOW-1：运行态被跳项取消勾选（避免"还勾着却删不掉"困惑）
            if !runningBlocked.isEmpty {
                st.items = st.items.map { item in
                    guard runningBlocked.contains(where: { $0.id == item.id }) else { return item }
                    var copy = item
                    copy.isSelected = false
                    return copy
                }
            }
            st.releasedBytes += releasedHere
        }
        return breakdown
    }

    /// 聚合清理的收尾播报：写清理历史、状态栏摘要、结果弹窗快照与系统通知
    private func reportAggregateCleanOutcome(result: Cleaner.Result,
                                             breakdown: [CleanCategory: Int64],
                                             runningBlocked: [CleanItem],
                                             beforeAvailable: Int64,
                                             permanently: Bool) {
        recordClean(categoryName: "多分类",
                    itemCount: result.succeeded,
                    bytes: result.releasedBytes,   // N8：实际释放量
                    mode: permanently ? "彻底删除" : "废纸篓",
                    failures: result.failures.count)
        var parts = ["已释放 \(result.releasedBytes.byteStringCN)"]
        if !result.failures.isEmpty {
            parts.append("\(result.failures.count) 项失败")
        }
        if !runningBlocked.isEmpty {
            parts.append("\(runningBlocked.count) 项因 App 正在运行已跳过")
        }
        lastCleanSummary = parts.joined(separator: "，")
        if result.releasedBytes > 0 || result.succeeded > 0 {
            lastCleanResult = CleanResultSnapshot(
                title: "聚合清理完成",
                releasedBytes: result.releasedBytes,
                itemCount: result.succeeded,
                failureCount: result.failures.count,
                mode: permanently ? "彻底删除" : "废纸篓",
                beforeAvailable: beforeAvailable,
                afterAvailable: diskAvailable,
                breakdown: breakdown,
                timestamp: Date()
            )
            showCleanResultSheet = true
        }
        NotificationManager.shared.notifyCleanCompleted(
            releasedBytes: result.releasedBytes,
            failureCount: result.failures.count
        )
    }

    /// 菜单栏助手一键快速安全清理：自动勾选所有结论为「可清理」且未加入白名单的项并移入废纸篓。
    ///
    /// 两道门槛，职责不同：
    ///  1. `recommendation.isSafe` —— 唯一结论轴。它**本身已经蕴含**
    ///     "所属应用未在运行、且不是靠推断判定的"；
    ///  2. `!usage.isRecentlyUsed` —— 额外保险。它不产出任何标签，因此不会造成第二条轴，
    ///     只是把"工具替你自动动手"的范围再收窄一档。与 `DiskMonitor` 的无人值守清理保持一致。
    ///
    /// 用户仍可手动勾选并清理近期写过的缓存——那是有意识的决定，不是一键代劳。
    func quickCleanSafeItems() {
        guard !isCleaning else { return }
        for st in categories {
            for i in 0..<st.items.count {
                let item = st.items[i]
                if item.recommendation.isSafe && !item.usage.isRecentlyUsed
                    && !whitelist.isWhitelisted(path: item.path) {
                    st.items[i].isSelected = true
                }
            }
        }
        cleanSelectedAcrossCategories(permanently: false)
    }

    /// 记录一次清理历史（Mole `mo history` 思路）
    func recordClean(categoryName: String, itemCount: Int, bytes: Int64,
                     mode: String, failures: Int) {
        history.insert(CleanRecord(categoryName: categoryName, itemCount: itemCount,
                                   bytes: bytes, mode: mode, failures: failures), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history = []
        HistoryStore.save(history)
    }

    // MARK: - 运行态实时校验（M3：扫描后新启动的浏览器不删其数据）

    /// 浏览器名称片段 → bundle id（路径特征匹配用）
    private static let browserPathHints: [(String, String)] = [
        ("Google Chrome", "com.google.Chrome"),
        ("Microsoft Edge", "com.microsoft.edgemac"),
        ("Brave Browser", "com.brave.Browser"),
        ("Opera", "com.operasoftware.Opera"),
        ("Vivaldi", "com.vivaldi.Vivaldi"),
        ("Safari", "com.apple.Safari"),
    ]

    /// 该项是否属于"对应 App 正在运行"的浏览器数据（此时不应清理）
    static func browserNowRunning(_ item: CleanItem) -> Bool {
        guard item.category == .browserAndSystem || item.category == .userCaches else { return false }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        for (hint, bundleID) in browserPathHints where running.contains(bundleID) {
            if item.name.contains(hint) || item.path.contains(hint) { return true }
            // #3（二轮）：C6 容器缓存 name 是 "com.google.Chrome 缓存" 这类 bundle-id 形态，
            // 名称 hint（"Google Chrome" 含空格）匹配不到 → 补 bundle id 匹配
            if item.name.contains(bundleID) || item.path.contains(bundleID) { return true }
        }
        // C1 用户缓存目录名即 bundle id（如 com.google.Chrome）
        if item.category == .userCaches {
            let dirName = (item.path as NSString).lastPathComponent
            if running.contains(dirName) { return true }
            // C6 容器缓存路径末段是 Caches，回退匹配路径中的 bundle id
            if running.contains(where: { item.path.contains($0) }) { return true }
        }
        return false
    }
}
