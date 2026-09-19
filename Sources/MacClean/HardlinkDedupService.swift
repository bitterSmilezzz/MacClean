import Foundation

// MARK: - 硬链接 / 写时复制去重结果

struct HardlinkDedupResult: Equatable {
    var succeededCount: Int = 0
    var freedBytes: Int64 = 0
    var skippedCount: Int = 0
    var failures: [String] = []

    init(succeededCount: Int = 0, freedBytes: Int64 = 0, skippedCount: Int = 0, failures: [String] = []) {
        self.succeededCount = succeededCount
        self.freedBytes = freedBytes
        self.skippedCount = skippedCount
        self.failures = failures
    }

    var summaryText: String {
        var parts: [String] = []
        if succeededCount > 0 {
            parts.append("成功无损硬链接去重 \(succeededCount) 个副本，释放物理空间 \(freedBytes.byteStringCN)")
        }
        if skippedCount > 0 {
            parts.append("\(skippedCount) 项已是硬链接已跳过")
        }
        if !failures.isEmpty {
            parts.append("\(failures.count) 项去重失败")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - APFS 硬链接 / 写时复制克隆无损去重引擎

enum HardlinkDedupService {

    /// 对单对完全相同的重复文件执行硬链接替换
    ///
    /// - Parameters:
    ///   - sourcePath: 推荐保留的主文件绝对路径
    ///   - targetPath: 待去重的重复副本绝对路径
    /// - Returns: 是否成功及释放的字节数（若原本非同一 inode 则释放文件大小）
    static func dedup(sourcePath: String, targetPath: String) throws -> (succeeded: Bool, freedBytes: Int64) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: sourcePath) else {
            throw NSError(domain: "HardlinkDedup", code: 404, userInfo: [NSLocalizedDescriptionKey: "源文件不存在: \(sourcePath)"])
        }
        guard fm.fileExists(atPath: targetPath) else {
            throw NSError(domain: "HardlinkDedup", code: 404, userInfo: [NSLocalizedDescriptionKey: "目标副本不存在: \(targetPath)"])
        }
        guard sourcePath != targetPath else {
            return (false, 0)
        }

        // 1. 获取 stat 检查设备号与 inode
        var srcStat = stat()
        var tgtStat = stat()

        guard stat(sourcePath, &srcStat) == 0 else {
            throw NSError(domain: "HardlinkDedup", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法获取源文件属性: \(sourcePath)"])
        }
        guard stat(targetPath, &tgtStat) == 0 else {
            throw NSError(domain: "HardlinkDedup", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法获取目标文件属性: \(targetPath)"])
        }

        // 检查是否必须在同一磁盘宗卷/设备
        guard srcStat.st_dev == tgtStat.st_dev else {
            throw NSError(domain: "HardlinkDedup", code: 3, userInfo: [NSLocalizedDescriptionKey: "源文件与目标副本不在同一磁盘宗卷，无法建立硬链接"])
        }

        // 检查是否已经是同一 inode（已是硬链接）
        if srcStat.st_ino == tgtStat.st_ino {
            return (true, 0) // 已经共享数据块，无需重复处理
        }

        // 检查文件大小是否一致
        guard srcStat.st_size == tgtStat.st_size else {
            throw NSError(domain: "HardlinkDedup", code: 4, userInfo: [NSLocalizedDescriptionKey: "文件大小不一致，安全拒绝硬链接去重"])
        }

        let fileSize = srcStat.st_size

        // 2. 原子化硬链接替换：创建临时硬链接 -> rename 覆盖目标
        let tempLinkPath = targetPath + ".macclean_dedup_tmp_\(UUID().uuidString)"

        // link(source, temp)
        if link(sourcePath, tempLinkPath) != 0 {
            let err = String(cString: strerror(errno))
            throw NSError(domain: "HardlinkDedup", code: 5, userInfo: [NSLocalizedDescriptionKey: "创建硬链接失败: \(err)"])
        }

        // rename(temp, target)
        if rename(tempLinkPath, targetPath) != 0 {
            let err = String(cString: strerror(errno))
            unlink(tempLinkPath) // 清理临时链接
            throw NSError(domain: "HardlinkDedup", code: 6, userInfo: [NSLocalizedDescriptionKey: "覆盖替换目标副本失败: \(err)"])
        }

        return (true, fileSize)
    }

    /// 批量对选中的完全一致重复文件执行硬链接去重
    static func dedupSelected(in groups: [DuplicateGroup]) -> HardlinkDedupResult {
        var result = HardlinkDedupResult()

        for group in groups {
            guard group.matchKind == .exact else {
                continue // 只对内容 100% 精确一致的组执行无损硬链接去重
            }

            // 寻找推荐主文件
            guard let original = group.items.first(where: { $0.isOriginal }) ?? group.items.first(where: { !$0.isSelected }) ?? group.items.first else {
                continue
            }

            for item in group.items where item.isSelected && item.id != original.id {
                do {
                    let (succeeded, freed) = try dedup(sourcePath: original.path, targetPath: item.path)
                    if succeeded {
                        if freed > 0 {
                            result.succeededCount += 1
                            result.freedBytes += freed
                        } else {
                            result.skippedCount += 1
                        }
                    }
                } catch {
                    result.failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
        }

        return result
    }
}
