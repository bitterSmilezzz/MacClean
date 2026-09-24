import Foundation
import AppKit

// MARK: - Spotlight 废弃索引与搜索数据库深度重建治理引擎 (v1.69.0 / v1.73.0 加固)
//
// v1.73.0 修掉的三个真实故障：
// ① `mdutil` 走裸 `Process`：`waitUntilExit()` 之后才读管道 —— 子进程输出超过
//    约 64 KB 管道缓冲就会阻塞在 write，父进程阻塞在 wait，双向死锁；且无超时。
// ② 更危险的是**判据**：只要 `try? process.run()` 不抛异常就报"已成功重建"，
//    而 `mdutil -E` 对无权访问的卷返回非 0 退出码 —— 失败被读成了成功。
// ③ 卷宗/索引目录（真机 `/Volumes/*/.Spotlight-V100` 多为 root 所有）读不到时，
//    `try?` 得到 0 字节，条目被丢弃或显示"正常"，用户读到的是"一切干净"。
//
// 现在：命令一律走 `SafeProcess`（先排空管道 + 超时 + 真实退出码），
// 判据一律在证据不足时**降级为"需确认"**，删除一律过 `ResidueDeletionGate`。

public final class SpotlightScanner {
    public static let shared = SpotlightScanner()

    private init() {}

    /// Spotlight 索引重建工具路径（自检通过 `SafeProcess.runner` 拦截，绝不真跑）
    public static let mdutilPath = "/usr/bin/mdutil"

    /// Apple 官方核心服务 Bundle ID 前缀白名单（受保护）
    public static let appleCorePrefixes: Set<String> = [
        "com.apple.",
        "apple.",
        "system."
    ]

    /// 本机可发现的卷根：启动卷 + `/Volumes` 下的真实目录（跳过软链）。
    ///
    /// 只列目录、**不调用 `diskutil`/`mount`**：扫描阶段不该起子进程。
    public static func discoverVolumeRoots(fm: FileManager = .default) -> [String] {
        var roots = ["/"]
        guard let entries = try? fm.contentsOfDirectory(atPath: "/Volumes") else { return roots }
        for entry in entries.sorted() {
            let full = ("/Volumes" as NSString).appendingPathComponent(entry)
            if FileSystem.isSymlink(full) { continue }   // 软链会跳出 /Volumes 授权域
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            roots.append(full)
        }
        return roots
    }

    // MARK: - 扫描

    /// 扫描指定目录或系统默认 Spotlight 存储库。
    ///
    /// 注意返回值里的 `issues`：只要非空，`isResultComplete` 即为 false，
    /// 调用方（卡片）必须显示"结果不完整"，**不得**把 0 项渲染成"没有残留"。
    func scan(
        customCoreSpotlightDir: String? = nil,
        customCacheDir: String? = nil,
        customVolumeDirs: [String]? = nil,
        inventory: AppInventory.Snapshot? = nil
    ) -> SpotlightSummary {
        let fm = FileManager.default
        let snapshot = inventory ?? AppInventory.current()

        var items: [SpotlightStoreItem] = []
        var issues: [GovernanceEvidenceIssue] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0
        var needsConfirmationCount = 0

        func countNeedConfirm(_ status: SpotlightIndexStatus) {
            if status == .needsConfirmation { needsConfirmationCount += 1 }
        }

        // 1. 扫描 CoreSpotlight 用户索引 (~/Library/Metadata/CoreSpotlight)
        let coreSpotlightPath = customCoreSpotlightDir
            ?? NSString(string: "~/Library/Metadata/CoreSpotlight").expandingTildeInPath
        if FileManager.default.fileExists(atPath: coreSpotlightPath) {
            do {
                let subdirs = try fm.contentsOfDirectory(atPath: coreSpotlightPath)
                for sub in subdirs {
                    guard !sub.hasPrefix(".") else { continue }
                    let subPath = (coreSpotlightPath as NSString).appendingPathComponent(sub)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: subPath, isDirectory: &isDir) else { continue }

                    let (dirSize, fileCount, mtime) = calculateDirectoryMetrics(at: subPath)
                    guard dirSize > 0 || fileCount > 0 else { continue }

                    let (kind, status) = Self.evaluateCoreSpotlightEntry(
                        name: sub, path: subPath, inventory: snapshot)
                    countNeedConfirm(status)

                    let isOrphan = status.isOrphanOrCorrupted
                    if isOrphan {
                        orphanCount += 1
                        orphanSize += dirSize
                    } else if status == .activeHealthy {
                        activeCount += 1
                    }

                    let item = SpotlightStoreItem(
                        id: subPath,
                        name: sub,
                        path: subPath,
                        kind: kind,
                        status: status,
                        size: dirSize,
                        fileCount: fileCount,
                        modificationDate: mtime,
                        isSelected: isOrphan
                    )
                    items.append(item)
                    totalSize += dirSize
                }
            } catch {
                // 「读不到」≠「没有残留」，也 ≠「一切正常」
                issues.append(Self.readIssue(for: coreSpotlightPath))
            }
        }

