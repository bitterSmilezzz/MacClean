import Foundation

// MARK: - APFS 硬链接 / 写时复制去重自检套件 (v1.47.0)

extension Selftest {
    static func suiteHardlinkDedupDeep() {
        print("==> 运行 APFS 硬链接无损去重深度自检 (v1.47.0)...")

        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacCleanHardlinkTest_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        let fileA = tempDir.appendingPathComponent("original_movie.mp4")
        let fileB = tempDir.appendingPathComponent("redundant_copy.mp4")
        let fileC = tempDir.appendingPathComponent("different_size.mp4")

        let sampleContent = "MacClean APFS Hardlink Lossless Deduplication Test Content 1234567890"
        try! sampleContent.write(to: fileA, atomically: true, encoding: .utf8)
        try! sampleContent.write(to: fileB, atomically: true, encoding: .utf8)
        try! "different".write(to: fileC, atomically: true, encoding: .utf8)

        // 1. 验证初始状态是两个独立的 inode
        check("硬链接去重：初始两份完全相同文件拥有不同 inode") {
            var statA = stat()
            var statB = stat()
            stat(fileA.path, &statA)
            stat(fileB.path, &statB)
            return statA.st_ino != statB.st_ino && statA.st_nlink == 1 && statB.st_nlink == 1
        }

        // 2. 执行硬链接原子替换
        check("硬链接去重：dedup 成功合并 inode 并释放物理字节") {
            guard let (succeeded, freed) = try? HardlinkDedupService.dedup(sourcePath: fileA.path, targetPath: fileB.path) else {
                return false
            }

            guard succeeded && freed > 0 else { return false }

            // 检查内容完整性
            guard let readBack = try? String(contentsOf: fileB, encoding: .utf8), readBack == sampleContent else {
                return false
            }

            // 检查 inode 与链接数
            var statA = stat()
            var statB = stat()
            stat(fileA.path, &statA)
            stat(fileB.path, &statB)

            return statA.st_ino == statB.st_ino && statA.st_nlink == 2 && statB.st_nlink == 2
        }

        // 3. 幂等性：已是硬链接时安全跳过且不报错
        check("硬链接去重：对已是硬链接的目标执行去重安全跳过 (freedBytes=0)") {
            guard let (succeeded, freed) = try? HardlinkDedupService.dedup(sourcePath: fileA.path, targetPath: fileB.path) else {
                return false
            }
            return succeeded == true && freed == 0
        }

        // 4. 安全防护：内容/大小不一致的文件拒绝去重
        check("硬链接去重：大小不一致的目标文件被安全拒绝") {
            do {
                _ = try HardlinkDedupService.dedup(sourcePath: fileA.path, targetPath: fileC.path)
                return false // 应该抛出错误
            } catch {
                return true
            }
        }

        // 5. 批量组去重逻辑测试 (dedupSelected)
        check("硬链接去重：DuplicateGroup 批量无损去重与结果统计") {
            let fileD = tempDir.appendingPathComponent("batch_source.bin")
            let fileE = tempDir.appendingPathComponent("batch_target.bin")
            let data = "BatchBinaryDataTesting123456"
            try! data.write(to: fileD, atomically: true, encoding: .utf8)
            try! data.write(to: fileE, atomically: true, encoding: .utf8)

            let itemD = DuplicateFileItem(
                path: fileD.path,
                name: "batch_source.bin",
                size: Int64(data.utf8.count),
                modificationDate: Date(),
                isSelected: false,
                isOriginal: true
            )

            let itemE = DuplicateFileItem(
                path: fileE.path,
                name: "batch_target.bin",
                size: Int64(data.utf8.count),
                modificationDate: Date(),
                isSelected: true,
                isOriginal: false
            )

            let group = DuplicateGroup(
                hash: "dummy_hash",
                fileSize: Int64(data.utf8.count),
                items: [itemD, itemE],
                matchKind: .exact
            )

            let result = HardlinkDedupService.dedupSelected(in: [group])
            guard result.succeededCount == 1 && result.freedBytes == Int64(data.utf8.count) else {
                return false
            }

            var statD = stat()
            var statE = stat()
            stat(fileD.path, &statD)
            stat(fileE.path, &statE)
            return statD.st_ino == statE.st_ino && statD.st_nlink == 2
        }
    }
}
