import Foundation

/// 清理执行器：默认移入废纸篓，可选择彻底删除（G3）
final class Cleaner {

    struct Result {
        var releasedBytes: Int64 = 0
        var succeeded: Int = 0
        var failures: [String] = []
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
            var itemOK = true
            for path in item.paths {
                // 双保险：执行前再校验一次安全护栏（G1/G6）
                guard FileSystem.isSafeToClean(path), FileManager.default.fileExists(atPath: path) else {
                    result.failures.append("\(item.name)：路径不安全或不存在（\(path)）")
                    itemOK = false
                    continue
                }
                do {
                    let url = URL(fileURLWithPath: path)
                    if forcePermanent {
                        try fm.removeItem(at: url)
                    } else {
                        var resulting: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &resulting)
                    }
                    result.releasedBytes += item.size
                    result.succeeded += 1
                    itemOK = true
                } catch {
                    result.failures.append("\(item.name)：\(error.localizedDescription)")
                    itemOK = false
                }
            }
            progress(item.name)
            _ = itemOK
        }
        return result
    }
}