        // 2. 扫描 Spotlight 用户搜索缓存 (~/Library/Caches/com.apple.Spotlight)
        let cachePath = customCacheDir
            ?? NSString(string: "~/Library/Caches/com.apple.Spotlight").expandingTildeInPath
        if fm.fileExists(atPath: cachePath) {
            if FileSystem.isPermissionDenied(cachePath) {
                issues.append(Self.readIssue(for: cachePath))
            } else {
                let (cacheSize, fileCount, mtime) = calculateDirectoryMetrics(at: cachePath)
                if cacheSize > 0 {
                    orphanCount += 1
                    orphanSize += cacheSize

                    let cacheItem = SpotlightStoreItem(
                        id: cachePath,
                        name: "com.apple.Spotlight (搜索临时缓存)",
                        path: cachePath,
                        kind: .spotlightCache,
                        status: .bloatedOrCorrupted,
                        size: cacheSize,
                        fileCount: fileCount,
                        modificationDate: mtime,
                        isSelected: true
                    )
                    items.append(cacheItem)
                    totalSize += cacheSize
                }
            }
        }

        // 3. 扫描磁盘卷根索引库 (.Spotlight-V100)
        let volumeRoots = customVolumeDirs ?? Self.discoverVolumeRoots(fm: fm)
        for volRoot in volumeRoots {
            let spotlightV100 = (volRoot as NSString).appendingPathComponent(".Spotlight-V100")
            guard fm.fileExists(atPath: spotlightV100) else { continue }
            let isSystemRoot = volRoot == "/"

            // 真机实测：卷宗与其索引目录多为 root 所有，普通进程 `contentsOfDirectory`
            // 直接 EACCES。此时**不能**按"体积 0、没有东西"处理。
            if FileSystem.isPermissionDenied(spotlightV100) {
                let issue = GovernanceEvidenceIssue(
                    kind: .permissionDenied, subject: spotlightV100,
                    message: "卷宗索引目录由 root 管理，当前用户不可读：\(spotlightV100)")
                issues.append(issue)
                needsConfirmationCount += 1
                items.append(SpotlightStoreItem(
                    id: spotlightV100,
                    name: isSystemRoot ? "系统根卷 Spotlight 索引库 (/)" : "卷索引库 (\(volRoot))",
                    path: spotlightV100,
                    kind: .volumeIndex,
                    status: .needsConfirmation,
                    size: 0, fileCount: 0,
                    modificationDate: FileSystem.modificationDate(spotlightV100) ?? .distantPast,
                    isSelected: false,
                    note: issue.message))
                continue
            }

            let (volSize, fileCount, mtime) = calculateDirectoryMetrics(at: spotlightV100)
            // 卷索引**永不**按文件删除来"清理"：唯一受支持的手段是用户显式勾选后
            // 执行 `mdutil -E <卷>`。因此状态一律非可删，也不计入 activeCount。
            let status: SpotlightIndexStatus = isSystemRoot ? .systemProtected : .needsConfirmation
            if status == .needsConfirmation { needsConfirmationCount += 1 }

            let volItem = SpotlightStoreItem(
                id: spotlightV100,
                name: isSystemRoot ? "系统根卷 Spotlight 索引库 (/)" : "卷索引库 (\(volRoot))",
                path: spotlightV100,
                kind: .volumeIndex,
                status: status,
                size: volSize,
                fileCount: fileCount,
                modificationDate: mtime,
                isSelected: false,
                isSelectedForRebuild: false,
                note: isSystemRoot ? "启动卷索引：仅在你显式勾选后才会执行 mdutil -E"
                                   : "外接/其他卷索引：仅在你显式勾选后才会执行 mdutil -E")
            items.append(volItem)
            totalSize += volSize
        }

