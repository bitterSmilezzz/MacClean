import Foundation
import AppKit

// MARK: - 剪贴板历史与大文件临时缓冲区治理引擎 (v1.63.0 / v1.72.0 安全加固)
//
// v1.72.0 修掉的三个真实故障：
// ① **静默清空 `…/TemporaryItems`**：旧实现只要路径以 `TemporaryItems` 结尾，就把该目录
//    的**全部子项** `try? removeItem` 掉——那里混着 Office/文本编辑器的**自动恢复草稿**、
//    预览与拖拽溢出的原件。`try?` 还把失败吞成"什么都没发生"，最后照抄扫描缓存的
//    `item.size` 记账，报出一个既没删也没测的"释放量"。
//    现在：逐子项判定 —— 归属不可识别的不删、年龄不够的不删、正被剪贴板引用的不删，
//    并且每个子项都过统一删除网关（G8/G6/白名单/软链/权限），结果如实计数。
// ② **无"正在使用"判据**：现在读取当前剪贴板里的 file-url 载荷与其父目录，
//    命中即拒绝（`~/Library/TemporaryItems` 里被引用的那个文件绝不能删）。
// ③ **谎报清空剪贴板**：`clearPasteboard()` 原先无条件 `return true`。
//    现在以 `clearContents()` 返回值 + `changeCount` 是否真的前进作为证据。

public final class ClipboardPurger {
    public static let shared = ClipboardPurger()

    private init() {}

    // MARK: 治理判据常量

    /// 可归属为"剪贴板 / 拖拽溢出"的名称标记（小写包含匹配）。
    /// **识别不出归属的项一律不删**——这是 `TemporaryItems` 敢自动清理的唯一前提。
    static let ownershipTokens = ["pasteboard", "pboard", "clipboard", "cliptemp"]

    /// `…/TemporaryItems` 子项的最低年龄门槛。
    /// 该位置混有正在编辑文档的自动恢复草稿（应用会持续回写），
    /// 因此只有**足够陈旧**（7 天未被写过）的项才可能被处理。
    static let temporaryItemsMinAge: TimeInterval = 7 * 86400

    /// `$TMPDIR` 内剪贴板溢出文件的最低年龄门槛（1 小时）。
    /// 刚写下的溢出文件很可能正是当前剪贴板的大对象载荷。
    static let tempDirMinAge: TimeInterval = 3600

    /// 清理历史类名
    static let historyCategory = "剪贴板临时缓冲"

    /// 已登记的剪贴板溢出目录（两个都可能存在，取决于 macOS 版本与应用）。
    /// **只有登记过的目录**才允许被"整目录展开成子项候选"——否则一条伪造的
    /// 目录条目就能把任意目录里的东西送进删除队列（旧版的静默清空就是这么发生的）。
    public static var temporaryItemsDirs: [String] {
        Self.knownTemporaryItemsDirs + extraTemporaryItemsDirs
    }

    static var knownTemporaryItemsDirs: [String] {
        ["~/Library/Caches/TemporaryItems", "~/Library/TemporaryItems"].map {
            ($0 as NSString).expandingTildeInPath
        }
    }

    /// 自检注入点：fixture 里的 TemporaryItems 目录（生产路径永远为空）。
    static var extraTemporaryItemsDirs: [String] = []

    /// 名称归属识别（大小写不敏感）
    public static func hasClipboardOwnership(_ path: String) -> Bool {
        let name = ((path as NSString).lastPathComponent).lowercased()
        return ownershipTokens.contains { name.contains($0) }
    }

    // MARK: - 当前剪贴板引用

    /// 当前剪贴板的文件引用快照。
    ///
    /// `readable == false` 表示"剪贴板里确实有 file-url 载荷，但本工具没能把它解出来"——
    /// 这是**读不到**，不是"没有引用"，调用方必须据此放弃删除。
    struct PasteboardReferences: Equatable {
        var paths: Set<String> = []
        var readable: Bool = true

        static let empty = PasteboardReferences()
    }

    /// 读取当前剪贴板里以**文件引用**形式存在的绝对路径（解析到真实位置）。
    static func pasteboardReferencedPaths(pasteboard: NSPasteboard = .general) -> PasteboardReferences {
        let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
        var found = Set<String>()
        var readable = true
        for item in (pasteboard.pasteboardItems ?? []) {
            for type in item.types {
                let raw = type.rawValue
                guard raw == fileURLType || raw.contains("file-url") || raw.contains("fileurl") else { continue }
                guard let data = item.data(forType: type),
                      let text = String(data: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    // 有 file-url 类型却解不出内容 → 归属未知，只能上报"读不到"
                    readable = false
                    continue
                }
                let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let path: String
                if candidate.hasPrefix("file://"), let url = URL(string: candidate) {
                    path = url.path
                } else if candidate.hasPrefix("/") {
                    path = candidate
                } else {
                    continue
                }
                guard !path.isEmpty else { continue }
                found.insert(FileSystem.normalizePath(FileSystem.realPath(path)))
            }
        }
        return PasteboardReferences(paths: found, readable: readable)
    }

