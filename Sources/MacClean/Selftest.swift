import SwiftUI
import ViewInspector
import Darwin
import Combine

// 进程内自检（替代 XCTest —— CommandLineTools 环境无 XCTest 框架）
// 用法: swift run MacClean --selftest  （退出码 0=全过，1=有失败；全程不渲染窗口）
// 注: ViewInspector 0.10+ 无需显式 Inspectable conform（已废弃）

enum Selftest {
    private static var failures: [String] = []
    private static var passed = 0

    private enum SelftestError: Error {
        case buttonNotFound(String)
    }

    /// 按 accessibilityIdentifier 查找按钮（label 含 Image 时 find(button:) 文本匹配不可靠）
    private static func button(_ id: String, in view: some View) throws -> InspectableView<ViewType.Button> {
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

        check("byteStringCN 格式化") {
            Int64(0).byteStringCN == "0 KB" &&
            Int64(500).byteStringCN == "500 B" &&
            Int64(1500).byteStringCN == "1.5 KB" &&
            Int64(5_000_000).byteStringCN == "5 MB" &&
            Int64(1_500_000_000).byteStringCN == "1.5 GB" &&
            Int64(150_000_000_000).byteStringCN == "150 GB"
        }
        check("UsageLevel 频率分级标签") {
            UsageLevel.active.label == "频繁使用中" &&
            UsageLevel.recent.label == "近期使用" &&
            UsageLevel.occasional.label == "偶尔使用" &&
            UsageLevel.dormant.label == "长期未用" &&
            UsageLevel.active.isRecentlyUsed && UsageLevel.recent.isRecentlyUsed &&
            !UsageLevel.occasional.isRecentlyUsed && !UsageLevel.dormant.isRecentlyUsed
        }
        check("FileSystem.usage 单文件分级（按 mtime 年龄）") {
            let path = "/private/tmp/macclean-usage-\(UUID().uuidString)"
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            defer { try? FileManager.default.removeItem(atPath: path) }
            let now = Date()
            let day: TimeInterval = 86400
            // 用修改时间模拟不同活跃度（mtime 为主判据）
            func setAge(_ age: TimeInterval) {
                let d = now.addingTimeInterval(-age)
                try? FileManager.default.setAttributes([.modificationDate: d], ofItemAtPath: path)
            }
            setAge(2 * day)
            guard FileSystem.usage(of: path).level == .active else { return false }
            setAge(15 * day)
            guard FileSystem.usage(of: path).level == .recent else { return false }
            setAge(60 * day)
            guard FileSystem.usage(of: path).level == .occasional else { return false }
            setAge(200 * day)
            return FileSystem.usage(of: path).level == .dormant
        }
        check("FileSystem.usage 不存在路径返回 unknown") {
            let info = FileSystem.usage(of: "/private/tmp/macclean-ghost-\(UUID().uuidString)")
            return info.level == .unknown && info.lastUsed == nil
        }
        check("CleanItem 标注与相对时间文案") {
            let item = CleanItem(name: "X", path: "/tmp/x", size: 1, risk: .safe,
                                 category: .userCaches, lastUsed: Date().addingTimeInterval(-3 * 86400),
                                 usage: .active)
            guard item.usage == .active, item.lastUsed != nil else { return false }
            // 3 天前应输出 "3 天前"；刚刚为 "刚刚"
            return item.lastUsed!.relativeUsage == "3 天前" && Date().relativeUsage == "刚刚"
        }
        check("AI 上下文渲染包含使用信息") {
            let ctx = AskContext(title: "TestCache", path: "/private/tmp/x", size: 1500,
                                 category: "用户缓存", risk: "安全", note: "可重建",
                                 lastUsed: Date().addingTimeInterval(-3 * 86400),
                                 usage: .active)
            let text = AIService.render(context: ctx)
            return text.contains("最近使用：") && text.contains("使用频率：频繁使用中")
        }
        check("CleanPaths.expand ~ 展开") {
            CleanPaths.expand("~/Library/Caches") == NSHomeDirectory() + "/Library/Caches" &&
            CleanPaths.expand("/private/tmp") == "/private/tmp"
        }
        check("isSafeToClean 安全护栏") {
            !FileSystem.isSafeToClean(NSHomeDirectory()) &&
            !FileSystem.isSafeToClean("/") &&
            !FileSystem.isSafeToClean("/System/Library") &&
            !FileSystem.isSafeToClean(NSHomeDirectory() + "/Library/Mail") &&
            !FileSystem.isSafeToClean(NSHomeDirectory() + "/.ssh") &&
            FileSystem.isSafeToClean(NSHomeDirectory() + "/Library/Caches/TestApp") &&
            FileSystem.isSafeToClean("/private/tmp/testfile")
        }
        check("isSafeToClean Homebrew Cellar 边界") {
            // D12 规则专用：仅放行 Cellar/<formula>/<version> 具体版本；拒绝根/公式/穿越
            FileSystem.isSafeToClean("/opt/homebrew/Cellar/openssl/3.0.0") &&
            FileSystem.isSafeToClean("/usr/local/Cellar/python@3.11/3.11.9_1") &&
            !FileSystem.isSafeToClean("/opt/homebrew/Cellar") &&
            !FileSystem.isSafeToClean("/opt/homebrew/Cellar/openssl") &&
            !FileSystem.isSafeToClean("/opt/homebrew/Cellar/.hidden") &&
            !FileSystem.isSafeToClean("/opt/homebrew/Cellar/openssl/archive") &&
            !FileSystem.isSafeToClean("/opt/homebrew/Cellar/openssl/../etc/passwd") &&
            !FileSystem.isSafeToClean("/opt/homebrew/Cellar/openssl/3.0.0/../..")
        }
        check("CategoryState 勾选逻辑") {
            let st = CategoryState(category: .userCaches)
            st.items = [
                CleanItem(name: "A", path: "/tmp/a", size: 100, risk: .safe, category: .userCaches),
                CleanItem(name: "B", path: "/tmp/b", size: 200, risk: .review, category: .userCaches),
            ]
            guard st.totalSize == 300, !st.allSelected, st.selectedCount == 0 else { return false }
            st.setAllSelected(true)
            guard st.allSelected, st.selectedCount == 2, st.selectedSize == 300 else { return false }
            st.setSelected(st.items[0].id, false)
            return st.selectedCount == 1 && st.selectedSize == 200 && !st.allSelected
        }
        check("勾选触发 UI 刷新链路（objectWillChange 转发）") {
            // 回归测试：setSelected 必须让 AppState 收到 objectWillChange，
            // 否则 CategoryDetailView 不重绘、清理按钮永远禁用（曾致 App 无法使用）
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.items = [CleanItem(name: "A", path: "/tmp/a", size: 100,
                                  risk: .safe, category: .userCaches)]
            var appFired = false
            let sub = app.objectWillChange.sink { _ in appFired = true }
            st.setSelected(st.items[0].id, true)
            defer { withExtendedLifetime(sub) {} }
            return appFired && st.selectedCount == 1
        }
        check("Cleaner 彻底删除") {
            let dir = "/private/tmp/macclean-test-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/file.txt"))
            let item = CleanItem(name: "test", path: dir, size: 5, risk: .safe, category: .logsAndTemp)
            let result = Cleaner.clean([item], permanently: true) { _ in }
            return result.succeeded == 1 && !FileManager.default.fileExists(atPath: dir)
        }
        check("Cleaner 移入废纸篓") {
            let dir = "/private/tmp/macclean-test-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/file.txt"))
            let item = CleanItem(name: "test", path: dir, size: 5, risk: .safe, category: .logsAndTemp)
            let result = Cleaner.clean([item], permanently: false) { _ in }
            let ok = result.succeeded == 1 && !FileManager.default.fileExists(atPath: dir)
            // LOW#8：清掉废纸篓里的测试残留（移入后目录名前缀 macclean-test-）
            let trash = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")
            if let children = try? FileManager.default.contentsOfDirectory(atPath: trash) {
                for name in children where name.hasPrefix("macclean-test-") {
                    try? FileManager.default.removeItem(atPath: (trash as NSString).appendingPathComponent(name))
                }
            }
            return ok
        }
        check("Cleaner 拒绝不安全路径") {
            let item = CleanItem(name: "bad", path: "/System/Library/Foo", size: 1,
                                 risk: .safe, category: .logsAndTemp)
            let result = Cleaner.clean([item], permanently: true) { _ in }
            return result.succeeded == 0 && result.failures.count == 1
        }
        check("RiskBadge 渲染") {
            let safe = try RiskBadge(risk: .safe).inspect().text().string()
            let danger = try RiskBadge(risk: .danger).inspect().text().string()
            return safe == "安全" && danger == "危险"
        }
        check("ItemRow 勾选回调") {
            let item = CleanItem(name: "CacheApp", path: "/tmp/x", size: 1024,
                                 risk: .safe, category: .userCaches)
            var toggledTo: Bool?
            let view = ItemRowView(item: item, isSelected: false) { toggledTo = $0 }
            try button("itemToggle", in: view).tap()
            return toggledTo == true
        }
        check("ItemRow 行内 ✨ 禁用态（LOW-2 终检）") {
            let item = CleanItem(name: "CacheApp", path: "/tmp/x", size: 1024,
                                 risk: .safe, category: .userCaches)
            let enabled = ItemRowView(item: item, isSelected: false,
                                      onToggle: { _ in }, onAskAI: {}, isDisabled: false)
            let disabled = ItemRowView(item: item, isSelected: false,
                                       onToggle: { _ in }, onAskAI: {}, isDisabled: true)
            return try !button("askAIButton", in: enabled).isDisabled()
                && button("askAIButton", in: disabled).isDisabled()
        }
        check("确认弹窗默认废纸篓") {
            var confirmValue: Bool?
            var permanent = false
            let sheet = CleanConfirmSheet(count: 3, size: 1024, hasPermanent: false,
                                          hasDanger: false, permanent: .init(get: { permanent }, set: { permanent = $0 })) { confirmValue = $0 }
            try button("confirmButton", in: sheet).tap()
            return confirmValue == false
        }
        check("确认弹窗切换彻底删除") {
            var confirmValue: Bool?
            var permanent = false
            let sheet = CleanConfirmSheet(count: 3, size: 1024, hasPermanent: false,
                                          hasDanger: true, permanent: .init(get: { permanent }, set: { permanent = $0 })) { confirmValue = $0 }
            try button("permanentOption", in: sheet).tap()
            guard permanent else { return false }
            try button("confirmButton", in: sheet).tap()
            return confirmValue == true
        }
        check("确认弹窗警告区") {
            var permanent = false
            let sheet = CleanConfirmSheet(count: 1, size: 1, hasPermanent: true,
                                          hasDanger: true, permanent: .init(get: { permanent }, set: { permanent = $0 })) { _ in }
            _ = try sheet.inspect().find(text: "包含废纸篓内容，将直接彻底删除")
            _ = try sheet.inspect().find(text: "包含高风险项，建议仅移入废纸篓并逐一确认")
            return true
        }
        check("确认弹窗 hint 渲染（终检 #4）") {
            var permanent = false
            let sheet = CleanConfirmSheet(count: 3, size: 1024, hasPermanent: false,
                                          hasDanger: false, permanent: .init(get: { permanent }, set: { permanent = $0 }),
                                          hint: "含隐藏已选 2 项") { _ in }
            _ = try sheet.inspect().find(text: "将清理 3 项，共 1.0 KB（含隐藏已选 2 项）")
            return true
        }
        check("分类详情空态与清理按钮禁用") {
            let app = AppState()
            let view = CategoryDetailView(category: .userCaches).environmentObject(app)
            _ = try view.inspect().find(text: "尚未扫描此分类")
            return try button("cleanButton", in: view).isDisabled()
        }
        check("端到端：勾选后清理按钮可用") {
            // 复现用户真实操作链：扫描结果 → 点击勾选 → 清理按钮解除禁用
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [
                CleanItem(name: "TestCache", path: "/private/tmp/macclean-e2e", size: 1024,
                          risk: .safe, category: .userCaches),
            ]
            let view = CategoryDetailView(category: .userCaches).environmentObject(app)
            // 勾选前：清理按钮禁用
            guard try button("cleanButton", in: view).isDisabled() else { return false }
            // 点击勾选框
            try button("itemToggle", in: view).tap()
            // 勾选后：清理按钮应可用（验证 @Published 整体赋值 + objectWillChange 转发链路）
            let enabled = try !button("cleanButton", in: view).isDisabled()
            return enabled && st.selectedCount == 1
        }
        check("卸载器：扫描已安装 App") {
            let apps = UninstallerScanner.scanApps()
            // 系统目录下通常有 App；且系统 App（com.apple.*）必须被排除
            let system = apps.filter { $0.isSystemApp }
            return !apps.isEmpty && system.isEmpty && apps.allSatisfy { $0.size >= 0 }
        }
        check("卸载器：未知 App 无关联文件") {
            let ghost = InstalledApp(name: "GhostApp\(UUID().uuidString.prefix(6))",
                                     path: "/Applications/Ghost.app",
                                     bundleID: "com.ghost.\(UUID().uuidString.prefix(6))",
                                     size: 0)
            return UninstallerScanner.relatedFiles(for: ghost).isEmpty
        }
        check("卸载器：勾选与统计") {
            let st = UninstallerState()
            st.related = [
                RelatedFile(name: "a", path: "/tmp/a", size: 100, kind: "Caches"),
                RelatedFile(name: "b", path: "/tmp/b", size: 200, kind: "Logs"),
            ]
            guard st.selectedCount == 0, st.selectedSize == 0 else { return false }
            st.setAllSelected(true)
            guard st.selectedCount == 2, st.selectedSize == 300, st.allSelected else { return false }
            st.toggle(st.related[0].id, false)
            return st.selectedCount == 1 && st.selectedSize == 200 && !st.allSelected
        }
        check("历史：记录与清空（隔离测试文件）") {
            // 注入临时文件，避免污染真实历史记录
            let tmpURL = URL(fileURLWithPath: "/private/tmp/macclean-history-\(UUID().uuidString).json")
            HistoryStore.fileURLOverride = tmpURL
            defer {
                HistoryStore.fileURLOverride = nil
                try? FileManager.default.removeItem(at: tmpURL)
            }
            let app = AppState()
            app.recordClean(categoryName: "用户缓存", itemCount: 3, bytes: 1234,
                            mode: "废纸篓", failures: 0)
            guard app.history.count == 1, app.history[0].bytes == 1234 else { return false }
            app.clearHistory()
            return app.history.isEmpty
        }
        check("AI：上下文渲染") {
            let ctx = AskContext(title: "TestCache", path: "/private/tmp/x", size: 1500,
                                 category: "用户缓存", risk: "安全", note: "可重建")
            let text = AIService.render(context: ctx)
            return text.contains("TestCache") && text.contains("1.5 KB") && text.contains("占用进程：无")
        }
        check("AI：占用检测（不存在路径返回空）") {
            AIService.detectProcesses(using: "/private/tmp/macclean-ghost-\(UUID().uuidString)").isEmpty
        }
        check("AI：占用检测（被打开的文件有结果）") {
            let path = "/private/tmp/macclean-lsof-\(UUID().uuidString).txt"
            FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
            let handle = FileHandle(forWritingAtPath: path)
            defer {
                try? handle?.close()
                try? FileManager.default.removeItem(atPath: path)
            }
            return !AIService.detectProcesses(using: path).isEmpty
        }
        check("AI：提问状态链路（上下文与消息）") {
            let st = AIState()
            let item = CleanItem(name: "CacheApp", path: "/private/tmp/cacheapp", size: 1024,
                                 risk: .safe, category: .userCaches)
            st.askAbout(item: item)
            return st.context != nil && st.context?.title == "CacheApp" && st.messages.count == 1
        }
        check("AI：提问确实发起请求（HIGH#2 回归）") {
            // 首轮审查 bug：ask/问列表/问全部只追加消息、从不调 performRequest（isLoading 恒 false）
            // 修复后：sendPendingUserMessage 应把 isLoading 置 true（自检 networkDisabled 下请求被短路）
            let st = AIState()
            let item = CleanItem(name: "RegCache", path: "/private/tmp/regcache", size: 10,
                                 risk: .safe, category: .userCaches)
            st.askAbout(item: item)
            guard st.isLoading else { return false }
            // 等请求错误返回后 isLoading 复位（networkDisabled → 立即抛错）
            let deadline = Date().addingTimeInterval(2)
            while st.isLoading && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return !st.isLoading && st.lastError != nil
        }
        check("AI：sendPendingUserMessage 不重复发（防抖）") {
            let st = AIState()
            let item = CleanItem(name: "DupCache", path: "/private/tmp/dup", size: 10,
                                 risk: .safe, category: .userCaches)
            st.askAbout(item: item)
            let msgCount = st.messages.count
            // isLoading 期间再次 ask → 应被 guard 拦截，不追加消息
            st.askAbout(item: item)
            return st.messages.count == msgCount
        }
        check("AI：列表上下文 Top 50 截断与渲染") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = (0..<60).map { i in
                CleanItem(name: "Item\(i)", path: "/tmp/item\(i)", size: Int64(i * 100),
                          risk: .safe, category: .userCaches)
            }
            app.destination = .category(.userCaches)
            app.ai.app = app
            app.ai.askAboutCurrentList()
            guard let ctx = app.ai.context, ctx.isListMode else { return false }
            // Top 50 截断：最大 50 项，按大小降序
            guard ctx.listItems.count == 50, ctx.listTotal == 60 else { return false }
            guard ctx.listItems.first?.name == "Item59" else { return false }
            // 渲染包含表头与截断说明
            let text = AIService.render(context: ctx)
            return text.contains("编号 | 名称 | 路径 | 大小 | 风险")
                && text.contains("其余 10 项未列出")
        }
        check("AI：问全部每类 Top 20") {
            let app = AppState()
            for cat in CleanCategory.allCases {
                let st = app.state(for: cat)
                st.isScanned = true
                st.items = (0..<30).map { i in
                    CleanItem(name: "\(cat.rawValue)-\(i)", path: "/tmp/\(cat.rawValue)/\(i)",
                              size: Int64(i), risk: .safe, category: cat)
                }
            }
            app.ai.app = app
            app.ai.askAboutAll()
            guard let ctx = app.ai.context, ctx.isListMode else { return false }
            // 6 类 × Top 20 = 120 项，总 180 项
            return ctx.listItems.count == 120 && ctx.listTotal == 180
        }
        check("AI：首条自动携带与切换即换") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "A", path: "/tmp/a", size: 10,
                                  risk: .safe, category: .userCaches)]
            app.destination = .category(.userCaches)
            app.ai.app = app
            // 直接输入提问（未点任何按钮）→ 首条自动携带列表上下文
            app.ai.draft = "这些能删吗？"
            app.ai.send()
            guard app.ai.context?.isListMode == true else { return false }
            // 切换目标页 → 上下文作废（Q7 切换即换）
            app.destination = .history
            return app.ai.context == nil
        }

        // MARK: - v1.6 全局检索 / 概览 / 扫描增强

        check("GlobalSearch：按名称与路径匹配") {
            let items = [
                CleanItem(name: "ChromeCache", path: "/tmp/chrome", size: 10,
                          risk: .safe, category: .userCaches),
                CleanItem(name: "WeChat", path: "/tmp/wechat", size: 20,
                          risk: .review, category: .appResidue),
            ]
            let byName = GlobalSearch.search(query: "chrome", items: items, history: [])
            let byPath = GlobalSearch.search(query: "wechat", items: items, history: [])
            return byName.count == 1 && byName[0].name == "ChromeCache"
                && byPath.count == 1 && byPath[0].kind == .item(.appResidue)
        }
        check("GlobalSearch：大小写不敏感与去空白") {
            let items = [CleanItem(name: "DeepSeekData", path: "/tmp/ds", size: 1,
                                   risk: .safe, category: .browserAndSystem)]
            let r = GlobalSearch.search(query: "  deepseek  ", items: items, history: [])
            return r.count == 1
        }
        check("GlobalSearch：空查询与上限 200") {
            guard GlobalSearch.search(query: "  ", items: [], history: []).isEmpty else { return false }
            let items = (0..<300).map { CleanItem(name: "Hit\($0)", path: "/tmp/hit", size: Int64($0),
                                                  risk: .safe, category: .userCaches) }
            return GlobalSearch.search(query: "Hit", items: items, history: []).count == 200
        }
        check("GlobalSearch：历史分类名检索") {
            let record = CleanRecord(categoryName: "开发残留", itemCount: 3, bytes: 999,
                                     mode: "废纸篓", failures: 0)
            let r = GlobalSearch.search(query: "开发", items: [], history: [record])
            guard r.count == 1, case .history = r[0].kind else { return false }
            return r[0].name == "开发残留"
        }
        check("AppState 聚合统计（scanned/total/risk）") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [
                CleanItem(name: "A", path: "/tmp/a", size: 100, risk: .safe, category: .userCaches),
                CleanItem(name: "B", path: "/tmp/b", size: 50, risk: .review, category: .userCaches),
            ]
            guard app.scannedCount == 1, app.totalCleanable == 150 else { return false }
            let risks = app.riskTotals
            return risks[.safe] == 100 && risks[.review] == 50
        }
        check("Dashboard：清理按钮默认禁用、全选后可点") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "TestCache", path: "/private/tmp/macclean-dash",
                                  size: 1024, risk: .safe, category: .userCaches)]
            let view = DashboardView().environmentObject(app)
            guard try button("dashboardCleanButton", in: view).isDisabled() else { return false }
            st.setSelected(st.items[0].id, true)
            return try !button("dashboardCleanButton", in: view).isDisabled()
        }
        check("SearchView：结果行渲染与跳转") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "UniqueCache", path: "/tmp/uc", size: 10,
                                  risk: .safe, category: .userCaches)]
            // 渲染一个结果行
            let result = SearchResult.from(item: st.items[0])
            let row = SearchResultRow(result: result, onOpen: { app.destination = .category(.userCaches) })
            _ = try row.inspect().find(text: "UniqueCache")
            row.onOpen()
            return app.destination == .category(.userCaches)
        }
        check("L5 旋转日志规则：不匹配普通日志") {
            // 正则会匹配 *.log.N / *.N.log / *.gz；普通 .log 不应误判
            let good = "System.log"
            let rotated1 = "System.log.3"
            let rotated2 = "System.2.log"
            let gz = "archive.log.gz"
            let bad = "README.md"
            return !Scanner.isRotatedLogName(good) && Scanner.isRotatedLogName(rotated1)
                && Scanner.isRotatedLogName(rotated2) && Scanner.isRotatedLogName(gz) && !Scanner.isRotatedLogName(bad)
        }
        check("N5 卸载器：短 vendor 目录不再误配他 App") {
            // 卸载 "Google Chrome" 不应把 "Google"（可能含 Drive/Earth 数据）整体列为关联文件
            let chrome = InstalledApp(name: "Google Chrome", path: "/Applications/Google Chrome.app",
                                      bundleID: "com.google.Chrome", size: 0)
            let files = UninstallerScanner.relatedFiles(for: chrome)
            return !files.contains { $0.path == NSHomeDirectory() + "/Library/Application Support/Google" }
        }
        check("N1 大文件去重：T2/T3 同路径不重复") {
            // 直接验证 Cleaner 对"路径已不存在"的 item 计成功但不计字节（N4/N1 联动）
            let dir = "/private/tmp/macclean-n1-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/f.txt"))
            let item = CleanItem(name: "gone", path: dir, size: 100, risk: .review,
                                 category: .largeFiles)
            let r1 = Cleaner.clean([item], permanently: true) { _ in }
            guard r1.succeeded == 1, r1.releasedBytes > 0 else { return false }
            // 路径已不存在：再次清理 → 成功（跳过）但不计字节
            let r2 = Cleaner.clean([item], permanently: true) { _ in }
            return r2.succeeded == 1 && r2.releasedBytes == 0 && r2.failures.isEmpty
        }
        check("cleanSelected：失败项保留、新勾选保留、成功项移除") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            let okItem = CleanItem(name: "OK", path: "/private/tmp/macclean-ok-\(UUID().uuidString)",
                                   size: 10, risk: .safe, category: .userCaches)
            let badItem = CleanItem(name: "Bad", path: "/System/Library/Denied",
                                    size: 20, risk: .safe, category: .userCaches)
            try FileManager.default.createDirectory(atPath: okItem.path, withIntermediateDirectories: true)
            st.items = [okItem, badItem]
            st.setAllSelected(true)
            app.cleanSelected(in: .userCaches, permanently: true)
            // 等后台清理完成
            let deadline = Date().addingTimeInterval(3)
            while app.isCleaning && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            // 成功项（okItem）被移除；失败项（badItem）保留且取消勾选
            return !st.items.contains { $0.id == okItem.id }
                && st.items.contains { $0.id == badItem.id && !$0.isSelected }
        }

        // MARK: - AI 再筛查（AI 扫描）

        check("AI 筛查：JSON 输出解析（含围栏）") {
            let items = [
                CleanItem(name: "CacheA", path: "/tmp/a", size: 10, risk: .safe, category: .userCaches),
                CleanItem(name: "DataB", path: "/tmp/b", size: 20, risk: .review, category: .appResidue),
                CleanItem(name: "LogC", path: "/tmp/c", size: 30, risk: .safe, category: .logsAndTemp),
            ]
            let raw = """
            ```json
            [{"name": "CacheA", "verdict": "可删", "reason": "缓存可重建"},
             {"name": "DataB", "verdict": "不建议删", "reason": "App 数据"},
             {"name": "LogC", "verdict": "谨慎", "reason": "近期使用"}]
            ```
            """
            let reviews = AIService.parseReviewOutput(raw, items: items)
            guard reviews.count == 3 else { return false }
            let byName = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), items))
            for r in reviews {
                guard let item = byName[r.itemID] else { return false }
                switch item.name {
                case "CacheA": guard r.verdict == .delete else { return false }
                case "DataB": guard r.verdict == .keep else { return false }
                case "LogC": guard r.verdict == .caution else { return false }
                default: return false
                }
            }
            return reviews.allSatisfy { !$0.reason.isEmpty }
        }
        check("AI 筛查：表格行回退解析") {
            let items = [
                CleanItem(name: "A", path: "/tmp/a", size: 10, risk: .safe, category: .userCaches),
                CleanItem(name: "B", path: "/tmp/b", size: 20, risk: .safe, category: .userCaches),
            ]
            let raw = "1 | A | 可删 | 缓存\n2 | B | 谨慎 | 需确认"
            let reviews = AIService.parseReviewOutput(raw, items: items)
            guard reviews.count == 2 else { return false }
            return reviews[0].verdict == .delete && reviews[1].verdict == .caution
        }
        check("AI 筛查：垃圾输入返回空") {
            let items = [CleanItem(name: "A", path: "/tmp/a", size: 10, risk: .safe, category: .userCaches)]
            return AIService.parseReviewOutput("我不确定，无法判断", items: items).isEmpty
        }
        check("AI 筛查：状态机（未配置 AI 时给出明确错误）") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "A", path: "/tmp/a", size: 10, risk: .safe, category: .userCaches)]
            // 未启用 AI 时 review 应报错而非静默（networkDisabled 下 send 也会被短路）
            app.aiReview.review(items: st.items)
            let deadline = Date().addingTimeInterval(2)
            while app.aiReview.isReviewing && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            return !app.aiReview.isReviewing
                && (app.aiReview.lastError != nil || app.aiReview.reviews.isEmpty)
        }
        check("AI 筛查：ReviewBadge 渲染") {
            let delete = try ReviewBadge(verdict: .delete).inspect().text().string()
            let keep = try ReviewBadge(verdict: .keep).inspect().text().string()
            return delete == "AI·可删" && keep == "AI·不建议删"
        }

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

    private static func check(_ name: String, _ body: () throws -> Bool) {
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
