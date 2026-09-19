import Foundation
import CryptoKit
import Combine

/// 匹配类型：精确重复、相似衍生或相似图片
enum DuplicateGroupMatchKind: String, Codable, CaseIterable, Equatable {
    case exact = "完全一致"       // SHA-256 分块哈希完全一致
    case similar = "相似衍生"     // 同名副本 (copy, (1), _副本等) 或 格式衍生
    case similarImage = "相似图片" // 感知哈希 (dHash) 识别视觉相似图片
}

/// 过滤器类型
enum DuplicateGroupFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case exact = "完全一致"
    case similar = "相似衍生"
    case similarImage = "相似图片"

    var id: String { rawValue }
}

/// 重复/相似文件组
struct DuplicateGroup: Identifiable, Equatable {
    let id: UUID = UUID()
    let hash: String
    let fileSize: Int64
    var items: [DuplicateFileItem]
    var matchKind: DuplicateGroupMatchKind = .exact
    var suggestionNote: String = ""

    /// 浪费的空间（除保留一个推荐副本外，其余多余副本的总体积）
    ///
    /// **按互异 inode 计算，而不是按路径条数**：多条硬链接指向同一份数据时，
    /// 删掉其中任意几条都不会释放空间，把它们算进"可节省"就是虚报。
    var wastedBytes: Int64 {
        guard items.count > 1 else { return 0 }
        let reclaimable = Int64(max(0, items.distinctInodeCount - 1))
        if matchKind == .exact {
            return fileSize * reclaimable
        } else {
            // 相似文件大小可能不一致：按"除去保留项之外、且不是同一 inode 的那些"求和
            let kept = items.first(where: \.isOriginal) ?? items.first
            var seenInodes = Set<String>()
            if let k = kept?.inodeKey { seenInodes.insert(k) }
            var total: Int64 = 0
            for item in items where item.id != kept?.id {
                if let k = item.inodeKey {
                    if seenInodes.contains(k) { continue }   // 同一 inode 的硬链接，删了不省空间
                    seenInodes.insert(k)
                }
                total += item.size
            }
            return max(0, total)
        }
    }

    /// 本组里有多少条是"删了也不释放空间"的硬链接副本（用于如实告知用户）
    var hardLinkCount: Int { items.hardLinkRedundantCount }

    /// 选中的待清理体积
    var selectedBytes: Int64 {
        items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }
}

/// 单个重复/相似副本条目
struct DuplicateFileItem: Identifiable, Equatable {
    let id: UUID = UUID()
    let path: String
    let name: String
    let size: Int64
    let modificationDate: Date?
    var isSelected: Bool = false
    var isOriginal: Bool = false  // 推荐保留的主文件
    var recommendationReason: String? = nil  // 推荐保留或清理的原因说明

    /// 硬链接标识（`设备号:inode`）。
    ///
    /// **为什么必须有**：两个路径若是指向同一 inode 的硬链接，它们的大小与 SHA-256
    /// 完全相同，必然被分进同一组——但删掉其中一个**释放 0 字节**（数据仍由另一条链接持有）。
    /// 不区分 inode 就会把同一份数据反复计入"可节省空间"，报出一个删了也拿不到的数字。
    /// 实测 macOS 上 Time Machine 本地快照、`cp -l` 备份、部分包管理器的 store 都会产生硬链接。
    var inodeKey: String? = nil
}

extension Array where Element == DuplicateFileItem {
    /// 这一组里**真正**占用空间的互异 inode 数量。
    /// 没有 inode 信息（取不到 stat）时按"每个路径各占一份"保守计算。
    var distinctInodeCount: Int {
        var keys = Set<String>()
        var unknown = 0
        for item in self {
            if let key = item.inodeKey { keys.insert(key) } else { unknown += 1 }
        }
        return keys.count + unknown
    }

    /// 这一组里指向同一 inode 的重复链接（即"删了也不省空间"的那些）。
    /// 每组每条 inode 只保留一条，其余都是硬链接副本。
    var hardLinkRedundantCount: Int {
        Swift.max(0, count - distinctInodeCount)
    }
}

