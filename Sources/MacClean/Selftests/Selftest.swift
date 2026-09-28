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

    /// 产品源码目录（编译期由 `#filePath` 推出）。
    ///
    /// 供"扫源码本身"的 lint 型自检使用。原先这类检查写的是相对路径
    /// `Sources/MacClean/...`，只要不是从仓库根启动就一个文件都读不到，
    /// 于是恒真通过 —— 看起来在把关，其实一直在空转。
    ///
    /// 自检文件后来被移进 `Selftests/` 子目录（为的是发布时整目录排除），
    /// 所以这里要**再往上一层**才是产品代码所在目录。少这一层，
    /// "所有视图都走 motionSafe"那条 lint 就会去扫自检文件自己。
    static let sourceDirectoryPath = ((#filePath as NSString)
        .deletingLastPathComponent as NSString).deletingLastPathComponent

    /// 给"扫全仓源码"那几条 lint 用的**最小化注释剥离**：
    /// - 逐行剔除以 `//` 起头的整行；
    /// - **行尾 `// ...` 也要剥**（v1.73.7 二次复审 P1-B：`guard let e = ... else { return [] }
    ///   // 这里要 recordDeniedAccess` 这种形状会被上一版放行）；
    /// - `/* ... */` 块注释支持跨行；
    /// - **字符串字面量保护**：用行首到目标点为止的 `"` 计数是否偶数来判"是不是在字符串里"
    ///   （v1.73.7 二次复审 P2-A：`summary: "~/Library/Caches/* 各子目录"` 里 `Caches/*` 会被
    ///   无保护的剥离器误当块注释开头、把 84.6% 的代码当垃圾丢掉）。
    /// 不是完整 tokenizer：转义引号 `\"`、多行字符串 `"""` 里的 `//` 会误剥——但误剥只会
    /// 让 lint 判据更严（少了一些词），不会把漏检变成假绿；这是这一族判据唯一可接受的偏差方向。
    /// 剥掉 `//` 行注释、行尾 `//` 与 `/* … */`（含跨行），**并保持物理行数不变**：
    /// 被剥掉的行留空。行号对齐是给"要拿命中行号报位置"的 lint 用的——
    /// v1.73.10 二次复审实测：上一版直接 `continue` 丢掉整行，让
    /// `Selftest+ScanDiagnostics` 的 enumerator lint 只能拿原始行做窗口，
    /// 于是"把 `recordDeniedAccess` 换成行尾注释"这种变异**仍然是绿的**
    /// （窗口按 `hasPrefix("//")` 过滤，只挡得住整行注释）。
    static func stripSwiftComments(_ src: String) -> String {
        var out: [String] = []
        var inBlock = false
        for raw in src.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if let r = line.range(of: "*/") {
                    inBlock = false
                    line = String(line[r.upperBound...])
                } else {
                    out.append("")
                    continue
                }
            }
            if t.hasPrefix("//") {
                out.append("")
                continue
            }

            // 反复处理本行里的 `/* ... */`；每次先判断 `/*` 之前是不是有奇数个 `"`
            // （奇数 = 在字符串里，跳过，让 lint 严格化方向偏严而不是偏宽）。
            while let open = line.range(of: "/*") {
                let head = String(line[line.startIndex..<open.lowerBound])
                if head.filter({ $0 == "\"" }).count % 2 == 1 { break }
                let rest = String(line[open.upperBound...])
                if let close = rest.range(of: "*/") {
                    let tail = String(rest[close.upperBound...])
                    line = head + tail
                } else {
                    line = head
                    inBlock = true
                    break
                }
            }
            // 行尾 `//`：同上，`"` 计数偶数才当注释。
            if let dbl = line.range(of: "//") {
                let before = String(line[line.startIndex..<dbl.lowerBound])
                if before.filter({ $0 == "\"" }).count % 2 == 0 {
                    line = before
                }
            }
            // 空行也原样保留：调用方要么把空白滤掉再比对，要么按行号对齐取窗口，
            // 两种都不希望行数在这里发生变化。
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

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

    /// 套件表：**唯一**的套件清单（顺序即执行顺序，与拆分前的历史顺序一致）。
    ///
    /// ## 为什么必须有这张表（而不是继续写 58 行连续调用）
    ///
    /// 编排模式（默认）为**每个套件开一个子进程**，而崩溃隔离的粒度就是这里的每一项。
    /// 以前 58 个套件挤在同一个进程里顺序调用，任何一个崩掉
    /// （`fatalError` / `SIGBUS` 这类**进程级**终止，Swift 里没法 catch）
    /// 都会连带吞掉它之后的全部自检；而外部看到的只是"跑完了、没报错"。
    ///
    /// 这不是假设：macOS 27 上第 4 个套件（SearchAndClean）因为 ViewInspector
    /// 不兼容而崩，后面 500 多条自检一条没跑，输出看起来却很像"通过了"。
    /// 见 docs/RELEASE-CHECKLIST.md §0.2。
    static let suites: [(name: String, run: () -> Void)] = [
        // 基础模型与格式化
        ("Foundation", suiteFoundation),
        // 进程占用事实来源与「未知 ≠ 没在用」接缝不变量
        ("ProcessOccupancy", suiteProcessOccupancy),
        // 扫描前的权限门（上面两套都不碰 ViewInspector）
        ("PermissionGate", suitePermissionGate),
        // 可清理量的口径：数字必须说人话（同样不碰 ViewInspector）
        ("CleanableAccounting", suiteCleanableAccounting),
        // 系统体验优化：读 / 写 / 还原（不碰 ViewInspector）
        ("SystemTweaks", suiteSystemTweaks),
        // 检索、概览与清理流程
        ("SearchAndClean", suiteSearchAndClean),
        // AI 再筛查
        ("AIReview", suiteAIReview),
        // 风险检查与白名单
        ("RiskAndWhitelist", suiteRiskAndWhitelist),
        // 重复文件
        ("Duplicates", suiteDuplicates),
        // 系统监控与清理成效
        ("SystemAndHistory", suiteSystemAndHistory),
        // 相似图片与感知哈希
        ("SimilarImages", suiteSimilarImages),
        // 目录树
        ("DirectoryTree", suiteDirectoryTree),
        // 照片元数据与对比
        ("Photos", suitePhotos),
        // 空间透视与图表
        ("SpaceVisualizer", suiteSpaceVisualizer),
        // 清理规则与结论不变量
        ("RulesAndVerdicts", suiteRulesAndVerdicts),
        // 扫描完整度与测量缓存
        ("ScanDiagnostics", suiteScanDiagnostics),
        // 性能基准
        ("Performance", suitePerformance),
        // 无障碍与子进程健壮性
        ("Accessibility", suiteAccessibility),
        // 无人值守与后台开销
        ("Unattended", suiteUnattended),
        // 孤儿残留排查
        ("Orphans", suiteOrphans),
        // 清理撤销与回滚 (v1.35.0)
        ("Undo", suiteUndo),
        // 智能清理推荐引擎 (v1.36.0)
        ("SmartRecommendation", suiteSmartRecommendation),
        // API Key 存储（钥匙串优先 + 内存回退，绝不落盘）
        ("AIKeyStorage", suiteAIKeyStorage),
        // 系统后台定时维护计划器 (v1.38.0)
        ("LaunchAgent", suiteLaunchAgent),
        // 应用程序卸载器深度扫描增强 (v1.39.0)
        ("UninstallerDeep", suiteUninstallerDeep),
        // 空间透视热力图与大文件分布可视化增强 (v1.40.0)
        ("SpaceVisualizerDeep", suiteSpaceVisualizerDeep),
        // 重复文件与相似图片清理体验升级 (v1.41.0)
        ("DuplicateDeep", suiteDuplicateDeep),
        // 大文件排查与分类洞察增强 (v1.42.0)
        ("LargeFilesDeep", suiteLargeFilesDeep),
        // 专业开发工具与容器深度清理 (v1.43.0)
        ("DevToolsDeep", suiteDevToolsDeep),
        // 偏好碎片与系统垃圾多角度扫描增强 (v1.44.0)
        ("OrphanPrefsDeep", suiteOrphanPrefsDeep),
        // 日常运行与菜单栏常驻调优 (v1.45.0)
        ("MenuBarDeep", suiteMenuBarDeep),
        // 重复文件与大文件智能分析进阶 (v1.46.0)
        ("MediaAndPivotDeep", suiteMediaAndPivotDeep),
        // 系统启动项与后台服务治理 (v1.47.0)
        ("StartupItemsDeep", suiteStartupItemsDeep),
        // 重复大文件 APFS 硬链接无损去重 (v1.47.0)
        ("HardlinkDedupDeep", suiteHardlinkDedupDeep),
        // 系统底层存储深度治理 (v1.48.0)
        ("SystemDeepStorage", suiteSystemDeepStorage),
        // 并发流水线哈希与轻量指纹缓存 (v1.49.0)
        ("FingerprintPipelineDeep", suiteFingerprintPipelineDeep),
        // 空间透视层级面包屑与闲置冷热动态色谱 (v1.50.0)
        ("SpaceVisualizerDeep2", suiteSpaceVisualizerDeep2),
        // 菜单栏常驻助手快捷小组件与状态指示深化 (v1.51.0)
        ("MenuBarWidgetsDeep", suiteMenuBarWidgetsDeep),
        // 网络与系统安全隐私数据深度体检 (v1.52.0)
        ("NetworkPrivacyDeep", suiteNetworkPrivacyDeep),
        // 已卸载应用深度偏好碎片智能反查 (v1.53.0)
        ("PreferenceResidueDeep", suitePreferenceResidueDeep),
        // 超大陈旧冷文件原位归档压缩与外接盘迁移 (v1.54.0)
        ("SpaceArchiveDeep", suiteSpaceArchiveDeep),
        // 应用扩展与 QuickLook/Spotlight 插件残存治理 (v1.55.0)
        ("PluginExtensionDeep", suitePluginExtensionDeep),
        // 全局快捷键呼出与极速一键清理微面板 (v1.56.0)
        ("GlobalHotkeyDeep", suiteGlobalHotkeyDeep),
        // 开发工程构建产物深度智能排查 (v1.57.0)
        ("DevProjectDeep", suiteDevProjectDeep),
        // 核心转储与废弃诊断报告智能排查 (v1.58.0)
        ("DiagnosticReportDeep", suiteDiagnosticReportDeep),
        // 电池健康度与充放电循环深度体检 (v1.59.0)
        ("BatteryDeep", suiteBatteryDeep),
        // 应用多语言本地化资源包瘦身深度治理 (v1.60.0)
        ("AppLocalizationDeep", suiteAppLocalizationDeep),
        // 字体缓存与孤儿系统字体残存治理 (v1.61.0)
        ("FontCacheDeep", suiteFontCacheDeep),
        // 下载目录智能时效归档与按类型治理 (v1.62.0)
        ("DownloadsOrganizerDeep", suiteDownloadsOrganizerDeep),
        // 剪贴板历史与大文件临时缓冲区治理 (v1.63.0)
        ("ClipboardDeep", suiteClipboardDeep),
        // 屏幕截图与录屏归档助手深度治理 (v1.64.0)
        ("ScreenshotsOrganizerDeep", suiteScreenshotsOrganizerDeep),
        // 终端与命令行开发缓存深度治理 (v1.65.0)
        ("CLICacheDeep", suiteCLICacheDeep),
        // 访达快速查看缩略图缓存释放深度治理 (v1.66.0)
        ("QuickLookThumbnailDeep", suiteQuickLookThumbnailDeep),
        // 已卸载应用登录项与自启残存深度治理 (v1.67.0)
        ("LoginItemDeep", suiteLoginItemDeep),
        // 系统多显示器色彩描述与 ICC Profile 残存治理 (v1.68.0)
        ("ColorSyncDeep", suiteColorSyncDeep),
        // Spotlight 废弃索引与搜索数据库深度重建治理 (v1.69.0)
        ("SpotlightDeep", suiteSpotlightDeep),
        // 系统音频 HAL 插件与残存驱动排查治理 (v1.70.0)
        ("AudioHALDeep", suiteAudioHALDeep),
        // 废弃打印机驱动与 PPD 描述文件治理 (v1.71.0)
        ("PrinterDriverDeep", suitePrinterDriverDeep),
        // Android 模拟器 AVD 与 SDK 系统镜像孤儿治理 (v1.73.10)
        ("AndroidEmulatorDeep", suiteAndroidEmulatorDeep),
        // 统一删除网关与治理域不变量 (v1.72.0)
        ("DeletionGate", suiteDeletionGate),
        // 文件粉碎器：覆写前裁决 / 多遍覆写观测 / 网关删除与历史 (v1.73.14)
        ("Shredder", suiteShredder),
        ("Maintenance", suiteMaintenance),   // 系统维护面板：First Aid / DNS 刷新 / Spotlight 重建 (v1.73.15)
        ("MailAttachments", suiteMailAttachments),   // Mail 附件清理：零默认勾选 / TCC 三态 / 网关可撤销 (v1.73.15)
        ("BrowserPrivacy", suiteBrowserPrivacy),   // 浏览器隐私 (浏览器×数据类) 矩阵：零勾选 / danger 确认 / G16 (v1.73.15)
    ]

    /// 子进程完成标记。父进程靠它区分"跑完了"和"崩了"。
    ///
    /// 为什么不用退出码：进程级终止可能被包装成任意退出码，且崩溃前已经打进部分输出。
    /// 只有"由子进程自己在**跑完最后一条断言之后**打印"这件事，才是
    /// "这个套件真的全部执行完"的可靠证据。没有这一行 = 没跑完。
    static let childResultPrefix = "##SELFTEST_SUITE_RESULT "

    static func run() -> Int32 {
        // stdout 无缓冲，保证管道/重定向下也能实时看到输出
        setvbuf(stdout, nil, _IONBF, 0)
        // 自检必须与用户真实数据隔离：历史记录、撤销快照、跨会话指纹缓存全部重定向
        // 到临时目录（子进程通过环境变量继承）。
        if ProcessInfo.processInfo.environment["MACCLEAN_STATE_DIR"].map(\.isEmpty) ?? true {
            setenv("MACCLEAN_STATE_DIR",
                   NSTemporaryDirectory() + "macclean-selftest-\(getpid())", 1)
        }
        // MED#7：自检全程禁用真实网络（AI 状态机照走，请求被短路）
        AIService.networkDisabled = true
        defer { AIService.networkDisabled = false }

        // ① 子进程模式：只跑 `--selftest-suite=<名字>` 指定的那一个套件
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--selftest-suite=") }) {
            return runSingleSuite(named: String(arg.dropFirst("--selftest-suite=".count)))
        }
        // ② 单进程模式：改造前的旧行为。保留它是为了在怀疑
        //    "是不是隔离本身改变了某个套件的行为" 时有一条对照路径。
        if CommandLine.arguments.contains("--selftest-inproc") {
            return runAllInProcess()
        }
        // ③ 编排模式（默认）：逐套件开子进程，崩一个不牵连其余
        return runOrchestrated()
    }

    /// 单进程跑完全部套件（`--selftest-inproc`）。任一崩溃会吞掉其后全部套件。
    private static func runAllInProcess() -> Int32 {
        failures = []
        passed = 0
        let start = Date()
        print("单进程模式：\(suites.count) 个套件共用一个进程（任一崩溃会吞掉其后全部套件）")
        for suite in suites { suite.run() }
        return summarize(passed: passed, failures: failures,
                         elapsed: Date().timeIntervalSince(start), unexecuted: [])
    }

    /// 子进程：只跑一个套件，并在最后一行打上机器可读的结果。
    private static func runSingleSuite(named wanted: String) -> Int32 {
        failures = []
        passed = 0
        guard let suite = suites.first(where: { $0.name.lowercased() == wanted.lowercased() }) else {
            print("!! 没有名为「\(wanted)」的套件。可用：")
            for s in suites { print("   \(s.name)") }
            return 2
        }
        print("--- [Suite] \(suite.name) ---")
        suite.run()
        // 这一行是"本套件真的跑完了"的唯一凭据：崩溃的进程不会留下它。
        print("\(childResultPrefix)name=\(suite.name) passed=\(passed) failed=\(failures.count)")
        return failures.isEmpty ? 0 : 1
    }

    /// 编排：逐套件开子进程执行并聚合。
    ///
    /// 关键性质：**一个套件崩溃只损失它自己**。父进程拿到"子进程没留下完成标记"
    /// 之后把它记成"未执行"，而不是让它连带吞掉后面的套件、也不是把它当成通过。
    private static func runOrchestrated() -> Int32 {
        guard let exe = Bundle.main.executablePath else {
            print("!! 取不到可执行文件路径，无法做崩溃隔离。请改用 --selftest-inproc")
            return 2
        }
        print("崩溃隔离模式：\(suites.count) 个套件各跑一个子进程（一个崩了不牵连其余）")
        let start = Date()
        var totalPassed = 0
        var allFailures: [String] = []
        var unexecuted: [(name: String, reason: String)] = []

        for suite in suites {
            guard let result = SafeProcess.run(exe,
                                               ["--selftest", "--selftest-suite=\(suite.name)"],
                                               timeout: 1800) else {
                unexecuted.append((suite.name, "子进程未能启动"))
                print("⚠️  [\(suite.name)] 子进程未能启动")
                continue
            }
            // 子进程的输出原样透传：既有习惯是"看得见每一条断言"。
            let text = result.output.trimmingCharacters(in: .newlines)
            if !text.isEmpty { print(text) }

            if result.timedOut {
                unexecuted.append((suite.name, "超时未完成"))
                print("⚠️  [\(suite.name)] 超时未完成 —— **未执行完**，不计入通过")
                continue
            }
            guard let counts = parseChildCounts(result.output) else {
                // 没留下完成标记 = 进程没跑完。fatalError / SIGBUS 都走这条，
                // 而且这正是本次改造要解决的问题。
                unexecuted.append((suite.name,
                                   "子进程异常终止（exit=\(result.exitCode)），未留下完成标记"))
                print("⚠️  [\(suite.name)] 未执行完：子进程异常终止 exit=\(result.exitCode)")
                continue
            }
            let names = failureNames(in: result.output)
            totalPassed += counts.passed
            allFailures.append(contentsOf: names)
            if counts.failed > 0, names.isEmpty {
                allFailures.append("\(suite.name)（子进程报 \(counts.failed) 项失败，但未捕获到名称）")
            }
        }
        return summarize(passed: totalPassed, failures: allFailures,
                         elapsed: Date().timeIntervalSince(start), unexecuted: unexecuted)
    }

    /// 统一的收尾汇报。
    ///
    /// **"未执行"与"通过"必须分开报**：这个项目栽过的跟头就是
    /// "没读到被当成很干净"；自检里同一类错误的形态是
    /// "没跑到被当成通过了"。所以未执行的套件单列一段，且默认让退出码非零。
    private static func summarize(passed: Int, failures: [String], elapsed: TimeInterval,
                                 unexecuted: [(name: String, reason: String)]) -> Int32 {
        let elapsedText = String(format: "%.2fs", elapsed)
        print("==============================================")
        print("MacClean 自检完成：\(passed) 通过 / \(failures.count) 失败 / \(unexecuted.count) 个套件未执行（\(elapsedText)）")
        if !failures.isEmpty {
            print("失败项：")
            for f in failures { print("  ❌ \(f)") }
        }
        if !unexecuted.isEmpty {
            print("⚠️ 未执行的套件 —— **不等于通过**，其中的断言一条都没有跑到：")
            for u in unexecuted { print("  ⚠️ \(u.name)：\(u.reason)") }
            print("   改造前，这些套件会被前一个崩溃连带吞掉，而输出看起来只是「少了几段」；")
            print("   现在「没跑到」和「通过了」分开报。")
        }
        if !failures.isEmpty { return 1 }
        if unexecuted.isEmpty {
            print("全部通过 ✅")
            return 0
        }
        if CommandLine.arguments.contains("--selftest-allow-environment-skips") {
            print("   （已用 --selftest-allow-environment-skips 容忍：退出码 0。）")
            print("     注意：这只让脚本能过，**不代表上面那些套件的断言通过了**。")
            return 0
        }
        print("   若已确认是环境问题（如 macOS 27 上 ViewInspector 不兼容，")
        print("   见 docs/RELEASE-CHECKLIST.md §0.2），可加 --selftest-allow-environment-skips")
        print("   让退出码为 0——那只是让脚本能过，不代表这些断言通过。")
        return 1
    }

    /// 解析子进程最后那行机器可读的结果。
    private static func parseChildCounts(_ output: String) -> (passed: Int, failed: Int)? {
        for line in output.split(separator: "\n").reversed() where line.hasPrefix(childResultPrefix) {
            var passed = 0
            var failed = 0
            for field in line.dropFirst(childResultPrefix.count).split(separator: " ") {
                let kv = field.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                if kv[0] == "passed" { passed = Int(kv[1]) ?? 0 }
                if kv[0] == "failed" { failed = Int(kv[1]) ?? 0 }
            }
            return (passed, failed)
        }
        return nil
    }

    /// 从子进程输出里取回失败断言名（子进程已按 `  ❌ 名字` 打印过）。
    private static func failureNames(in output: String) -> [String] {
        output.split(separator: "\n")
            .filter { $0.hasPrefix("  ❌ ") }
            .map { String($0.dropFirst("  ❌ ".count)) }
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
