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

    /// 源码目录（编译期由 `#filePath` 推出）。
    ///
    /// 供"扫源码本身"的 lint 型自检使用。原先这类检查写的是相对路径
    /// `Sources/MacClean/...`，只要不是从仓库根启动就一个文件都读不到，
    /// 于是恒真通过 —— 看起来在把关，其实一直在空转。
    static let sourceDirectoryPath = (#filePath as NSString).deletingLastPathComponent

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
        // 自检必须与用户真实数据隔离：历史记录、撤销快照、跨会话指纹缓存全部重定向
        // 到临时目录。此前只有个别套件靠自己的 fileURLOverride 兜住，其余写盘操作
        // 直接落进用户真实的 history.json —— 跑一次自检就多一条并不存在的清理记录。
        if ProcessInfo.processInfo.environment["MACCLEAN_STATE_DIR"].map(\.isEmpty) ?? true {
            setenv("MACCLEAN_STATE_DIR",
                   NSTemporaryDirectory() + "macclean-selftest-\(getpid())", 1)
        }
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
        // 系统后台定时维护计划器 (LaunchAgent & AutoClean v1.38.0)
        suiteLaunchAgent()
        // 应用程序卸载器深度扫描增强 (v1.39.0)
        suiteUninstallerDeep()
        // 空间透视热力图与大文件分布可视化增强 (v1.40.0)
        suiteSpaceVisualizerDeep()
        // 重复文件与相似图片清理体验升级 (v1.41.0)
        suiteDuplicateDeep()
        // 大文件排查与分类洞察增强 (v1.42.0)
        suiteLargeFilesDeep()
        // 专业开发工具与容器深度清理 (v1.43.0)
        suiteDevToolsDeep()
        // 偏好碎片与系统垃圾多角度扫描增强 (v1.44.0)
        suiteOrphanPrefsDeep()
        // 日常运行与菜单栏常驻调优 (v1.45.0)
        suiteMenuBarDeep()
        // 重复文件与大文件智能分析进阶 (v1.46.0)
        suiteMediaAndPivotDeep()
        // 系统启动项与后台服务治理 (v1.47.0)
        suiteStartupItemsDeep()
        // 重复大文件 APFS 硬链接无损去重 (v1.47.0)
        suiteHardlinkDedupDeep()
        // 系统底层存储深度治理 (v1.48.0)
        suiteSystemDeepStorage()
        // 重复大文件并发流水线哈希与轻量指纹缓存 (v1.49.0)
        suiteFingerprintPipelineDeep()
        // 空间透视层级面包屑与闲置冷热动态色谱 (v1.50.0)
        suiteSpaceVisualizerDeep2()
        // 菜单栏常驻助手快捷小组件与状态指示深化 (v1.51.0)
        suiteMenuBarWidgetsDeep()
        // 网络与系统安全隐私数据深度体检 (v1.52.0)
        suiteNetworkPrivacyDeep()
        // 已卸载应用深度偏好碎片智能反查 (v1.53.0)
        suitePreferenceResidueDeep()
        // 空间透视超大陈旧冷文件原位归档压缩与外接盘迁移 (v1.54.0)
        suiteSpaceArchiveDeep()
        // 系统深度应用扩展与 QuickLook/Spotlight 插件残存治理 (v1.55.0)
        suitePluginExtensionDeep()
        // 菜单栏常驻助手全局快捷键呼出与极速一键清理微面板 (v1.56.0)
        suiteGlobalHotkeyDeep()
        // 开发工程构建产物深度智能排查与按项目治理 (v1.57.0)
        suiteDevProjectDeep()
        // 系统核心转储与废弃诊断报告智能排查与治理 (v1.58.0)
        suiteDiagnosticReportDeep()
        // 系统电池健康度与充放电循环深度体检 (v1.59.0)
        suiteBatteryDeep()
        // 应用程序多语言本地化资源包瘦身深度治理 (v1.60.0)
        suiteAppLocalizationDeep()
        // 字体缓存与孤儿系统字体残存治理 (v1.61.0)
        suiteFontCacheDeep()
        // 下载目录智能时效归档与按类型治理 (v1.62.0)
        suiteDownloadsOrganizerDeep()
        // 剪贴板历史与大文件临时缓冲区治理 (v1.63.0)
        suiteClipboardDeep()
        // 屏幕截图与录屏归档助手深度治理 (v1.64.0)
        suiteScreenshotsOrganizerDeep()
        // 终端与命令行开发缓存深度治理 (v1.65.0)
        suiteCLICacheDeep()
        // 访达快速查看缩略图缓存释放深度治理 (v1.66.0)
        suiteQuickLookThumbnailDeep()
        // 已卸载应用登录项与自启残存深度治理 (v1.67.0)
        suiteLoginItemDeep()
        // 系统多显示器色彩描述与 ICC Profile 残存治理 (v1.68.0)
        suiteColorSyncDeep()
        // Spotlight 废弃索引与搜索数据库深度重建治理 (v1.69.0)
        suiteSpotlightDeep()
        // 系统音频 HAL 插件与残存驱动排查治理 (v1.70.0)
        suiteAudioHALDeep()
        // 废弃打印机驱动与 PPD 描述文件治理 (v1.71.0)
        suitePrinterDriverDeep()
        // 统一删除网关与治理域不变量 (v1.72.0)
        suiteDeletionGate()

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
