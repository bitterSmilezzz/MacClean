import Foundation

/// 「删了之后必须留下什么」的**唯一**出口：一行历史 + 与它配套的撤销快照。
///
/// 为什么要收成一处（R2 的 P0）：`Cleaner.clean` 在产品源码里原本有 **7 处调用点**
/// （`AppState` 两处、`AutoCleanService`、`DiskMonitor`、`DuplicateScanner`、`Uninstaller`、
/// `OrphanScanner`），其中 **4 处的账是残缺的**，分成两种：
/// - **一行都不写**：`Uninstaller.uninstallSelected`（删的常是 `Application Support/<App>`
///   里的真数据）与 `OrphanScanner.clean`（孤儿残留）；
/// - **写了历史、把快照丢掉**：`DiskMonitor.performSilentAutoClean`（唯一"没人看着也会删"
///   的链路）与 `DuplicateScanner`/`DuplicateView`（一次删整组副本，视图只补 `recordClean`）。
///
/// 用户侧的表现是"应用不知道发生过什么"：历史虚低、界面上没有「放回原位」，
/// 而那两条只写历史的链路会留下一行**永远点不动**的记录。
/// 另有两处不经过 `Cleaner` 的裸 `fm.trashItem`（归档、跨卷迁移）同样是零账。
/// 现在把"动手"与"记账"绑进同一个函数：常规写法下**想删就必须记账**。
///
/// ⚠ 这句话的边界要说清（v1.73.15 二次复审 P1/P3，别再拿它当编译器级保证）：
/// 配套 lint 是**文本判据**，它守得住"直接调 `Cleaner.clean`"与"取函数引用"两种写法，
/// 守不住刻意躲它的形状（`typealias KC = Cleaner; KC.clean(`），更守不住
/// "把调用点包进一个永不执行的分支"。真正编译器级的保护要把 `Cleaner` 并进本文件、
/// 把 `clean` 设成 `private`，那要动 `Cleaner.Result` 的可见性与 20+ 处类型引用，
/// 已记进 `docs/OPTIMIZATION-PLAN.md` 作为下一次发版前的硬条件。
enum DeletionLedger {
    struct Outcome {
        let result: Cleaner.Result
        /// 什么都没删成（`itemCount == 0 && failures == 0`）时为 nil —— 出口不会为
        /// "无事发生"刷一条噪声历史，那会把 200 条上限用在空行上。
        let record: CleanRecord?
        /// `HistoryStore.append` 落盘后合并回来的完整清单。
        /// **有 `AppState` 的链路不要拿它去刷缓存**：`refreshDisk()` 里的 `reloadHistory()`
        /// 读的是更晚的盘，用这份 append 时刻的快照覆盖回去反而会把窗口期内别的写手（网关、
        /// 定时自愈、无头维护）刚落的行抹掉——v1.73.2 修过的陈旧覆盖形状，只是换了个位置
        /// （v1.73.15 独立复审 P2-F5）。它存在的意思是给**没有内存缓存的无头链路**
        /// （`--autoclean`）一个"我确实写了"的回执。
        let history: [CleanRecord]?
        let undoSessionID: UUID?
    }

    /// 执行删除并记账。**产品代码里唯一允许直接调用 `Cleaner.clean` 的地方。**
    ///
    /// ⚠ `deleter` 这条注入缝**只在开发构建里存在**：`MACCLEAN_SELFTEST` 由 `Package.swift:41`
    ///   只在没设 `MACCLEAN_NO_SELFTEST` 时定义，所以发出去的 `.app` 里这条边**根本不存在**，
    ///   删除只可能从 `#else` 那一行走进出口。
    ///   为什么必须这样关起来（v1.73.15 二次复审 P1-1）：一个可以被任何文件重赋值的可变全局，
    ///   本身就是"绕过出口"的后门——把 `deleter` 换成一个不调 `Cleaner.clean`（因此也不跑
    ///   `isSafeToClean` 的 G1/G6/G8 护栏）的闭包，文件**没被删**却照样落一行"成功"历史；
    ///   而 lint 是文本判据，追不上这种语言层面可达的形状。
    #if MACCLEAN_SELFTEST
    /// 自检用它断言"出口把结果里的**快照、落点、字节数、失败数**逐列搬进账本"——
    /// 否则端到端只能拿 `permanently: true` 跑（不污染真废纸篓，但也永远走不到废纸篓分支），
    /// 于是"把 `snapshots:` 改成 `[]`"这种一个 token 的改动能让全量自检一字不差地全绿。
    static var deleter: ([CleanItem], Bool, @escaping (String) -> Void) -> Cleaner.Result = {
        Cleaner.clean($0, permanently: $1, progress: $2)
    }
    #endif