/// 重复文件扫描与管理状态
final class DuplicateState: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var scanProgressMessage = ""
    @Published var progressFraction: Double = 0
    @Published var lastSummary: String?

    /// 扫描范围根目录（默认从 DirectoryScopeManager 同步，也可直接自定义）
    @Published var searchPaths: [String] = DirectoryScopeManager.shared.searchRoots

    /// 最小过滤文件大小（小于此大小的文件不参与比对，默认 1 MB = 1_048_576 字节）
    @Published var minSizeBytes: Int64 = 1_048_576

    /// 当前视图过滤类型
    @Published var filterKind: DuplicateGroupFilter = .all

    /// 当前激活的目录分支过滤路径（为空则显示全部）
    @Published var activeDirectoryFilter: String? = nil

    /// 过滤后的展示分组
    var filteredGroups: [DuplicateGroup] {
        var result: [DuplicateGroup]
        switch filterKind {
        case .all:
            result = groups
        case .exact:
            result = groups.filter { $0.matchKind == .exact }
        case .similar:
            result = groups.filter { $0.matchKind == .similar }
        case .similarImage:
            result = groups.filter { $0.matchKind == .similarImage }
        }

        if let dirFilter = activeDirectoryFilter, !dirFilter.isEmpty {
            let expandedDir = CleanPaths.expand(dirFilter)
            result = result.filter { group in
                group.items.contains { item in
                    let itemExp = CleanPaths.expand(item.path)
                    return itemExp == expandedDir || itemExp.hasPrefix(expandedDir + "/")
                }
            }
        }
        return result
    }

    /// 提取当前全部文件条目（用于生成目录树）
    var allFileEntries: [DirectoryTreeBuilder.FileEntry] {
        var entries: [DirectoryTreeBuilder.FileEntry] = []
        for group in groups {
            for item in group.items {
                entries.append(DirectoryTreeBuilder.FileEntry(path: item.path, size: item.size, isSelected: item.isSelected))
            }
        }
        return entries
    }

    /// 批量切换某个目录（及其所有子目录）下重复副本的勾选状态
    func toggleDirectorySelection(path: String, select: Bool) {
        let expanded = CleanPaths.expand(path)
        for gIndex in groups.indices {
            for iIndex in groups[gIndex].items.indices {
                let itemExp = CleanPaths.expand(groups[gIndex].items[iIndex].path)
                if itemExp == expanded || itemExp.hasPrefix(expanded + "/") {
                    groups[gIndex].items[iIndex].isSelected = select
                }
            }
        }
    }

    /// 各类别统计
    var exactGroupsCount: Int {
        groups.filter { $0.matchKind == .exact }.count
    }

    var similarGroupsCount: Int {
        groups.filter { $0.matchKind == .similar }.count
    }

    var similarImageGroupsCount: Int {
        groups.filter { $0.matchKind == .similarImage }.count
    }

    /// 浪费的总体积
    var totalWastedBytes: Int64 {
        groups.reduce(0) { $0 + $1.wastedBytes }
    }

    /// 当前勾选准备清理的条目数与体积
    var selectedCount: Int {
        groups.reduce(0) { $0 + $1.items.filter(\.isSelected).count }
    }

    var selectedBytes: Int64 {
        groups.reduce(0) { $0 + $1.selectedBytes }
    }

    /// 取消请求标志。扫描在后台线程读取，主线程写入 —— 用锁包一层，
    /// 避免 TSan 报竞争（Bool 的读写不是语言层面保证的原子操作）。
    private let cancelLock = NSLock()
    private var _cancelRequested = false
    private var cancelRequested: Bool {
        get { cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelRequested }
        set { cancelLock.lock(); _cancelRequested = newValue; cancelLock.unlock() }
    }

    /// 请求停止当前扫描。哈希阶段会逐文件轮询这个标志并尽快退出。
    func cancelScan() {
        guard isScanning else { return }
        cancelRequested = true
        scanProgressMessage = "正在停止…"
    }

    /// 启动重复文件扫描
    func startScan() {
        // 已在扫描时不再静默丢弃：明确告诉用户"要么等、要么先停"
        guard !isScanning else {
            lastSummary = "已有一次扫描在进行中；如需重来请先点「停止」。"
            return
        }
        cancelRequested = false
        isScanning = true
        scanProgressMessage = "正在枚举文件…"
        progressFraction = 0.05
        lastSummary = nil

        let paths = searchPaths.map { CleanPaths.expand($0) }
        let minSize = minSizeBytes

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resultGroups = DuplicateScanner.scanDuplicates(
                in: paths,
                minSize: minSize,
                isCancelled: { [weak self] in self?.cancelRequested ?? true },
                progress: { fraction, msg in
                    DispatchQueue.main.async {
                        self?.progressFraction = fraction
                        self?.scanProgressMessage = msg
                    }
                }
            )

            DispatchQueue.main.async {
                guard let self else { return }
                let wasCancelled = self.cancelRequested
                self.cancelRequested = false
                self.isScanning = false
                // 取消时**保留上一次的结果**，不要把用户已有的列表清空
                if !wasCancelled {
                    self.groups = resultGroups
                    self.progressFraction = 1.0
                    let totalFiles = resultGroups.reduce(0) { $0 + $1.items.count }
                    self.scanProgressMessage = "扫描完成，发现 \(resultGroups.count) 组重复文件（共 \(totalFiles) 个副本）"
                } else {
                    self.scanProgressMessage = "已停止扫描（保留上次结果）"
                    self.lastSummary = "扫描已停止。"
                }
            }
        }
    }

    /// 智能自动勾选重复项（每组默认保留 1 个原始副本，其余自动勾选以便清理）
    ///
    /// **硬链接副本不勾选**：它们与组内某条路径共享同一 inode，删掉一个字节都不会释放，
    /// 勾上只会让"可节省空间"看起来更大、实际清理后对不上账。
    func autoSelectDuplicates() {
        for gIndex in groups.indices {
            // 每组每条 inode 只保留第一个见到的，其余同 inode 的都是硬链接副本
            var seenInodes = Set<String>()
            for iIndex in groups[gIndex].items.indices {
                let item = groups[gIndex].items[iIndex]
                var isHardLinkCopy = false
                if let key = item.inodeKey {
                    if seenInodes.contains(key) { isHardLinkCopy = true } else { seenInodes.insert(key) }
                }
                // 若是推荐保留的原始项，或只是同一 inode 的硬链接，则不勾选；其余副本默认勾选
                groups[gIndex].items[iIndex].isSelected = !item.isOriginal && !isHardLinkCopy
            }
        }
    }

    /// 勾选较旧版本（每组保留修改时间最新的 1 份）
    func selectOlderDuplicates() {
        for gIndex in groups.indices {
            guard groups[gIndex].items.count > 1 else { continue }
            let sorted = groups[gIndex].items.sorted { a, b in
                let dateA = a.modificationDate ?? Date.distantPast
                let dateB = b.modificationDate ?? Date.distantPast
                if dateA != dateB {
                    return dateA > dateB
                }
                let aInDl = a.path.contains("/Downloads/")
                let bInDl = b.path.contains("/Downloads/")
                if aInDl != bInDl { return !aInDl }
                return a.path.count < b.path.count
            }
            guard let newest = sorted.first else { continue }
            for iIndex in groups[gIndex].items.indices {
                let item = groups[gIndex].items[iIndex]
                groups[gIndex].items[iIndex].isSelected = (item.id != newest.id)
            }
        }
    }

    /// 勾选较新版本（每组保留最早创建/修改的历史版本 1 份）
    func selectNewerDuplicates() {
        for gIndex in groups.indices {
            guard groups[gIndex].items.count > 1 else { continue }
            let sorted = groups[gIndex].items.sorted { a, b in
                let dateA = a.modificationDate ?? Date.distantPast
                let dateB = b.modificationDate ?? Date.distantPast
                if dateA != dateB {
                    return dateA < dateB
                }
                let aInDl = a.path.contains("/Downloads/")
                let bInDl = b.path.contains("/Downloads/")
                if aInDl != bInDl { return !aInDl }
                return a.path.count < b.path.count
            }
            guard let oldest = sorted.first else { continue }
            for iIndex in groups[gIndex].items.indices {
                let item = groups[gIndex].items[iIndex]
                groups[gIndex].items[iIndex].isSelected = (item.id != oldest.id)
            }
        }
    }

    /// 勾选下载目录副本（若组内存在非下载目录的文件，优先保留非下载目录，勾选下载目录中的副本）
    func selectDownloadsDuplicates() {
        let dlPrefix = CleanPaths.expand("~/Downloads")
        for gIndex in groups.indices {
            guard groups[gIndex].items.count > 1 else { continue }
            let items = groups[gIndex].items
            let nonDownloads = items.filter { item in
                let p = CleanPaths.expand(item.path)
                return !p.hasPrefix(dlPrefix)
            }
            if !nonDownloads.isEmpty {
                for iIndex in groups[gIndex].items.indices {
                    let p = CleanPaths.expand(groups[gIndex].items[iIndex].path)
                    groups[gIndex].items[iIndex].isSelected = p.hasPrefix(dlPrefix)
                }
            } else {
                let sorted = items.sorted {
                    ($0.modificationDate ?? Date.distantPast) > ($1.modificationDate ?? Date.distantPast)
                }
                let keepID = sorted.first?.id
                for iIndex in groups[gIndex].items.indices {
                    groups[gIndex].items[iIndex].isSelected = (groups[gIndex].items[iIndex].id != keepID)
                }
            }
        }
    }

    /// 取消全部勾选
    func deselectAll() {
        for gIndex in groups.indices {
            for iIndex in groups[gIndex].items.indices {
                groups[gIndex].items[iIndex].isSelected = false
            }
        }
    }

    /// 切换单项勾选
    func toggleItem(groupID: UUID, itemID: UUID) {
        guard let gIndex = groups.firstIndex(where: { $0.id == groupID }),
              let iIndex = groups[gIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        groups[gIndex].items[iIndex].isSelected.toggle()
    }

    /// 清理所有勾选的重复文件（默认安全移入废纸篓）
    func cleanSelected(permanently: Bool = false) -> Cleaner.Result {
        var itemsToClean: [CleanItem] = []
        for group in groups {
            for item in group.items where item.isSelected {
                itemsToClean.append(
                    CleanItem(
                        name: item.name,
                        path: item.path,
                        size: item.size,
                        nature: .userData,
                        consequence: "重复副本；同组内已保留另一份，删除这一份不会丢失内容",
                        category: .largeFiles,
                        note: "重复副本（原文件保留）"
                    )
                )
            }
        }
        guard !itemsToClean.isEmpty else { return Cleaner.Result() }

        let result = Cleaner.clean(itemsToClean, permanently: permanently) { _ in }

        // 清理完成后更新内存列表（移除已成功删除的路径）
        let succeeded = result.succeededItemIDs
        let succeededPaths = Set(itemsToClean.filter { succeeded.contains($0.id) }.map(\.path))

        for gIndex in groups.indices {
            groups[gIndex].items.removeAll { succeededPaths.contains($0.path) }
        }
        // 移除已经不构成重复（副本数 <= 1）的组
        groups.removeAll { $0.items.count <= 1 }

        var parts = ["已清理 \(result.succeeded) 个重复副本，释放 \(result.releasedBytes.byteStringCN)"]
        if !result.failures.isEmpty { parts.append("\(result.failures.count) 项失败") }
        lastSummary = parts.joined(separator: "，")

        return result
    }
}

