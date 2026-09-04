import SwiftUI

@main
struct MacCleanApp: App {
    @StateObject private var app = AppState()

    init() {
        // 无头测试模式：swift run MacClean --selftest（进程内 UI 自检，零窗口）
        if CommandLine.arguments.contains("--selftest") {
            exit(Selftest.run())
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
            let results = CleanCategory.allCases.map { cat -> (String, [CleanItem]) in
                let items = (try? Scanner.scan(cat)) ?? []
                return (cat.title, items)
            }
            var total: Int64 = 0
            for (title, items) in results {
                let sum = items.reduce(Int64(0)) { $0 + $1.size }
                total += sum
                print("== \(title): \(items.count) 项, \(sum.byteString)")
                for item in items.prefix(10) {
                    let usage = item.lastUsed.map { "\($0.relativeUsage) · \(item.usage.label)" } ?? item.usage.label
                    print("   [\(item.risk.label)] \(item.name) — \(item.size.byteString) — \(item.path) — 使用:\(usage)")
                }
            }
            print("== 总计可清理: \(total.byteString)")
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1200, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
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
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        AIChatView()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .shadow(color: .black.opacity(0.10), radius: 18, x: -4, y: 0)
                    }
                    .zIndex(10)
                }

                // AI 再筛查抽屉：筛查时弹出，展示思考过程（进度/日志/结论流）
                if app.aiReview.isDrawerOpen {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        AIReviewView()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                            .shadow(color: .black.opacity(0.10), radius: 18, x: -4, y: 0)
                    }
                    .zIndex(11)
                }
            }
            .animation(.easeOut(duration: 0.25), value: app.ai.isDrawerOpen)
            .animation(.easeOut(duration: 0.25), value: app.aiReview.isDrawerOpen)
        }
        .background(Theme.parchment)
        .onAppear { app.refreshDisk() }
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
            case .history:
                HistoryView()
            case .search:
                SearchView()
            case .riskCheck:
                RiskView()
            }
        }
        // 任一抽屉展开都留白（AI 对话 / AI 再筛查）
        .padding(.trailing, (app.ai.isDrawerOpen || app.aiReview.isDrawerOpen) ? 344 : 0)
        .animation(.easeOut(duration: 0.25), value: app.ai.isDrawerOpen)
        .animation(.easeOut(duration: 0.25), value: app.aiReview.isDrawerOpen)
    }
}
