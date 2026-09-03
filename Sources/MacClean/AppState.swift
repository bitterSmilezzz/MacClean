import Combine
import Foundation

/// 全局 App 状态：磁盘信息、分类状态、清理任务、卸载器、历史
final class AppState: ObservableObject {
    @Published var diskTotal: Int64 = 0
    @Published var diskAvailable: Int64 = 0
    @Published var destination: Destination? = .category(.userCaches)
    @Published var categories: [CategoryState] = CleanCategory.allCases.map { CategoryState(category: $0) }
    @Published var isCleaning = false
    @Published var lastCleanSummary: String?
    @Published var history: [CleanRecord] = []
    let uninstaller = UninstallerState()
    var ai = AIState()   // 需为 var：Binding（$app.ai.xxx）不能穿过 let 属性

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

    func scan(_ cat: CleanCategory) {
        let st = state(for: cat)
        guard !st.isScanning else { return }
        st.isScanning = true
        st.lastError = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = Scanner.scan(cat)
            DispatchQueue.main.async {
                st.items = items
                st.isScanned = true
                st.isScanning = false
                self?.refreshDisk()
            }
        }
    }

    /// 扫描全部分类（侧边栏「全部扫描」）
    func scanAll() {
        for cat in CleanCategory.allCases { scan(cat) }
    }

    func cleanSelected(in cat: CleanCategory, permanently: Bool) {
        let st = state(for: cat)
        let items = st.selectedItems
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        let total = st.selectedSize
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Cleaner.clean(items, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self = self else { return }
                st.releasedBytes += result.releasedBytes
                st.items = st.items.filter { !$0.isSelected }  // 整体赋值触发 @Published
                st.isScanned = true
                self.isCleaning = false
                self.refreshDisk()
                self.recordClean(categoryName: cat.title,
                                 itemCount: result.succeeded,
                                 bytes: total,
                                 mode: permanently ? "彻底删除" : "废纸篓",
                                 failures: result.failures.count)
                var parts = ["已释放 \(total.byteStringCN)"]
                if !result.failures.isEmpty {
                    parts.append("\(result.failures.count) 项失败")
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
}