/// 重复文件扫描底层引擎（基于大小快速聚类 + SHA-256 分块哈希检验）
enum DuplicateScanner {

    /// 取路径的硬链接标识 `设备号:inode`。
    ///
    /// 用途：区分"内容相同的两份拷贝"（删一份能省空间）与"指向同一 inode 的两条硬链接"
    /// （删一条**一个字节都不省**）。二者大小与 SHA-256 完全一致，只有 inode 能分开。
    /// 取不到时返回 nil，调用方按"各占一份"保守处理。
    static func inodeKey(forPath path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }


    /// 在指定根目录集合中查找重复文件
    /// - Parameter isCancelled: 逐文件轮询的取消判据。
    ///   重复扫描会对每个候选文件做全量 SHA-256，大盘上动辄几分钟；
    ///   原实现没有任何取消途径，用户只能干等（再次点扫描还会被 `guard !isScanning` 静默丢弃）。
    static func scanDuplicates(
        in directories: [String],
        minSize: Int64,
        isCancelled: () -> Bool = { false },
        progress: @escaping (Double, String) -> Void
    ) -> [DuplicateGroup] {
        let fm = FileManager.default
        let whitelist = WhitelistManager.shared

        // 第一阶段：按文件大小快速归类，同时记录所有候选大文件
        var sizeMap: [Int64: [String]] = [:]
        var allCandidates: [(path: String, size: Int64)] = []
        var candidateFiles = 0

        for dir in directories {
            guard fm.fileExists(atPath: dir) else { continue }
            let dirURL = URL(fileURLWithPath: dir, isDirectory: true)
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]

            guard let enumerator = fm.enumerator(
                at: dirURL,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants, .skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let fileURL as URL in enumerator {
                if isCancelled() { return [] }
                let path = fileURL.path
                // 白名单与目录范围排除过滤（路径、文件扩展名与用户排除子目录）
                if whitelist.isWhitelisted(path: path) ||
                   whitelist.isExtensionWhitelisted(path: path) ||
                   DirectoryScopeManager.shared.isPathExcluded(path) { continue }

                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize else { continue }

                let sz = Int64(size)
                let isImg = ImageHash.isImageFile(path: path)
                let meetsGeneralSize = sz >= minSize
                let meetsImageSize = isImg && sz >= min(minSize, 50_000)

                if meetsGeneralSize {
                    sizeMap[sz, default: []].append(path)
                    allCandidates.append((path: path, size: sz))
                    candidateFiles += 1
                } else if meetsImageSize {
                    allCandidates.append((path: path, size: sz))
                    candidateFiles += 1
                }
            }
        }

        var resultGroups: [DuplicateGroup] = []
        var exactMatchedPaths: Set<String> = []

        // 第二阶段：多级自适应采样与并行哈希校验
        let potentialDuplicateSets = sizeMap.filter { $0.value.count >= 2 }
        let totalSets = max(1, potentialDuplicateSets.count)
        var processedSets = 0

        for (size, paths) in potentialDuplicateSets {
            processedSets += 1
            let frac = 0.1 + (Double(processedSets) / Double(totalSets)) * 0.5
            progress(frac, "正在比对特征 (\(processedSets)/\(totalSets))…")

            // 1. 头 8KB 快速初筛
            var partialMap: [String: [String]] = [:]
            for p in paths {
                if isCancelled() { return [] }
                if let headerHash = calculatePartialHash(at: p, length: 8192) {
                    partialMap[headerHash, default: []].append(p)
                }
            }

            // 2. 对头部相同的候选集合，做「头+尾+中」稀疏采样校验（过滤头同尾异的假阳性大文件）
            for (_, sameHeaderPaths) in partialMap where sameHeaderPaths.count >= 2 {
                let filteredSubgroups: [[String]]
                if size > 8192 {
                    var sampledMap: [String: [String]] = [:]
                    for p in sameHeaderPaths {
                        if isCancelled() { return [] }
                        if let sHash = calculateSampledHash(at: p, fileSize: size) {
                            sampledMap[sHash, default: []].append(p)
                        }
                    }
                    filteredSubgroups = sampledMap.values.filter { $0.count >= 2 }
                } else {
                    filteredSubgroups = [sameHeaderPaths]
                }

                for sameSamplePaths in filteredSubgroups {
                    // 3. 并行全量 SHA-256 计算（带自适应大缓冲与零拷贝）
                    var fullHashMap: [String: [DuplicateFileItem]] = [:]
                    let mapLock = NSLock()

                    DispatchQueue.concurrentPerform(iterations: sameSamplePaths.count) { i in
                        if isCancelled() { return }
                        let p = sameSamplePaths[i]
                        guard let fullHash = calculateFullSHA256(at: p) else { return }
                        let mtime = FileSystem.modificationDate(p)
                        let name = (p as NSString).lastPathComponent
                        let item = DuplicateFileItem(
                            path: p,
                            name: name,
                            size: size,
                            modificationDate: mtime,
                            inodeKey: DuplicateScanner.inodeKey(forPath: p)
                        )
                        mapLock.lock()
                        fullHashMap[fullHash, default: []].append(item)
                        mapLock.unlock()
                    }

                    if isCancelled() { return [] }

                    // 筛选出真正完全一致的文件组
                    for (h, items) in fullHashMap where items.count >= 2 {
                        // 标记推荐保留项（优先选取修改时间最早者；若时间相同，取路径较短者）
                        var sortedItems = items
                        sortedItems.sort { a, b in
                            if let d1 = a.modificationDate, let d2 = b.modificationDate, d1 != d2 {
                                return d1 < d2
                            }
                            return a.path.count < b.path.count
                        }
                        if !sortedItems.isEmpty {
                            sortedItems[0].isOriginal = true
                            sortedItems[0].recommendationReason = "原文件（时间最早）"
                            for idx in 1..<sortedItems.count {
                                sortedItems[idx].recommendationReason = "重复副本"
                            }
                        }
                        let group = DuplicateGroup(
                            hash: h,
                            fileSize: size,
                            items: sortedItems,
                            matchKind: .exact,
                            suggestionNote: "SHA-256 完全一致，保留一份原文件"
                        )
                        resultGroups.append(group)
                        for item in sortedItems {
                            exactMatchedPaths.insert(item.path)
                        }
                    }
                }
            }
        }

        // 第三阶段：相似衍生文件归类（排除已形成精确重复项的文件）
        progress(0.7, "正在分析相似衍生文件…")
        let remainingCandidates = allCandidates.filter { !exactMatchedPaths.contains($0.path) }
        var stemMap: [String: [(path: String, size: Int64)]] = [:]

        for cand in remainingCandidates {
            let filename = (cand.path as NSString).lastPathComponent
            let stem = normalizedStem(for: filename)
            if !stem.isEmpty {
                stemMap[stem, default: []].append(cand)
            }
        }

        // 筛选拥有 2 个及以上相似衍生副本的词干组
        for (stem, cands) in stemMap where cands.count >= 2 {
            var items: [DuplicateFileItem] = []
            for cand in cands {
                let mtime = FileSystem.modificationDate(cand.path)
                let name = (cand.path as NSString).lastPathComponent
                items.append(
                    DuplicateFileItem(
                        path: cand.path,
                        name: name,
                        size: cand.size,
                        modificationDate: mtime,
                        inodeKey: DuplicateScanner.inodeKey(forPath: cand.path)
                    )
                )
            }

            // 智能推荐保留规则：
            // 1. 若体积差异明显（如高清视频/高分辨率图片 vs 压缩版），优先保留体积较大/高清者；
            // 2. 若体积相近（差异 < 5%），优先保留较早修改的原始文件；
            // 3. 规范命名优于含 copy / (1) / 副本 的名称。
            items.sort { a, b in
                // 首先看名字是否是纯净规范名（不含 copy/副本/(1)）
                let aIsCopyName = isDerivedCopyName(a.name)
                let bIsCopyName = isDerivedCopyName(b.name)
                if aIsCopyName != bIsCopyName {
                    return !aIsCopyName // 规范名排前
                }
                // 体积大者排前（可能是更高清无损版本）
                if a.size != b.size {
                    return a.size > b.size
                }
                // 修改时间较早排前
                if let d1 = a.modificationDate, let d2 = b.modificationDate, d1 != d2 {
                    return d1 < d2
                }
                return a.path.count < b.path.count
            }

            if !items.isEmpty {
                items[0].isOriginal = true
                let best = items[0]
                if items.count > 1 && best.size > items[1].size {
                    items[0].recommendationReason = "推荐保留（体积最大/可能为高清版本）"
                } else {
                    items[0].recommendationReason = "推荐保留（主文件）"
                }

                for idx in 1..<items.count {
                    if isDerivedCopyName(items[idx].name) {
                        items[idx].recommendationReason = "衍生副本命名"
                    } else if items[idx].size < best.size {
                        items[idx].recommendationReason = "压缩/衍生版本"
                    } else {
                        items[idx].recommendationReason = "相似文件"
                    }
                }
            }

            let avgSize = items.reduce(0) { $0 + $1.size } / Int64(items.count)
            let group = DuplicateGroup(
                hash: "stem:\(stem)",
                fileSize: avgSize,
                items: items,
                matchKind: .similar,
                suggestionNote: "同词干衍生副本或多格式文件"
            )
            resultGroups.append(group)
        }

        // 第四阶段：基于感知哈希 (dHash) 智能排查相似图片（连拍、轻微裁剪、不同分辨率）
        progress(0.85, "正在比对图片感知指纹…")
        let existingGroupPathSets = Set(resultGroups.map { Set($0.items.map(\.path)) })
        let imageCandidates = allCandidates.filter { cand in
            ImageHash.isImageFile(path: cand.path) && !exactMatchedPaths.contains(cand.path)
        }

        // 优先比对体积较大的候选图片，上限 500 张以确保流畅度与秒级响应
        var sortedImageCandidates = imageCandidates
        sortedImageCandidates.sort { $0.size > $1.size }
        let targetedImages = Array(sortedImageCandidates.prefix(500))

        struct ImageFeature {
            let path: String
            let size: Int64
            let hash: UInt64
            let modificationDate: Date?
        }

        var features: [ImageFeature] = []
        features.reserveCapacity(targetedImages.count)
        let featuresLock = NSLock()
        var completedImages = 0
        let progressLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: targetedImages.count) { idx in
            if isCancelled() { return }
            let cand = targetedImages[idx]
            if let h = ImageHash.computeDHash(path: cand.path) {
                let mtime = FileSystem.modificationDate(cand.path)
                let feat = ImageFeature(path: cand.path, size: cand.size, hash: h, modificationDate: mtime)
                featuresLock.lock()
                features.append(feat)
                featuresLock.unlock()
            }
            progressLock.lock()
            completedImages += 1
            if completedImages % 25 == 0 || completedImages == targetedImages.count {
                let p = 0.85 + 0.1 * (Double(completedImages) / Double(max(1, targetedImages.count)))
                progress(p, "正在提取图片感知特征 (\(completedImages)/\(targetedImages.count))…")
            }
            progressLock.unlock()
        }

