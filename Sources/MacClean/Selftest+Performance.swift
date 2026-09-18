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

    }
}
