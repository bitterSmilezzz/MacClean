import Foundation

/// 废纸篓自动清空（v1.73.14，主流清理工具标配缺口）
///
/// 判据：废纸篓根（默认 `~/.Trash`）**顶层**条目的 **mtime** 早于 N 天前 → 彻底删除。
/// - 为什么用 mtime：把文件移进废纸篓**不会**改变它自身的修改时间，macOS 也没有公开 API
///   读「何时被丢进废纸篓」；按 RELEASE-CHECKLIST 的规矩，时间判据只用 mtime
///   （自家探查不会改动它，不会出现"扫描把自己扫成了证据"），所以 UI 文案必须说
///   「最后修改时间」，**不许**说成「丢弃时间」——量到什么就说什么。
/// - 彻底删除不经废纸篓（那正是本功能的目的），但删除仍走 `ResidueDeletionGate`：
///   G6 硬排除 / G8 系统保护 / 用户白名单照样裁决、删除前实测体积、写清理历史。
///   不可恢复是本功能的定义：开关默认关，开启处明示「无撤销快照」。
/// - G9：废纸篓根读不到（无完全磁盘访问权限时 `~/.Trash` 是 TCC 保护位）→
///   `rootUnreadable = true`、**什么都不删**——不许把「没读到」渲染成「清空了 0 项」。
/// - 软链条目不判龄不删：删掉一条软链释放 0 字节，且废纸篓里的软链可能指向别处。
enum TrashAutoEmptyService {

    struct Outcome: Equatable {
        var rootUnreadable = false
        /// 废纸篓根顶层条目总数
        var scanned = 0
        var cleaned = 0
        var freedBytes: Int64 = 0
        var rejected: [ResidueDeletionGate.Rejection] = []
        var failed: [(name: String, path: String, message: String)] = []
        /// 未到期 / 软链等跳过数
        var skippedRecent = 0

        static func == (l: Outcome, r: Outcome) -> Bool {
            l.rootUnreadable == r.rootUnreadable && l.scanned == r.scanned
                && l.cleaned == r.cleaned && l.freedBytes == r.freedBytes
                && l.rejected == r.rejected && l.skippedRecent == r.skippedRecent
                && l.failed.count == r.failed.count
        }
    }

    /// 开关开着才动手；配置来自 `DiskMonitorConfig`（与设置页同源）。
    /// `config` / `trashRoot` 是自检注入缝——自检**永不**用真实废纸篓或真实配置调用。
    static func emptyIfEnabled(now: Date = Date(),
                               trashRoot: String? = nil,
                               config: DiskMonitorConfig? = nil) -> Outcome? {
        let cfg = config ?? DiskMonitorConfig.load()
        guard cfg.trashAutoEmptyEnabled, cfg.trashAutoEmptyDays > 0 else { return nil }
        return emptyOlderThan(days: cfg.trashAutoEmptyDays, now: now, trashRoot: trashRoot)
    }

    /// 清空指定根下 mtime 早于 `days` 天的顶层条目。`trashRoot` 供自检注入夹具根。
    @discardableResult
    static func emptyOlderThan(days: Int, now: Date = Date(), trashRoot override: String? = nil) -> Outcome {
        var out = Outcome()
        let root = FileSystem.normalizePath(
            CleanPaths.expand(override ?? defaultTrashRoot()))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir),
              isDir.boolValue else {
            out.rootUnreadable = true
            return out
        }
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: root)
        } catch {
            // G9：读不到必须分开于「空」。这里是真试过的一次失败，照实记账。
            FileSystem.recordDeniedAccess(URL(fileURLWithPath: root, isDirectory: true), error: error)
            out.rootUnreadable = true
            return out
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86400)
        let normRoot = FileSystem.normalizePath(root)
        var candidates: [ResidueDeletionGate.Candidate] = []
        for entry in entries.sorted() {
            let p = (root as NSString).appendingPathComponent(entry)
            out.scanned += 1
            if FileSystem.isSymlink(p) {
                out.skippedRecent += 1
                continue
            }
            guard let mtime = FileSystem.modificationDate(p), mtime < cutoff else {
                out.skippedRecent += 1
                continue
            }
            // 只把废纸篓根的**直接子项**放进候选；嵌套内容作为子树随顶层一起走网关。
            candidates.append(ResidueDeletionGate.Candidate(entry, path: p, domain: nil))
        }
        guard !candidates.isEmpty else { return out }

        // 二道闸（与第一道独立）：policy 只放行「废纸篓根的直接子项」——
        // 即使上游拼路径出错，也不会有任何废纸篓之外的位置被删。
        let result = ResidueDeletionGate.execute(candidates, toTrash: false,
                                                 journal: .module(categoryName: "废纸篓自动清空")) { cand in
            let parent = (FileSystem.normalizePath(cand.path) as NSString).deletingLastPathComponent
            if parent == normRoot { return nil }
            return .make(cand, reason: .notDeletable, message: "不是废纸篓根的直接子项，拒绝删除")
        }
        out.cleaned = result.cleanedCount
        out.freedBytes = result.freedBytes
        out.rejected = result.rejected
        out.failed = result.failed
        return out
    }

    private static func defaultTrashRoot() -> String {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.path
            ?? NSString(string: "~/.Trash").expandingTildeInPath
    }
}
