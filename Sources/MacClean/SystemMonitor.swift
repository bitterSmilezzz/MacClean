import Foundation
import Darwin
import Combine
import SwiftUI

/// 内存压力分级
enum MemoryPressureLevel: String, Codable {
    case normal = "正常"
    case moderate = "适中"
    case high = "紧张"

    var color: Color {
        switch self {
        case .normal: return Color.green
        case .moderate: return Color.orange
        case .high: return Color.red
        }
    }
}

/// 系统物理内存与分布快照
struct MemoryStats: Equatable {
    var totalBytes: UInt64 = 0
    var usedBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var appBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0

    var usageRatio: Double {
        totalBytes > 0 ? min(1.0, Double(usedBytes) / Double(totalBytes)) : 0
    }

    var pressure: MemoryPressureLevel {
        if usageRatio >= 0.85 {
            return .high
        } else if usageRatio >= 0.65 {
            return .moderate
        } else {
            return .normal
        }
    }

    var usedString: String { Int64(usedBytes).byteStringCN }
    var totalString: String { Int64(totalBytes).byteStringCN }
    var freeString: String { Int64(freeBytes).byteStringCN }
    var appString: String { Int64(appBytes).byteStringCN }
    var wiredString: String { Int64(wiredBytes).byteStringCN }
    var compressedString: String { Int64(compressedBytes).byteStringCN }

    /// 从系统底层 Mach 内核获取真实物理内存分布（与 macOS 活动监视器标准一致）
    static func current() -> MemoryStats {
        let total = ProcessInfo.processInfo.physicalMemory
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vmStats = vm_statistics64()
        let hostPort = mach_host_self()
        let ret = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        guard ret == KERN_SUCCESS else {
            return MemoryStats(totalBytes: total, usedBytes: 0, freeBytes: total, appBytes: 0, wiredBytes: 0, compressedBytes: 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let app = UInt64(vmStats.internal_page_count) * pageSize
        let wired = UInt64(vmStats.wire_count) * pageSize
        let compressed = UInt64(vmStats.compressor_page_count) * pageSize
        let used = app + wired + compressed
        let free = total > used ? total - used : 0

        return MemoryStats(
            totalBytes: total,
            usedBytes: used,
            freeBytes: free,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed
        )
    }
}

/// 系统运行状态与内存监控器
///
/// **轮询策略是这里最要紧的事**。原实现是"永远每 3 秒在主线程上刷新一次"：
/// 菜单栏常驻意味着这个定时器从 App 启动跑到退出，一秒不停。后果有两个：
///  1. 每 3 秒把 CPU 从空闲唤醒一次 —— 笔记本上实打实地费电；
///  2. `@Published` 触发 SwiftUI 重绘，**哪怕当前是"仅图标"模式、标签上根本没有动态内容**。
///
/// 现在按"用户看不看"分档：
///  - `.foreground`：菜单栏浮窗打开着，用户在盯着看 → 3 秒（与原行为一致）；
///  - `.background`：浮窗关着，但标签上显示磁盘/内存数值 → 15 秒；
///  - `.dormant`：浮窗关着且标签只有图标 → 根本不轮询（图标不会变）。
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    /// 轮询档位
    enum PollingMode {
        case foreground   // 浮窗开着，用户正在看
        case background   // 浮窗关着，但标签要显示数值
        case dormant      // 浮窗关着且标签无动态内容 —— 不需要轮询

        var interval: TimeInterval? {
            switch self {
            case .foreground: return 3
            case .background: return 15
            case .dormant: return nil
            }
        }
    }

    /// 各档位的轮询间隔（自检直接读取，避免测试里硬编码数字）
    static let foregroundInterval: TimeInterval = 3
    static let backgroundInterval: TimeInterval = 15

    @Published var memory: MemoryStats = MemoryStats.current()

    private var timer: AnyCancellable?
    private(set) var mode: PollingMode = .dormant

    init() {
        refresh()
        apply(mode: .dormant)
    }

    func refresh() {
        memory = MemoryStats.current()
    }

    /// 切换轮询档位。重复设置同一档位是幂等的，不会重建定时器。
    func apply(mode newMode: PollingMode) {
        guard newMode != mode || timer == nil else { return }
        mode = newMode
        timer?.cancel()
        timer = nil
        guard let interval = newMode.interval else { return }   // dormant：不轮询
        timer = Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }
}

extension SystemMonitor.PollingMode: Equatable {}
