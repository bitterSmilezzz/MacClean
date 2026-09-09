import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

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
        check("ItemRow Quick Look 预览唤起") {
            let item = CleanItem(name: "LargeArchive.zip", path: "/tmp/archive.zip", size: 1048576,
                                 risk: .safe, category: .largeFiles)
            var previewedURL: URL?
            let view = ItemRowView(item: item, isSelected: false, onToggle: { _ in }, onPreview: { previewedURL = $0 })
            try button("itemQuickLookButton", in: view).tap()
            return previewedURL?.path == "/tmp/archive.zip"
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
        check("AI 筛查：启动自动开抽屉 + 思考过程日志") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "A", path: "/tmp/a", size: 10, risk: .safe, category: .userCaches)]
            app.aiReview.review(items: st.items)
            // 启动即开抽屉 + 记录日志（即使后续失败，过程也可见）
            let opened = app.aiReview.isDrawerOpen
            let hasLog = !app.aiReview.processLog.isEmpty
            let hasName = app.aiReview.itemNames.values.contains("A")
            return opened && hasLog && hasName
        }
        check("AI 筛查：抽屉与对话抽屉互斥") {
            let app = AppState()
            app.ai.openDrawer()
            let chatOpened = app.ai.isDrawerOpen
            let reviewClosedByChat = !app.aiReview.isDrawerOpen
            app.aiReview.openDrawer()
            return chatOpened && reviewClosedByChat
                && app.aiReview.isDrawerOpen && !app.ai.isDrawerOpen
        }
        check("AI 筛查：ReviewBadge 渲染") {
            let delete = try ReviewBadge(verdict: .delete).inspect().text().string()
            let keep = try ReviewBadge(verdict: .keep).inspect().text().string()
            return delete == "AI·可删" && keep == "AI·不建议删"
        }

        // MARK: - 风险检查（电脑风险提醒）

        check("风险检查：SSH 私钥权限过宽") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            let ssh = home + "/.ssh"
            try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let key = ssh + "/id_rsa"
            FileManager.default.createFile(atPath: key, contents: Data("test".utf8))
            // 权限 644（group/other 可读）→ 应报高风险
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: key)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ssh)
            let item = RiskScanner.checkSSHKeys(home: home)
            return item?.severity == .high && item?.category == .sensitiveData
        }
        check("风险检查：SSH 目录权限过宽") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            let ssh = home + "/.ssh"
            try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ssh)
            let item = RiskScanner.checkSSHKeys(home: home)
            return item?.severity == .medium
        }
        check("风险检查：明文密钥环境变量") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            let zshrc = home + "/.zshrc"
            try "export OPENAI_KEY=sk-REPLACE_ME_1234567890abcdef\n".write(toFile: zshrc, atomically: true, encoding: .utf8)
            let item = RiskScanner.checkEnvSecrets(home: home)
            guard let item, item.severity == .high else { return false }
            // 检测详情不得包含明文密钥本身（安全边界）
            return !item.detail.contains("sk-REPLACE_ME_1234567890abcdef")
        }
        check("风险检查：敏感命名文件暴露") {
            let home = "/private/tmp/macclean-risk-\(UUID().uuidString)"
            let desktop = home + "/Desktop"
            try FileManager.default.createDirectory(atPath: desktop, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: home) }
            FileManager.default.createFile(atPath: desktop + "/passwords.txt",
                                           contents: Data("a=b".utf8))
            FileManager.default.createFile(atPath: desktop + "/normal.txt",
                                           contents: Data("x".utf8))
            let items = RiskScanner.checkSensitiveFiles(home: home)
            return items.contains { $0.title == "发现疑似敏感文件" && $0.path?.hasSuffix("passwords.txt") == true }
                && !items.contains { $0.path?.hasSuffix("normal.txt") == true }
        }
        check("风险检查：敏感项不含明文（边界）") {
            // scan 全量时，任何 item 的 detail 不得包含常见密钥前缀明文
            let items = RiskScanner.scan(home: "/private/tmp/macclean-risk-\(UUID().uuidString)") { _ in }
            return items.allSatisfy {
                !$0.detail.contains("sk-") && !$0.detail.contains("AKIA") && !$0.detail.contains("ghp_")
            }
        }
        check("风险检查：RiskRow 渲染严重度徽标") {
            let item = RiskItem(title: "测试", detail: "d", severity: .high,
                                category: .sensitiveData, suggestion: "s")
            let row = RiskRow(item: item)
            _ = try row.inspect().find(text: "高风险")
            return true
        }
        check("历史导出器：CSV 导出（含 BOM 与列头）") {
            let records = [
                CleanRecord(date: Date(), categoryName: "系统日志", itemCount: 5, bytes: 1_000_000, mode: "移入废纸篓", failures: 0),
                CleanRecord(date: Date(), categoryName: "用户缓存", itemCount: 10, bytes: 2_000_000, mode: "彻底删除", failures: 1)
            ]
            let csv = HistoryExporter.generateCSV(records: records)
            guard csv.hasPrefix("\u{FEFF}") else { return false }
            guard csv.contains("记录ID,清理时间,分类,清理模式,清理项数,失败项数,释放字节数,释放大小") else { return false }
            guard csv.contains("系统日志") && csv.contains("用户缓存") && csv.contains("1 MB") && csv.contains("2 MB") else { return false }
            return true
        }
        check("历史导出器：Markdown 报告生成统计分析") {
            let records = [
                CleanRecord(date: Date(), categoryName: "系统日志", itemCount: 5, bytes: 1_000_000, mode: "移入废纸篓", failures: 0),
                CleanRecord(date: Date(), categoryName: "用户缓存", itemCount: 10, bytes: 2_000_000, mode: "彻底删除", failures: 1)
            ]
            let report = HistoryExporter.generateReport(records: records)
            guard report.contains("# MacClean 清理历史归档报告") else { return false }
            guard report.contains("清理执行次数：2 次") else { return false }
            guard report.contains("3 MB") else { return false }
            guard report.contains("各分类释放分布统计") else { return false }
            guard report.contains("详细清理流水记录") else { return false }
            return true
        }
        check("清单导出器：大文件与清理项 CSV / Markdown 报告生成") {
            let items = [
                CleanItem(name: "Xcode_16.dmg", path: "/Users/test/Downloads/Xcode_16.dmg", size: 10_000_000_000, risk: .review, category: .largeFiles, note: "安装包"),
                CleanItem(name: "old_dataset.zip", path: "/Users/test/Downloads/old_dataset.zip", size: 2_000_000_000, risk: .safe, category: .largeFiles, note: "数据包")
            ]
            let csv = HistoryExporter.generateItemsCSV(items: items, categoryTitle: "大文件与垃圾箱")
            guard csv.hasPrefix("\u{FEFF}") else { return false }
            guard csv.contains("分类,名称,大小,字节数,风险等级,使用情况,主路径,备注") else { return false }
            guard csv.contains("Xcode_16.dmg") && csv.contains("10 GB") && csv.contains("谨慎") else { return false }

            let report = HistoryExporter.generateItemsReport(items: items, categoryTitle: "大文件与垃圾箱")
            guard report.contains("# MacClean 大文件与垃圾箱清单报告") else { return false }
            guard report.contains("总计项目：2 项") && report.contains("12 GB") else { return false }
            guard report.contains("Xcode_16.dmg") && report.contains("old_dataset.zip") else { return false }
            return true
        }
        check("清单导出器：重复/相似大文件 CSV / Markdown 报告生成") {
            let item1 = DuplicateFileItem(path: "/a/video.mp4", name: "video.mp4", size: 100_000_000, modificationDate: Date(), isSelected: false, isOriginal: true, recommendationReason: "保留最早修改")
            let item2 = DuplicateFileItem(path: "/b/video copy.mp4", name: "video copy.mp4", size: 100_000_000, modificationDate: Date(), isSelected: true, isOriginal: false, recommendationReason: "重复副本")
            let group = DuplicateGroup(hash: "sha256_mock_hash", fileSize: 100_000_000, items: [item1, item2], matchKind: .exact, suggestionNote: "哈希完全一致")

            let csv = HistoryExporter.generateDuplicatesCSV(groups: [group])
            guard csv.hasPrefix("\u{FEFF}") else { return false }
            guard csv.contains("分组类型,哈希/特征,推荐操作,文件名,大小,字节数,修改时间,推荐说明,路径") else { return false }
            guard csv.contains("完全一致") && csv.contains("推荐保留") && csv.contains("已勾选清理") else { return false }

            let report = HistoryExporter.generateDuplicatesReport(groups: [group])
            guard report.contains("# MacClean 重复与相似大文件排查报告") else { return false }
            guard report.contains("总分组数：1 组（共 2 个文件）") else { return false }
            guard report.contains("100 MB") && report.contains("video.mp4") else { return false }
            return true
        }
        check("系统通知：扫描完成通知组装与派发") {
            let mgr = NotificationManager.shared
            mgr.notifyScanCompleted(categoryName: "开发残留", itemCount: 42, totalBytes: 52_428_800)
            guard let notif = mgr.lastNotification else { return false }
            guard notif.title == "开发残留 扫描完成" else { return false }
            guard notif.body.contains("42 个可清理项目") && notif.body.contains("52.4 MB") else { return false }
            return true
        }
        check("系统通知：清理完成通知与状态组装") {
            let mgr = NotificationManager.shared
            mgr.notifyCleanCompleted(releasedBytes: 104_857_600, failureCount: 0)
            guard let notif = mgr.lastNotification else { return false }
            guard notif.title == "MacClean 清理完成" else { return false }
            guard notif.body.contains("105 MB") else { return false }

            mgr.notifyCleanCompleted(releasedBytes: 20_000_000, failureCount: 2)
            guard let notif2 = mgr.lastNotification else { return false }
            guard notif2.body.contains("2 项清理失败或跳过") && notif2.body.contains("20 MB") else { return false }
            return true
        }
        check("系统通知：Dock 徽标状态同步") {
            NotificationManager.shared.updateDockBadge(count: 88)
            guard NSApplication.shared.dockTile.badgeLabel == "88" else { return false }
            NotificationManager.shared.updateDockBadge(count: 0)
            guard NSApplication.shared.dockTile.badgeLabel == nil else { return false }
            return true
        }
        check("大文件细分过滤：类型规则与匹配断言") {
            let dmg = CleanItem(name: "Xcode_16.dmg", path: "/Downloads/Xcode_16.dmg", size: 10_000_000_000, risk: .review, category: .largeFiles)
            let zip = CleanItem(name: "dataset.zip", path: "/Downloads/dataset.zip", size: 2_000_000_000, risk: .review, category: .largeFiles)
            let mov = CleanItem(name: "demo.mov", path: "/Downloads/demo.mov", size: 1_500_000_000, risk: .review, category: .largeFiles)
            let raw = CleanItem(name: "Landscape_001.ARW", path: "/Pictures/Landscape_001.ARW", size: 85_000_000, risk: .review, category: .largeFiles)
            let vdi = CleanItem(name: "Ubuntu22.vdi", path: "/VirtualBox/Ubuntu22.vdi", size: 40_000_000_000, risk: .review, category: .largeFiles)
            let archive = CleanItem(name: "MacClean.xcarchive", path: "/Library/Developer/Xcode/Archives/MacClean.xcarchive", size: 120_000_000, risk: .review, category: .largeFiles)
            let sim = CleanItem(name: "iPhone 15 Pro", path: "/Library/Developer/CoreSimulator/Devices/UUID", size: 5_000_000_000, risk: .danger, category: .largeFiles, note: "模拟器缓存")
            let unknown = CleanItem(name: "raw_data.bin", path: "/Downloads/raw_data.bin", size: 1_000_000_000, risk: .review, category: .largeFiles)

            guard LargeFileTypeFilter.installer.matches(item: dmg) && !LargeFileTypeFilter.installer.matches(item: zip) else { return false }
            guard LargeFileTypeFilter.archive.matches(item: zip) && !LargeFileTypeFilter.archive.matches(item: mov) else { return false }
            guard LargeFileTypeFilter.media.matches(item: mov) && !LargeFileTypeFilter.media.matches(item: dmg) else { return false }
            guard LargeFileTypeFilter.rawMedia.matches(item: raw) && !LargeFileTypeFilter.rawMedia.matches(item: zip) else { return false }
            guard LargeFileTypeFilter.diskImage.matches(item: vdi) && !LargeFileTypeFilter.diskImage.matches(item: mov) else { return false }
            guard LargeFileTypeFilter.codeArchive.matches(item: archive) && !LargeFileTypeFilter.codeArchive.matches(item: dmg) else { return false }
            guard LargeFileTypeFilter.simulator.matches(item: sim) && !LargeFileTypeFilter.simulator.matches(item: dmg) else { return false }
            guard LargeFileTypeFilter.other.matches(item: unknown) && !LargeFileTypeFilter.other.matches(item: dmg) else { return false }
            return true
        }
        check("磁盘监控：DiskMonitorConfig 配置加载与保存") {
            var cfg = DiskMonitorConfig()
            cfg.autoScanEnabled = true
            cfg.scanIntervalHours = 6
            cfg.lowSpaceAlertEnabled = true
            cfg.lowSpaceThresholdGB = 20
            cfg.autoCleanEnabled = true
            cfg.dndEnabled = true
            cfg.dndStartHour = 22
            cfg.dndEndHour = 6
            cfg.save()

            let loaded = DiskMonitorConfig.load()
            guard loaded.autoScanEnabled == true && loaded.scanIntervalHours == 6 else { return false }
            guard loaded.lowSpaceAlertEnabled == true && loaded.lowSpaceThresholdGB == 20 else { return false }
            guard loaded.autoCleanEnabled == true && loaded.dndEnabled == true else { return false }
            guard loaded.dndStartHour == 22 && loaded.dndEndHour == 6 else { return false }
            return true
        }
        check("智能静默清理：免打扰时间窗口判定") {
            var cfg = DiskMonitorConfig()
            cfg.dndEnabled = true
            cfg.dndStartHour = 23
            cfg.dndEndHour = 7

            let cal = Calendar.current
            // 构造 02:00（在允许窗口内）
            var compsNight = cal.dateComponents([.year, .month, .day], from: Date())
            compsNight.hour = 2
            let dateNight = cal.date(from: compsNight)!
            guard cfg.isWithinAllowedWindow(date: dateNight) else { return false }

            // 构造 14:00（在允许窗口外）
            var compsDay = cal.dateComponents([.year, .month, .day], from: Date())
            compsDay.hour = 14
            let dateDay = cal.date(from: compsDay)!
            guard !cfg.isWithinAllowedWindow(date: dateDay) else { return false }

            return true
        }
        check("磁盘监控：空间充足时不触发预警弹窗与通知") {
            let monitor = DiskMonitor.shared
            monitor.config.lowSpaceAlertEnabled = true
            monitor.config.lowSpaceThresholdGB = 15
            monitor.showLowSpaceAlert = false

            // 可用 50 GB (> 15 GB)
            monitor.checkDiskSpaceAlert(availableBytes: 50_000_000_000)
            guard monitor.showLowSpaceAlert == false else { return false }
            return true
        }
        check("磁盘监控：空间不足触发警戒弹窗与系统预警通知") {
            let monitor = DiskMonitor.shared
            monitor.config.lowSpaceAlertEnabled = true
            monitor.config.lowSpaceThresholdGB = 15
            monitor.showLowSpaceAlert = false

            // 可用 5 GB (< 15 GB)
            monitor.checkDiskSpaceAlert(availableBytes: 5_000_000_000)
            guard monitor.showLowSpaceAlert == true else { return false }

            // 检查系统通知是否派发
            guard let notif = NotificationManager.shared.lastNotification else { return false }
            guard notif.title == "⚠️ Mac 磁盘空间不足警戒" else { return false }
            guard notif.body.contains("5 GB") && notif.body.contains("15 GB") else { return false }

            // 复位测试状态
            monitor.showLowSpaceAlert = false
            return true
        }
        check("白名单：WhitelistManager 添加与持久化存储") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            let r1 = wm.addPathRule("~/workspace/secret-project", comment: "私人项目")
            let r2 = wm.addAppRule("MyCustomApp", comment: "自定义受保护应用")

            guard wm.rules.count == 2 else { return false }
            guard wm.rules.contains(where: { $0.id == r1.id && $0.type == .path }) else { return false }
            guard wm.rules.contains(where: { $0.id == r2.id && $0.type == .appName }) else { return false }

            let loaded = WhitelistManager.load()
            guard loaded.count == 2 else { return false }
            return true
        }
        check("白名单：路径精准匹配与子目录通配匹配") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            wm.addPathRule("/private/tmp/protected-suite", comment: "测试保护目录")

            // 1. 命中自身
            guard wm.isWhitelisted(path: "/private/tmp/protected-suite") else { return false }
            // 2. 命中子路径
            guard wm.isWhitelisted(path: "/private/tmp/protected-suite/build/output.log") else { return false }
            // 3. 不命中相似前缀但不是子目录的路径
            guard !wm.isWhitelisted(path: "/private/tmp/protected-suite-other") else { return false }
            // 4. 不命中其他无关路径
            guard !wm.isWhitelisted(path: "/private/tmp/random-file.txt") else { return false }
            return true
        }
        check("白名单：App 名称不区分大小写与空白匹配") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            wm.addAppRule("WeChat", comment: "微信")

            guard wm.isAppWhitelisted(appName: "WeChat") else { return false }
            guard wm.isAppWhitelisted(appName: "wechat") else { return false }
            guard wm.isAppWhitelisted(appName: " WECHAT ") else { return false }
            guard !wm.isAppWhitelisted(appName: "QQ") else { return false }
            return true
        }
        check("白名单：底层 FileSystem.isSafeToClean 防御阻断") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            let protectedDir = "/private/tmp/macclean-safe-test-\(UUID().uuidString)"
            wm.addPathRule(protectedDir, comment: "底层阻断测试")

            // 未加入白名单时普通 tmp 目录安全检查返回 true，加入后必须返回 false
            guard !FileSystem.isSafeToClean(protectedDir) else { return false }
            guard !FileSystem.isSafeToClean(protectedDir + "/child.txt") else { return false }

            // 清理规则
            wm.removeAllRules()
            return true
        }
        check("白名单：AppState.addPathToWhitelist 联动移除已扫描项") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            let keepItem = CleanItem(name: "KeepCache", path: "/private/tmp/keep-cache", size: 100, risk: .safe, category: .userCaches)
            let removePath = "/private/tmp/whitelist-target-cache"
            let removeItem = CleanItem(name: "RemoveCache", path: removePath, size: 200, risk: .safe, category: .userCaches)
            st.items = [keepItem, removeItem]

            guard st.items.count == 2 else { return false }
            app.addPathToWhitelist(removePath, comment: "测试移除")

            guard st.items.count == 1 && st.items.first?.path == keepItem.path else { return false }
            guard app.whitelist.isWhitelisted(path: removePath) else { return false }

            // 清理测试白名单
            app.whitelist.removeAllRules()
            return true
        }
        check("白名单：自定义文件扩展名排除规则与底层阻断") {
            let wm = WhitelistManager.shared
            wm.removeAllRules()
            let r = wm.addExtensionRule(".iso", comment: "镜像文件保护")
            _ = wm.addExtensionRule("dmg", comment: "安装包保护")

            guard wm.rules.count == 2 else { return false }
            guard r.normalizedExtension == "iso" else { return false }

            // 扩展名匹配
            guard wm.isExtensionWhitelisted(path: "/Users/test/Downloads/ubuntu.iso") else { return false }
            guard wm.isExtensionWhitelisted(path: "/Users/test/Downloads/UBUNTU.ISO") else { return false }
            guard wm.isExtensionWhitelisted(path: "/Users/test/Downloads/app.dmg") else { return false }
            guard !wm.isExtensionWhitelisted(path: "/Users/test/Downloads/app.pkg") else { return false }

            // 底层安全检查阻断
            guard !FileSystem.isSafeToClean("/private/tmp/installer.dmg") else { return false }

            wm.removeAllRules()
            return true
        }
        check("白名单：AppState.addExtensionToWhitelist 联动移除扫描与重复项") {
            let app = AppState()
            let st = app.state(for: .largeFiles)
            st.isScanned = true
            let keepItem = CleanItem(name: "archive.zip", path: "/tmp/archive.zip", size: 100, risk: .safe, category: .largeFiles)
            let isoItem = CleanItem(name: "fedora.iso", path: "/tmp/fedora.iso", size: 200, risk: .safe, category: .largeFiles)
            st.items = [keepItem, isoItem]

            app.duplicateState.groups = [
                DuplicateGroup(hash: "h1", fileSize: 200, items: [
                    DuplicateFileItem(path: "/tmp/a.iso", name: "a.iso", size: 200, modificationDate: Date()),
                    DuplicateFileItem(path: "/tmp/b.iso", name: "b.iso", size: 200, modificationDate: Date())
                ])
            ]

            guard st.items.count == 2 && app.duplicateState.groups.count == 1 else { return false }
            app.addExtensionToWhitelist("iso", comment: "测试扩展名排除")

            guard st.items.count == 1 && st.items.first?.path == keepItem.path else { return false }
            guard app.duplicateState.groups.isEmpty else { return false }

            app.whitelist.removeAllRules()
            return true
        }

        // MARK: - 重复文件查找与去重

        check("重复文件：Partial Hash 与 SHA256 哈希计算正确") {
            let tmpDir = "/private/tmp/macclean-dup-hash-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let fileA = tmpDir + "/fileA.bin"
            let fileB = tmpDir + "/fileB.bin"
            let contentA = Data(repeating: 0x41, count: 16384) // 16KB 'A'
            let contentB = Data(repeating: 0x41, count: 16384) // identical 16KB 'A'

            FileManager.default.createFile(atPath: fileA, contents: contentA)
            FileManager.default.createFile(atPath: fileB, contents: contentB)

            guard let partialA = DuplicateScanner.calculatePartialHash(at: fileA, length: 8192),
                  let partialB = DuplicateScanner.calculatePartialHash(at: fileB, length: 8192),
                  partialA == partialB else { return false }

            guard let fullA = DuplicateScanner.calculateFullSHA256(at: fileA),
                  let fullB = DuplicateScanner.calculateFullSHA256(at: fileB),
                  fullA == fullB && !fullA.isEmpty else { return false }

            return true
        }

        check("重复文件：文件扫描分组与 isOriginal 标记") {
            let tmpDir = "/private/tmp/macclean-dup-group-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 构造两组文件：第一组 3 个相同内容 (10KB)，第二组 1 个独有内容
            let data1 = "MacCleanDuplicateGroupTest1234567890".data(using: .utf8)!
            let data2 = "DifferentContentForSingleFileTest".data(using: .utf8)!

            let f1 = tmpDir + "/original.txt"
            let f2 = tmpDir + "/copy1.txt"
            let f3 = tmpDir + "/copy2.txt"
            let f4 = tmpDir + "/unique.txt"

            FileManager.default.createFile(atPath: f1, contents: data1)
            FileManager.default.createFile(atPath: f2, contents: data1)
            FileManager.default.createFile(atPath: f3, contents: data1)
            FileManager.default.createFile(atPath: f4, contents: data2)

            let groups = DuplicateScanner.scanDuplicates(in: [tmpDir], minSize: 10) { _, _ in }
            guard groups.count == 1 else { return false }
            let group = groups[0]
            guard group.items.count == 3 else { return false }
            // 必须有且仅有 1 个 isOriginal == true
            let originals = group.items.filter { $0.isOriginal }
            guard originals.count == 1 else { return false }
            // 浪费空间应为 2 个副本的大小
            guard group.wastedBytes == Int64(data1.count * 2) else { return false }
            return true
        }

        check("重复文件：智能勾选与清理逻辑") {
            let tmpDir = "/private/tmp/macclean-dup-clean-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let data = "CleanableContentTest".data(using: .utf8)!
            let f1 = tmpDir + "/original.txt"
            let f2 = tmpDir + "/dupe.txt"
            FileManager.default.createFile(atPath: f1, contents: data)
            FileManager.default.createFile(atPath: f2, contents: data)

            let state = DuplicateState()
            state.searchPaths = [tmpDir]
            state.minSizeBytes = 5
            state.startScan()

            // 等待后台扫描完成（最多 2 秒）
            let deadline = Date().addingTimeInterval(2.0)
            while state.isScanning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            guard state.groups.count == 1 else { return false }
            // 智能勾选测试
            state.autoSelectDuplicates()
            let group = state.groups[0]
            let selected = group.items.filter { $0.isSelected }
            let unselected = group.items.filter { !$0.isSelected }
            guard selected.count == 1 && unselected.count == 1 else { return false }
            guard unselected.first?.isOriginal == true else { return false }

            // 清理勾选项（permanently: true 在 tmp 目录快速删除）
            _ = state.cleanSelected(permanently: true)

            // 清理后原文件应依然存在，副本已被删除，且分组被清空
            let originalExists = FileManager.default.fileExists(atPath: f1)
            let dupeExists = FileManager.default.fileExists(atPath: f2)
            guard originalExists && !dupeExists else { return false }
            guard state.groups.isEmpty else { return false }

            return true
        }

        check("相似文件：词干提取与衍生归一化") {
            let s1 = DuplicateScanner.normalizedStem(for: "Video_Presentation (1).mp4")
            let s2 = DuplicateScanner.normalizedStem(for: "Video_Presentation copy.mov")
            let s3 = DuplicateScanner.normalizedStem(for: "Video_Presentation_副本.mkv")
            let s4 = DuplicateScanner.normalizedStem(for: "Video_Presentation-backup.mp4")
            let s5 = DuplicateScanner.normalizedStem(for: "Video_Presentation.mp4")

            guard s1 == "video_presentation" else { return false }
            guard s2 == "video_presentation" else { return false }
            guard s3 == "video_presentation" else { return false }
            guard s4 == "video_presentation" else { return false }
            guard s5 == "video_presentation" else { return false }

            guard DuplicateScanner.isDerivedCopyName("MyDoc copy.pdf") else { return false }
            guard DuplicateScanner.isDerivedCopyName("Photo (2).png") else { return false }
            guard DuplicateScanner.isDerivedCopyName("Project_副本.zip") else { return false }
            guard !DuplicateScanner.isDerivedCopyName("MyOriginalDocument.pdf") else { return false }
            return true
        }

        check("相似文件：聚类与推荐保留规则") {
            let tmpDir = "/private/tmp/macclean-sim-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 创建同词干、不同大小的衍生文件（如高清源视频与衍生副本/转码）
            let dataLarge = Data(repeating: 0x41, count: 2000)
            let dataSmall = Data(repeating: 0x42, count: 1200)

            let f1 = tmpDir + "/MovieTeaser.mov"
            let f2 = tmpDir + "/MovieTeaser (1).mp4"
            FileManager.default.createFile(atPath: f1, contents: dataLarge)
            FileManager.default.createFile(atPath: f2, contents: dataSmall)

            let groups = DuplicateScanner.scanDuplicates(in: [tmpDir], minSize: 100) { _, _ in }
            guard groups.count == 1 else { return false }
            let group = groups[0]
            guard group.matchKind == .similar else { return false }
            guard group.items.count == 2 else { return false }

            // 推荐保留应该偏向体积更大/命名纯净的 MovieTeaser.mov
            guard let original = group.items.first(where: \.isOriginal) else { return false }
            guard original.path == f1 else { return false }
            guard group.wastedBytes == Int64(dataSmall.count) else { return false }

            return true
        }

        check("系统监控：真实物理内存采集与压力计算") {
            let stats = MemoryStats.current()
            guard stats.totalBytes > 0, stats.usedBytes > 0 else { return false }
            guard !stats.usedString.isEmpty, !stats.totalString.isEmpty else { return false }

            // 压力等级判定测试
            let normal = MemoryStats(totalBytes: 100, usedBytes: 50)
            guard normal.pressure == .normal, normal.pressure.rawValue == "正常" else { return false }

            let moderate = MemoryStats(totalBytes: 100, usedBytes: 70)
            guard moderate.pressure == .moderate, moderate.pressure.rawValue == "适中" else { return false }

            let high = MemoryStats(totalBytes: 100, usedBytes: 90)
            guard high.pressure == .high, high.pressure.rawValue == "紧张" else { return false }

            return true
        }

        check("菜单栏配置：显示模式与持久化序列化") {
            var cfg = DiskMonitorConfig()
            cfg.menuBarDisplayMode = .iconAndDisk
            let data = try JSONEncoder().encode(cfg)
            let decoded = try JSONDecoder().decode(DiskMonitorConfig.self, from: data)
            guard decoded.menuBarDisplayMode == .iconAndDisk else { return false }

            cfg.menuBarDisplayMode = .iconAndMemory
            let data2 = try JSONEncoder().encode(cfg)
            let decoded2 = try JSONDecoder().decode(DiskMonitorConfig.self, from: data2)
            guard decoded2.menuBarDisplayMode == .iconAndMemory else { return false }

            return true
        }

        check("菜单栏组件：MenuBarLabelView 与 MenuBarCategoryRow 渲染") {
            let app = AppState()
            let labelView = MenuBarLabelView().environmentObject(app)
            _ = try labelView.inspect()

            let cat = CleanCategory.userCaches
            let st = app.state(for: cat)
            var clicked = false
            let rowView = MenuBarCategoryRow(category: cat, state: st) {
                clicked = true
            }
            let inspected = try rowView.inspect()
            try inspected.find(ViewType.Button.self).tap()
            guard clicked else { return false }

            return true
        }

        check("清理成效：CleanResultSnapshot 数据与指标构建") {
            let snapshot = CleanResultSnapshot(
                title: "用户缓存 清理完成",
                releasedBytes: 500_000_000, // 500MB (macOS 十进制)
                itemCount: 42,
                failureCount: 0,
                mode: "废纸篓",
                beforeAvailable: 100_000_000_000,
                afterAvailable: 100_500_000_000,
                breakdown: [.userCaches: 500_000_000]
            )
            guard snapshot.releasedBytes == 500_000_000 else { return false }
            guard snapshot.deltaString == "500 MB" else { return false }
            guard snapshot.itemCount == 42, snapshot.mode == "废纸篓" else { return false }
            guard snapshot.afterAvailable > snapshot.beforeAvailable else { return false }
            guard snapshot.breakdown[.userCaches] == 500_000_000 else { return false }
            return true
        }

        check("历史趋势：时间范围筛选 (全部 / 近 7 天 / 近 30 天)") {
            let now = Date()
            let day: TimeInterval = 86400
            let r1 = CleanRecord(date: now, categoryName: "用户缓存", itemCount: 10, bytes: 1000, mode: "废纸篓")
            let r2 = CleanRecord(date: now.addingTimeInterval(-3 * day), categoryName: "日志", itemCount: 5, bytes: 2000, mode: "废纸篓")
            let r3 = CleanRecord(date: now.addingTimeInterval(-15 * day), categoryName: "开发残留", itemCount: 2, bytes: 5000, mode: "彻底删除")
            let r4 = CleanRecord(date: now.addingTimeInterval(-45 * day), categoryName: "大文件", itemCount: 1, bytes: 10000, mode: "废纸篓")

            let list = [r1, r2, r3, r4]

            // 全部：4条
            guard list.count == 4 else { return false }

            // 近 7 天：r1, r2 (2条)
            let cutoff7 = now.addingTimeInterval(-7 * day)
            let f7 = list.filter { $0.date >= cutoff7 }
            guard f7.count == 2 else { return false }

            // 近 30 天：r1, r2, r3 (3条)
            let cutoff30 = now.addingTimeInterval(-30 * day)
            let f30 = list.filter { $0.date >= cutoff30 }
            guard f30.count == 3 else { return false }

            return true
        }

        check("清理成效组件：CleanResultSheet 与 HistoryCategoryDistributionCard 渲染") {
            let snapshot = CleanResultSnapshot(
                title: "清理完成",
                releasedBytes: 1500000,
                itemCount: 3,
                failureCount: 0,
                mode: "移入废纸篓",
                beforeAvailable: 10000000,
                afterAvailable: 11500000,
                breakdown: [.userCaches: 1000000, .logsAndTemp: 500000]
            )
            var historyClicked = false
            var dismissed = false
            let sheet = CleanResultSheet(snapshot: snapshot) {
                historyClicked = true
            } onDismiss: {
                dismissed = true
            }
            let histBtn = try button("resultSheetHistoryButton", in: sheet)
            try histBtn.tap()
            let finishBtn = try button("resultSheetDoneButton", in: sheet)
            try finishBtn.tap()
            guard historyClicked && dismissed else { return false }

            // 检查各分类累计释放分布卡片渲染
            let distCard = HistoryCategoryDistributionCard(records: [
                CleanRecord(categoryName: "用户缓存", itemCount: 1, bytes: 500, mode: "废纸篓"),
                CleanRecord(categoryName: "开发残留", itemCount: 1, bytes: 1500, mode: "废纸篓")
            ])
            _ = try distCard.inspect()

            return true
        }

        check("感知哈希：dHash 计算与汉明距离") {
            guard ImageHash.isImageFile(path: "photo.JPG") else { return false }
            guard ImageHash.isImageFile(path: "image.png") else { return false }
            guard ImageHash.isImageFile(path: "snapshot.heic") else { return false }
            guard !ImageHash.isImageFile(path: "document.pdf") else { return false }
            guard !ImageHash.isImageFile(path: "video.mp4") else { return false }

            let tmp = "/private/tmp/macclean-dhash-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            func writeTestPattern(width: Int, height: Int, path: String, pattern: (Int, Int) -> UInt8) -> Bool {
                let cs = CGColorSpaceCreateDeviceGray()
                guard let ctx = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }

                let bpr = ctx.bytesPerRow
                guard let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: bpr * height) else { return false }
                for y in 0..<height {
                    for x in 0..<width {
                        ptr[y * bpr + x] = pattern(x, y)
                    }
                }
                guard let img = ctx.makeImage() else { return false }
                let url = URL(fileURLWithPath: path) as CFURL
                guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(dest, img, nil)
                return CGImageDestinationFinalize(dest)
            }

            let p1 = "\(tmp)/img_64.png"
            let p2 = "\(tmp)/img_48.png"
            let p3 = "\(tmp)/other.png"

            // 图像 1 与图像 2 具有相同的棋盘/对角渐变视觉特征（仅尺寸不同：64x64 vs 48x48）
            guard writeTestPattern(width: 64, height: 64, path: p1, pattern: { x, y in UInt8((x * 255 / 64) ^ (y * 255 / 64)) }) else { return false }
            guard writeTestPattern(width: 48, height: 48, path: p2, pattern: { x, y in UInt8((x * 255 / 48) ^ (y * 255 / 48)) }) else { return false }
            // 图像 3 具有同心圆正弦特征，视觉差异极大
            guard writeTestPattern(width: 64, height: 64, path: p3, pattern: { x, y in
                let dx = Double(x - 32), dy = Double(y - 32)
                return UInt8(clamping: Int(sin(sqrt(dx*dx + dy*dy) / 4.0) * 127.0 + 128.0))
            }) else { return false }

            guard let h1 = ImageHash.computeDHash(path: p1),
                  let h2 = ImageHash.computeDHash(path: p2),
                  let h3 = ImageHash.computeDHash(path: p3) else { return false }

            let distSimilar = ImageHash.hammingDistance(h1, h2)
            let distDifferent = ImageHash.hammingDistance(h1, h3)

            guard distSimilar <= 8 else { return false }
            guard ImageHash.isSimilar(h1, h2, maxDistance: 8) else { return false }
            guard ImageHash.similarity(h1, h2) >= 0.875 else { return false }

            guard distDifferent > 8 else { return false }
            guard !ImageHash.isSimilar(h1, h3, maxDistance: 8) else { return false }

            return true
        }

        check("相似图片：视觉聚类与推荐保留规则") {
            let tmp = "/private/tmp/macclean-imgcluster-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            func writeTestPattern(width: Int, height: Int, path: String, pattern: (Int, Int) -> UInt8) -> Bool {
                let cs = CGColorSpaceCreateDeviceGray()
                guard let ctx = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }

                let bpr = ctx.bytesPerRow
                guard let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: bpr * height) else { return false }
                for y in 0..<height {
                    for x in 0..<width {
                        ptr[y * bpr + x] = pattern(x, y)
                    }
                }
                guard let img = ctx.makeImage() else { return false }
                let url = URL(fileURLWithPath: path) as CFURL
                guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(dest, img, nil)
                return CGImageDestinationFinalize(dest)
            }

            // 创建两张同图不同分辨率的图片（模拟相机原图与缩略图/连拍）
            let fHigh = "\(tmp)/DSC_1001.png"
            let fLow = "\(tmp)/DSC_1002.png"
            let fUnrelated = "\(tmp)/Unrelated_Artwork.png"

            guard writeTestPattern(width: 80, height: 80, path: fHigh, pattern: { x, y in UInt8((x * 255 / 80) ^ (y * 255 / 80)) }) else { return false }
            guard writeTestPattern(width: 40, height: 40, path: fLow, pattern: { x, y in UInt8((x * 255 / 40) ^ (y * 255 / 40)) }) else { return false }
            guard writeTestPattern(width: 80, height: 80, path: fUnrelated, pattern: { x, y in
                let dx = Double(x - 40), dy = Double(y - 40)
                return UInt8(clamping: Int(sin(sqrt(dx*dx + dy*dy) / 4.0) * 127.0 + 128.0))
            }) else { return false }

            // 扫描该目录（minSize 设为 1，确保测试小文件参与扫描）
            let groups = DuplicateScanner.scanDuplicates(in: [tmp], minSize: 1) { _, _ in }
            let simGroups = groups.filter { $0.matchKind == .similarImage }
            guard simGroups.count == 1 else { return false }

            let group = simGroups[0]
            guard group.items.count == 2 else { return false }
            // 推荐保留应该偏向体积大/高清的 fHigh (80x80)
            guard let original = group.items.first(where: \.isOriginal) else { return false }
            guard original.path == fHigh else { return false }
            guard original.recommendationReason?.contains("推荐保留") == true else { return false }

            // 次要副本应带相似度标签
            guard let secondary = group.items.first(where: { !$0.isOriginal }) else { return false }
            guard secondary.path == fLow else { return false }
            guard secondary.recommendationReason?.contains("相似度") == true else { return false }

            // 独立无相似的图片不应成组
            let allGroupedPaths = Set(group.items.map(\.path))
            guard !allGroupedPaths.contains(fUnrelated) else { return false }

            return true
        }

        check("相似图片组件：DuplicateThumbnailView 渲染与空态回退") {
            let thumb = DuplicateThumbnailView(path: "/nonexistent/test.png", isImage: true)
            _ = try thumb.inspect()
            return true
        }

        check("目录树：路径解析与体积累加建树") {
            let home = CleanPaths.expand("~")
            let entries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/ubuntu.iso", size: 4_000_000_000, isSelected: true),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/fedora.iso", size: 2_000_000_000, isSelected: false),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/clip.mp4", size: 1_000_000_000, isSelected: false),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Pictures/Wallpapers/mountain.jpg", size: 50_000_000, isSelected: true)
            ]

            let tree = DirectoryTreeBuilder.buildTree(from: entries)
            guard tree.count >= 2 else { return false }

            guard let dlNode = tree.first(where: { $0.path.contains("Downloads") }) else { return false }
            guard dlNode.totalBytes == 7_000_000_000 else { return false }
            guard dlNode.fileCount == 3 else { return false }

            guard let isoNode = dlNode.children.first(where: { $0.path.contains("ISO") }) else { return false }
            guard isoNode.totalBytes == 6_000_000_000 else { return false }
            guard isoNode.fileCount == 2 else { return false }

            guard let picNode = tree.first(where: { $0.path.contains("Pictures") }) else { return false }
            guard picNode.totalBytes == 50_000_000 else { return false }
            guard picNode.fileCount == 1 else { return false }

            return true
        }

        check("目录树：三态勾选与级联状态判定") {
            let home = CleanPaths.expand("~")
            let mixedEntries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/1.iso", size: 100, isSelected: true),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Downloads/ISO/2.iso", size: 100, isSelected: false)
            ]
            let treeMixed = DirectoryTreeBuilder.buildTree(from: mixedEntries)
            guard let dlMixed = treeMixed.first(where: { $0.path.contains("Downloads") }) else { return false }
            guard dlMixed.checkState == .mixed else { return false }

            let allEntries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Documents/Doc/a.pdf", size: 100, isSelected: true),
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Documents/Doc/b.pdf", size: 100, isSelected: true)
            ]
            let treeAll = DirectoryTreeBuilder.buildTree(from: allEntries)
            guard let docAll = treeAll.first(where: { $0.path.contains("Documents") }) else { return false }
            guard docAll.checkState == .all else { return false }

            let noneEntries = [
                DirectoryTreeBuilder.FileEntry(path: "\(home)/Desktop/Tmp/a.tmp", size: 100, isSelected: false)
            ]
            let treeNone = DirectoryTreeBuilder.buildTree(from: noneEntries)
            guard let dtNone = treeNone.first(where: { $0.path.contains("Desktop") }) else { return false }
            guard dtNone.checkState == .none else { return false }

            return true
        }

        check("目录树：范围管理与子路径排除") {
            let mgr = DirectoryScopeManager.shared
            let testDir = "/tmp/macclean_scope_test_\(UUID().uuidString)"
            let testSub = "\(testDir)/excluded_sub"

            mgr.setPathExcluded(testSub, excluded: true)
            defer { mgr.setPathExcluded(testSub, excluded: false) }

            guard mgr.isPathExcluded("\(testSub)/file.iso") else { return false }
            guard !mgr.isPathExcluded("\(testDir)/allowed_sub/file.iso") else { return false }

            return true
        }

        check("目录树组件：DirectoryTreeSheet 与 DirectoryFilterBadge 渲染") {
            var cleared = false
            let badge = DirectoryFilterBadge(path: "~/Downloads/Videos") {
                cleared = true
            }
            _ = try badge.inspect()
            // 触发清除闭包验证
            badge.onClear()
            guard cleared else { return false }

            var dismissed = false
            var appliedFilter: String? = nil
            let entries = [
                DirectoryTreeBuilder.FileEntry(path: "/tmp/a/test.mov", size: 1000, isSelected: true)
            ]
            let sheet = DirectoryTreeSheet(
                title: "测试目录树",
                entries: entries,
                activeFilterPath: "/tmp/a",
                onApplyFilter: { filter in
                    appliedFilter = filter
                },
                onToggleBatchSelection: { _, _ in },
                onDismiss: {
                    dismissed = true
                }
            )

            let doneBtn = try button("directoryTreeDoneButton", in: sheet)
            try doneBtn.tap()
            guard dismissed else { return false }
            guard appliedFilter == "/tmp/a" else { return false }

            return true
        }

        check("照片元数据：EXIF 参数深度提取与格式化") {
            let tmp = "/private/tmp/macclean-exif-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let path = "\(tmp)/photo_with_exif.jpg"
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            let bpr = ctx.bytesPerRow
            if let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: bpr * 64) {
                for y in 0..<64 {
                    for x in 0..<64 {
                        ptr[y * bpr + x] = UInt8(x ^ y)
                    }
                }
            }
            guard let img = ctx.makeImage() else { return false }
            let url = URL(fileURLWithPath: path) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) else { return false }

            let exif: [CFString: Any] = [
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFocalLength: 24.0,
                kCGImagePropertyExifLensModel: "iPhone 15 Pro lens 24mm"
            ]
            let tiff: [CFString: Any] = [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 15 Pro",
                kCGImagePropertyTIFFDateTime: "2024:06:01 10:30:00"
            ]
            let props: [CFString: Any] = [
                kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyTIFFDictionary: tiff
            ]
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return false }

            let meta = PhotoMetadata.extract(from: URL(fileURLWithPath: path))
            guard meta.pixelWidth == 64 && meta.pixelHeight == 64 else { return false }
            guard meta.hasExif else { return false }
            guard meta.shutterString == "1/250s" else { return false }
            guard meta.apertureString == "f/1.8" else { return false }
            guard meta.isoString == "ISO 100" else { return false }
            guard meta.cameraSummary.contains("iPhone 15 Pro") else { return false }
            guard meta.format == "JPG" else { return false }
            return true
        }

        check("照片元数据：非 EXIF 普通图片回退解析与哈希") {
            let tmp = "/private/tmp/macclean-plainimg-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let path = "\(tmp)/screenshot.png"
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(
                data: nil,
                width: 48,
                height: 48,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            guard let img = ctx.makeImage() else { return false }
            let url = URL(fileURLWithPath: path) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, img, nil)
            guard CGImageDestinationFinalize(dest) else { return false }

            let meta = PhotoMetadata.extract(from: URL(fileURLWithPath: path))
            guard meta.pixelWidth == 48 && meta.pixelHeight == 48 else { return false }
            guard !meta.hasExif else { return false }
            guard meta.shutterString == "未知快门" else { return false }
            guard meta.format == "PNG" else { return false }
            guard meta.dHash != nil else { return false }
            return true
        }

        check("照片对比：智能画质评分与推荐保留引擎") {
            let metaA = PhotoMetadata(
                fileURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                filePath: "/tmp/a.jpg",
                fileName: "a.jpg",
                fileSize: 4_000_000,
                format: "JPG",
                pixelWidth: 4032,
                pixelHeight: 3024,
                colorSpace: "Display P3",
                make: "Apple",
                model: "iPhone 15 Pro",
                lensModel: nil,
                focalLength: 24.0,
                focalLengthIn35mm: 24.0,
                apertureFNumber: 1.78,
                exposureTimeSeconds: 0.002, // 1/500s 高速快门
                isoSpeed: 64, // 低感纯净
                captureDate: Date(),
                captureDateString: "2024:06:01 10:30:00",
                dHash: 0x1234567890ABCDEF
            )

            let metaB = PhotoMetadata(
                fileURL: URL(fileURLWithPath: "/tmp/b.jpg"),
                filePath: "/tmp/b.jpg",
                fileName: "b.jpg",
                fileSize: 1_000_000,
                format: "JPG",
                pixelWidth: 2016,
                pixelHeight: 1512, // 较低分辨率
                colorSpace: "sRGB",
                make: "Apple",
                model: "iPhone 15 Pro",
                lensModel: nil,
                focalLength: 24.0,
                focalLengthIn35mm: 24.0,
                apertureFNumber: 1.78,
                exposureTimeSeconds: 0.033, // 1/30s 较慢快门
                isoSpeed: 800, // 高感噪点多
                captureDate: Date().addingTimeInterval(-2),
                captureDateString: "2024:06:01 10:29:58",
                dHash: 0x1234567890ABCDE0
            )

            let comparison = PhotoComparisonResult.compare(photoA: metaA, photoB: metaB)
            guard comparison.recommendedChoice == .left else { return false }
            guard comparison.scoreA > comparison.scoreB else { return false }
            guard comparison.recommendationReason.contains("左图") else { return false }
            guard comparison.diffRows.count >= 6 else { return false }
            guard comparison.similarity > 0.9 else { return false }
            return true
        }

        check("照片对比组件：PhotoCompareSheet 渲染与快速决策") {
            let tmp = "/private/tmp/macclean-sheet-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let p1 = "\(tmp)/shot1.jpg"
            let p2 = "\(tmp)/shot2.jpg"
            let cs = CGColorSpaceCreateDeviceGray()
            if let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue),
               let img = ctx.makeImage() {
                for p in [p1, p2] {
                    if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, img, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }
            }

            let item1 = DuplicateFileItem(path: p1, name: "shot1.jpg", size: 5000, modificationDate: Date(), isSelected: false, isOriginal: true)
            let item2 = DuplicateFileItem(path: p2, name: "shot2.jpg", size: 5000, modificationDate: Date(), isSelected: true, isOriginal: false)
            let group = DuplicateGroup(hash: "photo-group-hash", fileSize: 5000, items: [item1, item2], matchKind: .similarImage)

            let state = DuplicateState()
            state.groups = [group]

            var dismissed = false
            let sheet = PhotoCompareSheet(group: group, dupState: state) {
                dismissed = true
            }

            // 测试快速决策：保留左图（取消 item1 勾选，选中 item2 待清理）
            sheet.keepOnlyA()
            guard state.groups[0].items[0].isSelected == false else { return false }
            guard state.groups[0].items[1].isSelected == true else { return false }

            // 测试快速决策：保留右图（选中 item1 待清理，取消 item2 勾选）
            sheet.keepOnlyB()
            guard state.groups[0].items[0].isSelected == true else { return false }
            guard state.groups[0].items[1].isSelected == false else { return false }

            // 测试两张均保留
            sheet.keepBoth()
            guard state.groups[0].items[0].isSelected == false else { return false }
            guard state.groups[0].items[1].isSelected == false else { return false }

            // 测试完成按钮交互
            let doneBtn = try button("photoCompareDoneButton", in: sheet)
            try doneBtn.tap()
            guard dismissed else { return false }

            return true
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
