import Foundation

// MARK: - 重复大文件并发流水线哈希与轻量指纹缓存深度自检 (v1.49.0)

extension Selftest {
    static func suiteFingerprintPipelineDeep() {
        print("==> 运行重复大文件并发流水线哈希与轻量指纹缓存深度自检 (v1.49.0)...")

        // 1. 指纹缓存基础读写与分级哈希
        check("指纹缓存：三级哈希（头哈希/稀疏哈希/全量哈希）存储与读取一致性") {
            let cache = FileFingerprintCache()
            cache.clearMemory()
            let testPath = "/tmp/macclean_test_fingerprint_1.dat"
            let now = Date()
            let size: Int64 = 20480

            cache.resetStats()
            cache.put(
                path: testPath,
                size: size,
                mtime: now,
                headerHash: "head_abc123",
                sampledHash: "sample_def456",
                fullSHA256: "full_789xyz"
            )

            guard cache.count >= 1 else { return false }
            guard let hit = cache.get(path: testPath, size: size, mtime: now) else { return false }
            guard hit.headerHash == "head_abc123" &&
                    hit.sampledHash == "sample_def456" &&
                    hit.fullSHA256 == "full_789xyz" else {
                return false
            }

            guard cache.hitsCount == 1 && cache.savedBytes == size else { return false }

            // 未收录的路径应返回 nil 并增加 missesCount
            let missing = cache.get(path: "/tmp/non_existent.dat", size: 100, mtime: now)
            guard missing == nil && cache.missesCount == 1 else { return false }

            return true
        }

        // 2. mtime 与 fileSize 变更自适应失效
        check("指纹缓存：文件尺寸或修改时间改变时自动判定失效并淘汰陈旧项") {
            let cache = FileFingerprintCache()
            cache.clearMemory()
            let testPath = "/tmp/macclean_test_fingerprint_inval.dat"
            let date1 = Date(timeIntervalSince1970: 1000000.0)
            let date2 = Date(timeIntervalSince1970: 1000050.0) // 50秒后修改
            let size1: Int64 = 50000
            let size2: Int64 = 50001

            cache.put(path: testPath, size: size1, mtime: date1, fullSHA256: "sha_original")

            // 尺寸变动导致失效
            let sizeMiss = cache.get(path: testPath, size: size2, mtime: date1)
            guard sizeMiss == nil else { return false }

            // 重新写入后测试 mtime 变动失效
            cache.put(path: testPath, size: size1, mtime: date1, fullSHA256: "sha_original")
            let mtimeMiss = cache.get(path: testPath, size: size1, mtime: date2)
            guard mtimeMiss == nil else { return false }

            // 确认已从缓存中淘汰
            guard cache.get(path: testPath, size: size1, mtime: date1) == nil else { return false }
            return true
        }

        // 3. 磁盘原子化持久化与跨实例加载恢复
        check("指纹缓存：磁盘原子化存储与跨实例无缝加载还原") {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macclean_cache_test_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let cacheA = FileFingerprintCache(cacheDirectory: tempDir)
            cacheA.clearMemory()

            let now = Date()
            cacheA.put(path: "/test/fileA", size: 100, mtime: now, fullSHA256: "shaA")
            cacheA.put(path: "/test/fileB", size: 200, mtime: now, fullSHA256: "shaB")
            cacheA.saveToDisk()

            // 验证磁盘生成了 fingerprints.json
            let targetFile = tempDir.appendingPathComponent("fingerprints.json")
            guard FileManager.default.fileExists(atPath: targetFile.path) else { return false }

            // 实例 B 加载相同目录
            let cacheB = FileFingerprintCache(cacheDirectory: tempDir)

            guard cacheB.count == 2 else { return false }
            guard let itemA = cacheB.get(path: "/test/fileA", size: 100, mtime: now), itemA.fullSHA256 == "shaA" else {
                return false
            }
            guard let itemB = cacheB.get(path: "/test/fileB", size: 200, mtime: now), itemB.fullSHA256 == "shaB" else {
                return false
            }

            return true
        }

        // 4. 多线程并发读写安全性
        check("指纹缓存：多线程高并发读写与统计计数线程安全性") {
            let cache = FileFingerprintCache()
            cache.clearMemory()
            let now = Date()

            DispatchQueue.concurrentPerform(iterations: 128) { idx in
                let path = "/test/concurrent/\(idx % 16)"
                let size = Int64(1024 + (idx % 16))
                cache.put(path: path, size: size, mtime: now, fullSHA256: "sha_\(idx % 16)")
                _ = cache.get(path: path, size: size, mtime: now)
            }

            guard cache.count == 16 else { return false }
            guard cache.hitsCount > 0 else { return false }
            return true
        }

        // 5. 端到端流水线哈希并发扫描与二次秒级缓存命中
        check("并发流水线：重复文件端到端并发哈希识别与二次扫描缓存秒级命中") {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("macclean_dup_test_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }

            // 构建测试文件：file1 和 file2 完全相同（16KB），file3 不同（16KB）
            let data1 = Data(repeating: 0x4D, count: 16384)
            var data2 = Data(repeating: 0x4E, count: 16384)
            data2[100] = 0x55

            let file1 = tempDir.appendingPathComponent("dup1.bin")
            let file2 = tempDir.appendingPathComponent("dup2.bin")
            let file3 = tempDir.appendingPathComponent("diff.bin")

            try? data1.write(to: file1)
            try? data1.write(to: file2)
            try? data2.write(to: file3)

            // 第一次扫描：冷扫描构建指纹
            let groupsCold = DuplicateScanner.scanDuplicates(
                in: [tempDir.path],
                minSize: 1024,
                isCancelled: { false },
                progress: { _, _ in }
            )

            // 应成功识别出 1 个重复组，包含 dup1 和 dup2
            guard groupsCold.count == 1 else { return false }
            guard groupsCold[0].items.count == 2 else { return false }

            // 重置统计指标
            FileFingerprintCache.shared.resetStats()

            // 第二次扫描：热扫描（指纹缓存命中）
            let groupsHot = DuplicateScanner.scanDuplicates(
                in: [tempDir.path],
                minSize: 1024,
                isCancelled: { false },
                progress: { _, _ in }
            )

            guard groupsHot.count == 1 else { return false }
            guard groupsHot[0].items.count == 2 else { return false }

            // 验证命中缓存且节省了磁盘 I/O 字节
            let hits = FileFingerprintCache.shared.hitsCount
            let saved = FileFingerprintCache.shared.savedBytes
            guard hits >= 2 && saved >= 32768 else { return false }

            return true
        }
    }
}
