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
                .frame(minWidth: 900, minHeight: 580)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

struct ContentView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
            } detail: {
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
            }

            // 右侧 AI 对话面板
            Divider().overlay(Theme.hairline)
            AIChatView()
        }
        .background(Theme.parchment)
        .onAppear { app.refreshDisk() }
    }
}