        if isCancelled() { return [] }

        let fCount = features.count
        if fCount >= 2 {
            var parent = Array(0..<fCount)
            func findRoot(_ i: Int) -> Int {
                var r = i
                while r != parent[r] { r = parent[r] }
                var curr = i
                while curr != r {
                    let next = parent[curr]
                    parent[curr] = r
                    curr = next
                }
                return r
            }
            func unionNodes(_ i: Int, _ j: Int) {
                let rootI = findRoot(i)
                let rootJ = findRoot(j)
                if rootI != rootJ {
                    parent[rootJ] = rootI
                }
            }

            for i in 0..<(fCount - 1) {
                let hashI = features[i].hash
                for j in (i + 1)..<fCount {
                    let hashJ = features[j].hash
                    // 汉明距离 <= 8 (感知相似度 >= 87.5%)
                    if ImageHash.isSimilar(hashI, hashJ, maxDistance: 8) {
                        unionNodes(i, j)
                    }
                }
            }

            var clusters: [Int: [ImageFeature]] = [:]
            for i in 0..<fCount {
                let root = findRoot(i)
                clusters[root, default: []].append(features[i])
            }

            for (_, members) in clusters where members.count >= 2 {
                let memberPaths = Set(members.map(\.path))
                // 避免与前序阶段产生的完全一致组重复
                if existingGroupPathSets.contains(memberPaths) { continue }
                if existingGroupPathSets.contains(where: { memberPaths.isSubset(of: $0) }) { continue }

                // 排序规则：
                // 1. 体积最大排最前（分辨率更高、无损或未过度压缩的高清原片）
                // 2. 修改时间较早排前
                // 3. 路径短排前
                var sortedMembers = members
                sortedMembers.sort { a, b in
                    if a.size != b.size {
                        return a.size > b.size
                    }
                    if let d1 = a.modificationDate, let d2 = b.modificationDate, d1 != d2 {
                        return d1 < d2
                    }
                    return a.path.count < b.path.count
                }

                let baseHash = sortedMembers[0].hash
                var items: [DuplicateFileItem] = []
                var similarities: [Double] = []

                for (idx, m) in sortedMembers.enumerated() {
                    let filename = (m.path as NSString).lastPathComponent
                    let sim = ImageHash.similarity(baseHash, m.hash)
                    let simPct = Int(round(sim * 100))
                    if idx > 0 { similarities.append(sim) }

                    var item = DuplicateFileItem(
                        path: m.path,
                        name: filename,
                        size: m.size,
                        modificationDate: m.modificationDate,
                        inodeKey: DuplicateScanner.inodeKey(forPath: m.path)
                    )
                    if idx == 0 {
                        item.isOriginal = true
                        item.isSelected = false
                        item.recommendationReason = "推荐保留（最高画质原图）"
                    } else {
                        item.isOriginal = false
                        item.isSelected = false
                        item.recommendationReason = "相似图片 (相似度 \(simPct)%)"
                    }
                    items.append(item)
                }

                let avgSize = items.reduce(0) { $0 + $1.size } / Int64(items.count)
                let minPct = similarities.isEmpty ? 100 : Int(round((similarities.min() ?? 1.0) * 100))
                let maxPct = similarities.isEmpty ? 100 : Int(round((similarities.max() ?? 1.0) * 100))
                let simNote = minPct == maxPct ? "感知相似度 \(minPct)%" : "感知相似度 \(minPct)%~\(maxPct)%"

                let group = DuplicateGroup(
                    hash: "dhash:\(String(baseHash, radix: 16))",
                    fileSize: avgSize,
                    items: items,
                    matchKind: .similarImage,
                    suggestionNote: "\(simNote)，已为您推荐保留画质最优的原图"
                )
                resultGroups.append(group)
            }
        }

