import Foundation
import AppKit

// MARK: - 外接卷信息模型

struct ExternalVolumeInfo: Identifiable, Equatable, Hashable {
    let id: String           // 挂载路径
    let name: String         // 卷宗名称
    let path: String         // 挂载路径
    let availableBytes: Int64
    let totalBytes: Int64
    let isRemovable: Bool

    var formattedAvailable: String {
        availableBytes.byteStringCN
    }

    var formattedTotal: String {
        totalBytes.byteStringCN
    }
}

// MARK: - 归档与迁移结果模型

struct ArchiveResult: Equatable {
    let success: Bool
    let archivePath: String
    let originalSize: Int64
    let archiveSize: Int64
    let savedBytes: Int64
    let deletedOriginal: Bool
    let errorMessage: String?

    var ratioString: String {
        guard originalSize > 0 else { return "100%" }
        let pct = (Double(archiveSize) / Double(originalSize)) * 100.0
        return String(format: "%.1f%%", pct)
    }
}

struct MigrationResult: Equatable {
    let success: Bool
    let destinationPath: String
    let migratedBytes: Int64
    let deletedOriginal: Bool
    let errorMessage: String?
}

// MARK: - 空间透视归档与迁移服务

final class SpaceArchiveService {
    static let shared = SpaceArchiveService()

    private init() {}

    /// ditto 打包/复制是**按体积**跑的，不能套 `SafeProcess` 那个 10 秒默认值——那是给
    /// `mdutil`/`launchctl` 这类瞬时命令用的，用在这里会把正常的大目录判成超时。
    /// 60 分钟够跑完上百 GB（内盘归档）到慢速 USB 卷复制；重点是**有界**：
    /// 旧写法完全没有界，ditto 把 stderr 写满约 64 KB 就父子互等，`isArchiving` 永不复位。
    static let dittoTimeout: TimeInterval = 60 * 60

    // MARK: - 外接存储设备探测

    /// 检测本机当前挂载的可用外接驱动器 / 卷宗
    func detectExternalVolumes() -> [ExternalVolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeAvailableCapacityKey,
            .volumeTotalCapacityKey,
            .volumeIsLocalKey
        ]

        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []

        var results: [ExternalVolumeInfo] = []

        for url in volumes {
            let path = url.path
            // 排除根目录与系统内部保护分区
            if path == "/" || path == "/System" { continue }

            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? (path as NSString).lastPathComponent
            let isInternal = values?.volumeIsInternal ?? true
            let isRemovable = values?.volumeIsRemovable ?? false
            let available = Int64(values?.volumeAvailableCapacity ?? 0)
            let total = Int64(values?.volumeTotalCapacity ?? 0)

            // 过滤掉 Macintosh HD 内部数据宗卷与恢复卷
            let lowerName = name.lowercased()
            if lowerName.contains("macintosh hd") || lowerName.contains("update") || lowerName.contains("vm") || lowerName.contains("preboot") {
                continue
            }

            // 优先接纳 /Volumes/ 下的独立外挂卷或被标记为可移动/非内部的存储
            if path.hasPrefix("/Volumes/") || !isInternal || isRemovable {
                results.append(ExternalVolumeInfo(
                    id: path,
                    name: name,
                    path: path,
                    availableBytes: available,
                    totalBytes: total,
                    isRemovable: isRemovable || !isInternal
                ))
            }
        }

