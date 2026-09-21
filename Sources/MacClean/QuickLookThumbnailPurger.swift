import Foundation

// MARK: - 访达快速查看（QuickLook）缩略图缓存释放引擎 (v1.66.0 / v1.72.0 安全加固)
//
// v1.72.0 三处修复：
// ① **崩溃形状**：旧实现 `try? p.run()` 之后无条件 `p.waitUntilExit()`。`run()` 抛错时
//    进程根本没起来，在从未 launch 的 `Process` 上 `waitUntilExit()` 会再抛一次异常，
//    而这里没有任何 do/catch —— 直接崩。现在统一走 `SafeProcess`（含超时与管道排空）。
// ② **谎报成功**：旧实现只要 `purge` 跑完就返回成功，卡片文案固定写"已重置系统缩略图缓存"。
//    现在"已重置"必须有命令成功证据：`qlmanage` 不存在 / 非 0 退出 / 超时 / 未执行
//    一律记为失败并带原因，且计入 `errorCount`。
// ③ **护栏与记账**：删除改走 `ResidueDeletionGate`（唯一护栏入口 + 删除**前**实测真实体积），
//    并写历史记录。系统动态缓存 `/var/folders/…/C` 在主目录之外，故为其声明**治理域**，
//    授权精确到三个 QuickLook 条目、且只允许删它们的**子项**（禁删缓存目录本身）。

public final class QuickLookThumbnailPurger {
    public static let shared = QuickLookThumbnailPurger()

    private init() {}

    // MARK: 授权范围常量

    /// QuickLook 缓存的路径特征（大小写不敏感）：整条路径里必须出现该标记。
    /// 保留它是因为它仍是**业务判据**（"这确实是 QuickLook 的缓存"），
    /// 但不再当安全护栏用——安全由网关负责。
    static let quickLookMarker = "quicklook"

    /// 系统动态缓存目录（`$TMPDIR` 同级的 `C`）里被授权清理的三个条目名。
    /// 其余条目一概不在授权范围内 —— 那个目录混着其它子系统的活跃缓存。
    static let darwinCacheEntries: Set<String> = [
        "com.apple.QuickLook.thumbnailcache",
        "com.apple.QuickLookUIFramework.QLPreviewGenerationExtension",
        "com.apple.quicklook.QuickLookUIService",
    ]

    /// 清理历史类名
    static let historyCategory = "QuickLook 缩略图缓存"

    /// qlmanage 可执行文件路径。**自检注入点**：指向不存在的路径即可演练"工具不可用"分支。
    static var qlmanagePath = "/usr/bin/qlmanage"

    /// 重置系统缩略图缓存所需的两条命令（顺序执行，全部成功才算重置成功）
    static let qlmanageResetCommands: [[String]] = [["-r", "cache"], ["-r"]]

