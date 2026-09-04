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
        // 无头扫描模式：swift run MacClean --scan
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
                    print("   [\(item.risk.label)] \(item.name) — \(item.size.byteString) — \(item.path)")
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

                // AI 抽屉：覆盖在右侧，不挤占内容宽度（深度优化 d1）
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
            }
            .animation(.easeOut(duration: 0.25), value: app.ai.isDrawerOpen)
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
            }
        }
        .padding(.trailing, app.ai.isDrawerOpen ? 344 : 0)
        .animation(.easeOut(duration: 0.25), value: app.ai.isDrawerOpen)
    }
}