        return results.sorted {
            if $0.isRemovable != $1.isRemovable {
                return $0.isRemovable && !$1.isRemovable
            }
            return $0.availableBytes > $1.availableBytes
        }
    }

    // MARK: - 原位压缩归档

    /// 将指定超大陈旧目录/文件原地打包压缩为 .zip
    /// - Parameters:
    ///   - sourcePath: 目标源路径
    ///   - deleteOriginal: 压缩成功后是否将原件移入废纸篓（默认 true）
    func archiveInPlace(sourcePath: String, deleteOriginal: Bool = true) -> ArchiveResult {
        let expanded = CleanPaths.expand(sourcePath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: expanded) else {
            return ArchiveResult(success: false, archivePath: "", originalSize: 0, archiveSize: 0, savedBytes: 0, deletedOriginal: false, errorMessage: "源文件不存在")
        }

        // 路径安全判定（不可压缩根目录或关键系统目录）
        guard isSafeToArchive(expanded) else {
            return ArchiveResult(success: false, archivePath: "", originalSize: 0, archiveSize: 0, savedBytes: 0, deletedOriginal: false, errorMessage: "该路径受系统核心保护，禁止归档")
        }

        if expanded.lowercased().hasSuffix(".zip") {
            return ArchiveResult(success: false, archivePath: expanded, originalSize: 0, archiveSize: 0, savedBytes: 0, deletedOriginal: false, errorMessage: "该文件本身已是 Zip 压缩包")
        }

        let originalSize = FileSystem.size(at: expanded)
        guard originalSize > 0 else {
            return ArchiveResult(success: false, archivePath: "", originalSize: 0, archiveSize: 0, savedBytes: 0, deletedOriginal: false, errorMessage: "目标为空，无需归档")
        }

        // 推导目标 Zip 存储路径
        let destZipPath = generateUniqueZipPath(for: expanded)

        // 调用原生 ditto 打包（--sequesterRsrc 保留 resource forks 与扩展属性，--keepParent 维持顶层文件夹根名）
        let ditto = SafeProcess.run("/usr/bin/ditto",
                                    ["-c", "-k", "--sequesterRsrc", "--keepParent", expanded, destZipPath],
                                    timeout: Self.dittoTimeout)
            ?? SafeProcess.Result(exitCode: -1, output: "ditto 未能启动")
        guard ditto.exitCode == 0, !ditto.timedOut, fm.fileExists(atPath: destZipPath) else {
            // 半截压缩包一律清掉，原件**绝不**移动
            try? fm.removeItem(atPath: destZipPath)
            let message: String
            if ditto.timedOut {
                message = "ditto 超过 \(Int(Self.dittoTimeout / 60)) 分钟仍未完成，已强制终止（原件未移动，半截压缩包已删除）"
            } else {
                let err = ditto.output.trimmingCharacters(in: .whitespacesAndNewlines)
                message = err.isEmpty ? "ditto 执行异常（退出码 \(ditto.exitCode)）" : err
            }
            return ArchiveResult(success: false, archivePath: "", originalSize: originalSize,
                                 archiveSize: 0, savedBytes: 0, deletedOriginal: false,
                                 errorMessage: message)
        }

        let archiveSize = FileSystem.size(at: destZipPath)
        let savedBytes = max(0, originalSize - archiveSize)

        var didDelete = false
        if deleteOriginal {
            // 压缩包按设计就比原件小，没法用体积比判"复制完整"，改判 ZIP 结构：
            // 中途写失败会留下**没有中央目录**的残缺包，看着生成成功、实际一个文件
            // 都解不出来。校验不过就保留原件，并清掉这个会误导用户的残缺包。
            guard isZipStructurallyIntact(destZipPath, size: archiveSize) else {
                try? fm.removeItem(atPath: destZipPath)
                return ArchiveResult(
                    success: false, archivePath: "", originalSize: originalSize,
                    archiveSize: 0, savedBytes: 0, deletedOriginal: false,
                    errorMessage: "压缩包校验未通过（缺少中央目录），原件已保留")
            }
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: expanded), resultingItemURL: &resultingURL)
                didDelete = true
            } catch {
                // 原件入废纸篓失败不影响压缩包已就绪事实
                didDelete = false
            }
        }

        return ArchiveResult(
            success: true,
            archivePath: destZipPath,
            originalSize: originalSize,
            archiveSize: archiveSize,
            savedBytes: savedBytes,
            deletedOriginal: didDelete,
            errorMessage: nil
        )
    }

    // MARK: - 外接盘文件安全迁移

    /// 将指定超大文件/目录迁移至外接驱动器
    func migrateToVolume(sourcePath: String, targetVolumePath: String, deleteOriginal: Bool = true) -> MigrationResult {
        let expanded = CleanPaths.expand(sourcePath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: expanded) else {
            return MigrationResult(success: false, destinationPath: "", migratedBytes: 0, deletedOriginal: false, errorMessage: "源路径不存在")
        }

        guard fm.fileExists(atPath: targetVolumePath) else {
            return MigrationResult(success: false, destinationPath: "", migratedBytes: 0, deletedOriginal: false, errorMessage: "目标外接卷未就绪或已拔出")
        }

        guard isSafeToArchive(expanded) else {
            return MigrationResult(success: false, destinationPath: "", migratedBytes: 0, deletedOriginal: false, errorMessage: "系统受保护关键文件禁止迁移")
        }

        let sourceSize = FileSystem.size(at: expanded)
        let fileName = (expanded as NSString).lastPathComponent
        // 落点必须**未被占用**：目标卷上叫这个名字的很可能是用户自己的旧副本，
        // 而下面的失败分支会删掉这个路径。旧实现直接拼死路径，等于"迁移一失败就删用户既有目录"。
        let destPath = Self.uniqueDestination(in: targetVolumePath, named: fileName)

        // 检查外接卷剩余容量
        let volAttrs = try? fm.attributesOfFileSystem(forPath: targetVolumePath)
        if let freeSize = volAttrs?[.systemFreeSize] as? Int64, freeSize < sourceSize {
            return MigrationResult(success: false, destinationPath: "", migratedBytes: 0, deletedOriginal: false, errorMessage: "外接卷剩余空间不足（需要 \(sourceSize.byteStringCN)，仅剩 \(freeSize.byteStringCN)）")
        }

        // 使用 ditto 保真复制。注意**不能带 `--sequesterRsrc`**：该 flag 只在 PKZip
        // （`-c -k`）形态下合法，复制形态下 ditto 在解析参数阶段就直接退出
        // （`ditto: --sequesterRsrc is only for PKZip archives`），迁移一个字节都不会复制。
        // ditto 的复制形态本身就保留 resource fork / ACL / xattr，不需要这个 flag。
        let ditto = SafeProcess.run("/usr/bin/ditto", [expanded, destPath],
                                    timeout: Self.dittoTimeout)
            ?? SafeProcess.Result(exitCode: -1, output: "ditto 未能启动")
        guard ditto.exitCode == 0, !ditto.timedOut, fm.fileExists(atPath: destPath) else {
            // 只可能删到我们刚建的那个落点（见上）
            try? fm.removeItem(atPath: destPath)
            let message: String
            if ditto.timedOut {
                message = "ditto 超过 \(Int(Self.dittoTimeout / 60)) 分钟仍未完成，已强制终止（原件未移动，残缺副本已删除）"
            } else {
                let err = ditto.output.trimmingCharacters(in: .whitespacesAndNewlines)
                message = err.isEmpty ? "ditto 复制未成功（退出码 \(ditto.exitCode)）" : err
            }
            return MigrationResult(success: false, destinationPath: "", migratedBytes: 0,
                                   deletedOriginal: false, errorMessage: message)
        }

        var didDelete = false
        if deleteOriginal {
            // 删原件之前先验复制完整性：`ditto` 退出码 0 不代表目标字节数对得上
            // （外接卷在写入过程中被填满、中途拔盘都可能留下截断副本）。
            // 跨卷的块大小不同会让"分配体积"有出入，因此用 95% 下限而不是严格相等，
            // 宁可少删一次（用户可重试），也不能把原件删成一个残缺副本。
            let copied = FileSystem.size(at: destPath)
            guard copied > 0, copied >= sourceSize * 95 / 100 else {
                return MigrationResult(
                    success: false, destinationPath: destPath, migratedBytes: copied,
                    deletedOriginal: false,
                    errorMessage: "副本校验未通过（源 \(sourceSize.byteStringCN) / 副本 \(copied.byteStringCN)），原件已保留")
            }
            do {
                var resultingURL: NSURL?
                try fm.trashItem(at: URL(fileURLWithPath: expanded), resultingItemURL: &resultingURL)
                didDelete = true
            } catch {
                didDelete = false
            }
        }

        return MigrationResult(
            success: true,
            destinationPath: destPath,
            migratedBytes: sourceSize,
            deletedOriginal: didDelete,
            errorMessage: nil
        )
    }

    // MARK: - 迁移脚本生成

    /// 生成自动化外接盘迁移 Shell 脚本
    func generateMigrationScript(for sourcePath: String, targetVolumePath: String? = nil) -> String {
        let expanded = CleanPaths.expand(sourcePath)
        let fileName = (expanded as NSString).lastPathComponent
        let defaultDest = targetVolumePath ?? "/Volumes/YourExternalDrive"
        let nowStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let size = FileSystem.size(at: expanded).byteStringCN

        return """
        #!/bin/bash
        # ==============================================================================
        # MacClean 空间透视超大文件/目录外接盘安全迁移脚本
        # 源目标: \(fileName) (\(size))
        # 生成时间: \(nowStr)
        # ==============================================================================
        set -euo pipefail

        SRC="\(expanded)"
        DEST_VOL="${1:-\(defaultDest)}"

        echo "==> 检查源文件存在性..."
        if [ ! -e "$SRC" ]; then
            echo "❌ 错误: 源路径不存在: $SRC" >&2
            exit 1
        fi

        echo "==> 检查目标存储就绪状态: $DEST_VOL"
        if [ ! -d "$DEST_VOL" ]; then
            echo "❌ 错误: 目标外接卷未挂载: $DEST_VOL" >&2
            echo "💡 提示: 请插入外接移动硬盘，并传入挂载路径，例如: $0 /Volumes/MyPassport" >&2
            exit 1
        fi

        echo "==> 开始通过 rsync 安全腾挪原件并释放本地空间..."
        if rsync -avP --remove-source-files "$SRC" "$DEST_VOL/"; then
            echo "=============================================================================="
            echo "✅ 迁移成功！本地占用已释放 (\(size))"
            echo "📁 目标位置: $DEST_VOL/\(fileName)"
            echo "=============================================================================="
        else
            echo "❌ 迁移过程中出现异常，已保留本地原文件。" >&2
            exit 2
        fi
        """
    }

    // MARK: - 辅助与安全校验

    /// ZIP 结构完整性核验：末尾是否含中央目录结束标记（EOCD，`PK\x05\x06`）。
    private func isZipStructurallyIntact(_ path: String, size: Int64) -> Bool {
        guard size > 22 else { return false }
        // EOCD 定长 22 字节 + 最多 65535 字节注释，只需回看尾部这一小段
        let tail = min(size, 65_557)
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        do {
            handle.seek(toFileOffset: UInt64(size - tail))
            guard let data = try handle.read(upToCount: Int(tail)), data.count >= 22 else { return false }
            return data.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: [.backwards]) != nil
        } catch {
            return false
        }
    }

    /// 归档/迁移的强度必须等同**删除**护栏：这两条路径在复制成功后都会把原件
    /// 移进废纸篓（`deleteOriginal` 默认 true）。
    ///
    /// 原实现只挡住几个危险根的**字面相等**（`norm == "/Library"`），于是
    /// `/Library/Printers`、`~/Library/Mail`、`~/Library/Keychains` 全都放行；
    /// 用的又是 `standardizingPath`（会依路径是否存在改变形态，`/private/var` 与
    /// `/var` 匹配不上），也不查 G6 用户数据硬排除与用户白名单。
    private func isSafeToArchive(_ path: String) -> Bool {
        if FileSystem.isSymlink(path) { return false }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        guard !real.isEmpty, real != "/" else { return false }
        // G8 系统硬保护 + G6 用户数据硬排除 + 用户自定义白名单
        if FileSystem.coreGuardVerdict(real) != nil { return false }
        // 主目录与临时目录内：直接吃统一护栏（含"不许是家目录本身"）
        if FileSystem.governanceVerdictWithinHome(path).isAllowed { return true }
        // 外接卷：只允许卷下的具体条目（禁卷根），且已通过上面三道护栏
        let volumes = FileSystem.normalizePath("/Volumes")
        guard real.hasPrefix(volumes + "/") else { return false }
        return real.dropFirst(volumes.count).split(separator: "/").count >= 2
    }

    private func generateUniqueZipPath(for sourcePath: String) -> String {
        let fm = FileManager.default
        let baseZip = sourcePath + ".zip"
        if !fm.fileExists(atPath: baseZip) {
            return baseZip
        }

        let dateStr = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let candidate = "\(sourcePath) (Archived \(dateStr)).zip"
        if !fm.fileExists(atPath: candidate) {
            return candidate
        }

        return "\(sourcePath) (\(UUID().uuidString.prefix(6))).zip"
    }

    /// 目标卷下**未被占用**的落点（与 `generateUniqueZipPath` 同形）。
    /// 迁移的失败分支会删掉这个路径，所以它必须是"刚新建的"，不能是用户已有的同名目录。
    static func uniqueDestination(in volume: String, named fileName: String) -> String {
        let fm = FileManager.default
        let base = (volume as NSString).appendingPathComponent(fileName)
        guard fm.fileExists(atPath: base) else { return base }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let candidate = (volume as NSString).appendingPathComponent("\(fileName) (Migrated \(stamp))")
        guard fm.fileExists(atPath: candidate) else { return candidate }
        return candidate + "-\(UUID().uuidString.prefix(6))"
    }
}