    /// 获取当前 macOS 系统用户的 Darwin 缓存根目录
    public static func getDarwinUserCacheDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count)
        if len > 0 {
            return String(cString: buffer)
        }
        // 兜底策略：由 NSTemporaryDirectory() 向上推导 (通常为 /var/folders/xx/xxxx/T/ -> /var/folders/xx/xxxx/C/)
        let tempDir = NSTemporaryDirectory()
        let parent = (tempDir as NSString).deletingLastPathComponent
        let cDir = (parent as NSString).appendingPathComponent("C")
        if FileManager.default.fileExists(atPath: cDir) {
            return cDir
        }
        return nil
    }

    /// 系统动态缓存的治理域。
    ///
    /// `minDepthBelowRoot = 2`：授权只覆盖 `<darwin C>/com.apple.QuickLook.thumbnailcache/<子项>`，
    /// 缓存目录本身（深度 1）与域根（深度 0）都删不掉。
    ///
    /// 这个根只有运行时发现得到（路径里带机器相关的随机段），因此首次使用时**登记进注册表**，
    /// 让 `Selftest+DeletionGate` 那几条遍历 `GovernanceDomain.all` 的穷举断言覆盖到它。
    static func darwinCacheDomain() -> GovernanceDomain? {
        guard let root = getDarwinUserCacheDir(), !root.isEmpty else { return nil }
        let domain = GovernanceDomain(
            id: "quicklook.darwinCache",
            root: FileSystem.normalizePath(root),
            minDepthBelowRoot: 2,
            note: "访达快速查看在系统动态缓存目录里的缩略图数据库（删除后系统自动重建）",
            allowedEntryNames: darwinCacheEntries)
        GovernanceDomain.register(domain)
        return domain
    }

    /// 该路径挂在哪个治理域上。`nil` = 位于主目录内，走常规护栏。
    ///
    /// 先确保动态域已登记（首次使用即登记，之后 `all` 一直带着它），
    /// 再交给注册表的统一解析器——本模块不再自己写 normalize + hasPrefix 那一套。
    static func domain(forPath path: String) -> GovernanceDomain? {
        _ = darwinCacheDomain()
        return GovernanceDomain.domain(forPath: path)
    }

    /// 路径特征判定（业务判据，非安全护栏）
    static func isQuickLookCachePath(_ path: String) -> Bool {
        !path.isEmpty && path.lowercased().contains(quickLookMarker)
    }

    // MARK: - 扫描

    /// 扫描 QuickLook 缩略图数据库与生成缓存
    public func scan(customDirectories: [String]? = nil) -> QuickLookThumbnailSummary {
        let fm = FileManager.default
        var candidatePaths: [(path: String, kind: QuickLookCacheKind, title: String)] = []

        if let custom = customDirectories {
            for p in custom {
                candidatePaths.append((p, .thumbnailDatabase, "测试缩略图数据库"))
            }
        } else {
            // 系统动态缓存目录
            if let darwinCache = Self.getDarwinUserCacheDir() {
                let p1 = (darwinCache as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
                candidatePaths.append((p1, .thumbnailDatabase, "系统级 QuickLook 缩略图数据库"))

                let p2 = (darwinCache as NSString).appendingPathComponent("com.apple.QuickLookUIFramework.QLPreviewGenerationExtension")
                candidatePaths.append((p2, .previewExtensionCache, "预览生成扩展渲染缓存"))

                let p3 = (darwinCache as NSString).appendingPathComponent("com.apple.quicklook.QuickLookUIService")
                candidatePaths.append((p3, .uiServiceCache, "QuickLook UI 服务临时缓存"))
            }

            // 用户个人缓存目录
            let userCaches = NSString(string: "~/Library/Caches").expandingTildeInPath
            let u1 = (userCaches as NSString).appendingPathComponent("com.apple.QuickLook.thumbnailcache")
            candidatePaths.append((u1, .thumbnailDatabase, "用户级 QuickLook 缩略图数据库"))

            let u2 = (userCaches as NSString).appendingPathComponent("com.apple.quicklook.ui.helper")
            candidatePaths.append((u2, .userQuickLookCache, "QuickLook UI 辅助组件缓存"))
        }

        var items: [QuickLookCacheItem] = []
        var totalSize: Int64 = 0

        for candidate in candidatePaths {
            let path = candidate.path

            // 安全防线：绝对不扫描系统关键目录
            if path.hasPrefix("/System") || path == "/Library" || path == NSString(string: "~").expandingTildeInPath {
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

            let (size, count) = CLICacheScanner.calculateDirectoryStats(at: path)
            if size > 0 && count > 0 {
                let item = QuickLookCacheItem(
                    id: path,
                    kind: candidate.kind,
                    title: candidate.title,
                    path: path,
                    size: size,
                    fileCount: count,
                    isSelected: true
                )
                items.append(item)
                totalSize += size
            }
        }

        let sorted = items.sorted { $0.size > $1.size }

        return QuickLookThumbnailSummary(
            items: sorted,
            totalSize: totalSize
        )
    }

    // MARK: - 清理

    /// 安全清空选中的 QuickLook 缓存并重置系统缩略图数据库。
    ///
    /// 只删缓存目录的**直接子项**（缓存目录本身保留，与旧版行为一致），
    /// 每个子项都过一遍 `ResidueDeletionGate`：软链防跳板 → G8 → G6 → 用户白名单 →
    /// 治理域/主目录护栏 → 删除权限；释放量取**删除前实测**，不再沿用扫描缓存。
    ///
    /// - Parameters:
    ///   - items: 卡片上勾选的缓存项
    ///   - resetSystemCache: 是否调用 `qlmanage` 让系统立即重置缩略图索引
    ///   - toTrash: 缓存默认可再生，故默认彻底删除（`false`）；置 `true` 则移入废纸篓并可撤销
    ///   - journal: 历史写入策略，自检传 `.none`
    func purge(
        items: [QuickLookCacheItem],
        resetSystemCache: Bool = true,
        toTrash: Bool = false,
        journal: ResidueDeletionGate.Journal = .module(categoryName: QuickLookThumbnailPurger.historyCategory)
    ) -> QuickLookPurgeResult {
        var candidates: [ResidueDeletionGate.Candidate] = []
        var blocked: [ResidueDeletionGate.Rejection] = []

        for item in items {
            let path = item.path

            // 业务判据：路径必须带 QuickLook 标记（安全判定交给网关，不在此重复造轮子）
            guard Self.isQuickLookCachePath(path) else {
                blocked.append(.make(name: item.title, path: path, reason: .outsideDomain,
                                     message: "路径不含 QuickLook 标识，不在本模块授权范围内"))
                continue
            }

            guard FileSystem.exists(path) else {
                blocked.append(.make(name: item.title, path: path, reason: .missing))
                continue
            }

            // 「读不到」≠「可以删」：列不出子项就一项都不动，并如实上报
            let children: [String]
            do {
                children = try FileManager.default.contentsOfDirectory(atPath: path)
            } catch {
                let reason: GovernanceVerdict.Reason =
                    FileSystem.isPermissionDenied(path) ? .needsPrivilege : .blockedByBaseGate
                blocked.append(.make(name: item.title, path: path, reason: reason,
                                     message: "无法读取缓存目录内容（\(error.localizedDescription)），未删除任何文件"))
                continue
            }

            let domain = Self.domain(forPath: path)
            for child in children {
                let childPath = (path as NSString).appendingPathComponent(child)
                candidates.append(ResidueDeletionGate.Candidate(item.title, path: childPath, domain: domain))
            }
        }

        // 模块自己先拦下的项与网关结果合成一份完整结论（合并逻辑只在 Outcome.merge 里有一份）
        var outcome = ResidueDeletionGate.Outcome(rejected: blocked).merging(
            ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal) { candidate in
                // 双保险：子项路径同样必须带 QuickLook 标识，否则不属于本模块
                guard Self.isQuickLookCachePath(candidate.path) else {
                    return .make(candidate, reason: .outsideDomain,
                                 message: "子项路径不含 QuickLook 标识，不属于本模块授权范围")
                }
                return nil
            })

        var resetSucceeded = false
        var resetFailure: String?
        if resetSystemCache {
            let reset = Self.executeQLManageReset()
            resetSucceeded = reset.reset
            resetFailure = reset.failureReason
            if let resetFailure {
                outcome.rejected.append(.make(name: "系统缩略图缓存重置", path: Self.qlmanagePath,
                                              reason: .blockedByBaseGate, message: resetFailure))
            }
        }

        return QuickLookPurgeResult(outcome: outcome, resetRequested: resetSystemCache,
                                    systemCacheReset: resetSucceeded, systemResetFailure: resetFailure)
    }

    /// 执行系统级 qlmanage 重置命令，并**如实**报告是否真的重置成功。
    ///
    /// 返回 `(reset: false, failureReason: …)` 的四种情形：
    /// 工具不存在、进程未被执行、非 0 退出、超时。任何一种都不得写成"已重置"。
    @discardableResult
    public static func executeQLManageReset(timeout: TimeInterval = 20) -> (reset: Bool, failureReason: String?) {
        guard SafeProcess.isAvailable(qlmanagePath) else {
            return (false, "系统未提供 \(qlmanagePath)，未执行任何重置命令，缩略图索引仍是旧状态")
        }
        var reasons: [String] = []
        for args in qlmanageResetCommands {
            let label = "qlmanage \(args.joined(separator: " "))"
            guard let result = SafeProcess.run(qlmanagePath, args, timeout: timeout) else {
                reasons.append("\(label) 未被执行")
                continue
            }
            if !result.succeeded {
                let detail = result.timedOut ? "超时（>\(Int(timeout))s）被终止"
                                             : "退出码 \(result.exitCode)"
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                reasons.append(output.isEmpty ? "\(label) \(detail)" : "\(label) \(detail)：\(output.prefix(160))")
            }
        }
        guard !reasons.isEmpty else { return (true, nil) }
        return (false, reasons.joined(separator: "；"))
    }
}