        // 优先将可清理的孤儿/损坏项排在前面
        let sorted = items.sorted { a, b in
            if a.status.isOrphanOrCorrupted != b.status.isOrphanOrCorrupted {
                return a.status.isOrphanOrCorrupted
            }
            return a.size > b.size
        }

        return SpotlightSummary(
            items: sorted,
            totalSize: totalSize,
            orphanCount: orphanCount,
            orphanSize: orphanSize,
            activeCount: activeCount,
            issues: issues,
            needsConfirmationCount: needsConfirmationCount
        )
    }

    /// 把一个"读不到"的路径翻译成用户能看懂的问题记录。
    static func readIssue(for path: String) -> GovernanceEvidenceIssue {
        FileSystem.isPermissionDenied(path)
            ? GovernanceEvidenceIssue(kind: .permissionDenied, subject: path,
                                       message: "权限不足，该目录当前用户不可读：\(path)")
            : GovernanceEvidenceIssue(kind: .unreadable, subject: path,
                                      message: "读取失败：\(path)")
    }

    /// 评估 CoreSpotlight 子项的状态与归属（清单不完整时降级为"需确认"）。
    /// internal：`AppInventory.Snapshot` 是内部类型，不能出现在 public 签名上。
    static func evaluateCoreSpotlightEntry(
        name: String,
        path: String,
        inventory: AppInventory.Snapshot
    ) -> (kind: SpotlightStoreKind, status: SpotlightIndexStatus) {
        let lower = name.lowercased()

        // 1. 系统核心服务前缀保护
        for prefix in appleCorePrefixes where lower.hasPrefix(prefix) {
            return (.coreSpotlightIndex, .activeHealthy)
        }

        // 2. 命中已安装应用（含正在运行的 App）
        if inventory.contains(bundleID: lower) {
            return (.coreSpotlightIndex, .activeHealthy)
        }

        // 3. 清单本身不可信（有根目录读不到，或一台机器不可能一个 App 都没装）
        //    → 绝不能据"不在清单里"判孤儿。
        guard inventory.isComplete else {
            return (.coreSpotlightIndex, .needsConfirmation)
        }

        // 4. 清单完整且确实不匹配 → 已卸载应用的残留
        return (.coreSpotlightIndex, .orphanAppResidue)
    }

    /// 兼容旧调用方的集合版判据。
    ///
    /// 该入口无法表达"清单不完整"，因此调用方必须自己保证 `installedBIDs` 可信；
    /// 扫描链路请改用 `evaluateCoreSpotlightEntry(name:path:inventory:)`。
    public static func evaluateCoreSpotlightEntry(
        name: String,
        path: String,
        installedBIDs: Set<String>
    ) -> (kind: SpotlightStoreKind, status: SpotlightIndexStatus) {
        let lower = name.lowercased()

        // 1. 系统核心服务前缀保护
        for prefix in appleCorePrefixes {
            if lower.hasPrefix(prefix) {
                return (.coreSpotlightIndex, .activeHealthy)
            }
        }

        // 2. 匹配当前已安装应用 Bundle ID
        if installedBIDs.contains(lower) {
            return (.coreSpotlightIndex, .activeHealthy)
        }

        // 3. 未安装的第三方应用残留
        return (.coreSpotlightIndex, .orphanAppResidue)
    }

    // MARK: - 清理

    /// 待删候选（供卡片展示网关拒绝原因）。
    static func candidates(for items: [SpotlightStoreItem]) -> [ResidueDeletionGate.Candidate] {
        items.map { ResidueDeletionGate.Candidate($0.name, path: $0.path, domain: $0.governanceDomain) }
    }

    /// 清理选中的 Spotlight 孤儿索引与缓存。
    ///
    /// 全部删除动作交给 `ResidueDeletionGate`：软链防跳板 + G8 + G6 + 用户白名单
    /// + 治理域 + 真实 unlink 权限 + 删除前实测体积 + 撤销快照与历史记录。
    /// 扫描时缓存的 `item.size` 只做展示，**不再参与记账**。
    func clean(
        items: [SpotlightStoreItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "Spotlight 索引残留")
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let outcome = cleanOutcome(items: items, toTrash: toTrash, journal: journal)
        return (outcome.cleanedCount, outcome.freedBytes, outcome.errorCount)
    }

    /// 同上，但返回逐项拒绝原因，卡片要如实展示而不是笼统一句"清理失败"。
    @discardableResult
    func cleanOutcome(
        items: [SpotlightStoreItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "Spotlight 索引残留")
    ) -> ResidueDeletionGate.Outcome {
        var byPath: [String: SpotlightStoreItem] = [:]
        for item in items { byPath[item.path] = item }

        return ResidueDeletionGate.execute(
            Self.candidates(for: items),
            toTrash: toTrash,
            journal: journal,
            policy: { candidate in
                guard let item = byPath[candidate.path] else {
                    return .make(candidate, reason: .notDeletable, message: "该路径不在本轮选定清单里，未删除")
                }
                // ① 文件系统根与启动卷索引：绝对拦截
                if item.path == "/" || item.path == "/.Spotlight-V100" {
                    return .make(candidate, reason: .resolvesToRoot,
                                 message: "目标是文件系统根/启动卷索引本身，绝不清理")
                }
                // ② 状态门槛：只删确证的孤儿/损坏项
                switch item.status {
                case .systemProtected:
                    return .make(candidate, reason: .systemProtected,
                                 message: "系统索引组件，绝不清理")
                case .activeHealthy, .needsConfirmation:
                    return .make(candidate, reason: .notDeletable,
                                 message: "研判结论为「\(item.status.rawValue)」，不是确证的孤儿/损坏，未删除")
                case .orphanAppResidue, .bloatedOrCorrupted:
                    break
                }
                // ③ 卷索引只能靠 mdutil 重建，永不按文件删除
                if item.kind == .volumeIndex {
                    return .make(candidate, reason: .notDeletable,
                                 message: "外接卷索引请用「重建索引」，不按文件删除")
                }
                return nil
            })
    }

    // MARK: - 索引重建

    /// 调用系统标准 mdutil 工具擦除并重建指定卷的 Spotlight 索引。
    ///
    /// - Returns: `success` **只**在 `mdutil` 真实退出码为 0 且未超时时为 true；
    ///   命令不存在、启动失败、非 0 退出、超时四种情况全部报失败并说明原因。
    public func rebuildVolumeIndex(volumePath: String = "/",
                                   timeout: TimeInterval = 60) -> (success: Bool, message: String) {
        guard SafeProcess.isAvailable(Self.mdutilPath) else {
            return (false, "本机找不到 \(Self.mdutilPath)，未执行任何索引重建，现有搜索数据库未受影响。")
        }
        guard !volumePath.isEmpty else {
            return (false, "卷路径为空，已拒绝执行 mdutil -E。")
        }

        guard let result = SafeProcess.run(Self.mdutilPath, ["-E", volumePath], timeout: timeout) else {
            return (false, "mdutil 未能启动，未执行索引重建。")
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.timedOut {
            return (false, "mdutil -E \(volumePath) 超时（\(Int(timeout)) 秒）未返回，"
                         + "索引重建状态未知，请勿重复触发；可用 mdutil -s \(volumePath) 复查。")
        }
        if result.exitCode != 0 {
            return (false, "索引重建未成功（mdutil 退出码 \(result.exitCode)）：\(output.isEmpty ? "无输出" : output)"
                         + "。常见原因是该卷由 root 管理或需要管理员授权——MacClean 不做提权。")
        }
        return (true, "已向系统发送 Spotlight 索引重建指令（\(volumePath)）："
                    + (output.isEmpty ? "mdutil 返回 0" : output))
    }

    // MARK: - 辅助：递归统计目录指标
    private func calculateDirectoryMetrics(at path: String) -> (size: Int64, fileCount: Int, modificationDate: Date) {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        var fileCount = 0
        var latestMTime = Date.distantPast

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                // 被权限挡掉的子目录必须留痕。不写 errorHandler 时 Foundation 的语义是
                // **第一个错误就停止遍历且不报告**——于是「只读到一半」和「就这么大」给出
                // 同一个数，而这个偏小的值会被一路当权威体积用。
                FileSystem.recordDeniedAccess(url, error: error)
                return true
            }
        ) else {
            return (0, 0, latestMTime)
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
                continue
            }

            if values.isDirectory == false {
                totalSize += Int64(values.fileSize ?? 0)
                fileCount += 1
            }
            if let mtime = values.contentModificationDate, mtime > latestMTime {
                latestMTime = mtime
            }
        }

        return (totalSize, fileCount, latestMTime)
    }
}
