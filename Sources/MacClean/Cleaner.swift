import Foundation

/// 清理执行器：默认移入废纸篓，可选择彻底删除（G3）
final class Cleaner {

    struct Result {
        var releasedBytes: Int64 = 0
        var succeeded: Int = 0
        var failures: [String] = []
        /// 失败的具体路径（供调用方按 item 保留/移除）
        var failedPaths: Set<String> = []
        /// 完全成功的 item id（供调用方精确过滤，二轮 #6）
        var succeededItemIDs: Set<UUID> = []
        /// 逐 item 实际释放字节（LOW-4：与 releasedBytes 口径一致，供跨分类精确记账）
        var releasedBytesByItem: [UUID: Int64] = [:]
    }

    /// 执行清理
    /// - Parameters:
    ///   - items: 已勾选的清理项
    ///   - permanently: 是否彻底删除（否则移入废纸篓）
    ///   - progress: 逐项进度回调（名称）
    static func clean(_ items: [CleanItem], permanently: Bool, progress: @escaping (String) -> Void) -> Result {
        var result = Result()
        let fm = FileManager.default

        for item in items {
            // 废纸篓内内容无法再移入废纸篓 → 强制彻底删除
            let forcePermanent = item.permanentDelete || permanently
            var itemFailedPaths: [String] = []
            var deletedAnyPath = false   // N4：至少实际删了一个路径才计字节
            var itemBytes: Int64 = 0     // LOW-4：逐 item 实际释放字节
            for path in item.paths {
                // 双保险：执行前再校验一次安全护栏（G1/G6）
                guard FileSystem.isSafeToClean(path) else {
                    itemFailedPaths.append(path)
                    continue
                }
                // 二轮 #4/#6：路径已不存在（如整目录先被删、或上次部分删除残留）→ 跳过而非失败
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    // 先取实际大小（删除后取不到），用于精确记账（LOW-4）
                    let actual = FileSystem.size(at: path)
                    let url = URL(fileURLWithPath: path)
                    if forcePermanent {
                        try fm.removeItem(at: url)
                    } else {
                        var resulting: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &resulting)
                    }
                    deletedAnyPath = true
                    itemBytes += actual
                } catch {
                    itemFailedPaths.append(path)
                }
            }
            // 按 item 计成功：全部路径删净（或已不存在）才算该项成功，避免多路径重复累加字节（M1）
            if itemFailedPaths.isEmpty {
                if deletedAnyPath { result.releasedBytes += itemBytes }
                result.succeeded += 1
                result.succeededItemIDs.insert(item.id)
                result.releasedBytesByItem[item.id] = itemBytes
            } else {
                for p in itemFailedPaths {
                    result.failedPaths.insert(p)
                    result.failures.append("\(item.name)：\(p)")
                }
            }
            progress(item.name)
        }
        return result
    }
}
