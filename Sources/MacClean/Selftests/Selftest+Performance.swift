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
            // 并发读写测量缓存（NSLock 保护），不能崩溃或死锁。
            //
            // 为什么不用真实系统目录：原先这里对 `/System`、`/Library`、家目录各测一遍，
            // 每次自检都要走几十万文件的 stat —— 而 measure 本身在下面两个用例里已经
            // 由 `scanAllCategories()` 真实覆盖过一次。线程安全断言需要的只是
            // "同一批路径被并发读写"，用临时目录树完全等价，代价从数十秒降到毫秒级。
            FileSystem.beginMeasurementSession()
            let tmpRoot = NSTemporaryDirectory() + "macclean_conc_\(UUID().uuidString)"
            let fm = FileManager.default
            var paths: [String] = []
            for shard in 0..<10 {
                let dir = "\(tmpRoot)/s\(shard)"
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                for file in 0..<12 {
                    let p = "\(dir)/f\(file).bin"
                    try? Data(repeating: 0xCD, count: 1024).write(to: URL(fileURLWithPath: p))
                }
                paths.append(dir)
            }
            defer { try? fm.removeItem(atPath: tmpRoot) }

            let lock = NSLock()
            var successCount = 0
            var byteSum: Int64 = 0
            DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                let m = FileSystem.measure(at: paths[i])
                lock.lock()
                if m.exists { successCount += 1 }
                byteSum += m.size
                lock.unlock()
            }
            // 每层 12 个 1 KB 文件；体积必须被并发累加得不重不漏
            return successCount == paths.count && byteSum > 0
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

        // v1.72 修：`usageMeasurement` 开始回填抽样结果后，必须守住一条不变量——
        // **抽样结果永远不能被当成体积复用**。否则为了省一次枚举，
        // 会把一个几 GB 的目录在界面上报成 0 字节（比慢得多严重）。
        check("测量缓存：仅抽样条目不参与体积复用，size 始终等于全量递归结果") {
            let fm = FileManager.default
            let dir = "/private/tmp/macclean_partial_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }
            let payload = Data(repeating: 0xB5, count: 4096)
            for i in 0..<5 {
                try? payload.write(to: URL(fileURLWithPath: "\(dir)/f\(i).bin"))
            }
            let expected = Int64(payload.count * 5)

            FileSystem.beginMeasurementSession()
            // 先问 usage（走有界抽样并回填），再问 size —— 顺序正是回归的触发条件
            let usage = FileSystem.usageMeasurement(at: dir)
            guard usage.exists, usage.isDirectory else { return false }
            let size = FileSystem.size(at: dir)
            guard size == expected else {
                print("      抽样条目被当成体积用了：size=\(size) 期望 \(expected)")
                return false
            }
            // 第三次必须是纯缓存命中（值不变），且 usage 也拿到了全量结果
            let again = FileSystem.size(at: dir)
            let usageAfter = FileSystem.usageMeasurement(at: dir)
            return again == expected && usageAfter.size == expected
        }

        // 失效必须把"仅抽样"标记一起清掉，否则删完文件后父目录会继续报旧体积
        check("测量缓存：invalidate 同时清除抽样标记，删除后体积立即归零") {
            let fm = FileManager.default
            let dir = "/private/tmp/macclean_inval_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }
            let file = "\(dir)/a.bin"
            try? Data(repeating: 0x11, count: 8192).write(to: URL(fileURLWithPath: file))

            FileSystem.beginMeasurementSession()
            guard FileSystem.size(at: dir) == 8192 else { return false }
            // 只问 usage（把该键标成"仅抽样"）之后再删除
            _ = FileSystem.usageMeasurement(at: dir)
            try? fm.removeItem(atPath: file)
            FileSystem.invalidateMeasurements(for: [dir])
            return FileSystem.size(at: dir) == 0
        }

        // 回填生效的**确定性**证明：不靠计时（计时受机器负载与其它套件干扰，
        // 上一轮 `--scan` 的耗时对比就是因为日志项从 503 涨到 997 而失去可比性）。
        // 抽样结果若真的进了缓存，那么中途改动文件 mtime 后立刻再问一次，
        // 拿到的必须还是**旧的** newest；一旦失效缓存，才会看到新值。
        check("测量缓存：usage 回填后可被命中（改 mtime 不重采，失效后才重采）") {
            let fm = FileManager.default
            let dir = "/private/tmp/macclean_backfill_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: dir) }
            let old = Date(timeIntervalSince1970: 1_600_000_000)   // 固定过去时间，避免依赖当前时刻
            let newer = Date(timeIntervalSince1970: 1_900_000_000)
            for (i, date) in [old, old, old].enumerated() {
                let f = "\(dir)/f\(i).bin"
                try? Data([0x01]).write(to: URL(fileURLWithPath: f))
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: f)
            }

            FileSystem.beginMeasurementSession()
            let first = FileSystem.usageMeasurement(at: dir)
            guard let firstNewest = first.newest, abs(firstNewest.timeIntervalSince(old)) < 2 else {
                print("      首次抽样未拿到预期 mtime：\(String(describing: first.newest))")
                return false
            }

            // 中途把其中一个文件改到很新的时间
            try? fm.setAttributes([.modificationDate: newer], ofItemAtPath: dir + "/f0.bin")
            let cached = FileSystem.usageMeasurement(at: dir)
            guard let cachedNewest = cached.newest, abs(cachedNewest.timeIntervalSince(old)) < 2 else {
                print("      未命中缓存（拿到了改动后的新值）：\(String(describing: cached.newest))")
                return false
            }

            FileSystem.invalidateMeasurements(for: [dir])
            let refreshed = FileSystem.usageMeasurement(at: dir)
            guard let r = refreshed.newest, abs(r.timeIntervalSince(newer)) < 2 else {
                print("      失效后未重新抽样：\(String(describing: refreshed.newest))")
                return false
            }
            return true
        }

        // MARK: - 护栏热路径（v1.72.4）
        //
        // `isSafeToClean` 是**每个候选项**都要过的闸门：Scanner 单个分类就有 50+ 调用点，
        // 孤儿排查按子项循环调用，删除网关还会再判一次。它只读路径、不读目录内容，
        // 所以它的开销理论上应当 ≈ 一次软链解析；高出的部分全是重复计算的纯 CPU。
        //
        // 断言用**比值**而不是绝对耗时：分子分母在同一时刻背靠背测量，
        // 机器负载会同比放大两边。上一轮 `< 60 µs` 的绝对阈值在两个并发构建时自己变过红。
        check("护栏热路径：一次判定的开销相对单次软链解析的倍数") {
            let fm = FileManager.default
            let root = NSTemporaryDirectory() + "macclean_guardrail_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            var paths: [String] = []
            for i in 0..<200 {
                let p = "\(root)/c\(i)/Library/Caches/com.example.app\(i)"
                try? fm.createDirectory(atPath: p, withIntermediateDirectories: true)
                paths.append(p)
            }
            // 计时函数返回**调用次数**而不是判定结果：这些路径位于 `$TMPDIR`
            // （`/var/folders/…`）不在常规放行根内，闸门必然全判 false——
            // 拿"有多少个 true"当热身判据会把整轮测成空转。
            func timedCalls(_ body: (String) -> Void) -> TimeInterval {
                let start = Date()
                var calls = 0
                for p in paths { body(p); calls += 1 }
                let elapsed = Date().timeIntervalSince(start)
                // 一次都没真正调用到就判失败：否则"空转 0 ms"会刷出一个假的漂亮比值
                return calls > 0 ? elapsed : .greatestFiniteMagnitude
            }

            // 交替测两轮，各取较小值：热身那轮要付 dentry 缓存未命中的代价
            let r1 = timedCalls { _ = FileSystem.realPath($0).count }
            let g1 = timedCalls { _ = FileSystem.isSafeToClean($0) }
            let r2 = timedCalls { _ = FileSystem.realPath($0).count }
            let g2 = timedCalls { _ = FileSystem.isSafeToClean($0) }
            let resolve = min(r1, r2)
            let gate = min(g1, g2)
            let ratio = resolve > 0 ? gate / resolve : .greatestFiniteMagnitude
            print(String(format: "      200 项 × 2 轮：单次软链解析 %.1f ms，闸门判定 %.1f ms → %.1f 倍",
                         resolve * 1000, gate * 1000, ratio))
            // 上界 3.0 而不是更紧的值：判定至少要付一次软链解析（分母本身）
            // + 一次 `lstat`（末段软链判定）+ 一次 `normalizePath`，
            // 这三项在调试构建下约等于分母的 1.3 倍，再压就要动 G1 的软链封堵。
            // 修好之前的实测是 **14.6 倍**（清单常量的重复归一化占掉 215/299 µs）。
            return ratio < 3.0
        }

        // 规则 v2 步骤 6 给 C1/C6/A1 各加了一次"这个目录读得到吗"探测（每个候选目录一次）。
        // 探测走 `opendir`+`closedir` 而不是 `contentsOfDirectory`：后者要把顶层条目全读一遍，
        // 而扫描紧接着就要为同一条路径做一次全量遍历——那是白花一趟 readdir。
        check("盲区探测的开销不随目录条目数增长（且必须真的能发现被拒目录）") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean_s6_perf_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            // 主动探测默认关（无人值守开着会被模态授权框挂死），而本条量的就是**探测本身**
            // 的开销与能力：不显式打开的话 150 次调用全部在 guard 里直接返回，
            // 分子恒为 0，比值怎么量都"通过"——那是一条只会点头的假绿断言。
            let savedProbe = FileSystem.proactiveBlindSpotProbe
            FileSystem.proactiveBlindSpotProbe = true
            FileSystem.resetWedgedReadsForSelftest()
            defer {
                FileSystem.proactiveBlindSpotProbe = savedProbe
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root + "/locked")
                try? fm.removeItem(atPath: root)
            }
            // 正确性腿只需要"一个可读目录"，不需要 150 个 × 60 文件。
            // 缩放比判据用的是下面的 sparse/dense 两组，与这里无关。
            var paths: [String] = []
            for i in 0..<2 {
                let p = "\(root)/c\(i)"
                try? fm.createDirectory(atPath: p + "/sub", withIntermediateDirectories: true)
                fm.createFile(atPath: p + "/sub/f0.bin", contents: Data(repeating: 1, count: 512))
                paths.append(p)
            }
            let locked = root + "/locked"
            try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
            fm.createFile(atPath: locked + "/secret.bin", contents: Data(repeating: 2, count: 1024))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)

            // 先钉正确性：便宜的那个原语必须仍然看得见 TCC/权限拒绝
            var bad: [String] = []
            if FileSystem.canOpenDirectory(locked) {
                bad.append("opendir 探测没发现 mode 000 的目录（探测换便宜写法把能力换掉了）")
            }
            FileSystem.resetDeniedAccess()
            if !FileSystem.recordBlindSpotIfNeeded(at: locked) {
                bad.append("recordBlindSpotIfNeeded 没把被拒目录记成盲区")
            }
            if FileSystem.recordBlindSpotIfNeeded(at: paths[0]) {
                bad.append("可读目录被误判成盲区")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            guard bad.isEmpty else { return false }

            func timed(_ list: [String], _ body: (String) -> Void) -> TimeInterval {
                let start = Date()
                for p in list { body(p) }
                return Date().timeIntervalSince(start)
            }
            // 判据换成**负载无关**的那一个：探测的开销不许随目录条目数增长。
            // 原先量的是"探测 ÷ 同一路径体积测算 < 0.5"，而分子自 v1.73.3 起含一次
            // GCD 派发 + 信号量等待——机器一忙（实测 load 9.7）就从 0.04 倍跳到 0.58 倍假红，
            // 上轮评审预言过这条会因调度抖动假红，一轮之内就咬人了。
            // 现在两个被测量在同一个时刻、同样的负载下跑，负载对分子分母同比例作用，比值稳定；
            // 而"探测退化成读一遍顶层条目"这件事仍然会暴露：条目数 1→60 会直接把比值推到 ~60。
            let sparseRoot = "\(root)/sparse"
            let denseRoot = "\(root)/dense"
            var sparse: [String] = []
            var dense: [String] = []
            // 对比要拉到 1 : 300。60 的时候实测把探测改成"读一遍顶层"也只推到 2.8 倍
            // ——每次调用的固定开销（一次 GCD 派发 + 信号量）盖过了条目成本，界就分不开。
            // 条目必须摆在**顶层**：第一版放在 sub/ 下，两种目录顶层都只有 1 个条目，
            // 那个变异照样测不出来——是变异验证把它判红的。
            for i in 0..<8 {
                let s = "\(sparseRoot)/c\(i)"
                let d = "\(denseRoot)/c\(i)"
                try? fm.createDirectory(atPath: s, withIntermediateDirectories: true)
                try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                fm.createFile(atPath: s + "/f0.bin", contents: Data(repeating: 1, count: 512))
                for j in 0..<300 {
                    fm.createFile(atPath: d + "/f\(j).bin", contents: Data(repeating: 1, count: 128))
                }
                sparse.append(s); dense.append(d)
            }
            // 丢弃返回值会让这条在"探测根本没发生"时照样绿：目录一旦被记进
            // `wedgedReads`（TTL 600 s），后续探测不再 dispatch 而直接短路，
            // 量到的是"什么都不做"的时间，比值当然漂亮。短路/超时的返回值是 true，
            // 所以这里把它当活性证据用：任何一次 true 都说明本轮比值不可信。
            let shortCircuited = SelftestCounter()
            func bestProbe(_ list: [String]) -> TimeInterval {
                func once() -> TimeInterval {
                    timed(list) { if FileSystem.recordBlindSpotIfNeeded(at: $0) { shortCircuited.bump() } }
                }
                return min(once(), once())
            }
            let pSparse = bestProbe(sparse), pDense = bestProbe(dense)
            if shortCircuited.count > 0 {
                print("      \(shortCircuited.count) 次探测被判成读不到/被 TTL 短路，本轮比值无意义")
                return false
            }
            // 这里**不设绝对时间下界**：任何写死的毫秒数都是一台特定机器上的经验值，
            // 拿它当门禁就会重演本轮那条比率断言的假红。上面"有没有返回 true"才是与
            // 机器无关的活性证据——短路、被 TTL 吞掉、额度耗尽这三种"没真跑"都会让它返回 true。
            let scale = pSparse > 0 ? pDense / pSparse : .greatestFiniteMagnitude
            // 只作信息输出，不再当门禁：这条就是刚被负载证伪过的那一个
            let sizeStart = Date()
            FileSystem.invalidateMeasurements(for: dense)
            for p in dense { _ = FileSystem.size(at: p) }
            let sizeCost = Date().timeIntervalSince(sizeStart)
            print(String(format: "      8 个目录：探测 1 条目 %.1f ms / 300 条目 %.1f ms → %.2f 倍"
                            + "（体积测算 %.1f ms，仅参考）",
                         pSparse * 1000, pDense * 1000, scale, sizeCost * 1000))
            // 上界 3：探测是 lstat + opendir + closedir，一个条目都不读，比值应≈1；
            // 退化成"读一遍顶层"时实测 6~10 倍。两侧同负载下量，抖动抵消。
            return scale < 3.0
        }
    }
}

/// 线程安全的计数（自检里量"有没有真的发生过"用）
final class SelftestCounter {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}