    /// 路径是否被当前剪贴板引用（含"父目录被引用 → 其子项同样不可删"，
    /// 以及"引用文件在本路径之下"两种方向）。
    static func isReferencedByPasteboard(_ path: String, _ references: PasteboardReferences) -> Bool {
        guard !references.paths.isEmpty else { return false }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        for target in references.paths where !target.isEmpty {
            if real == target || real.hasPrefix(target + "/") || target.hasPrefix(real + "/") { return true }
        }
        return false
    }

    // MARK: - 探测

    /// 探测当前剪贴板状态与临时缓存
    public func inspect() -> ClipboardReport {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        var summaries: [PasteboardItemSummary] = []
        var totalMem: Int64 = 0
        var hasSensitive = false

        if let types = pb.types {
            for type in types {
                let typeStr = type.rawValue
                let data = pb.data(forType: type)
                let size = Int64(data?.count ?? 0)
                totalMem += size

                let (dataType, isSens, preview) = analyzeData(forType: type, data: data)
                if isSens { hasSensitive = true }

                summaries.append(PasteboardItemSummary(
                    id: typeStr,
                    typeName: typeStr,
                    dataType: dataType,
                    size: size,
                    preview: preview,
                    isLarge: size > 5 * 1024 * 1024,
                    isSensitive: isSens
                ))
            }
        }

        let caches = scanClipboardCaches()
        let totalCache = caches.reduce(0) { $0 + $1.size }

        return ClipboardReport(
            items: summaries,
            cacheItems: caches,
            totalMemorySize: totalMem,
            totalCacheSize: totalCache,
            hasSensitiveData: hasSensitive,
            changeCount: changeCount
        )
    }

    /// 分析数据类型与敏感性
    private func analyzeData(forType type: NSPasteboard.PasteboardType, data: Data?) -> (PasteboardDataType, Bool, String) {
        let typeStr = type.rawValue.lowercased()
        guard let data = data, !data.isEmpty else {
            return (.binary, false, "空数据")
        }

        // 1. 文本分析
        if type == .string || typeStr.contains("text") || typeStr.contains("utf8") {
            if let str = String(data: data, encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSens = checkSensitivity(text: trimmed)
                let preview = isSens ? "•••••••• (已脱敏敏感凭据)" : String(trimmed.prefix(60))
                let kind: PasteboardDataType = isSens ? .sensitiveCredential : .text
                return (kind, isSens, preview)
            }
        }

        // 2. 富文本
        if type == .rtf || typeStr.contains("rtf") {
            return (.rtf, false, "富文本数据 (\(data.count) 字节)")
        }

        // 3. 图像
        if type == .tiff || type == .png || typeStr.contains("image") || typeStr.contains("tiff") || typeStr.contains("png") {
            return (.image, false, "位图图像 (\(Int64(data.count).byteStringCN))")
        }

        // 4. 文件 URL
        if type == .fileURL || typeStr.contains("file-url") {
            if let urlStr = String(data: data, encoding: .utf8) {
                return (.fileURL, false, urlStr)
            }
            return (.fileURL, false, "文件引用对象")
        }

        return (.binary, false, "二进制对象 (\(type.rawValue))")
    }

    /// 校验是否包含敏感凭据
    public func checkSensitivity(text: String) -> Bool {
        for pattern in Self.sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: text.utf16.count)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// 敏感信息正则表达式模式（API Key、Token、私钥等）
    private static let sensitivePatterns: [String] = [
        "sk-[a-zA-Z0-9_\\-]{20,}",              // OpenAI API Key
        "ghp_[a-zA-Z0-9]{36}",                  // GitHub Personal Token
        "AKIA[0-9A-Z]{16}",                     // AWS Access Key
        "bearer\\s+[a-zA-Z0-9_\\-\\.]{20,}",    // Bearer Token
        "-----BEGIN[ A-Z0-9_-]+PRIVATE KEY-----", // Private Key
        "password\\s*[:=]\\s*\\S+",             // Password 文本
        "passwd\\s*[:=]\\s*\\S+"
    ]

    // MARK: - 缓存扫描

