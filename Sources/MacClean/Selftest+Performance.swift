import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：性能基准
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 2395–2423）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suitePerformance() {
        // MARK: - 并发安全
        //
        // `AppState.scanAll` 会把 6 个分类**同时**丢进 `DispatchQueue.global`，
        // 每个分类内部的每一项又会去碰共享缓存（运行中 App 别名、测量结果、已安装 App 集合）。
        // 这些共享状态此前有几处是无锁的——下面把它压出来。

        check("性能基准：渲染热路径的 recommendation 求值开销") {
            // 这不是断言"快"，而是把开销**量出来**：日志分类实测 548 项，
            // 渲染一帧会多次访问 recommendation（分组 4 次 + 徽标 + 展开区理由）。
            // 若它是每次重建字符串的计算属性，一帧就是几千次字符串分配。
            let items = (0..<548).map { i in
                CleanItem(name: "item-\(i)", path: "/tmp/p\(i)", size: Int64(i),
                          nature: .losslessCache, consequence: "应用缓存文件，删除后应用会自动重建",
                          category: .userCaches,
                          use: UseState(ownerIsRunning: false, ownerName: nil,
                                        lastUsed: nil, level: .dormant))
            }
            let start = Date()
            var sink = 0
            // 模拟一帧：4 次分组判定 + 每项 3 次徽标/理由访问
            for _ in 0..<7 {
                for item in items { sink += item.recommendation.label.count }
            }
            let elapsed = Date().timeIntervalSince(start)
            print("      基准：548 项 × 7 轮 = \(sink) 次访问，耗时 \(String(format: "%.1f", elapsed * 1000)) ms")
            // 缓存后应为亚毫秒级；未缓存时这里会明显变慢
            return elapsed < 0.05
        }
        // MARK: - 并发扫描加速（v1.33.0）

        check("并发扫描：concurrentPerform 结果完整性（6 个分类全部返回）") {
            // scanAllCategories 内部用 concurrentPerform，必须确保全部 6 个分类都有结果
            let results = Scanner.scanAllCategories()
            let allCats = Set(CleanCategory.allCases)
            let returnedCats = Set(results.keys)
            if returnedCats != allCats {
                let missing = allCats.subtracting(returnedCats)
                print("      缺失分类: \(missing.map(\.title))")
            }
            return returnedCats == allCats
        }

        check("并发扫描：FileSystem.measure 多线程并发无崩溃") {
            // 10 线程并发读写测量缓存（NSLock 保护），不能崩溃或死锁
            FileSystem.beginMeasurementSession()
            let paths = ["/tmp", "/private/tmp", "/var/tmp",
                         NSHomeDirectory(), "/usr/local", "/usr/bin",
                         "/System", "/Library", "/Applications", "/dev"]
            let lock = NSLock()
            var successCount = 0
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                let _ = FileSystem.measure(at: paths[i])
                lock.lock()
                successCount += 1
                lock.unlock()
            }
            return successCount == paths.count
        }

        check("并发扫描：scanAllCategoriesWithProgress 回调完整性（6 次回调全部触发）") {
            // 回调必须精确触发 6 次，每个分类一次
            var callbackCats = Set<CleanCategory>()
            let callbackLock = NSLock()
            // 用 DispatchQueue.global 作为回调队列（非主队列，避免死锁）
            Scanner.scanAllCategoriesWithProgress(callbackQueue: .global()) { cat, _ in
                callbackLock.lock()
                callbackCats.insert(cat)
                callbackLock.unlock()
            }
            // concurrentPerform 是同步的，执行完后回调已全部 dispatch，
            // 但回调在 .global() 上异步执行，需短暂等待
            Thread.sleep(forTimeInterval: 0.1)
            callbackLock.lock()
            let count = callbackCats.count
            callbackLock.unlock()
            if count != CleanCategory.allCases.count {
                print("      回调触发 \(count)/\(CleanCategory.allCases.count) 次")
            }
            return count == CleanCategory.allCases.count
        }

        // MARK: - 增量扫描缓存（v1.34.0）

        check("增量扫描缓存：目录指纹计算与幂等性") {
            let tmpDir = NSTemporaryDirectory() + "macclean_inc_test_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let subFile1 = tmpDir + "/a.txt"
            let subFile2 = tmpDir + "/b.txt"
            try? "hello".write(toFile: subFile1, atomically: true, encoding: .utf8)
            try? "world123".write(toFile: subFile2, atomically: true, encoding: .utf8)

            guard let fp1 = IncrementalCache.fingerprint(for: tmpDir) else { return false }
            guard let fp2 = IncrementalCache.fingerprint(for: tmpDir) else { return false }

            return fp1 == fp2 && fp1.isDirectory && fp1.childCount == 2
        }

        check("增量扫描缓存：跨会话缓存命中与 Measurement 零误差复用") {
            let tmpDir = NSTemporaryDirectory() + "macclean_inc_test_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let subFile = tmpDir + "/data.bin"
            let data = Data(repeating: 0xAB, count: 4096)
            try? data.write(to: URL(fileURLWithPath: subFile))

            IncrementalCache.resetStats()
            IncrementalCache.invalidate([tmpDir])

            // 第 1 次测量：新路径，此时增量缓存必然未命中
            FileSystem.beginMeasurementSession()
            let m1 = FileSystem.measure(at: tmpDir)

            // 第 2 次测量：开启新一轮会话（清空单次会话缓存），模拟用户重新扫描
            FileSystem.beginMeasurementSession()
            let initialHits = IncrementalCache.hitCount
            let m2 = FileSystem.measure(at: tmpDir)

            // 结果必须与第一次完全一致，且增量缓存命中计数递增
            let sizeMatches = m1.size > 0 && m1.size == m2.size && m1.newest == m2.newest
            let hitMatches = IncrementalCache.hitCount == initialHits + 1
            return sizeMatches && hitMatches
        }

        check("增量扫描缓存：失效联动与文件变动感知") {
            let tmpDir = NSTemporaryDirectory() + "macclean_inc_test_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let subFile = tmpDir + "/chunk.bin"
            try? Data(repeating: 0x01, count: 1024).write(to: URL(fileURLWithPath: subFile))

            // 首次测量
            FileSystem.beginMeasurementSession()
            let m1 = FileSystem.measure(at: tmpDir)
            guard m1.size > 0 else { return false }

            // 修改目录内容（追加新文件改变子项数与指纹）
            let subFile2 = tmpDir + "/chunk2.bin"
            try? Data(repeating: 0x02, count: 8192).write(to: URL(fileURLWithPath: subFile2))

            // 主动通知失效（模拟清理或文件变动）
            FileSystem.invalidateMeasurements(for: [tmpDir])

            FileSystem.beginMeasurementSession()
            let m2 = FileSystem.measure(at: tmpDir)

            // 重新测量后必须反映最新体积增长且两文件都被计入
            return m2.size > m1.size
        }

    }
}
