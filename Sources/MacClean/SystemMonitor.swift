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
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published var memory: MemoryStats = MemoryStats.current()

    private var timer: AnyCancellable?

    init() {
        refresh()
        setupTimer()
    }

    func refresh() {
        memory = MemoryStats.current()
    }

    private func setupTimer() {
        timer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refresh()
            }
    }
}
