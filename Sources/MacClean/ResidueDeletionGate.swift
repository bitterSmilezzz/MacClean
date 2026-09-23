import Foundation

// MARK: - 统一删除网关（v1.72.0 安全收敛）
//
// 此前每个治理模块都自带一份 `clean(items:toTrash:)`：十余份同形代码，
// 且各自只写着 `path.hasPrefix("/System")` 这种字符串护栏，删完就地累加
// `item.size` 记账。三条老毛病在这里一次收敛：
//
// ① **护栏**：一律走 `FileSystem.governanceVerdict`（软链防跳板 + G8 + G6 + 用户白名单 +
//    治理域 + 真实删除权限），调用方无法再"自己决定要不要检查"；
// ② **记账**：删除**前**实测真实体积，而不是沿用扫描时的缓存值——此前
//    `FontCacheInspector` 之类用 `try?` 读到 0 仍计成功，释放量是编出来的；
// ③ **可撤销**：移入废纸篓时捕获 `resultingItemURL` 并写 Undo 会话与历史记录。
//    此前 14 张治理卡片无一写历史，用户清完整个人没有回退路径。

enum ResidueDeletionGate {

    /// 一个待删候选。`domain == nil` 表示目标在主目录内，走常规护栏。
    struct Candidate {
        let name: String
        let path: String
        let domain: GovernanceDomain?

        init(_ name: String, path: String, domain: GovernanceDomain? = nil) {
            self.name = name
            self.path = path
            self.domain = domain
        }
    }

    struct Rejection: Equatable {
        let name: String
        let path: String
        let reason: GovernanceVerdict.Reason
        let message: String

        /// 拒绝项的统一工厂（此前 3 个模块各写一份本地 `rejection(...)` 工厂）。
        /// `message` 省略时回落到 `reason` 的内置文案；模块自己的中文原因请传进来。
        static func make(name: String, path: String, reason: GovernanceVerdict.Reason,
                         message: String? = nil) -> Rejection {
            Rejection(name: name, path: path, reason: reason,
                      message: message ?? GovernanceVerdict.rejected(reason).message)
        }

        /// `policy` 闭包一侧的工厂：候选自带 name/path，闭包里只给 reason + 中文原因。
        static func make(_ candidate: Candidate, reason: GovernanceVerdict.Reason,
                         message: String? = nil) -> Rejection {
            make(name: candidate.name, path: candidate.path, reason: reason, message: message)
        }
    }

    struct Outcome {
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var cleanedPaths: [String] = []
        var rejected: [Rejection] = []
        var failed: [(name: String, path: String, message: String)] = []
        var trashedSnapshots: [TrashedItemEntry] = []

        init() {}

        /// 以模块自己先拦下的项起步，网关结果随后 `merge` 进来。
        init(rejected: [Rejection]) { self.rejected = rejected }

        /// 与旧版各模块 `(cleanedCount, freedBytes, errorCount)` 元组兼容的错误计数，
        /// 便于渐进迁移且保留既有自检断言的语义。
        var errorCount: Int { rejected.count + failed.count }
        var needsPrivilege: [Rejection] { rejected.filter { $0.reason == .needsPrivilege } }
        var isEmptyAction: Bool { cleanedCount == 0 && errorCount == 0 }

        /// 一句可直接放进 Toast 的结论
        var summary: String {
            var parts: [String] = []
            if cleanedCount > 0 { parts.append("已清理 \(cleanedCount) 项 / \(freedBytes.byteStringCN)") }
            if !needsPrivilege.isEmpty {
                parts.append("\(needsPrivilege.count) 项由 root 管理，无权限删除")
            }
            let otherRejected = rejected.count - needsPrivilege.count
            if otherRejected > 0 { parts.append("\(otherRejected) 项被安全护栏拦下") }
            if !failed.isEmpty { parts.append("\(failed.count) 项删除失败") }
            return parts.isEmpty ? "没有可清理的项目" : parts.joined(separator: "；")
        }

        /// 两份结果相加的**唯一**实现。
        ///
        /// v1.72 那轮并行改动里，4 个模块各自抄了一遍同一段"逐字段相加"
        /// （`FontCacheInspector.absorb`、`CLICacheScanner.merge`、`LoginItemCleaner`、
        /// `PluginExtensionInspector` 里的内联版），因为网关的返回值无法预置模块
        /// 自己先记下的拦截项。现在：
        /// - 模块侧先拦的项用 `Outcome(rejected:)` 起步；
        /// - 网关结果用 `merge` / `merging` 并进来（保留"模块项在前"的顺序）。
        mutating func merge(_ other: Outcome) {
            cleanedCount += other.cleanedCount
            freedBytes += other.freedBytes
            cleanedPaths.append(contentsOf: other.cleanedPaths)
            rejected.append(contentsOf: other.rejected)
            failed.append(contentsOf: other.failed)
            trashedSnapshots.append(contentsOf: other.trashedSnapshots)
        }

        /// 非变异版：`Outcome(rejected: blocked).merging(gateOutcome)`
        func merging(_ other: Outcome) -> Outcome {
            var merged = self
            merged.merge(other)
            return merged
        }
    }

    /// 是否写历史与撤销快照。自检传 `.none`，避免污染用户真实历史。
    enum Journal {
        case none
        case module(categoryName: String)
    }

