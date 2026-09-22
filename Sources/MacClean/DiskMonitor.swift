import Foundation
import Combine
import AppKit

/// 菜单栏助手常驻图标显示模式
enum MenuBarDisplayMode: String, Codable, CaseIterable, Identifiable {
    case iconOnly = "仅图标"
    case iconAndDisk = "图标 + 可用磁盘"
    case iconAndMemory = "图标 + 内存压力"

    var id: String { rawValue }
}

/// 磁盘低空间警戒、定时巡检与智能静默清理配置
struct DiskMonitorConfig: Codable, Equatable {
    /// 是否开启定时自动巡检扫描
    var autoScanEnabled: Bool = true
    /// 定时巡检时间间隔（小时，默认 3 小时 = 10800s）
    var scanIntervalHours: Int = 3
    /// 是否开启磁盘低空间警戒提示
    var lowSpaceAlertEnabled: Bool = true
    /// 磁盘可用空间阈值低于该值时预警（单位 GB，默认 15 GB）
    var lowSpaceThresholdGB: Int = 15

    /// 是否开启智能静默自动清理（仅自动清理 .safe 级别且非在用项）
    var autoCleanEnabled: Bool = false
    /// 免打扰时间段过滤（如仅在凌晨或夜间空闲时执行自动清理）
    var dndEnabled: Bool = true
    /// 免打扰开始小时（默认 23 点）
    var dndStartHour: Int = 23
    /// 免打扰结束小时（默认次日 7 点）
    var dndEndHour: Int = 7
    /// 智能清理分类：默认仅限最安全的用户缓存与日志临时文件
    var autoCleanUserCaches: Bool = true
    var autoCleanLogsAndTemp: Bool = true

    /// 是否开启系统级后台定时维护 (macOS LaunchAgent)
    var launchAgentEnabled: Bool = false
    /// LaunchAgent 调度触发频率
    var launchAgentFrequency: LaunchAgentFrequency = .daily
    /// 每天定点执行小时（0~23，默认 3 点）
    var launchAgentDailyHour: Int = 3
    /// 每天定点执行分钟（0~59，默认 0 分）
    var launchAgentDailyMinute: Int = 0
    /// 磁盘可用容量跌破警戒阈值时，是否自动触发自愈深度清理
    var autoHealOnLowSpace: Bool = true
    /// 自动清理是否纳入加权评分评定为高等级的智能推荐精选项
    var autoCleanSmartRecommended: Bool = true

    /// 菜单栏助手显示模式
    var menuBarDisplayMode: MenuBarDisplayMode = .iconOnly

    /// 全局快捷键呼出极速清理微面板 (v1.56.0)
    var globalHotkeyEnabled: Bool = true
    var globalHotkeyPreset: GlobalHotkeyPreset = .controlOptionSpace

    private static let key = "MacClean_DiskMonitorConfig"

    static func load() -> DiskMonitorConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(DiskMonitorConfig.self, from: data) else {
            return DiskMonitorConfig()
        }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: DiskMonitorConfig.key)
        }
        GlobalHotkeyManager.shared.setEnabled(globalHotkeyEnabled, preset: globalHotkeyPreset)
    }

    /// 判断指定时间是否处于允许静默执行的时段内
    func isWithinAllowedWindow(date: Date = Date()) -> Bool {
        guard dndEnabled else { return true }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        if dndStartHour <= dndEndHour {
            return hour >= dndStartHour && hour < dndEndHour
        } else {
            // 跨天窗口，如 23:00 至 07:00
            return hour >= dndStartHour || hour < dndEndHour
        }
    }
}

/// 磁盘空间低警戒、定时后台巡检与智能静默清理器
final class DiskMonitor: ObservableObject {
    static let shared = DiskMonitor()

    @Published var config: DiskMonitorConfig {
        didSet {
            config.save()
            rescheduleTimer()
            LaunchAgentManager.shared.syncWithConfig(config)
        }
    }

