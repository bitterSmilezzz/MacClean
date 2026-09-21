import Foundation

// MARK: - 终端与命令行开发缓存治理扫描引擎 (v1.65.0 · v1.73.0 安全加固)
//
// 本轮修掉三个真机可复现的破坏：
//
// ① **`~/.npm` 被整体清空**。旧 `typicalPaths` 是 `["~/.npm/_cacache", "~/.npm"]`，
//    本机 `~/.npm` 下确实没有 `_cacache`（只有 `_logs`、`_npx`、`_prebuilds` 与安装期状态），
//    于是落到兜底根，`clean` 再把它的**全部子项逐个删掉**——那不是缓存，是工具的家。
//    现在兜底根删掉了，只认精确缓存子路径；扫不到就在总结里报"该工具缓存位置未识别"。
//
// ② **`protectedKeywords` 校验对象错位**。旧实现只拿父目录 `path` 去比关键词，
//    而真正被删的是 `childPath`——`.npmrc`、`config.toml` 这类文件从没被校验过。
//    现在校验对象改成 childPath。
//
// ③ **删除绕开护栏 + 自计体积**。现在全部走 `ResidueDeletionGate`：
//    软链跳板、G6/G8、用户白名单、真实 unlink 权限由网关裁决，释放量在删除前实测。

public final class CLICacheScanner {
    public static let shared = CLICacheScanner()

    private init() {}

    /// 危险系统与关键用户文件黑名单（绝不允许清理）
    ///
    /// 注意：校验对象是**真正要删的那条 childPath**，不是父缓存根。
    static let protectedKeywords: [String] = [
        ".npmrc",
        ".zshrc",
        ".bashrc",
        ".bash_profile",
        "config.toml",
        "settings.json",
        ".gitconfig",
        "/System",
        "/Applications",
        "/usr",
        "/bin",
        "/sbin"
    ]

    /// 工具"数据根"目录名：这些点号目录里混有配置与状态，**绝不能**当成缓存根清空。
    static let toolDataRootNames: Set<String> = [
        ".npm", ".cargo", ".gradle", ".yarn", ".pnpm", ".m2", ".ssh", ".gnupg",
        ".config", ".local", ".cache", ".aws", ".docker", ".vscode", ".zsh_sessions"
    ]

    /// 扫描所有或指定的命令行缓存目录
    public func scan(customPaths: [CLIToolKind: [String]]? = nil) -> CLICacheSummary {
        let fm = FileManager.default
        var items: [CLICacheItem] = []
        var totalSize: Int64 = 0
        var unrecognized: [CLIToolKind] = []

        let toolsToScan = customPaths != nil ? Array(customPaths!.keys) : CLIToolKind.allCases

        for tool in toolsToScan {
            let custom = customPaths?[tool]
            let pathsToScan = custom ?? tool.typicalPaths.map { NSString(string: $0).expandingTildeInPath }
            var matched = false

            for rawPath in pathsToScan {
                let path = FileSystem.normalizePath(rawPath)

                // 兜底防线：命中工具数据根就**什么都不做**（旧版在这里删掉了整个 ~/.npm）
                if Self.isToolDataRoot(path) { continue }
                // 主目录本身、系统关键位置一律不扫（不再用 hasPrefix("/System") 字符串护栏）
                if path == FileSystem.normalizePath(NSHomeDirectory()) { continue }
                if FileSystem.isSystemProtected(path) { continue }
                // 内置路径还必须是"精确缓存子路径"；调用方显式给定的 customPaths 只受数据根与
                // 网关护栏约束（自检 fixture 就靠这条走得通）
                if custom == nil && !Self.isPreciseCachePath(path) { continue }

                guard fm.fileExists(atPath: path) else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                // 软链不作为缓存根：删它不释放空间，还会把治理带到别处
                if FileSystem.isSymlink(path) { continue }

                let (size, count) = Self.calculateDirectoryStats(at: path)
                if size > 0 && count > 0 {
                    items.append(CLICacheItem(
                        id: path,
                        toolKind: tool,
                        title: "\(tool.rawValue)",
                        path: path,
                        size: size,
                        fileCount: count,
                        isSelected: true
                    ))
                    totalSize += size
                    matched = true
                    // 每个工具只要命中了一个主有效缓存目录即可（避免子目录重复累加）
                    break
                }
                matched = true
            }

            if !matched { unrecognized.append(tool) }
        }

        let sorted = items.sorted { $0.size > $1.size }

        return CLICacheSummary(
            items: sorted,
            totalSize: totalSize,
            toolCount: sorted.count,
            unrecognizedTools: unrecognized
        )
    }

    // MARK: - 路径判据

    /// 该路径本身是否就是某个工具的数据根（如 `~/.npm`、`~/.cargo`）。
    static func isToolDataRoot(_ path: String) -> Bool {
        let normalized = FileSystem.normalizePath(path)
        let leaf = (normalized as NSString).lastPathComponent
        return toolDataRootNames.contains(leaf)
    }

    /// 是否为"精确缓存子路径"：位于 `.../Caches/<Name>` 之下，或在某个点号工具目录**之内**。
    static func isPreciseCachePath(_ path: String) -> Bool {
        let normalized = FileSystem.normalizePath(path)
        if isToolDataRoot(normalized) { return false }
        let leaf = (normalized as NSString).lastPathComponent
        // 点号目录本身不是缓存；空路径不是
        if leaf.isEmpty || leaf.hasPrefix(".") { return false }
        let parent = FileSystem.normalizePath((normalized as NSString).deletingLastPathComponent)
        if (parent as NSString).lastPathComponent == "Caches" { return true }
        for tool in CLIToolKind.allCases {
            for root in tool.toolDataRoots {
                let expanded = FileSystem.normalizePath(NSString(string: root).expandingTildeInPath)
                if normalized.hasPrefix(expanded + "/") { return true }
            }
        }
        return false
    }

