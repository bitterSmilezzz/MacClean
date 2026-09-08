import Foundation
import Combine

/// 磁盘低空间警戒与定时巡检配置
struct DiskMonitorConfig: Codable, Equatable {
    /// 是否开启定时自动巡检扫描
    var autoScanEnabled: Bool = true
    /// 定时巡检时间间隔（秒，默认 3 小时 = 10800s）
    var scanIntervalHours: Int = 3
    /// 是否开启磁盘低空间警戒提示
    var lowSpaceAlertEnabled: Bool = true
    /// 磁盘可用空间阈值低于该值时预警（单位 GB，默认 15 GB）
    var lowSpaceThresholdGB: Int = 15

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
}

/// 磁盘空间低警戒与定时后台巡检器
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

    /// 执行一次巡检与磁盘低空间评估
    func performAutoInspection() {
        guard let app else { return }
        app.refreshDisk()

        // 1. 低空间警戒判断
        checkDiskSpaceAlert(availableBytes: app.diskAvailable)

        // 2. 自动静默全部分类扫描
        if config.autoScanEnabled && !app.categories.contains(where: { $0.isScanning }) {
            app.scanAll()
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