    /// 是否显示磁盘低空间警戒弹窗
    @Published var showLowSpaceAlert: Bool = false
    @Published var currentAvailableGB: Double = 0

    private var timer: AnyCancellable?
    private var sleepObserver: AnyCancellable?
    private var wakeObserver: AnyCancellable?
    private(set) var isSleeping: Bool = false
    weak var app: AppState?

    // MARK: - 低空间告警的节流状态
    //
    // 历史缺陷：`checkDiskSpaceAlert` 每次被调用都无条件发通知，而它挂在 `refreshDisk()` 上，
    // `refreshDisk()` 又在每个分类扫描结束时被调用 —— 于是 `scanAll` 会在几秒内连发 6 条
    // 低空间通知，之后每 3 小时再重复一轮，直到用户腾出空间为止。
    // 现在改成**边沿触发 + 冷却期**：跌破阈值时提醒一次，之后最多每 `lowSpaceCooldown` 再提醒一次。
    private var lastLowSpaceAlertAt: Date?
    private var wasLowSpace = false
    /// 告警冷却期：进入低空间状态后多久内不再重复提醒
    static let lowSpaceCooldown: TimeInterval = 6 * 3600

    /// 本轮静默清理最多等待扫描完成的轮数（每轮 1 秒）
    static let maxScanWaitAttempts = 120

    init() {
        self.config = DiskMonitorConfig.load()
        setupTimer()
        setupSleepWakeObservers()
    }

