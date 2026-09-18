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

    }
}
