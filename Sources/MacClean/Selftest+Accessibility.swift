import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：无障碍与子进程健壮性
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 2424–2614）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteAccessibility() {
        // MARK: - 无障碍

        check("无障碍：所有动画/转场都走 motionSafe（尊重「减少动态效果」）") {
            // 项目此前完全没有适配 Reduce Motion —— 全 App 遍布弹簧、位移与数字翻页。
            // 这条用例直接在源码层面把关：出现裸 .animation/.transition/.contentTransition
            // 即视为回归（Theme.swift 内部实现自身除外）。
            var offenders: [String] = []
            for file in ["AIChatView", "AIReviewView", "CategoryDetailView", "CleanConfirmSheet",
                         "CleanResultSheet", "DashboardView", "DirectoryTreeView", "DuplicateView",
                         "HistoryView", "MenuBarView", "PhotoCompareView", "RiskView",
                         "SearchView", "SidebarView", "SpaceVisualizerView", "StartupItemManagerView", "UninstallerView"] {
                let path = "Sources/MacClean/\(file).swift"
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                for (idx, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                    if t.contains(".motionSafe") { continue }
                    if t.contains(".animation(") || t.contains(".transition(") || t.contains("contentTransition(") {
                        offenders.append("\(file):\(idx + 1)")
                    }
                }
            }
            if !offenders.isEmpty { print("      未适配 Reduce Motion：\(offenders.prefix(5))") }
            return offenders.isEmpty
        }

        check("无障碍：“减少动态效果”的替代动画足够短且非零") {
            // reduced 应当是"近乎瞬时"的淡出，而不是把动画整个删掉导致状态跳变
            return Motion.reducedDuration > 0 && Motion.reducedDuration <= 0.05
        }

        check("性能基准：过滤+分组改为单次求值后，开销显著低于旧模式") {
            // 旧模式（已修复）：CategoryDetailView 把 filteredItems 写成无缓存计算属性，
            // 一帧被引用约 12 次，且分组循环里还要各 filter 一遍（4 次）。
            // 新模式：body 里算一次 filtered，再一次 Dictionary(grouping:) 完成分组。
            //
            // 用同一次运行内的 A/B 对比，避免机器负载波动导致数字不可比。
            let base = "/Users/x/Downloads/Videos"
            let items = (0..<548).map { i in
                CleanItem(name: "file-\(i).mov", path: "\(base)/sub\(i % 20)/file-\(i).mov",
                          size: Int64(i), rule: "T3", category: .largeFiles)
            }
            func runFilter() -> [CleanItem] {
                let expDir = CleanPaths.expand(base)
                return items.filter { item in
                    let itemExp = CleanPaths.expand(item.path)
                    return itemExp == expDir || itemExp.hasPrefix(expDir + "/")
                }
            }
            let kinds: [Recommendation.Kind] = [.safe, .inUse, .review, .keep]

            // 旧模式：12 次过滤 + 4 次分组过滤
            var oldSink = 0
            let oldStart = Date()
            for _ in 0..<3 {
                for _ in 0..<12 { oldSink += runFilter().count }
                for k in kinds { oldSink += runFilter().filter { $0.recommendation.kind == k }.count }
            }
            let oldElapsed = Date().timeIntervalSince(oldStart)

            // 新模式：3 轮（每轮一帧）各 1 次过滤 + 1 次分组
            var newSink = 0
            let newStart = Date()
            for _ in 0..<3 {
                let filtered = runFilter()
                let grouped = Dictionary(grouping: filtered) { $0.recommendation.kind }
                newSink += filtered.count
                for k in kinds { newSink += (grouped[k] ?? []).count }
            }
            let newElapsed = Date().timeIntervalSince(newStart)

            let oldMS = oldElapsed * 1000, newMS = newElapsed * 1000
            print(String(format: "      基准：旧模式 %.1f ms / 新模式 %.1f ms（同为 3 帧，548 项）", oldMS, newMS))
            guard oldSink > 0, newSink > 0 else { return false }
            // 新模式必须显著更快（理论上 ~1/16 的工作量，留足余量只要 3 倍即可）
            return newElapsed * 3 < oldElapsed
        }

        check("并发安全：运行中 App 别名缓存，多线程读取结果一致") {
            // 缓存是无锁可变静态时，这里可能读到"算了一半"的集合或撕裂的元组。
            let group = DispatchGroup()
            let lock = NSLock()
            var sets: [Set<String>] = []
            for _ in 0..<8 {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    let aliases = CleanPaths.runningAppAliases
                    lock.lock(); sets.append(aliases); lock.unlock()
                }
            }
            group.wait()
            guard let first = sets.first, sets.count == 8 else { return false }
            return sets.allSatisfy { $0 == first }
        }

        check("并发安全：6 个分类并发扫描不崩溃且结果自洽") {
            // 复现 scanAll 的并发度：共享的测量缓存、别名缓存、已安装 App 集合同期被访问。
            let group = DispatchGroup()
            let lock = NSLock()
            var counts: [String: Int] = [:]
            var bad = 0
            FileSystem.beginMeasurementSession()
            for cat in CleanCategory.allCases {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    let outcome = Scanner.scanDetailed(cat)
                    lock.lock()
                    counts[cat.rawValue] = outcome.items.count
                    // 结果自洽性：体积不能为负、路径不能为空
                    if outcome.items.contains(where: { $0.size < 0 || $0.path.isEmpty }) { bad += 1 }
                    lock.unlock()
                }
            }
            group.wait()
            return counts.count == CleanCategory.allCases.count && bad == 0
        }

        check("并发安全：测量缓存的读写与失效可并发执行") {
            let dir = "/private/tmp/macclean-conc-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for i in 0..<20 {
                FileManager.default.createFile(atPath: dir + "/f\(i).bin",
                                               contents: Data(repeating: 0, count: 4096))
            }
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let group = DispatchGroup()
            for i in 0..<8 {
                DispatchQueue.global(qos: .userInitiated).async(group: group) {
                    if i % 2 == 0 {
                        _ = FileSystem.size(at: dir)
                    } else {
                        FileSystem.invalidateMeasurements(for: [dir + "/f\(i).bin"])
                    }
                }
            }
            group.wait()
            // 并发过后仍要给出正确结果（而不是崩溃或返回脏值）
            return FileSystem.size(at: dir) > 0
        }

        check("扫描诊断：每个分类都声明了扫描根目录（供完整度体检）") {
            for cat in CleanCategory.allCases {
                let roots = Scanner.scanRoots(for: cat)
                if roots.isEmpty { return false }
                if roots.contains(where: { $0.path.isEmpty || $0.label.isEmpty }) { return false }
            }
            return true
        }

        check("扫描诊断：废纸篓在扫描根清单中（TCC 静默失败最严重的一处）") {
            let roots = Scanner.scanRoots(for: .largeFiles).map {
                FileSystem.normalizePath(CleanPaths.expand($0.path))
            }
            let trash = FileSystem.normalizePath(CleanPaths.expand(CleanPaths.trash))
            return roots.contains(trash)
        }

        check("扫描诊断：scanDetailed 与兼容签名结果一致") {
            let outcome = Scanner.scanDetailed(.userCaches)
            let compat = (try? Scanner.scan(.userCaches)) ?? []
            guard outcome.items.count == compat.count else { return false }
            // issue 必须带可展示的说明与路径，否则界面上是一句空话
            return outcome.issues.allSatisfy { !$0.message.isEmpty && !$0.path.isEmpty }
        }

        check("扫描诊断：缺失的根目录不算问题（避免误报「结果不完整」）") {
            // "不存在"是正常的"这里没东西"；只有"存在但读不到"才该报。
            // 用一个不存在的路径走同一条判定：exists=false 时必须放过。
            let ghost = "/private/tmp/macclean-ghost-\(UUID().uuidString)"
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: ghost, isDirectory: &isDir)
            return !exists && !FileSystem.isPermissionDenied(ghost)
        }

        check("风险扫描：子进程输出超过管道缓冲区时不死锁（64KB 陷阱）") {
            // macOS 管道缓冲区约 64KB。若先 waitUntilExit 再读管道，
            // 子进程写满后会阻塞在 write、父进程阻塞在 wait —— 双向死锁。
            // `launchctl list` 在多服务的机器上轻易超过这个量。
            // 这里用 256KB 输出把条件造出来；函数自带超时，所以即便回归也不会挂住测试。
            let out = RiskScanner.runCommand("/bin/sh", ["-c", "yes macclean | head -c 262144"])
            return (out?.count ?? 0) >= 262_144
        }

        check("风险扫描：子进程卡死时由超时兜底，不会拖住整轮扫描") {
            let start = Date()
            // sleep 30 远超 1 秒超时
            _ = RiskScanner.runCommand("/bin/sleep", ["30"], timeout: 1)
            let elapsed = Date().timeIntervalSince(start)
            // 必须在超时附近返回（允许少量调度余量），而不是等满 30 秒
            return elapsed < 6
        }

    }
}