    static func clean(_ items: [CleanItem],
                      permanently: Bool,
                      categoryName: String,
                      progress: @escaping (String) -> Void = { _ in }) -> Outcome {
        #if MACCLEAN_SELFTEST
        let result = deleter(items, permanently, progress)
        #else
        let result = Cleaner.clean(items, permanently: permanently, progress: progress)
        #endif
        let written = write(categoryName: categoryName,
                            itemCount: result.succeeded,
                            bytes: result.releasedBytes,
                            trashedBytes: result.trashedBytes,
                            failures: result.failures.count,
                            // ⚠ 主链路目前**拿不到"体积是不是下限"**：`Cleaner` 用的是
                            //   `FileSystem.size(at:)`，那个接口丢掉了来源信息
                            //   （`sizeWithProvenance` 才有 `walkWasBlocked`），所以这里只能写 0。
                            //   后果是网关那条链路会写「（下限）」而主链路一律写精确值——
                            //   口径**尚未**在全部链路一致，这条记在 `docs/OPTIMIZATION-PLAN.md` §5bis。
                            lowerBoundCount: 0,
                            permanently: permanently,
                            snapshots: result.trashedSnapshots)
        return Outcome(result: result, record: written.record,
                       history: written.history, undoSessionID: written.undoSessionID)
    }

    /// 不经过 `Cleaner` 的路径（统一删除网关、归档/迁移里自己 `trashItem` 的那两处）
    /// 用同一个写手补账，保证 mode、`trashedBytes`、快照三样的口径在全部链路上一致。
    /// 只有真的删成了东西才落一行：`itemCount == 0 && failures == 0` 时返回 nil，
    /// 免得"什么都没做"也刷一条历史（那会把 200 条上限用在噪声上）。
    @discardableResult
    static func write(categoryName: String,
                      itemCount: Int,
                      bytes: Int64,
                      trashedBytes: Int64,
                      failures: Int,
                      lowerBoundCount: Int = 0,
                      permanently: Bool,
                      snapshots: [TrashedItemEntry],
                      modeOverride: String? = nil) -> (record: CleanRecord?, history: [CleanRecord]?, undoSessionID: UUID?) {
        guard itemCount > 0 || failures > 0 else { return (nil, nil, nil) }
        let record = CleanRecord(
            id: UUID(), date: Date(), categoryName: categoryName,
            itemCount: itemCount, bytes: bytes,
            mode: modeOverride ?? (permanently ? "彻底删除" : "废纸篓"),
            failures: failures,
            // 只在"确实是下限"时写 true，其余留 nil：老记录与不需要这句话的记录
            // 保持和改动前逐字节一致（合成 Codable 对非 Optional 不用默认值，
            // 见 `CleanRecord` 上那段注释）。
            freedIsLowerBound: lowerBoundCount > 0 ? true : nil,
            trashedBytes: trashedBytes > 0 ? trashedBytes : nil)
        let history = HistoryStore.append(record)

        var undoSessionID: UUID? = nil
        if !permanently && !snapshots.isEmpty {
            let session = CleanUndoSession(recordID: record.id, entries: snapshots)
            UndoManagerStore.record(session: session)
            undoSessionID = session.id
        }
        return (record, history, undoSessionID)
    }
}
