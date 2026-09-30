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
        /// 移入废纸篓的项目快照（v1.35.0：供 Undo / 放回原位使用）
        var trashedSnapshots: [TrashedItemEntry] = []
        /// `releasedBytes` 里**只是搬进废纸篓**的那部分：同卷 rename，磁盘可用量一分没动。
        /// 一次清理里可以两种落点并存——已在废纸篓里的条目会强制彻底删除。
        var trashedBytes: Int64 = 0

        /// 这批字节究竟落到哪儿了。「释放了多少」这句话只能由它出口。
        var space: SpaceDisposition {
            SpaceDisposition(reclaimed: releasedBytes - trashedBytes, trashed: trashedBytes)
        }
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
            var itemTrashedBytes: Int64 = 0   // 其中只是搬进废纸篓、磁盘还没落定的部分
            for path in item.paths {
                // ⚠ 顺序就是这条 P0：**必须先对未解析的原路径判软链，再解析**。
                //   以前这里是先 `realPath(path)`、后 `isSafeToClean(target)`，而
                //   `isSafeToClean` 的第一层恰恰是 `isSymlink(path)`（`FileSystem.swift:1374`）——
                //   拿已经解析完的路径去问"你是不是软链"永远是"不是"，
                //   于是 G14 那条"软链防跳板"在主链路上**一次都没生效过**。
                //   它漏掉的不是"删到受保护位置"（解析后的目标仍要过闸门），而是更隐蔽的一种：
                //   **删掉列表上根本没写的那个东西**。一项写着 `~/Downloads/report.pdf`、
                //   实际是一条指向 `~/Documents/合同.pdf` 的软链，被删的是合同那份；
                //   而撤销快照记的也是目标路径，用户看到的"已清理 1 项"其实是"清掉了别处的文件"。
                //   残留（已知、未在本条修掉）：中间某一级目录本身是软链时仍会跳，
                //   扫描侧靠 `isRealDir` 不下钻，所以只有"卡片自己拼出来的路径"会撞上，
                //   已记进 `docs/OPTIMIZATION-PLAN.md`。
                guard !FileSystem.isSymlink(path) else {
                    itemFailedPaths.append(path)
                    continue
                }
                // 之后校验与删除都作用于同一个解析结果。
                // 为什么必须共用：若"校验时解析一次、删除时再解析一次"，
                // 两次解析之间路径被换成软链就出现了 TOCTOU 缝隙。
                let target = FileSystem.realPath(path)

                // 双保险：执行前再校验一次安全护栏（G1/G6/G8，含软链防跳板）
                guard FileSystem.isSafeToClean(target) else {
                    itemFailedPaths.append(path)
                    continue
                }
                // 二轮 #4/#6：路径已不存在（如整目录先被删、或上次部分删除残留）→ 跳过而非失败
                guard FileManager.default.fileExists(atPath: target) else { continue }
                do {
                    // 先取实际大小（删除后取不到），用于精确记账（LOW-4）
                    let actual = FileSystem.size(at: target)
                    let url = URL(fileURLWithPath: target)
                    if forcePermanent {
                        try fm.removeItem(at: url)
                    } else {
                        var resulting: NSURL?
                        try fm.trashItem(at: url, resultingItemURL: &resulting)
                        if let trashPath = (resulting as URL?)?.path {
                            result.trashedSnapshots.append(TrashedItemEntry(
                                originalPath: target,
                                trashPath: trashPath,
                                size: actual,
                                itemName: item.name
                            ))
                        }
                    }
                    deletedAnyPath = true
                    itemBytes += actual
                    // `trashItem` 在同一卷上只是一次 rename：字节还占着磁盘。
                    // 本机实测（`volumeAvailableCapacityForImportantUsage`，与界面同一格读数）
                    // 200 MiB 同卷 rename 之后 Δ = 0 MiB，`removeItem` 之后 Δ = +200 MiB。
                    if !forcePermanent { itemTrashedBytes += actual }
                    // 让测量缓存失效：否则紧接着的重新扫描会命中旧值，
                    // 给已经删掉的目录报出删除前的体积
                    FileSystem.invalidateMeasurements(for: [target])
                } catch {
                    itemFailedPaths.append(path)
                }
            }
            // 按 item 计成功：全部路径删净（或已不存在）才算该项成功，避免多路径重复累加字节（M1）
            if itemFailedPaths.isEmpty {
                if deletedAnyPath {
                    result.releasedBytes += itemBytes
                    result.trashedBytes += itemTrashedBytes
                }
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
