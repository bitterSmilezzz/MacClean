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
    @Published var history: [CleanRecord] = []
    let uninstaller = UninstallerState()
    var ai = AIState()   // 需为 var：Binding（$app.ai.xxx）不能穿过 let 属性
    /// AI 再筛查状态（AI 扫描）：脚本扫描之外的 AI 二次判断
    let aiReview = AIReviewState()

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
        ai.app = self   // 弱引用：列表级提问需访问当前分类状态
        aiReview.app = self

        history = HistoryStore.load()
        refreshDisk()
    }

    var diskUsed: Int64 { max(0, diskTotal - diskAvailable) }
    var usedRatio: Double { diskTotal > 0 ? min(1.0, Double(diskUsed) / Double(diskTotal)) : 0 }

    func refreshDisk() {
        if let v = DiskInfo.volumes() {
            diskTotal = v.total
            diskAvailable = v.available
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
    var riskTotals: [RiskLevel: Int64] {
        var totals: [RiskLevel: Int64] = [:]
        for item in searchableItems {
            totals[item.risk, default: 0] += item.size
        }
        return totals
    }

    func scan(_ cat: CleanCategory) {
        let st = state(for: cat)
        guard !st.isScanning else { return }
        st.isScanning = true
        st.lastError = nil
        // 重新扫描后该分类旧 AI 结论失效（item id 变化）——仅清当前分类的筛查结果
        let oldIDs = Set(st.items.map(\.id))
        aiReview.removeReviews(for: oldIDs)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let items = try Scanner.scan(cat)
                DispatchQueue.main.async {
                    st.items = items
                    st.isScanned = true
                    st.isScanning = false
                    self?.refreshDisk()
                }
            } catch {
                DispatchQueue.main.async {
                    st.isScanning = false
                    st.lastError = "扫描失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 扫描全部分类（侧边栏「全部扫描」）
    func scanAll() {
        for cat in CleanCategory.allCases { scan(cat) }
    }

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
        isCleaning = true
        let total = items.reduce(Int64(0)) { $0 + $1.size }
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
        isCleaning = true
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Cleaner.clean(items, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let done = result.succeededItemIDs
                // #7（二轮）：按成功项逐分类记账，而非全记到第一个贡献分类
                for st in contributingCategories {
                    // LOW-4：用 Cleaner 逐 item 实际释放字节记账（与全局 releasedBytes 口径一致），
                    // 避免"全部路径已不存在仍按 item.size 计"的偏差
                    let originalItems = st.items
                    let releasedHere = originalItems
                        .filter { cleaningIDs.contains($0.id) && done.contains($0.id) }
                        .reduce(Int64(0)) { $0 + (result.releasedBytesByItem[$1.id] ?? 0) }
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
                self.isCleaning = false
                self.refreshDisk()
                self.recordClean(categoryName: "多分类",
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
                self.lastCleanSummary = parts.joined(separator: "，")
            }
        }
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
