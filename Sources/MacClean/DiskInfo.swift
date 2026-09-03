import Foundation

enum DiskInfo {
    /// 磁盘总容量 / 可用容量（字节）
    static func volumes() -> (total: Int64, available: Int64)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: [URLResourceKey] = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return (Int64(total), Int64(available))
    }

    static var home: String { NSHomeDirectory() }
}
