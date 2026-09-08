import Foundation
import CryptoKit
import Combine

/// 重复文件组
struct DuplicateGroup: Identifiable, Equatable {
    let id: UUID = UUID()
    let hash: String
    let fileSize: Int64
    var items: [DuplicateFileItem]

    /// 浪费的空间（除保留一个副本外，其余多余副本的总体积）
    var wastedBytes: Int64 {
        guard items.count > 1 else { return 0 }
        return fileSize * Int64(items.count - 1)
    }

    /// 选中的待清理体积
    var selectedBytes: Int64 {
        let count = items.filter(\.isSelected).count
        return fileSize * Int64(count)
    }
}

/// 单个重复副本条目
struct DuplicateFileItem: Identifiable, Equatable {
    let id: UUID = UUID()
    let path: String
    let name: String
    let size: Int64
    let modificationDate: Date?
    var isSelected: Bool = false
    var isOriginal: Bool = false  // 推荐保留的原始文件（如修改时间最早或路径最短者）
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

        // 第一阶段：按文件大小快速归类
        var sizeMap: [Int64: [String]] = [:]
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
                // 白名单过滤
                if whitelist.isWhitelisted(path: path) { continue }

                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      let size = values.fileSize,
                      Int64(size) >= minSize else { continue }

                let sz = Int64(size)
                sizeMap[sz, default: []].append(path)
                candidateFiles += 1
            }
        }

        // 仅保留文件大小相同且个数 >= 2 的候选池
        let potentialDuplicateSets = sizeMap.filter { $0.value.count >= 2 }
        if potentialDuplicateSets.isEmpty {
            progress(1.0, "未发现重复大小的文件")
            return []
        }

        let totalSets = potentialDuplicateSets.count
        var processedSets = 0

        // 第二阶段：分块哈希校验（首 8KB 预检 + 全量 SHA-256 确认）
        var duplicatesByHash: [String: [DuplicateFileItem]] = [:]

        for (size, paths) in potentialDuplicateSets {
            processedSets += 1
            let frac = 0.1 + (Double(processedSets) / Double(totalSets)) * 0.85
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
                    }
                    duplicatesByHash[h] = sortedItems
                }
            }
        }

        // 构造最终结果组，按浪费空间从大到小排序
        let groups = duplicatesByHash.map { (hash, items) -> DuplicateGroup in
            let sz = items.first?.size ?? 0
            return DuplicateGroup(hash: hash, fileSize: sz, items: items)
        }.sorted { $0.wastedBytes > $1.wastedBytes }

        return groups
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
