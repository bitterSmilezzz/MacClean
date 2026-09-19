import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 进程内自检（替代 XCTest —— CommandLineTools 环境无 XCTest 框架）
// 用法: swift run MacClean --selftest  （退出码 0=全过，1=有失败；全程不渲染窗口）
// 注: ViewInspector 0.10+ 无需显式 Inspectable conform（已废弃）
//
// 本文件只负责**调度与基础设施**；具体检查按领域拆在 `Selftest+<领域>.swift` 里。
//
// 为什么拆：原先 163 项检查全塞在 `run()` 一个函数里，那一个函数有 2712 行。
// 代价是可测量的 —— 改一行自检要 6.3 秒增量编译（改 Models.swift 只要 1.8 秒），
// 单文件类型检查 3.8 秒（Scanner.swift 只要 0.3 秒）。
// 拆分的硬约束是**执行顺序必须完全不变**，所以 `run()` 按原顺序依次调用各套件，
// 切分点全部取在 `check(...)` 语句边界上。

enum Selftest {
    // 以下基础设施对 `Selftest+*.swift` 的各套件可见，故为 internal（非 private）
    static var failures: [String] = []
    static var passed = 0

    enum SelftestError: Error {
        case buttonNotFound(String)
    }

    /// 按 accessibilityIdentifier 查找按钮（label 含 Image 时 find(button:) 文本匹配不可靠）
    static func button(_ id: String, in view: some View) throws -> InspectableView<ViewType.Button> {
        let buttons = try view.inspect().findAll(ViewType.Button.self)
        for b in buttons {
            if (try? b.accessibilityIdentifier()) == id { return b }
        }
        throw SelftestError.buttonNotFound(id)
    }

    static func run() -> Int32 {
        // stdout 无缓冲，保证管道/重定向下也能实时看到输出
        setvbuf(stdout, nil, _IONBF, 0)
        failures = []
        passed = 0
        // MED#7：自检全程禁用真实网络（AI 状态机照走，请求被短路）
        AIService.networkDisabled = true
        defer { AIService.networkDisabled = false }
        let start = Date()

        // ── 各领域套件，顺序与拆分前的历史顺序一致 ──
        // 基础模型与格式化
        suiteFoundation()
        // 检索、概览与清理流程
        suiteSearchAndClean()
        // AI 再筛查
        suiteAIReview()
        // 风险检查与白名单
        suiteRiskAndWhitelist()
        // 重复文件
        suiteDuplicates()
        // 系统监控与清理成效
        suiteSystemAndHistory()
        // 相似图片与感知哈希
        suiteSimilarImages()
        // 目录树
        suiteDirectoryTree()
        // 照片元数据与对比
        suitePhotos()
        // 空间透视与图表
        suiteSpaceVisualizer()
        // 清理规则与结论不变量
        suiteRulesAndVerdicts()
        // 扫描完整度与测量缓存
        suiteScanDiagnostics()
        // 性能基准
        suitePerformance()
        // 无障碍与子进程健壮性
        suiteAccessibility()
        // 无人值守与后台开销
        suiteUnattended()
        // 孤儿残留排查
        suiteOrphans()
        // 清理撤销与回滚（v1.35.0）
        suiteUndo()
        // 智能清理推荐引擎（v1.36.0）
        suiteSmartRecommendation()
        // API Key 存储（钥匙串优先 + 内存回退，绝不落盘）
        suiteAIKeyStorage()

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(start))

        print("==============================================")
        print("MacClean 自检完成：\(passed) 通过 / \(failures.count) 失败（\(elapsed)）")
        if !failures.isEmpty {
            print("失败项：")
            for f in failures { print("  ❌ \(f)") }
            return 1
        }
        print("全部通过 ✅")
        return 0
    }

    static func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() {
                passed += 1
                print("  ✅ \(name)")
            } else {
                failures.append(name)
                print("  ❌ \(name)（断言不成立）")
            }
        } catch {
            failures.append("\(name)（异常: \(error)）")
            print("  ❌ \(name)（异常: \(error)）")
        }
    }
}