    /// 执行删除。
    /// - Parameters:
    ///   - candidates: 调用方已勾选的项（**不要**自己预筛护栏，交给网关）
    ///   - toTrash: true 移入废纸篓；false 彻底删除
    ///   - journal: 历史与撤销快照写入策略
    ///   - policy: 模块特有的业务判据（如"状态必须是孤儿/损坏"）。返回 `Rejection`
    ///     即拦下，并可携带**模块自己的中文原因**；返回 nil 表示放行。
    ///     只想套用 `reason` 内置文案时用 `Rejection.make(candidate, reason:)`。
    /// - Returns: 逐项结果，含被拦原因
    @discardableResult
    static func execute(
        _ candidates: [Candidate],
        toTrash: Bool = true,
        journal: Journal = .module(categoryName: "治理清理"),
        policy: (Candidate) -> Rejection? = { _ in nil }
    ) -> Outcome {
        var out = Outcome()
        let fm = FileManager.default

        // 先删浅层：父目录被删之后，其子项必然已不存在。若不排序，勾选了
        // 「厂商驱动目录」又恰好勾了它内部的单个文件时会重复计体积。
        let ordered = candidates.sorted {
            $0.path.split(separator: "/").count < $1.path.split(separator: "/").count
        }
        var deletedRealPaths: [String] = []

        for candidate in ordered {
            let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))

            // 祖先已被本次操作删除 → 视为已清理，静默跳过（不重复计体积）
            if deletedRealPaths.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) { continue }

            let verdict: GovernanceVerdict
            if let domain = candidate.domain {
                verdict = FileSystem.governanceVerdict(candidate.path, domain: domain)
            } else {
                verdict = FileSystem.governanceVerdictWithinHome(candidate.path)
            }
            guard verdict.isAllowed else {
                let reason: GovernanceVerdict.Reason
                if case .rejected(let r) = verdict { reason = r } else { reason = .blockedByBaseGate }
                out.rejected.append(Rejection(name: candidate.name, path: candidate.path,
                                              reason: reason, message: verdict.message))
                continue
            }
            if let rejection = policy(candidate) {
                out.rejected.append(rejection)
                continue
            }

            // 删除前实测真实体积：扫描缓存可能是上一次会话的旧值
            let actual = FileSystem.size(at: real)
            do {
                if toTrash {
                    var resulting: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: real), resultingItemURL: &resulting)
                    if let trashPath = (resulting as URL?)?.path {
                        out.trashedSnapshots.append(TrashedItemEntry(
                            originalPath: real, trashPath: trashPath,
                            size: actual, itemName: candidate.name))
                    }
                } else {
                    try fm.removeItem(atPath: real)
                }
                out.cleanedCount += 1
                out.freedBytes += actual
                out.cleanedPaths.append(real)
                deletedRealPaths.append(real)
                FileSystem.invalidateMeasurements(for: [real])
            } catch {
                out.failed.append((candidate.name, candidate.path, error.localizedDescription))
            }
        }

        if case .module(let categoryName) = journal, out.cleanedCount > 0 {
            record(categoryName: categoryName, outcome: out, permanently: !toTrash)
        }
        return out
    }

    /// 旧签名：`policy` 只能回一个 `GovernanceVerdict.Reason`，带不动模块自己的中文原因，
    /// 于是 4 批工程师各自造了绕过方案（预置 blocked 数组、本地 Rejection 工厂、借用
    /// 语义不符的 reason）。保留此重载只为让未迁移的调用方仍能编译；新代码请用
    /// `policy: (Candidate) -> Rejection?`。
    @available(*, deprecated, message: "改传 policy: (Candidate) -> ResidueDeletionGate.Rejection?，可携带模块自己的中文原因")
    @discardableResult
    static func execute(
        _ candidates: [Candidate],
        toTrash: Bool = true,
        journal: Journal = .module(categoryName: "治理清理"),
        policy: (Candidate) -> GovernanceVerdict.Reason?
    ) -> Outcome {
        execute(candidates, toTrash: toTrash, journal: journal) { candidate in
            guard let reason = policy(candidate) else { return nil }
            return Rejection.make(candidate, reason: reason)
        }
    }

    /// 写历史记录与撤销快照（G3：默认移入废纸篓时才可回退）。
    ///
    /// 串行化不在这里做：`HistoryStore.append` 与 `UndoManagerStore.record` 各自是原子的
    /// 读改写，两次并发清理不会互相覆盖**同一份列表**。
    /// **已知残余**：一条记录与它的快照仍不在同一个临界区，中间进程被终止（`--autoclean`
    /// 被 launchd 杀掉、用户强退）会留下"有历史行、无快照"的记录。界面按
    /// "快照不存在就不给放回按钮"降级（`HistoryRow`），不再为此补一把跨存储的锁。
    private static func record(categoryName: String, outcome: Outcome, permanently: Bool) {
        let record = CleanRecord(
            id: UUID(), date: Date(), categoryName: categoryName,
            itemCount: outcome.cleanedCount, bytes: outcome.freedBytes,
            mode: permanently ? "彻底删除" : "废纸篓", failures: outcome.errorCount)
        HistoryStore.append(record)

        if !permanently && !outcome.trashedSnapshots.isEmpty {
            UndoManagerStore.record(session: CleanUndoSession(recordID: record.id,
                                                              entries: outcome.trashedSnapshots))
        }
    }
}