    /// 扫描系统剪贴板临时缓存文件。
    ///
    /// 只上报**可识别归属**的项，并给出体积与年龄依据；
    /// `TemporaryItems` 作为目录上报时同时携带 `childCount`，删除阶段再逐子项判定。
    public func scanClipboardCaches(now: Date = Date()) -> [ClipboardCacheItem] {
        var results: [ClipboardCacheItem] = []

        // 1. NSTemporaryDirectory 下的 Pasteboard 相关临时文件
        let fm = FileManager.default
        let tmpDir = NSTemporaryDirectory()
        let entries = (try? fm.contentsOfDirectory(atPath: tmpDir)) ?? []
        if entries.isEmpty && FileSystem.isPermissionDenied(tmpDir) {
            // 读不到就是读不到，不能当成"没有缓存"
            results.append(ClipboardCacheItem(
                id: tmpDir, name: "用户临时目录（无读取权限）", path: tmpDir, size: 0,
                note: "无法读取，未做任何判定", isReadable: false))
        }
        for item in entries where Self.hasClipboardOwnership(item) {
            let path = (tmpDir as NSString).appendingPathComponent(item)
            let size = FileSystem.size(at: path)
            guard size > 0 else { continue }
            results.append(ClipboardCacheItem(
                id: path, name: item, path: path, size: size,
                note: "系统剪贴板临时缓存文件",
                modificationDate: FileSystem.modificationDate(path),
                ageDays: Self.ageDays(of: path, now: now)))
        }

        // 2. TemporaryItems：剪贴板/拖拽溢出与**自动恢复草稿**混住的位置
        for tempItemsDir in Self.temporaryItemsDirs where fm.fileExists(atPath: tempItemsDir) {
            guard let children = try? fm.contentsOfDirectory(atPath: tempItemsDir) else {
                // 读不到 ≠ 没有缓存，也 ≠ 可以整目录处理
                results.append(ClipboardCacheItem(
                    id: tempItemsDir, name: "TemporaryItems（无法读取）", path: tempItemsDir, size: 0,
                    note: "无读取权限，未做任何判定", isReadable: false))
                continue
            }
            var attributableBytes: Int64 = 0
            var attributable = 0
            for child in children where Self.hasClipboardOwnership(child) {
                let childPath = (tempItemsDir as NSString).appendingPathComponent(child)
                guard let age = FileSystem.modificationDate(childPath),
                      now.timeIntervalSince(age) >= Self.temporaryItemsMinAge else { continue }
                attributableBytes += FileSystem.size(at: childPath)
                attributable += 1
            }
            let total = FileSystem.size(at: tempItemsDir)
            guard total > 0 else { continue }
            let staleDays = Int(Self.temporaryItemsMinAge / 86400)
            results.append(ClipboardCacheItem(
                id: tempItemsDir,
                name: "TemporaryItems（剪贴板与拖拽溢出缓存）",
                path: tempItemsDir,
                size: attributableBytes,
                note: "目录总占用 \(total.byteStringCN)，共 \(children.count) 个子项；其中可归属为剪贴板"
                    + "且已闲置满 \(staleDays) 天的 \(attributable) 项（\(attributableBytes.byteStringCN)）"
                    + "才会被处理，其余项（含自动恢复草稿）一律保留",
                modificationDate: FileSystem.modificationDate(tempItemsDir),
                ageDays: Self.ageDays(of: tempItemsDir, now: now),
                childCount: children.count))
        }

        return results
    }

    static func ageDays(of path: String, now: Date = Date()) -> Int {
        guard let mtime = FileSystem.modificationDate(path) else { return 0 }
        return max(0, Int(now.timeIntervalSince(mtime) / 86400))
    }

    // MARK: - 清理

    /// 清空当前系统剪贴板。
    /// - Returns: 真实结果——以 `changeCount` **确实前进**为准；
    ///   没前进时只有"剪贴板本来就没有内容"才算已清空，其余一律算失败。
    @discardableResult
    public func clearPasteboard() -> Bool {
        let pb = NSPasteboard.general
        let before = pb.changeCount
        _ = pb.clearContents()          // 返回被清掉的条目数，不是布尔
        if pb.changeCount > before { return true }
        return pb.types.map(\.isEmpty) ?? true
    }

