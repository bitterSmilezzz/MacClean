import Foundation

/// 无头后台定时维护与低空间自愈服务
///
/// 当系统 launchd 定时触发或运行 `MacClean --autoclean` 时调用。
/// 全程零 GUI 窗口运行，快速巡检、执行安全自愈清理、持久化清理历史与撤销快照，并向系统发送通知。
enum AutoCleanService {

    /// 自测注入支持
    static var lockFileURLOverride: URL?
    static var skipDiskCheckForTesting: Bool = false
    static var mockAvailableBytes: Int64?

    /// 进程互斥锁路径（防止多实例并发竞争）
    private static var lockFileURL: URL {
        if let override = lockFileURLOverride { return override }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.macclean.autoclean.lock")
    }

    /// 执行后台自动维护与自愈巡检
    /// - Returns: 进程退出状态码 (0 为成功)
    @discardableResult
    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timeStr = formatter.string(from: now)

        print("== MacClean 定时自动维护与自愈巡检 [\(timeStr)] ==")

        // 1. 尝试获取文件锁
        let lockPath = lockFileURL.path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard lockFD >= 0 else {
            print("[AutoClean] 无法创建进程互斥锁，退出")
            return 1
        }
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            print("[AutoClean] 另一实例正在执行自动维护，跳过本轮执行")
            return 0
        }

        // 2. 读取配置
        let config = DiskMonitorConfig.load()
        let diskAvail = DiskInfo.volumes()?.available ?? 0
        let available = mockAvailableBytes ?? diskAvail
        let availGB = Double(available) / 1_000_000_000.0
        let isLowSpace = availGB < Double(config.lowSpaceThresholdGB)
        let triggerHeal = isLowSpace && config.autoHealOnLowSpace

        print("[AutoClean] 磁盘当前可用: \(available.byteStringCN) (\(String(format: "%.1f", availGB)) GB), 警戒阈值: \(config.lowSpaceThresholdGB) GB")
        if triggerHeal {
            print("⚠️ [AutoClean] 触发低空间紧急自愈模式：将进行全面深度安全释放")
        }

        // 3. 规划扫描分类
        var categoriesToScan: [CleanCategory] = []
        if config.autoCleanUserCaches || triggerHeal {
            categoriesToScan.append(.userCaches)
        }
        if config.autoCleanLogsAndTemp || triggerHeal {
            categoriesToScan.append(.logsAndTemp)
        }
        if triggerHeal || config.autoCleanSmartRecommended {
            categoriesToScan.append(contentsOf: [.devResidue, .browserAndSystem])
        }

        // 4. 并发扫描收集候选项
        var allScannedItems: [CleanItem] = []
        for cat in categoriesToScan {
            if let items = try? Scanner.scan(cat) {
                allScannedItems.append(contentsOf: items)
            }
        }
        print("[AutoClean] 扫描完成，候选项目共 \(allScannedItems.count) 项")

        // 5. 严格过滤安全项（遵循系统最高安全防护门槛）
        let whitelist = WhitelistManager.shared
        let candidates = filterEligibleCandidates(
            items: allScannedItems,
            whitelist: whitelist,
            isLowSpaceHeal: triggerHeal
        )
        let plannedBytes = candidates.reduce(Int64(0)) { $0 + $1.size }
        print("[AutoClean] 筛选出可安全释放项: \(candidates.count) 项，预计释放 \(plannedBytes.byteStringCN)")

        guard !candidates.isEmpty else {
            print("[AutoClean] 没有满足安全门槛的可清理项，本次维护完成")
            return 0
        }

        // 6. 执行安全清理（非彻底删除，统一移入系统废纸篓）
        let result = Cleaner.clean(candidates, permanently: false) { _ in }
        print("[AutoClean] 清理完成：成功移入废纸篓 \(result.succeeded) 项，实际释放 \(result.releasedBytes.byteStringCN)，失败 \(result.failures.count) 项")

        // 7. 持久化记录（历史记录与撤销快照）
        if result.succeeded > 0 {
            var history = HistoryStore.load()
            let categoryLabel = triggerHeal ? "系统定时自愈清理" : "系统定时维护"
            let record = CleanRecord(
                categoryName: categoryLabel,
                itemCount: result.succeeded,
                bytes: result.releasedBytes,
                mode: "废纸篓",
                failures: result.failures.count
            )
            history.insert(record, at: 0)
            if history.count > 200 { history = Array(history.prefix(200)) }
            HistoryStore.save(history)

            // 写入撤销快照，方便用户后续随时在主界面放回原位
            if !result.trashedSnapshots.isEmpty {
                let session = CleanUndoSession(recordID: record.id, entries: result.trashedSnapshots)
                UndoManagerStore.record(session: session)
            }

            // 8. 发送系统通知
            sendCompletionNotification(
                releasedBytes: result.releasedBytes,
                failures: result.failures.count,
                isHeal: triggerHeal
            )
        }

        return 0
    }

    /// 过滤符合无人值守安全标准的清理项
    static func filterEligibleCandidates(
        items: [CleanItem],
        whitelist: WhitelistManager,
        isLowSpaceHeal: Bool
    ) -> [CleanItem] {
        items.filter { item in
            // 1. 白名单保护
            if whitelist.isWhitelisted(path: item.path) { return false }

            // 2. 结论必须为「可清理」
            guard item.recommendation.isSafe else { return false }

            // 3. 所属应用不能处于正在运行状态
            guard !item.use.ownerIsRunning && !item.use.isBeingWrittenNow else { return false }

            // 4. 无人值守保守门槛：近期使用/写入的项坚决跳过
            guard !item.usage.isRecentlyUsed else { return false }

            // 5. 若处于低空间自愈模式，放行所有符合上述安全门槛的项；
            //    常规模式下，若为扩展分类，需加权推荐评定为 high 或 medium
            if !isLowSpaceHeal && item.category != .userCaches && item.category != .logsAndTemp {
                let score = RecommendationScorer.score(item: item)
                return score.tier == .high || score.tier == .medium
            }

            return true
        }
    }

    /// 发送 macOS 系统完成通知
    private static func sendCompletionNotification(releasedBytes: Int64, failures: Int, isHeal: Bool) {
        let title = isHeal ? "MacClean 低空间自愈完成" : "MacClean 定时自动维护完成"
        let body: String
        if failures > 0 {
            body = "已安全释放 \(releasedBytes.byteStringCN)，另有 \(failures) 项被跳过或失败。"
        } else {
            body = "已成功安全释放 \(releasedBytes.byteStringCN) 空间！"
        }

        // 1. 若处于 App Bundle 环境，直接使用 NotificationManager
        if NotificationManager.isAppBundle {
            NotificationManager.shared.notifyCleanCompleted(releasedBytes: releasedBytes, failureCount: failures)
            return
        }

        // 2. 命令行/无头环境下，使用 osascript 发送原生横幅通知
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