    /// 命中的保护关键词（校验对象是**真正要删的路径**）
    static func protectedKeywordHit(in path: String) -> String? {
        let normalized = FileSystem.normalizePath(path)
        return protectedKeywords.first { normalized.contains($0) }
    }

    // MARK: - 删除（全部走统一网关）

    /// 安全清空选中的 CLI 缓存目录子项。
    ///
    /// - 缓存根**永不删除**，只清内部子项（保持工具的目录结构假设）
    /// - 工具数据根（`~/.npm` 等）直接整项拒绝，绝不退化成"删它下面的所有东西"
    /// - 每个子项单独过网关：`protectedKeywords` 现在按 childPath 校验
    /// - 释放量来自删除前实测，不再自计 `item.size`
    @discardableResult
    func clean(
        items: [CLICacheItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "命令行缓存治理")
    ) -> ResidueDeletionGate.Outcome {
        var outcome = ResidueDeletionGate.Outcome()
        guard !items.isEmpty else { return outcome }

        let fm = FileManager.default
        var candidates: [ResidueDeletionGate.Candidate] = []
        var governedRoots = Set<String>()

        for item in items {
            let root = FileSystem.normalizePath(item.path)

            // ① 工具数据根：整项拒绝（这就是 ~/.npm 被清空的那条路径）
            if Self.isToolDataRoot(root) {
                outcome.rejected.append(.init(name: item.title, path: item.path, reason: .hardExcluded,
                                              message: "这是工具的数据目录（含配置与状态），不是缓存根，拒绝清空"))
                continue
            }
            guard Self.isAllowedCacheRoot(root) else {
                outcome.rejected.append(.init(name: item.title, path: item.path, reason: .outsideDomain,
                                              message: "该路径不是可识别的精确缓存子目录，拒绝清空"))
                continue
            }
            guard let contents = try? fm.contentsOfDirectory(atPath: root) else {
                outcome.rejected.append(.init(name: item.title, path: item.path, reason: .missing,
                                              message: "缓存目录无法枚举或已不存在，按未清理处理"))
                continue
            }
            governedRoots.insert(root)
            for child in contents.sorted() {
                let childPath = (root as NSString).appendingPathComponent(child)
                candidates.append(.init(child, path: childPath,
                                        domain: Self.governanceDomain(forPath: childPath)))
            }
        }

        let rootsSnapshot = governedRoots
        let merged = ResidueDeletionGate.execute(
            candidates, toTrash: toTrash, journal: journal) { candidate in
            // ② 只允许删"已登记缓存根的直接子项"，且逐条按 childPath 校验保护清单
            let child = FileSystem.normalizePath(candidate.path)
            let parent = FileSystem.normalizePath((child as NSString).deletingLastPathComponent)
            guard rootsSnapshot.contains(parent) else { return .outsideDomain }
            if Self.isToolDataRoot(child) { return .hardExcluded }
            if Self.protectedKeywordHit(in: child) != nil { return .hardExcluded }
            return nil
        }
        merge(merged, into: &outcome)
        return outcome
    }

    /// 缓存根是否落在本模块被授权的范围内：用户主目录、`~/Library/Caches` 或临时目录之下。
    static func isAllowedCacheRoot(_ path: String) -> Bool {
        let normalized = FileSystem.normalizePath(path)
        if isToolDataRoot(normalized) { return false }
        let home = FileSystem.normalizePath(NSHomeDirectory())
        if normalized.hasPrefix(home + "/") { return true }
        for tmp in ["/tmp", "/var/tmp"] {
            if normalized.hasPrefix(FileSystem.normalizePath(tmp) + "/") { return true }
        }
        return false
    }

    /// 全局缓存位置（如 `/Library/Caches`）需要显式声明治理域；本模块目前只治理主目录与临时目录。
    static func governanceDomain(forPath path: String) -> GovernanceDomain? {
        let normalized = FileSystem.normalizePath(path)
        let root = GovernanceDomain.systemCachesGlobal.normalizedRoot
        if normalized.hasPrefix(root + "/") { return .systemCachesGlobal }
        return nil
    }

    private func merge(_ src: ResidueDeletionGate.Outcome, into dst: inout ResidueDeletionGate.Outcome) {
        dst.cleanedCount += src.cleanedCount
        dst.freedBytes += src.freedBytes
        dst.cleanedPaths.append(contentsOf: src.cleanedPaths)
        dst.rejected.append(contentsOf: src.rejected)
        dst.failed.append(contentsOf: src.failed)
        dst.trashedSnapshots.append(contentsOf: src.trashedSnapshots)
    }

    /// 统计目录内文件大小与文件数
    public static func calculateDirectoryStats(at path: String) -> (size: Int64, fileCount: Int) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }

        var totalSize: Int64 = 0
        var count = 0

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey, .isDirectoryKey]) else {
                continue
            }
            if values.isDirectory == true {
                continue
            }
            let s = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            totalSize += s
            count += 1
        }

        return (totalSize, count)
    }
}
