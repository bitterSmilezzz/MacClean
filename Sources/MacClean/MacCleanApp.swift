import SwiftUI

@main
struct MacCleanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState()

    init() {
        // 无头测试模式：swift run MacClean --selftest（进程内 UI 自检，零窗口）
        #if MACCLEAN_SELFTEST
        if CommandLine.arguments.contains("--selftest") {
            exit(Selftest.run())
        }
        #else
        // release 产物不链入自检代码（见 Package.swift 的 MACCLEAN_NO_SELFTEST）。
        // 这里必须**明确报错并非零退出**：静默忽略会让跑的人以为"自检过了"，
        // 而实际上一个断言都没执行——正是本项目反复在防的"没读到被当成很干净"。
        if CommandLine.arguments.contains("--selftest") {
            let msg = "此构建未包含自检代码（release 产物）。请改用开发构建执行：\n"
                + "  SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift run MacClean --selftest\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }
        #endif
        // `--selftest-suite=` 只有在 `--selftest` 之下才有意义（父进程用它派子进程跑单个套件）。
        // 漏了 `--selftest` 时以前会**一路落到 GUI 分支**——命令行看起来"什么都没发生"，
        // 实际把整个 App 界面开了起来（v1.73.15 复审实测误开出两个窗口）。未知/搭配错的
        // `--selftest*` 一律 fail fast：静默起 GUI 是把"没执行"演成"在执行"。
        if !CommandLine.arguments.contains("--selftest"),
           let stray = CommandLine.arguments.first(where: { $0.hasPrefix("--selftest") }) {
            FileHandle.standardError.write(Data(
                "参数 \(stray) 只在配合 --selftest 时有效；未启动任何自检，也未启动界面。\n".utf8))
            exit(2)
        }
        // 后台定时维护与低空间自愈命令行模式（LaunchAgent 无头执行，零窗口）
        if CommandLine.arguments.contains("--autoclean") {
            exit(AutoCleanService.run())
        }
        // 一次性迁移：旧明文 Key 文件 → 系统钥匙串（swift run MacClean --keymigrate）
        // v1.35 及以前 Key 存 ~/Library/Application Support/MacClean/ai.key（明文）；
        // 现在只写钥匙串。本模式让老用户无需启动 GUI 即可完成迁移，成功即删除明文文件。
        if CommandLine.arguments.contains("--keymigrate") {
            setvbuf(stdout, nil, _IONBF, 0)
            print("== MacClean API Key 迁移（旧明文文件 → 系统钥匙串）==")
            guard let key = AIConfig.loadAPIKey(), !key.isEmpty else {
                print("未发现 Key：钥匙串与旧明文文件均为空，无需迁移")
                exit(0)
            }
            print("apiKey: 已读取（长度 \(key.count)）")
            if AIConfig.legacyKeyFileStillPresent {
                print("⚠️ 钥匙串写入失败：\(AIConfig.lastKeychainStatusDescription)")
                print("   明文文件已保留以免丢失凭据；启动 App 后会自动重试迁移")
                exit(3)
            }
            print("✅ 明文文件已清除，Key 现仅存于系统钥匙串")
            exit(0)
        }
        // AI 链路无头诊断：--aitest [baseURL] [model]
        // 用真实配置+钥匙串复现完整请求链路，定位"发消息不回"
        if CommandLine.arguments.contains("--aitest") {
            setvbuf(stdout, nil, _IONBF, 0)
            let args = CommandLine.arguments
            let cfg = AIConfig.load()
            let baseURL = args.count > 2 ? args[2] : cfg.baseURL
            let model = args.count > 3 ? args[3] : cfg.model
            print("== MacClean AI 诊断 ==")
            print("baseURL: \(baseURL)")
            print("model:   \(model)")
            print("enabled: \(cfg.enabled)")
            let key = AIConfig.loadAPIKey()
            print("apiKey:  \(key != nil ? "已读取（\(key!.prefix(6))…，长度 \(key!.count)）" : "❌ 读不到（钥匙串拒访）")")
            guard let key, !key.isEmpty else {
                print("结论：钥匙串读取失败 → App 内必然报『尚未配置』或静默失败")
                exit(2)
            }
            print("发送测试请求…")
            let sem = DispatchSemaphore(value: 0)
            // detached：不继承 MainActor——否则 sem.wait() 阻塞主线程会造成恢复死锁
            Task.detached {
                do {
                    let reply = try await AIService.testConnection(baseURL: baseURL, apiKey: key, model: model)
                    print("✅ 成功，模型回复：\(reply)")
                    sem.signal()
                } catch {
                    print("❌ 失败：\(error.localizedDescription)")
                    sem.signal()
                }
            }
            sem.wait()
            exit(0)
        }
        // 真实问答链路诊断：--aitest2 走 AIService.send（与 App 内完全一致），定位"连接测试正常但问答不行"
        if CommandLine.arguments.contains("--aitest2") {
            setvbuf(stdout, nil, _IONBF, 0)
            let cfg = AIConfig.load()
            print("== MacClean 问答链路诊断 ==")
            print("enabled: \(cfg.enabled)")
            print("baseURL: \(cfg.baseURL)")
            print("model:   \(cfg.model)")
            let key = AIConfig.loadAPIKey()
            print("apiKey:  \(key != nil ? "已读取（长度 \(key!.count)）" : "❌ 读不到")")
            guard cfg.enabled, let key, !key.isEmpty else {
                print("❌ 失败：enabled=\(cfg.enabled) 或 key 缺失 → AIService.send 会抛 notConfigured")
                exit(2)
            }
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let msg = ChatMessage(role: .user, content: "回复 OK 两个字母即可")
                    let reply = try await AIService.send(messages: [msg], context: nil)
                    print("✅ send 成功，模型回复：\(reply)")
                } catch {
                    print("❌ send 失败：\(error.localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        // 无头 AI 再筛查模式：swift run MacClean --aireview [分类数限制]
        // 用真实 AI 对扫描结果逐项二次判断，验证 AI 扫描链路
        if CommandLine.arguments.contains("--aireview") {
            setvbuf(stdout, nil, _IONBF, 0)
            let limit = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 10 : 10
            print("== MacClean AI 再筛查诊断 ==")
            let cfg = AIConfig.load()
            print("enabled: \(cfg.enabled) | baseURL: \(cfg.baseURL) | model: \(cfg.model)")
            guard cfg.enabled, AIConfig.loadAPIKey() != nil else {
                print("❌ AI 未配置，无法筛查")
                exit(2)
            }
            // 收集已扫描项（取各分类 Top，控制条数）
            let all = CleanCategory.allCases.flatMap { cat -> [CleanItem] in
                let items = (try? Scanner.scan(cat)) ?? []
                return Array(items.prefix(limit / CleanCategory.allCases.count))
            }
            print("待筛查：\(all.count) 项（每分类 Top \(limit / CleanCategory.allCases.count)）")
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let reviews = try await AIService.review(items: all) { msg in
                        print("  进度：\(msg)")
                    }
                    print("✅ 筛查完成：\(reviews.count) 项有结论")
                    let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
                    for r in reviews.prefix(12) {
                        if let item = byID[r.itemID] {
                            print("  [AI·\(r.verdict.label)] \(item.name) — \(r.reason)")
                        }
                    }
                } catch {
                    print("❌ 筛查失败：\(error.localizedDescription)")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        if CommandLine.arguments.contains("--scan") {
            print("MacClean headless scan")
            // 无头路径没有窗口能应答 TCC 的模态授权框，主动盲区探测必须关着
            FileSystem.proactiveBlindSpotProbe = false
            // 逐分类计时：扫描是这套工具最慢的一步，没有分段耗时就只能靠猜
            let results = CleanCategory.allCases.map { cat -> (String, [CleanItem], Double) in
                let t0 = Date()
                let items = (try? Scanner.scan(cat)) ?? []
                return (cat.title, items, Date().timeIntervalSince(t0))
            }
            var scanned: Int64 = 0
            var cleanable: Int64 = 0
            for (title, items, elapsed) in results {
                let sum = items.reduce(Int64(0)) { $0 + $1.size }
                // "扫到多少"与"能清多少"是两个量，必须分开报。早先这里只打一个
                // 汇总并写成「总计可清理」，而它是**所有项之和**——含「勿删 / 使用中 /
                // 需确认」。真机实测该数字比"全选"实际能勾掉的量虚高 55%。
                let safe = items.filter { $0.recommendation.isSafe }
                    .reduce(Int64(0)) { $0 + $1.size }
                scanned += sum
                cleanable += safe
                print("== \(title): \(items.count) 项, 扫到 \(sum.byteStringCN), 其中可清理 \(safe.byteStringCN)  [\(String(format: "%.2f", elapsed))s]")
                for item in items.prefix(10) {
                    // 只打**精确**的"距今多久"。早先这里还拼了 `usage.label`（"7 天内有写入"
                    // 这种粗档位），而门槛是 3 天——一个 5 天前写过的项旁边印着
                    // "最近 7 天内有写入"，读起来像是自相矛盾。依据那一行已经给了绝对时间。
                    let usage = item.lastUsed.map { $0.relativeUsage } ?? "写入时间未知"
                    let recommendation = item.recommendation
                    print("   [\(recommendation.label)] \(item.name) — \(item.size.byteStringCN) — \(item.path) — 使用:\(usage) — 依据:\(recommendation.reason)")
                }
            }
            print("== 共扫描到: \(scanned.byteStringCN)")
            print("== 可清理（只含结论为「可清理 / 确定是垃圾」的项）: \(cleanable.byteStringCN)")
            exit(0)
        }
        if CommandLine.arguments.contains("--permission-check") {
            // 权限体检：只读，不改任何东西。
            // 存在的理由有两个：
            //   ① 用户不用开 GUI 就能问"我到底缺不缺权限、缺了会少看到哪些位置"；
            //   ② 让"缺 FDA"这条分支能被端到端验证——真实探针 + 真实可读性探测，
            //      而不是只靠自检里的探针覆盖。
            print("MacClean 权限体检（只读）")
            let has = FileSystem.hasFullDiskAccess()
            print("== 完全磁盘访问权限（FDA）：\(has ? "已授权 ✅" : "未授权 ❌")")

            let interactive = PermissionGuide.scanGate(unattended: false,
                                                       hasFullDiskAccess: has,
                                                       acknowledgedWithoutFDA: false)
            print("== 交互式扫描：\(interactive == .needsFullDiskAccess ? "会先提示授权再扫" : "直接开始扫描")")
            let unattended = PermissionGuide.scanGate(unattended: true,
                                                      hasFullDiskAccess: has,
                                                      acknowledgedWithoutFDA: false)
            print("== 无人值守扫描：\(unattended == .proceed ? "不拦截（有意：没人应答模态框）" : "被拦截（异常）")")

            print("== 逐个扫描根的可读性：")
            var denied: [(String, String)] = []
            for cat in CleanCategory.allCases {
                for root in Scanner.scanRoots(for: cat) {
                    let path = CleanPaths.expand(root.path)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                    if FileSystem.isPermissionDenied(path) { denied.append((root.label, path)) }
                }
            }
            if denied.isEmpty {
                print("   现状：全部可读，或该位置不存在（不存在不算问题）")
            } else {
                for (label, path) in denied { print("   [读不到] \(label) — \(path)") }
                print("   ↑ 这 \(denied.count) 个位置的内容没有计入扫描结果——是「没看到」，不是「没有东西」")
            }
            if !has {
                print("== 下一步：系统设置 → 隐私与安全性 → 完全磁盘访问权限，勾选 MacClean")
                print("   \(PermissionGuide.settingsURLString)")
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--prefs-check") {
            // 系统体验优化**体检**。
            //
            // **只读**：这个命令不写任何偏好、不重启任何进程。它是"看清现状"的那一步；
            // 真去改设置必须在 GUI 里逐条确认（每改一条都会先落一条撤销记录）。
            // 之所以单独给一个只读入口：用户应该能在被"建议"之前先看清现状，
            // 而不是点一下按钮就被改了系统。
            print("MacClean 系统体验优化体检（只读，不改任何设置）")
            let findings = SystemTweakStore.inspect()
            var currentGroup: SystemTweakGroup?
            for finding in findings {
                if currentGroup != finding.tweak.group {
                    currentGroup = finding.tweak.group
                    print("\n== \(finding.tweak.group.title)")
                }
                let mark: String
                switch finding.status {
                case .alreadyOptimal: mark = "✅ 已是推荐值"
                case .deviates:       mark = "○  可优化"
                case .unreadable:     mark = "⚠️  读不到"
                }
                print("  [\(mark)] \(finding.tweak.title)")
                print("       现状：\(finding.current?.display ?? "读不到")    推荐：\(finding.tweak.recommended.display)")
                print("       收益：\(finding.tweak.benefit)")
                print("       代价：\(finding.tweak.tradeoff)")
                if let process = finding.tweak.restartProcess {
                    print("       生效：需重启 \(process)")
                }
                if finding.tweak.needsRelogin {
                    print("       生效：部分应用需重新登录后才读取")
                }
            }
            let deviates = findings.filter { $0.status == .deviates }.count
            let unreadable = findings.filter { $0.status == .unreadable }.count
            print("\n== 可优化 \(deviates) 项 / 共 \(findings.count) 项"
                  + (unreadable > 0 ? "（另有 \(unreadable) 项读不到，未计入）" : ""))

            // 只读的系统状态：SIP / 门禁 / 加密 / 防火墙 / 备份 / 索引。
            // 这些**工具不会改**（需要管理员权限，或动的是安全边界），所以只报现状与去哪儿改。
            print("\n== 系统状态（只读，工具不改这些）")
            for finding in SystemStatusStore.inspect() {
                print("  [\(finding.reading.label)] \(finding.check.title)")
                print("       证据：\(finding.reading.evidence)")
                if let detail = finding.detail { print("       \(detail)") }
                print("       去哪儿改：\(finding.check.whereToChange)")
            }

            print("\n== 本命令**只读**：没有写入任何偏好，也没有重启任何进程。")
            print("   关于「未设置」：defaults 只告诉我们键在不在，不告诉我们各 App 的默认值，")
            print("   所以这里按「与推荐值不一致」呈现，而不是替系统断言它已经是默认值。")
            exit(0)
        }
        if CommandLine.arguments.contains("--prefs-roundtrip") {
            // 偏好读写删的**真机往返**自验。
            //
            // 为什么必须真机跑：`defaults write` 的参数拼法（`-bool true` / `-int 2` /
            // `-string x`）与"删键才算还原成没设过"这两件事，只有真的调一次系统命令才验得到；
            // 自检里那些注入假 runner 的用例证明的是**逻辑**，不是**机制**。
            //
            // 安全性：全程只用我们自己的临时域 `com.macclean.selftest.roundtrip`，
            // 结束时把整个域删掉，**不碰任何系统偏好**。
            print("MacClean 偏好读写往返自验（只用临时域 com.macclean.selftest.roundtrip）")
            let domain = "com.macclean.selftest.roundtrip"
            let key = "probe"
            var problems: [String] = []
            func expect(_ condition: Bool, _ what: String) {
                if condition { print("   ✅ \(what)") } else { problems.append(what); print("   ❌ \(what)") }
            }

            // 起点：先清干净
            _ = SystemTweakStore.writeRaw(domain: domain, key: key, value: .unset)
            expect(SystemTweakStore.readRaw(domain: domain, key: key, kind: .bool) == .unset,
                   "起点是「未设置」而不是读不到")

            expect(SystemTweakStore.writeRaw(domain: domain, key: key, value: .bool(true)),
                   "写入 bool 成功")
            expect(SystemTweakStore.readRaw(domain: domain, key: key, kind: .bool) == .bool(true),
                   "bool 能原样读回")

            expect(SystemTweakStore.writeRaw(domain: domain, key: key, value: .int(2)),
                   "写入 int 成功")
            expect(SystemTweakStore.readRaw(domain: domain, key: key, kind: .int) == .int(2),
                   "int 能原样读回")

            expect(SystemTweakStore.writeRaw(domain: domain, key: key, value: .string("scale")),
                   "写入 string 成功")
            expect(SystemTweakStore.readRaw(domain: domain, key: key, kind: .string) == .string("scale"),
                   "string 能原样读回")

            // 关键一条：还原"原本没设过"= 删键
            expect(SystemTweakStore.writeRaw(domain: domain, key: key, value: .unset),
                   "删键（还原成『没设过』）成功")
            expect(SystemTweakStore.readRaw(domain: domain, key: key, kind: .bool) == .unset,
                   "删键之后确实读不到了")

            // 收尾：清理临时域。
            //
            // 踩到的坑：`defaults delete <域>` 对一个只剩空字典的 plist **会失败**
            // （它报 `Domain '...' not found.`），于是那个 42 字节的 `{}` plist 留在
            // `~/Library/Preferences/` 里——第一次跑这条自验时它就是这么留下来的。
            // 所以除了 `defaults delete`，还要把属于**这个固定临时域**的 plist 文件删掉。
            //
            // 安全性：文件名由常量拼出、并且断言它就是那个临时域，别的一概不碰。
            _ = SafeProcess.run(SystemTweakStore.defaultsPath, ["delete", domain], timeout: 8)
            assert(domain == "com.macclean.selftest.roundtrip", "只允许清理这个临时域")
            let scratchPlist = ("~/Library/Preferences/\(domain).plist" as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: scratchPlist) {
                do {
                    try FileManager.default.removeItem(atPath: scratchPlist)
                } catch {
                    problems.append("临时域 plist 删不掉：\(scratchPlist)")
                }
            }
            let leftover = SystemTweakStore.readRaw(domain: domain, key: key, kind: .bool)
            expect(leftover == .unset || leftover == nil, "临时域已清理干净")
            expect(!FileManager.default.fileExists(atPath: scratchPlist), "临时域 plist 文件已删除")

            if problems.isEmpty {
                print("== 全部通过：真实 defaults 的读 / 写 / 删都可用，且没有残留 ✅")
                exit(0)
            }
            print("== 有 \(problems.count) 项未通过：")
            for problem in problems { print("   - \(problem)") }
            exit(1)
        }
    }

    var body: some Scene {
        WindowGroup(id: "mainWindow") {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1200, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            operationMenu
            navigationMenu
            settingsCommand
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(app)
        } label: {
            MenuBarLabelView()
                .environmentObject(app)
        }
        .menuBarExtraStyle(.window)
    }

    /// 「操作」菜单：刷新扫描 / 快速检索 / AI 助手抽屉（⌘R / ⌘K / ⌘I）
    private var operationMenu: some Commands {
        CommandMenu("操作") {
            Button("刷新与扫描") {
                app.refreshCurrentContext()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("快速检索…") {
                app.focusSearch()
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Button(app.ai.isDrawerOpen ? "收起 AI 助手" : "展开 AI 助手") {
                withAnimation(.easeOut(duration: 0.25)) {
                    app.ai.isDrawerOpen.toggle()
                }
            }
            .keyboardShortcut("i", modifiers: .command)
        }
    }

    /// 「导航」菜单：各功能页直达（⌘1–⌘7 / ⌘8 / ⌘U / ⌘0）
    private var navigationMenu: some Commands {
        CommandMenu("导航") {
            Button("概览") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .dashboard }
            }
            .keyboardShortcut("1", modifiers: .command)

            Button("用户缓存") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .category(.userCaches) }
            }
            .keyboardShortcut("2", modifiers: .command)

            Button("日志与临时文件") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .category(.logsAndTemp) }
            }
            .keyboardShortcut("3", modifiers: .command)

            Button("开发残留") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .category(.devResidue) }
            }
            .keyboardShortcut("4", modifiers: .command)

            Button("App 残留") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .category(.appResidue) }
            }
            .keyboardShortcut("5", modifiers: .command)

            Button("废纸篓") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .category(.largeFiles) }
            }
            .keyboardShortcut("6", modifiers: .command)

            Button("浏览器与系统数据") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .category(.browserAndSystem) }
            }
            .keyboardShortcut("7", modifiers: .command)

            Divider()

            Button("空间审计") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .spaceAudit }
            }
            .keyboardShortcut("9", modifiers: .command)

            Button("重复文件查找") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .duplicates }
            }
            .keyboardShortcut("8", modifiers: .command)

            Button("App 卸载器") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .uninstaller }
            }
            .keyboardShortcut("u", modifiers: .command)

            Button("电脑风险提醒") {
                withAnimation(.easeOut(duration: 0.15)) { app.destination = .riskCheck }
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }

    /// 「偏好设置…」入口（⌘,）
    private var settingsCommand: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("偏好设置…") {
                app.ai.showSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let app = appState {
            GlobalHotkeyManager.shared.setup(with: app)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows {
                if window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return true
                }
            }
        }
        return true
    }
}

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 300)
        } detail: {
            ZStack(alignment: .trailing) {
                // 主内容（抽屉收起时占满全部宽度）
                mainContent

                // AI 对话抽屉：覆盖在右侧，不挤占内容宽度（深度优化 d1）
                // M8：抽屉展开时主内容加右侧留白，避免遮住右侧主操作（清理/搜索框）
                if app.ai.isDrawerOpen {
                    aiChatDrawer
                }

                // AI 再筛查抽屉：筛查时弹出，展示思考过程（进度/日志/结论流）
                if app.aiReview.isDrawerOpen {
                    aiReviewDrawer
                }

                // 抽屉展开时，⌘W 与 Esc 优先收起抽屉
                drawerDismissShortcuts
            }
            .motionSafe(.easeOut(duration: 0.25), value: app.ai.isDrawerOpen)
            .motionSafe(.easeOut(duration: 0.25), value: app.aiReview.isDrawerOpen)
        }
        .onAppear {
            app.refreshDisk()
            NotificationManager.shared.requestAuthorization()
            GlobalHotkeyManager.shared.setup(with: app)
        }
        .alert("磁盘空间不足", isPresented: $app.diskMonitor.showLowSpaceAlert) {
            Button("立即扫描全部分类", role: .none) {
                withAnimation(.easeOut(duration: 0.15)) {
                    app.destination = .dashboard
                }
                app.scanAll()
            }
            Button("稍后提醒", role: .cancel) {}
        } message: {
            Text("当前可用空间仅剩 \(app.diskAvailable.byteStringCN)，已低于预设的警戒阈值 \(app.diskMonitor.config.lowSpaceThresholdGB) GB。建议立即执行系统深度清理释放空间。")
        }
        .sheet(isPresented: $app.showCleanResultSheet) {
            if let snapshot = app.lastCleanResult {
                CleanResultSheet(snapshot: snapshot) {
                    app.showCleanResultSheet = false
                    withAnimation(.easeOut(duration: 0.15)) {
                        app.destination = .history
                    }
                } onDismiss: {
                    app.showCleanResultSheet = false
                }
            }
        }
        // 扫描前的权限门。挂在顶层（ContentView）而不是各页各自挂：
        // Dashboard / 侧边栏 / 菜单栏 / 快速清理 / 空间审计 / 检索页 / ⌘R 都会走到
        // `AppState.scan` 或 `AppState.scanAll`，那一层已经把门设好，这里只负责呈现。
        .sheet(item: $app.permissionGate) { gate in
            PermissionGateSheet(gate: gate)
                .environmentObject(app)
        }
    }

    /// AI 对话抽屉：贴右覆盖，左缘分隔线 + 投影
    private var aiChatDrawer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            AIChatView()
                .overlay(
                    Rectangle()
                        .fill(Surface.hairline.opacity(0.5))
                        .frame(width: 0.8),
                    alignment: .leading
                )
                .motionSafeTransition(.move(edge: .trailing).combined(with: .opacity))
                .shadow(color: .black.opacity(0.15), radius: 18, x: -4, y: 0)
        }
        .zIndex(10)
    }

    /// AI 再筛查抽屉：筛查时弹出，展示思考过程（进度/日志/结论流）
    private var aiReviewDrawer: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            AIReviewView()
                .overlay(
                    Rectangle()
                        .fill(Surface.hairline.opacity(0.5))
                        .frame(width: 0.8),
                    alignment: .leading
                )
                .motionSafeTransition(.move(edge: .trailing).combined(with: .opacity))
                .shadow(color: .black.opacity(0.15), radius: 18, x: -4, y: 0)
        }
        .zIndex(11)
    }

    /// 抽屉展开时，⌘W 与 Esc 优先收起抽屉（无可见外观的快捷键按钮）
    @ViewBuilder
    private var drawerDismissShortcuts: some View {
        if app.ai.isDrawerOpen || app.aiReview.isDrawerOpen {
            Button("") {
                withAnimation(.easeOut(duration: 0.25)) {
                    app.ai.isDrawerOpen = false
                    app.aiReview.isDrawerOpen = false
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)

            Button("") {
                withAnimation(.easeOut(duration: 0.25)) {
                    app.ai.isDrawerOpen = false
                    app.aiReview.isDrawerOpen = false
                }
            }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
        }
    }

    private var mainContent: some View {
        Group {
            switch app.destination {
            case .dashboard:
                DashboardView()
            case .category(let cat):
                // M4：.id(cat) 强制分类切换时重建视图，避免 filterQuery 等 @State 残留
                CategoryDetailView(category: cat).id(cat)
            case .uninstaller:
                UninstallerView()
            case .duplicates:
                DuplicateView()
            case .history:
                HistoryView()
            case .search:
                SearchView()
            case .riskCheck:
                RiskView()
            case .spaceTreemap:
                SpaceVisualizerView()
            case .spaceAudit:
                SpaceAuditView()
            case .startupItems:
                StartupItemManagerView()
            case .systemOptimize:
                SystemOptimizeView()
            case .shredder:
                ShredderView()
            case .appUpdate:
                AppUpdateView()
            case .maintenance:
                MaintenanceView()
            case .browserPrivacy:
                BrowserPrivacyView()
            case .mailAttachments:
                MailAttachmentsView()
            }
        }
        .motionSafeTransition(.opacity)
        .motionSafe(Motion.micro, value: app.destination)
        // 任一抽屉展开都留白（AI 对话 / AI 再筛查）
        .padding(.trailing, (app.ai.isDrawerOpen || app.aiReview.isDrawerOpen) ? 344 : 0)
        .motionSafe(.easeOut(duration: 0.25), value: app.ai.isDrawerOpen)
        .motionSafe(.easeOut(duration: 0.25), value: app.aiReview.isDrawerOpen)
    }
}
