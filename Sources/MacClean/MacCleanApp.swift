import SwiftUI

@main
struct MacCleanApp: App {
    @StateObject private var app = AppState()

    init() {
        // 无头测试模式：swift run MacClean --selftest（进程内 UI 自检，零窗口）
        if CommandLine.arguments.contains("--selftest") {
            exit(Selftest.run())
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
                switch app.destination {
                case .category(let cat):
                    CategoryDetailView(category: cat)
                case .uninstaller:
                    UninstallerView()
                case .history:
                    HistoryView()
                case nil:
                    Text("选择一个功能开始")
                        .font(Theme.bodyFont(17))
                        .foregroundColor(Theme.inkMuted48)
                }

                // AI 抽屉：覆盖在右侧，不挤占内容宽度（深度优化 d1）
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
        }
        .background(Theme.parchment)
        .onAppear { app.refreshDisk() }
    }
}