        // 按可节省空间从大到小排序
        resultGroups.sort { $0.wastedBytes > $1.wastedBytes }
        progress(1.0, "扫描完成")
        return resultGroups
    }

    /// 提取并归一化文件词干（去除操作系统副本后缀，如 ' (1)', ' copy', ' 拷贝', '_副本', '-backup' 等）
    static func normalizedStem(for filename: String) -> String {
        let ns = filename as NSString
        var stem = ns.deletingPathExtension.lowercased()

        // 移除常见衍生标记
        let patterns = [
            #"\s*[\(_（]\s*\d+\s*[\)_）]"#,         // " (1)", "（2）", "_1"
            #"\s*[-_]backup\b"#,                    // "-backup", "_backup"
            #"\s*[-_]bak\b"#,                       // "-bak"
            #"\s*[-_]?copy\b"#,                     // " copy", "-copy", "copy"
            #"\s*[-_]?拷贝\b"#,                     // " 拷贝", "_拷贝"
            #"\s*[-_]?副本\b"#                      // "_副本", " 副本"
        ]

        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: stem.utf16.count)
                stem = regex.stringByReplacingMatches(in: stem, options: [], range: range, withTemplate: "")
            }
        }

        return stem.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 判断文件名是否包含典型的衍生副本标识
    static func isDerivedCopyName(_ filename: String) -> Bool {
        let lower = filename.lowercased()
        let keywords = [" (1)", " (2)", " (3)", " copy", "_copy", "-copy", " 拷贝", "_拷贝", "副本", "-backup", "_bak"]
        for kw in keywords {
            if lower.contains(kw) { return true }
        }
        return false
    }

    /// 读取文件前 length 字节生成快速哈希
    static func calculatePartialHash(at path: String, length: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: length) else { return nil }
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// 组合多级采样哈希（头 16KB + 尾 16KB + 中 16KB）
    ///
    /// 在计算耗时的全量 SHA-256 之前，通过对大文件的头部、尾部（常包含音视频索引与元数据表）
    /// 以及正中位置进行稀疏采样，能够瞬间淘汰 95% 以上"同格式、同大小但内容不同"的假阳性文件，
    /// 避免在数 GB 到数百 GB 文件上执行无效的整盘顺序读取。
    static func calculateSampledHash(at path: String, fileSize: Int64) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // 文件过小时，直接读取整文件作为采样哈希
        if fileSize <= 49152 { // <= 48KB
            guard let data = try? handle.read(upToCount: Int(fileSize)) else { return nil }
            let digest = Insecure.MD5.hash(data: data)
            return digest.map { String(format: "%02hhx", $0) }.joined()
        }

        var hasher = Insecure.MD5()
        let sampleSize = 16384 // 16KB 采样块

        // 1. 头采样
        if let headData = try? handle.read(upToCount: sampleSize) {
            hasher.update(data: headData)
        } else {
            return nil
        }

        // 2. 中部采样（仅对 > 1MB 的大文件）
        if fileSize > 1024 * 1024 {
            let midOffset = UInt64((fileSize / 2) - Int64(sampleSize / 2))
            do {
                try handle.seek(toOffset: midOffset)
                if let midData = try? handle.read(upToCount: sampleSize) {
                    hasher.update(data: midData)
                }
            } catch {
                return nil
            }
        }

        // 3. 尾部采样
        let tailOffset = UInt64(fileSize - Int64(sampleSize))
        do {
            try handle.seek(toOffset: tailOffset)
            if let tailData = try? handle.read(upToCount: sampleSize) {
                hasher.update(data: tailData)
            }
        } catch {
            return nil
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// 计算文件全量 SHA-256（带自适应 I/O 缓冲与零拷贝指针操作）
    static func calculateFullSHA256(at path: String) -> String? {
        let size = FileSystem.size(at: path)
        let bufferSize: Int
        if size > 64 * 1024 * 1024 {
            bufferSize = 2 * 1024 * 1024  // 2MB: 针对 >64MB 大文件，大幅减少系统调用并跑满 NVMe 带宽
        } else if size > 1024 * 1024 {
            bufferSize = 512 * 1024       // 512KB: 针对 1MB~64MB 中等文件
        } else {
            bufferSize = 64 * 1024        // 64KB: 针对 <=1MB 小文件
        }

        guard let stream = InputStream(fileAtPath: path) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            hasher.update(data: Data(bytesNoCopy: buffer, count: read, deallocator: .none))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
