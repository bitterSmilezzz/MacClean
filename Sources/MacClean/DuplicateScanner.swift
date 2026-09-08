import Foundation
import CryptoKit
import Combine

/// 匹配类型：精确重复或相似衍生
enum DuplicateGroupMatchKind: String, Codable, CaseIterable, Equatable {
    case exact = "完全一致"       // SHA-256 分块哈希完全一致
    case similar = "相似衍生"     // 同名副本 (copy, (1), _副本等) 或 格式衍生
}

/// 过滤器类型
enum DuplicateGroupFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case exact = "完全一致"
    case similar = "相似衍生"

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
    var wastedBytes: Int64 {
        guard items.count > 1 else { return 0 }
        if matchKind == .exact {
            return fileSize * Int64(items.count - 1)
        } else {
            // 相似文件大小可能不一致，浪费体积为除推荐保留项之外的所有项大小之和
            let total = items.reduce(0) { $0 + $1.size }
            let keptSize = items.first(where: \.isOriginal)?.size ?? (items.first?.size ?? 0)
            return max(0, total - keptSize)
        }
    }

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
}

/// 重复文件扫描与管理状态
final class DuplicateState: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var scanProgressMessage = ""
    @Published var progressFraction: Double = 0
    @Published var lastSummary: String?

    /// 扫描范围根目录（默认包含“下载”、“文稿”、“桌面”）
    @Published var searchPaths: [String] = [
        "~/Downloads",
        "~/Documents",
        "~/Desktop"
    ]

    /// 最小过滤文件大小（小于此大小的文件不参与比对，默认 1 MB = 1_048_576 字节）
    @Published var minSizeBytes: Int64 = 1_048_576

    /// 当前视图过滤类型
    @Published var filterKind: DuplicateGroupFilter = .all

    /// 过滤后的展示分组
    var filteredGroups: [DuplicateGroup] {
        switch filterKind {
        case .all:
            return groups
        case .exact:
            return groups.filter { $0.matchKind == .exact }
        case .similar:
            return groups.filter { $0.matchKind == .similar }
        }
    }

    /// 各类别统计
    var exactGroupsCount: Int {
        groups.filter { $0.matchKind == .exact }.count
    }

    var similarGroupsCount: Int {
        groups.filter { $0.matchKind == .similar }.count
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

    /// 启动重复文件扫描
    func startScan() {
        guard !isScanning else { return }
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
                progress: { fraction, msg in
                    DispatchQueue.main.async {
                        self?.progressFraction = fraction
                        self?.scanProgressMessage = msg
                    }
                }
            )

            DispatchQueue.main.async {
                self?.groups = resultGroups
                self?.isScanning = false
                self?.progressFraction = 1.0
                let totalFiles = resultGroups.reduce(0) { $0 + $1.items.count }
                self?.scanProgressMessage = "扫描完成，发现 \(resultGroups.count) 组重复文件（共 \(totalFiles) 个副本）"
            }
        }
    }

    /// 智能自动勾选重复项（每组默认保留 1 个原始副本，其余自动勾选以便清理）
    func autoSelectDuplicates() {
        for gIndex in groups.indices {
            for iIndex in groups[gIndex].items.indices {
                // 若是推荐保留的原始项，则不勾选；其余副本默认勾选
                groups[gIndex].items[iIndex].isSelected = !groups[gIndex].items[iIndex].isOriginal
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
                        risk: .review,
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

    /// 在指定根目录集合中查找重复文件
    static func scanDuplicates(
        in directories: [String],
        minSize: Int64,
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
                let path = fileURL.path
                // 白名单过滤（路径与文件扩展名排除）
                if whitelist.isWhitelisted(path: path) || whitelist.isExtensionWhitelisted(path: path) { continue }

                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      Int64(size) >= minSize else { continue }

                let sz = Int64(size)
                sizeMap[sz, default: []].append(path)
                allCandidates.append((path: path, size: sz))
                candidateFiles += 1
            }
        }

        var resultGroups: [DuplicateGroup] = []
        var exactMatchedPaths: Set<String> = []

        // 第二阶段：精确分块哈希校验（首 8KB 预检 + 全量 SHA-256 确认）
        let potentialDuplicateSets = sizeMap.filter { $0.value.count >= 2 }
        let totalSets = max(1, potentialDuplicateSets.count)
        var processedSets = 0

        for (size, paths) in potentialDuplicateSets {
            processedSets += 1
            let frac = 0.1 + (Double(processedSets) / Double(totalSets)) * 0.5
            progress(frac, "正在比对特征 (\(processedSets)/\(totalSets))…")

            // 1. 头 8KB 快速比对
            var partialMap: [String: [String]] = [:]
            for p in paths {
                if let headerHash = calculatePartialHash(at: p, length: 8192) {
                    partialMap[headerHash, default: []].append(p)
                }
            }

            // 2. 头部相同的项进行全量 SHA-256 哈希
            for (_, sameHeaderPaths) in partialMap where sameHeaderPaths.count >= 2 {
                var fullHashMap: [String: [DuplicateFileItem]] = [:]
                for p in sameHeaderPaths {
                    guard let fullHash = calculateFullSHA256(at: p) else { continue }
                    let mtime = FileSystem.modificationDate(p)
                    let name = (p as NSString).lastPathComponent
                    let item = DuplicateFileItem(path: p, name: name, size: size, modificationDate: mtime)
                    fullHashMap[fullHash, default: []].append(item)
                }

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
                        modificationDate: mtime
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

    /// 计算文件全量 SHA-256
    static func calculateFullSHA256(at path: String) -> String? {
        guard let stream = InputStream(fileAtPath: path) else { return nil }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 { return nil }
            if read == 0 { break }
            hasher.update(data: Data(bytes: buffer, count: read))
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }
}