    /// 安全清理剪贴板临时缓存。
    ///
    /// `TemporaryItems` 这类**目录**条目会展开成逐子项候选，
    /// 每条候选都要过：统一网关（G8/G6/白名单/软链/权限） + 本模块业务判据
    /// （归属可识别、足够陈旧、未被当前剪贴板引用）。
    /// `toTrash` 默认 **true**（G3：默认移入废纸篓）。这里的东西看着像缓存，
    /// 实际混着 Office / 文本编辑器的**自动恢复草稿**——删错了不可恢复，
    /// 所以宁可多占一次废纸篓空间，也不做"看起来更快"的直接彻底删除。
    func cleanClipboardCaches(
        items: [ClipboardCacheItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: ClipboardPurger.historyCategory),
        now: Date = Date(),
        references: ClipboardPurger.PasteboardReferences? = nil
    ) -> ClipboardCleanResult {
        let fm = FileManager.default
        var candidates: [ResidueDeletionGate.Candidate] = []
        var blocked: [ResidueDeletionGate.Rejection] = []
        /// 路径 → 最低年龄门槛
        var minAge: [String: TimeInterval] = [:]

        // 引用源读不到时**绝不降级为"可以删"**：逐条拒绝并如实上报
        let refs = references ?? Self.pasteboardReferencedPaths()

        for item in items {
            let isDirectory = FileSystem.isDir(item.path)
            guard isDirectory else {
                // 单文件条目：必须可识别归属
                if !Self.hasClipboardOwnership(item.path) {
                    blocked.append(Self.rejection(item.name, path: item.path, reason: .outsideDomain,
                                             message: "名称不含剪贴板/拖拽标识，归属无法识别，未删除"))
                    continue
                }
                candidates.append(ResidueDeletionGate.Candidate(item.name, path: item.path))
                minAge[FileSystem.normalizePath(FileSystem.realPath(item.path))] = Self.tempDirMinAge
                continue
            }

            guard let children = try? fm.contentsOfDirectory(atPath: item.path) else {
                let reason: GovernanceVerdict.Reason =
                    FileSystem.isPermissionDenied(item.path) ? .needsPrivilege : .blockedByBaseGate
                blocked.append(Self.rejection(item.name, path: item.path, reason: reason,
                                         message: "无法读取该目录内容，未删除任何文件"))
                continue
            }
            // 只有真正的剪贴板溢出目录才允许整目录展开；
            // 位置认不出来时宁可一个字节都不动，也不能拿"目录条目"当整删的通行证
            let isTemporaryItems = Self.temporaryItemsDirs.contains {
                FileSystem.normalizePath(FileSystem.realPath($0)) ==
                FileSystem.normalizePath(FileSystem.realPath(item.path))
            }
            guard isTemporaryItems else {
                blocked.append(Self.rejection(item.name, path: item.path, reason: .outsideDomain,
                                              message: "不是已登记的剪贴板溢出目录，整目录展开不予处理"))
                continue
            }
            let threshold = Self.temporaryItemsMinAge
            for child in children {
                let childPath = (item.path as NSString).appendingPathComponent(child)
                if !Self.hasClipboardOwnership(childPath) {
                    blocked.append(Self.rejection(child, path: childPath, reason: .outsideDomain,
                                             message: "归属无法识别（可能是正在编辑文档的自动恢复草稿），一律保留"))
                    continue
                }
                candidates.append(ResidueDeletionGate.Candidate(child, path: childPath))
                minAge[FileSystem.normalizePath(FileSystem.realPath(childPath))] = threshold
            }
        }

        var outcome = ResidueDeletionGate.execute(
            candidates, toTrash: toTrash, journal: journal
        ) { candidate in
            let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))

            // ① 引用源读不到 → 保守放弃（"没读到引用" ≠ "没有引用"）
            guard refs.readable else { return .blockedByBaseGate }
            // ② 剪贴板仍指向它 → 绝对不删
            if Self.isReferencedByPasteboard(real, refs) { return .blockedByBaseGate }
            // ③ 归属复判（网关入参可能被上游绕过）
            if !Self.hasClipboardOwnership(real) {
                return .outsideDomain
            }
            // ④ 年龄门槛：mtime 读不到同样视为不可删
            guard let mtime = FileSystem.modificationDate(real) else {
                return .missing
            }
            let threshold = minAge[real] ?? Self.tempDirMinAge
            if now.timeIntervalSince(mtime) < threshold {
                return .blockedByBaseGate
            }
            return nil
        }
        outcome.rejected.append(contentsOf: blocked)

        return ClipboardCleanResult(outcome: outcome, referencesReadable: refs.readable)
    }

    /// 一键清除剪贴板并清理临时缓存。
    ///
    /// 内存侧结论必须来自 `clearPasteboard()` 的真实返回值；失败时**不得**写成"已清空"。
    func purgeAll(
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: ClipboardPurger.historyCategory)
    ) -> (clearedMemory: Bool, memoryFailure: String?, cleanedCacheCount: Int,
          freedCacheBytes: Int64, cacheResult: ClipboardCleanResult) {
        let memOk = clearPasteboard()
        let memoryFailure = memOk ? nil : "系统拒绝清空剪贴板（clearContents 未生效），内容可能仍在剪贴板里"
        let caches = scanClipboardCaches()
        let cacheRes = cleanClipboardCaches(items: caches, toTrash: toTrash, journal: journal)
        return (memOk, memoryFailure, cacheRes.cleanedCount, cacheRes.freedBytes, cacheRes)
    }

    static func rejection(_ name: String, path: String, reason: GovernanceVerdict.Reason,
                          message: String) -> ResidueDeletionGate.Rejection {
        ResidueDeletionGate.Rejection(name: name, path: path, reason: reason, message: message)
    }
}
