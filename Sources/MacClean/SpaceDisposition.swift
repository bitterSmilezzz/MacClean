import Foundation

/// 一次删除之后，那批字节究竟落到哪里去了。
///
/// 为什么需要这个类型：G3 把「移入废纸篓」设成默认，而同卷上的 `trashItem` 只是一次 rename。
/// 本机实测（读的正是 `DiskInfo.volumes()` 用的 `volumeAvailableCapacityForImportantUsage`，
/// 与界面那格「可用空间」同源；200 MiB 已分配载荷）：
/// - 同卷 rename（= 移入废纸篓的实际动作）→ Δ = **0 MiB**
/// - `removeItem`（= 彻底删除）→ Δ = **+200 MiB**
///
/// 而清理结论此前一律写成「已释放 / 实际释放 / 累计释放」，于是默认路径上每一次清理都在
/// 报一个磁盘上并没有发生的数字；同一个结果弹窗里唯一能证伪它的「可用空间前后对比」，
/// 还被 `max(前, 后)` 夹成永不下降。字节没算错，**错的是动词**——而动词此前有 19 个手写副本。
///
/// 所以这个类型只负责一件事：「字节 + 动词」这句话全 App 只有一个出处
/// （`claim()`），并且有一条源码自检守着不许在别处再拼一遍。
enum SpaceDisposition: Equatable {
    case nothing
    /// 真的从磁盘上删掉了：彻底删除、清空废纸篓、释放本地快照
    case reclaimed(Int64)
    /// 只是搬进废纸篓：字节还占着磁盘，清空废纸篓之后才落定
    case trashed(Int64)
    /// 一次动作里两种都有（主链路逐条路径判定：已在废纸篓里的条目会强制彻底删除）
    case split(reclaimed: Int64, trashed: Int64)

    init(reclaimed: Int64, trashed: Int64) {
        switch (reclaimed > 0, trashed > 0) {
        case (true, true): self = .split(reclaimed: reclaimed, trashed: trashed)
        case (true, false): self = .reclaimed(reclaimed)
        case (false, true): self = .trashed(trashed)
        case (false, false): self = .nothing
        }
    }

    /// 一次动作只有一种落点时用它：网关的 `execute(toTrash:)` 就是这种。
    init(toTrash: Bool, bytes: Int64) {
        self.init(reclaimed: toTrash ? 0 : bytes, trashed: toTrash ? bytes : 0)
    }

    /// 两次删除的结果并成一句话时用（如字体面板一次跑「字体 + 缓存」两批删除）。
    static func + (lhs: SpaceDisposition, rhs: SpaceDisposition) -> SpaceDisposition {
        SpaceDisposition(reclaimed: lhs.reclaimedBytes + rhs.reclaimedBytes,
                         trashed: lhs.trashedBytes + rhs.trashedBytes)
    }

    var reclaimedBytes: Int64 {
        switch self {
        case .nothing, .trashed: return 0
        case .reclaimed(let b): return b
        case .split(let r, _): return r
        }
    }

    var trashedBytes: Int64 {
        switch self {
        case .nothing, .reclaimed: return 0
        case .trashed(let b): return b
        case .split(_, let t): return t
        }
    }

    var totalBytes: Int64 { reclaimedBytes + trashedBytes }

    /// 有没有哪一批字节还压在磁盘上。任何"释放了多少"的合计都必须先问这一句。
    var hasPendingTrash: Bool { trashedBytes > 0 }

    /// 「字节 + 动词」的唯一出处。
    ///
    /// 措辞刻意说得直白：移进废纸篓的那部分**没有**释放磁盘，只有清空废纸篓之后才释放。
    /// 这里不写「已释放（部分在废纸篓）」那种两头讨好的句子——用户据此做的决定是
    /// "磁盘够不够用"，而那一半空间此刻并不够用。
    func claim() -> String {
        switch self {
        case .nothing:
            // 只报量，不替调用方下"什么都没做"的结论：删掉一个空目录、或一个 0 字节的
            // 日志时，`cleanedCount > 0` 而字节为 0（`Cleaner` 的 `deletedAnyPath` 证明这形态
            // 可达）。那句时报"没有清掉任何内容"就是把"做成了但没量到"播成"没做成"（G9 反方向）。
            return "0 B"
        case .reclaimed(let b):
            return "释放 \(b.byteStringCN)"
        case .trashed(let b):
            return "移入废纸篓 \(b.byteStringCN)（磁盘还没释放，清空废纸篓才算数）"
        case .split(let r, let t):
            return "释放 \(r.byteStringCN)，另有 \(t.byteStringCN) 移入废纸篓（清空后才释放磁盘）"
        }
    }

    /// 结果弹窗顶部那个大数字的标签。数字是总量，所以标签必须能同时容纳两种落点。
    var heroLabel: String {
        switch self {
        case .nothing, .reclaimed: return "本次释放"
        case .trashed: return "本次移入废纸篓"
        case .split: return "本次清理"
        }
    }

    /// 顶部大数字下面那行小字：把"还没落定"的部分单独说出来。无未落定量时回 nil。
    var heroCaveat: String? {
        guard hasPendingTrash else { return nil }
        return "其中 \(trashedBytes.byteStringCN) 只是搬进废纸篓，磁盘可用量要等清空废纸篓才变"
    }
}