    private func setupSleepWakeObservers() {
        sleepObserver = NotificationCenter.default.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.handleWillSleep()
            }
        wakeObserver = NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.handleDidWake()
            }
    }

    /// 系统即将休眠：挂起巡检定时器
    func handleWillSleep() {
        guard !isSleeping else { return }
        isSleeping = true
        timer?.cancel()
        timer = nil
    }

    /// 系统已唤醒：恢复巡检定时器并触发一次磁盘刷新
    func handleDidWake() {
        guard isSleeping else { return }
        isSleeping = false
        setupTimer()
        app?.refreshDisk()
    }

    /// 重新设定定时器调度
    func rescheduleTimer() {
        timer?.cancel()
        setupTimer()
    }

    private func setupTimer() {
        guard config.autoScanEnabled, !isSleeping else { return }
        let interval = max(1, Double(config.scanIntervalHours) * 3600)
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.performAutoInspection()
            }
    }

    /// 执行一次巡检、低空间评估及合规下的智能静默清理
    func performAutoInspection() {
        guard let app else { return }
        app.refreshDisk()

        // 1. 低空间警戒判断
        checkDiskSpaceAlert(availableBytes: app.diskAvailable)

        // 2. 自动静默全部分类扫描
        if config.autoScanEnabled && !app.categories.contains(where: { $0.isScanning }) {
            // unattended：这一轮没人守在屏幕前，不能让主动探测弹出模态授权框把扫描挂住
            app.scanAll(unattended: true)

            // 3. 智能静默自动清理（若启用且处于设定允许时段）
            if config.autoCleanEnabled && config.isWithinAllowedWindow() {
                waitForScanCompletion()
            }
        }
    }

    /// 等待扫描真正结束再执行静默清理。
    ///
    /// 原实现是 `asyncAfter(deadline: .now() + 4.0)` 的**固定延时**：扫描在慢盘或大盘上
    /// 远超 4 秒时，清理会跑在"只扫了一半"的数据上——这一轮少清一点、下一轮再清一点，
    /// 行为不确定且难以复现。这里改成轮询等待 `isScanning` 全部落地，并设轮数上限兜底
    /// （扫不完就放弃本轮，绝不带着半份数据动手）。
    private func waitForScanCompletion(attempt: Int = 0) {
        guard let app else { return }
        if !app.categories.contains(where: { $0.isScanning }) {
            // 至少要有分类真的扫完过，否则空表清理没有意义
            if app.categories.contains(where: { $0.isScanned }) {
                performSilentAutoClean()
            }
            return
        }
        guard attempt < Self.maxScanWaitAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.waitForScanCompletion(attempt: attempt + 1)
        }
    }

    /// 智能静默清理：安全移入废纸篓，仅处理「可清理」结论、且长期未写入的指定分类项。
    ///
    /// 结论只认 `CleanItem.recommendation`（`.safe` 已蕴含"所属 App 未在运行"这一不变量），
    /// 这里不再拿 nature / usage 自己拼判断。`!usage.isRecentlyUsed` 是无人值守静默删除
    /// 额外加的保守门槛（与 `AppState.quickCleanSafeItems` 同一口径），它只会让清理更保守，
    /// 不改变也不覆盖结论本身。
    func performSilentAutoClean() {
        guard let app, !app.isCleaning else { return }
        var safeCandidates: [CleanItem] = []

        if config.autoCleanUserCaches {
            let st = app.state(for: .userCaches)
            safeCandidates.append(contentsOf: st.items.filter {
                $0.recommendation.isSafe && !$0.usage.isRecentlyUsed
            })
        }
        if config.autoCleanLogsAndTemp {
            let st = app.state(for: .logsAndTemp)
            safeCandidates.append(contentsOf: st.items.filter {
                $0.recommendation.isSafe && !$0.usage.isRecentlyUsed
            })
        }

        // 白名单硬过滤
        let whitelist = WhitelistManager.shared
        safeCandidates.removeAll { whitelist.isWhitelisted(path: $0.path) }

        guard !safeCandidates.isEmpty else { return }

        // 执行安全清理（非彻底删除，默认移入废纸篓以保万全）
        let result = Cleaner.clean(safeCandidates, permanently: false) { _ in }
        if result.succeeded > 0 {
            DispatchQueue.main.async {
                app.refreshDisk()
                app.recordClean(
                    categoryName: "智能静默定时清理",
                    itemCount: result.succeeded,
                    bytes: result.releasedBytes,
                    mode: "废纸篓",
                    failures: result.failures.count
                )
                NotificationManager.shared.notifyCleanCompleted(
                    releasedBytes: result.releasedBytes,
                    failureCount: result.failures.count
                )
            }
        }
    }

    /// 检查磁盘可用空间是否触发阈值警戒。
    ///
    /// **边沿触发 + 冷却期**，不是"每次调用都报"：
    /// - 空间恢复 → 重置状态，下次跌破时重新提醒；
    /// - 刚跌破 → 提醒一次；
    /// - 持续处于低空间 → 每个冷却期最多提醒一次，避免每 3 小时（以及每次扫描结束）骚扰用户。
    ///
    /// - Parameter now: 便于自检注入时间，正常调用不传。
    func checkDiskSpaceAlert(availableBytes: Int64, now: Date = Date()) {
        guard config.lowSpaceAlertEnabled else { return }
        let availGB = Double(availableBytes) / 1_000_000_000.0
        currentAvailableGB = availGB

        let isLow = availGB < Double(config.lowSpaceThresholdGB)
        guard isLow else {
            // 空间恢复：清掉状态，下次跌破重新提醒
            wasLowSpace = false
            lastLowSpaceAlertAt = nil
            return
        }

        // 首次跌破，或已过冷却期 → 提醒；弹窗已经立着就不再重复置位
        let isFirstEdge = !wasLowSpace
        let cooldownElapsed = lastLowSpaceAlertAt.map { now.timeIntervalSince($0) >= Self.lowSpaceCooldown } ?? true
        guard isFirstEdge || cooldownElapsed else { return }

        wasLowSpace = true
        lastLowSpaceAlertAt = now
        showLowSpaceAlert = true
        NotificationManager.shared.notifyLowDiskSpace(availableBytes: availableBytes,
                                                      thresholdGB: config.lowSpaceThresholdGB)
    }
}
