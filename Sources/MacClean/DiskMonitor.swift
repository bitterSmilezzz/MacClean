import Foundation
import Combine

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
        }
    }

    /// 是否显示磁盘低空间警戒弹窗
    @Published var showLowSpaceAlert: Bool = false
    @Published var currentAvailableGB: Double = 0

    private var timer: AnyCancellable?
    weak var app: AppState?

    init() {
        self.config = DiskMonitorConfig.load()
        setupTimer()
    }

    /// 重新设定定时器调度
    func rescheduleTimer() {
        timer?.cancel()
        setupTimer()
    }

    private func setupTimer() {
        guard config.autoScanEnabled else { return }
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
            app.scanAll()

            // 3. 智能静默自动清理（若启用且处于设定允许时段）
            if config.autoCleanEnabled && config.isWithinAllowedWindow() {
                // 等待各分类扫描就绪后择机安全清理
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                    self?.performSilentAutoClean()
                }
            }
        }
    }

    /// 智能静默清理：安全移入废纸篓，仅处理 .safe 级别、不在使用中的指定分类项
    func performSilentAutoClean() {
        guard let app, !app.isCleaning else { return }
        var safeCandidates: [CleanItem] = []

        if config.autoCleanUserCaches {
            let st = app.state(for: .userCaches)
            safeCandidates.append(contentsOf: st.items.filter { $0.risk == .safe && !$0.usage.isRecentlyUsed })
        }
        if config.autoCleanLogsAndTemp {
            let st = app.state(for: .logsAndTemp)
            safeCandidates.append(contentsOf: st.items.filter { $0.risk == .safe && !$0.usage.isRecentlyUsed })
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

    /// 检查磁盘可用空间是否触发阈值警戒
    func checkDiskSpaceAlert(availableBytes: Int64) {
        guard config.lowSpaceAlertEnabled else { return }
        let availGB = Double(availableBytes) / 1_000_000_000.0
        currentAvailableGB = availGB

        if availGB < Double(config.lowSpaceThresholdGB) {
            showLowSpaceAlert = true
            NotificationManager.shared.notifyLowDiskSpace(availableBytes: availableBytes, thresholdGB: config.lowSpaceThresholdGB)
        }
    }
}
