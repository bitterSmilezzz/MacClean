import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：基础模型与格式化
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 39–410）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteFoundation() {
        check("byteStringCN 格式化") {
            Int64(0).byteStringCN == "0 KB" &&
            Int64(500).byteStringCN == "500 B" &&
            Int64(1500).byteStringCN == "1.5 KB" &&
            Int64(5_000_000).byteStringCN == "5 MB" &&
            Int64(1_500_000_000).byteStringCN == "1.5 GB" &&
            Int64(150_000_000_000).byteStringCN == "150 GB"
        }
        check("UsageLevel 写入档位标签：只说量到的事，不宣称「频率」") {
            UsageLevel.active.label == "7 天内有写入" &&
            UsageLevel.recent.label == "7–30 天内有写入" &&
            UsageLevel.occasional.label == "30–90 天内有写入" &&
            UsageLevel.dormant.label == "90 天以上无写入" &&
            // 反证：标签里不许再出现从单个 mtime 推不出来的词
            ![UsageLevel.active, .recent, .occasional, .dormant, .unknown]
                .contains(where: { $0.label.contains("频繁") || $0.label.contains("偶尔") }) &&
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
            let item = CleanItem(name: "X", path: "/tmp/x", size: 1, rule: "C1",
                                 category: .userCaches,
                                 use: UseState(ownerIsRunning: false, ownerName: nil,
                                               lastUsed: Date().addingTimeInterval(-3 * 86400),
                                               level: .active))
            guard item.usage == .active, item.lastUsed != nil else { return false }
            // 3 天前应输出 "3 天前"；刚刚为 "刚刚"
            return item.lastUsed!.relativeUsage == "3 天前" && Date().relativeUsage == "刚刚"
        }
        check("AI 上下文渲染包含使用信息") {
            let ctx = AskContext(title: "TestCache", path: "/private/tmp/x", size: 1500,
                                 category: "用户缓存", risk: "可清理", note: "可重建",
                                 lastUsed: Date().addingTimeInterval(-3 * 86400),
                                 usage: .active)
            let text = AIService.render(context: ctx)
            return text.contains("最近写入：") && text.contains("写入档位：7 天内有写入")
        }
        check("CleanPaths.expand ~ 展开") {
            CleanPaths.expand("~/Library/Caches") == NSHomeDirectory() + "/Library/Caches" &&
            CleanPaths.expand("/private/tmp") == "/private/tmp"
        }
        // v1.72.4：`expand` 原先是 `replacingOccurrences(of: "~", ...)`，会把路径**中间**的
        // `~` 也换成主目录，于是护栏拿去和 G6/G8/白名单比对的是一个根本不存在的串。
        check("CleanPaths.expand 只认前缀 ~，不碰路径中间的 ~") {
            CleanPaths.expand("/tmp/a~b") == "/tmp/a~b" &&
            CleanPaths.expand("/Users/x/Downloads/report~final.pdf") == "/Users/x/Downloads/report~final.pdf" &&
            CleanPaths.expand("~") == NSHomeDirectory() &&
            CleanPaths.expand("~/") == NSHomeDirectory() + "/" &&
            FileSystem.normalizePath("/tmp/a~b") == "/tmp/a~b"
        }
        // `normalizePath` 有一条"已是干净绝对路径就原样返回"的快速通道。
        // 快速通道与完整消解流程必须**逐字符同结果**，否则护栏的清单匹配会出现两套口径。
        check("normalizePath 快速通道与完整消解同结果") {
            let home = NSHomeDirectory()
            let cases: [(String, String)] = [
                ("/a//b", "/a/b"),
                ("//", "/"),
                ("/a//", "/a"),
                ("/a/./b", "/a/b"),
                ("/a/../b", "/b"),
                ("/a/b/../c", "/a/c"),
                ("/a/b/", "/a/b"),
                ("/a/b/.", "/a/b"),
                ("/a/b/..", "/a"),
                ("/a/.../b", "/a/.../b"),        // 三个点不是 "."/".."，原样保留
                ("/private/tmp/x", "/tmp/x"),
                ("/private/var/db", "/var/db"),
                ("/private", "/private"),
                ("/private/", "/private"),
                ("/", "/"),
                ("/tmp", "/tmp"),
                ("/tmp/", "/tmp"),
                ("/x~/y", "/x~/y"),
                ("/a~/b/../c", "/a~/c"),
                ("~", home),
                ("~/Library", home + "/Library"),
                (home + "/Library/Caches/a", home + "/Library/Caches/a"),
                // `..` 是纯字符串消解、不查文件系统：`/Users/name/..` 就是 `/Users`，
                // 所以这里得到 /Users/etc/passwd 而不是 /etc/passwd（与改造前完全一致）。
                (home + "/../etc/passwd", (home as NSString).deletingLastPathComponent + "/etc/passwd"),
            ]
            var bad: [String] = []
            for (input, expected) in cases {
                let got = FileSystem.normalizePath(input)
                if got != expected { bad.append("\(input) → \(got)，期望 \(expected)") }
                // 幂等：归一一次与归一两次必须同值（快速通道只在幂等成立时才敢提前返回）
                let twice = FileSystem.normalizePath(got)
                if twice != got { bad.append("\(input) 不幂等：\(got) → \(twice)") }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
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
                CleanItem(name: "A", path: "/tmp/a", size: 100, rule: "C1", category: .userCaches),
                CleanItem(name: "B", path: "/tmp/b", size: 200, rule: "A1", category: .userCaches),
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
                                  rule: "C1", category: .userCaches)]
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
            let item = CleanItem(name: "test", path: dir, size: 5, rule: "C1", category: .logsAndTemp)
            let result = Cleaner.clean([item], permanently: true) { _ in }
            return result.succeeded == 1 && !FileManager.default.fileExists(atPath: dir)
        }
        check("Cleaner 移入废纸篓") {
            let dir = "/private/tmp/macclean-test-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/file.txt"))
            let item = CleanItem(name: "test", path: dir, size: 5, rule: "C1", category: .logsAndTemp)
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
                                 rule: "C1", category: .logsAndTemp)
            let result = Cleaner.clean([item], permanently: true) { _ in }
            return result.succeeded == 0 && result.failures.count == 1
        }
        check("VerdictBadge 渲染（四档结论各不相同）") {
            let labels = [Recommendation.Kind.safe, .inUse, .review, .keep].map { kind -> String in
                let rec = Recommendation(kind: kind, reason: "r")
                return (try? VerdictBadge(recommendation: rec).inspect().text().string()) ?? ""
            }
            return labels == ["可清理", "使用中", "需确认", "勿删"]
        }
        check("ItemRow 勾选回调") {
            let item = CleanItem(name: "CacheApp", path: "/tmp/x", size: 1024,
                                 rule: "C1", category: .userCaches)
            var toggledTo: Bool?
            let view = ItemRowView(item: item, isSelected: false) { toggledTo = $0 }
            try button("itemToggle", in: view).tap()
            return toggledTo == true
        }
        check("ItemRow 行内「问 AI」禁用态（LOW-2 终检）") {
            let item = CleanItem(name: "CacheApp", path: "/tmp/x", size: 1024,
                                 rule: "C1", category: .userCaches)
            let enabled = ItemRowView(item: item, isSelected: false,
                                      onToggle: { _ in }, onAskAI: {}, isDisabled: false)
            let disabled = ItemRowView(item: item, isSelected: false,
                                       onToggle: { _ in }, onAskAI: {}, isDisabled: true)
            return try !button("askAIButton", in: enabled).isDisabled()
                && button("askAIButton", in: disabled).isDisabled()
        }
        check("ItemRow Quick Look 预览唤起") {
            let item = CleanItem(name: "LargeArchive.zip", path: "/tmp/archive.zip", size: 1048576,
                                 rule: "C1", category: .largeFiles)
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
                          rule: "C1", category: .userCaches),
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
                            mode: "废纸篓", failures: 0, trashedBytes: 1234)
            guard app.history.count == 1, app.history[0].bytes == 1234 else { return false }
            // 落点必须跟着进历史：这批字节此刻还压在磁盘上，"累计释放"不许算它
            guard app.history[0].reclaimedBytes == 0,
                  app.history[0].pendingTrashBytes == 1234 else { return false }
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
                                 rule: "C1", category: .userCaches)
            st.askAbout(item: item)
            return st.context != nil && st.context?.title == "CacheApp" && st.messages.count == 1
        }
        check("AI：提问确实发起请求（HIGH#2 回归）") {
            // 首轮审查 bug：ask/问列表/问全部只追加消息、从不调 performRequest（isLoading 恒 false）
            // 修复后：sendPendingUserMessage 应把 isLoading 置 true（自检 networkDisabled 下请求被短路）
            let st = AIState()
            let item = CleanItem(name: "RegCache", path: "/private/tmp/regcache", size: 10,
                                 rule: "C1", category: .userCaches)
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
                                 rule: "C1", category: .userCaches)
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
                          rule: "C1", category: .userCaches)
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
            return text.contains("编号 | 名称 | 路径 | 大小 | 处置结论")
                && text.contains("其余 10 项未列出")
        }
        check("AI：问全部每类 Top 20") {
            let app = AppState()
            for cat in CleanCategory.allCases {
                let st = app.state(for: cat)
                st.isScanned = true
                st.items = (0..<30).map { i in
                    CleanItem(name: "\(cat.rawValue)-\(i)", path: "/tmp/\(cat.rawValue)/\(i)",
                              size: Int64(i), rule: "C1", category: cat)
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
                                  rule: "C1", category: .userCaches)]
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

        // MARK: - App 更新检查（v1.73.14）
        // 网络相关的断言全部走注入 fetcher，绝不发真网络。

        check("compareVersions 逐段数值比较（1.2.10 > 1.2.9，字符串比较会判反）") {
            func lt(_ a: String, _ b: String) -> Bool { compareVersions(a, b) == .orderedAscending }
            func eq(_ a: String, _ b: String) -> Bool { compareVersions(a, b) == .orderedSame }
            func gt(_ a: String, _ b: String) -> Bool { compareVersions(a, b) == .orderedDescending }
            // 逐段数值：这是变异验证的目标断言（把数值比较改成字符串比较必须红）
            guard lt("1.2.9", "1.2.10"), gt("1.2.10", "1.2.9"),
                  lt("1.9", "1.10"), lt("2.0", "10.0") else { return false }
            // 缺段按 0 补齐
            guard eq("1.2", "1.2.0"), lt("1.2", "1.2.1"), gt("1.2.3.1", "1.2.3") else { return false }
            // 相等、v 前缀、首尾空白
            guard eq("1.2.3", "1.2.3"), eq("v1.2.3", "1.2.3"), eq("  1.2.3  ", "1.2.3") else { return false }
            // 括号 build 后缀：主版本分胜负优先；主版本相同才比 build；缺 build 按 0
            guard lt("1.2.3 (917)", "1.2.3 (918)"), gt("1.2.3 (917)", "1.2.3"),
                  lt("1.2.3", "1.2.4 (100)"), lt("1.2.3 (999)", "1.3.0"),
                  eq("1.2.3 (917)", "1.2.3+917") else { return false }
            // 非数字段：预发布 < 正式；两侧都有按字母序；大小写不敏感
            guard lt("1.0.0-beta", "1.0.0"), lt("1.2.3b2", "1.2.3"),
                  lt("1.0.0-alpha", "1.0.0-beta"), eq("1.0.Beta", "1.0.beta") else { return false }
            return true
        }
        check("Appcast 解析：第一条 item 即最新；enclosure 属性与 sparkle 元素两种写法") {
            // 两种写法混在一条 feed 里：元素写法（Sparkle 2 常见）
            let elementXML = """
            <?xml version="1.0" standalone="yes"?>
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel><title>Foo</title>
            <item>
              <title>Version 1.2.10</title>
              <sparkle:shortVersionString>1.2.10</sparkle:shortVersionString>
              <sparkle:version>920</sparkle:version>
              <enclosure url="https://example.com/Foo-1.2.10.zip" length="1234" type="application/octet-stream" />
            </item>
            <item>
              <title>Version 1.2.9</title>
              <sparkle:shortVersionString>1.2.9</sparkle:shortVersionString>
              <sparkle:version>919</sparkle:version>
              <enclosure url="https://example.com/Foo-1.2.9.zip" length="1200" type="application/octet-stream" />
            </item>
            </channel></rss>
            """
            // 正向样本断言：输入真有版本号与 enclosure，解析结果必须非空且取第一条（最新）
            guard let item = AppcastParser.parse(Data(elementXML.utf8)) else { return false }
            guard item.shortVersion == "1.2.10", item.buildVersion == "920",
                  item.downloadURL == "https://example.com/Foo-1.2.10.zip" else { return false }
            // 属性写法（Sparkle 1.x 常见：版本直接挂在 enclosure 上）
            let attrXML = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel><item>
              <enclosure url="https://example.com/Foo-1.3.zip" sparkle:version="921" sparkle:shortVersionString="1.3.0" />
            </item></channel></rss>
            """
            guard let attrItem = AppcastParser.parse(Data(attrXML.utf8)) else { return false }
            guard attrItem.buildVersion == "921", attrItem.shortVersion == "1.3.0",
                  attrItem.downloadURL == "https://example.com/Foo-1.3.zip" else { return false }
            // 反证：非 XML、空数据、没有 item 的 RSS → nil（不许编出结果）
            guard AppcastParser.parse(Data("这不是 XML".utf8)) == nil else { return false }
            guard AppcastParser.parse(Data()) == nil else { return false }
            guard AppcastParser.parse(Data("<rss><channel><title>无条目</title></channel></rss>".utf8)) == nil else { return false }
            return true
        }
        check("AppUpdate 默认关 = 零网络零解析（开关从未设置必须是关）") {
            let suiteName = "macclean-selftest-appupdate-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let scanner = AppUpdateScanner(defaults: defaults)
            // 默认关：从没写过这个键
            guard !scanner.isEnabled else { return false }
            var fetchCalls: [URL] = []
            let sparkle = AppUpdateEntry(path: "/tmp/Foo.app", name: "Foo", bundleID: "com.example.foo",
                                         shortVersion: "1.0", buildVersion: "1",
                                         source: .sparkle(appcastURL: "https://updates.example.com/foo.xml"))
            let out = scanner.checkUpdates(entries: [sparkle]) { url in
                fetchCalls.append(url)
                return Data()
            }
            // 关闭态：fetcher 一次都不被调，结果原样（不是 unreachable、更不是 upToDate）
            return fetchCalls.isEmpty && out == [sparkle]
        }
        check("AppUpdate 开启后才发请求：只对 sparkle 来源，App Store / 无机制不发") {
            let suiteName = "macclean-selftest-appupdate-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let scanner = AppUpdateScanner(defaults: defaults)
            scanner.setEnabled(true)
            let sparkle = AppUpdateEntry(path: "/tmp/Foo.app", name: "Foo", bundleID: "com.example.foo",
                                         shortVersion: "1.2.3", buildVersion: "917",
                                         source: .sparkle(appcastURL: "https://updates.example.com/foo.xml"))
            let store = AppUpdateEntry(path: "/tmp/Bar.app", name: "Bar", bundleID: "com.example.bar",
                                       shortVersion: "1.0", buildVersion: "1", source: .appStore)
            let bare = AppUpdateEntry(path: "/tmp/Baz.app", name: "Baz", bundleID: "com.example.baz",
                                      shortVersion: "1.0", buildVersion: "1", source: .none)
            var fetchCalls: [URL] = []
            let appcast = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel><item>
              <enclosure url="https://example.com/Foo-1.2.10.zip" sparkle:version="920" sparkle:shortVersionString="1.2.10" />
            </item></channel></rss>
            """
            let out = scanner.checkUpdates(entries: [sparkle, store, bare]) { url in
                fetchCalls.append(url)
                return Data(appcast.utf8)
            }
            // 三个来源只有 sparkle 发了请求
            guard fetchCalls == [URL(string: "https://updates.example.com/foo.xml")!] else { return false }
            // sparkle 条目得出「有更新」，其余保持 notChecked（不许被顺手标成 upToDate）
            guard out[0].result == .available(latestVersion: "1.2.10"),
                  out[1].result == .notChecked, out[2].result == .notChecked else { return false }
            return true
        }
        check("AppUpdate：Info.plist 来源判别（SUFeedURL / 收据 / 双无 / plist 读不到）") {
            let root = "/private/tmp/macclean-appupdate-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            func makeApp(_ name: String, info: [String: Any]?, receipt: Bool) -> String {
                let appPath = (root as NSString).appendingPathComponent("\(name).app")
                let contents = (appPath as NSString).appendingPathComponent("Contents")
                try? FileManager.default.createDirectory(atPath: (contents as NSString)
                    .appendingPathComponent("_MASReceipt"), withIntermediateDirectories: true)
                if let info {
                    NSDictionary(dictionary: info).write(toFile: (contents as NSString)
                        .appendingPathComponent("Info.plist"), atomically: true)
                }
                if receipt {
                    FileManager.default.createFile(atPath: (contents as NSString)
                        .appendingPathComponent("_MASReceipt/receipt"), contents: Data("x".utf8))
                }
                return appPath
            }
            let sparklePath = makeApp("SparkleApp",
                                      info: ["CFBundleIdentifier": "Com.Example.SparkleApp",
                                             "CFBundleDisplayName": "Sparkle 应用",
                                             "CFBundleShortVersionString": "1.2.3",
                                             "CFBundleVersion": "917",
                                             "SUFeedURL": "https://updates.example.com/sparkleapp.xml"],
                                      receipt: false)
            let storePath = makeApp("StoreApp",
                                    info: ["CFBundleIdentifier": "com.example.storeapp"], receipt: true)
            let barePath = makeApp("BareApp",
                                   info: ["CFBundleIdentifier": "com.example.bareapp"], receipt: false)
            // Info.plist 读不到：必须如实列示，不许静默跳过
            let unreadPath = makeApp("UnreadApp", info: nil, receipt: false)

            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: [], bundlePrefixes: [], normalizedNames: [], executableNames: [],
                runningBundleIDs: [], appPaths: [sparklePath, storePath, barePath, unreadPath],
                unreadableRoots: [])
            defer { AppInventory.snapshotOverride = nil }

            let suiteName = "macclean-selftest-appupdate-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let summary = AppUpdateScanner(defaults: defaults).scanInstalledSources()
            guard summary.entries.count == 4 else { return false }
            let byPath = Dictionary(uniqueKeysWithValues: summary.entries.map { ($0.path, $0) })
            // sparkle：URL 用 Info.plist 原值；bundle id 归一小写；版本号取到
            guard let sparkleEntry = byPath[sparklePath],
                  case .sparkle(let feed) = sparkleEntry.source,
                  feed == "https://updates.example.com/sparkleapp.xml",
                  sparkleEntry.bundleID == "com.example.sparkleapp",
                  sparkleEntry.shortVersion == "1.2.3", sparkleEntry.buildVersion == "917",
                  sparkleEntry.name == "Sparkle 应用" else { return false }
            guard byPath[storePath]?.source == AppUpdateEntry.Source.appStore else { return false }
            // 注意写全类型：`?.source == .none` 会把 .none 解析成 Optional.none（比较 nil），判据就假了
            guard byPath[barePath]?.source == AppUpdateEntry.Source.none else { return false }
            guard let unreadEntry = byPath[unreadPath],
                  unreadEntry.source == AppUpdateEntry.Source.none,
                  unreadEntry.displayVersion == "未知" else { return false }
            return true
        }
        check("AppUpdate G16：清单不可信必须降级明示，不许渲染成「全部最新」") {
            let root = "/private/tmp/macclean-appupdate-g16-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: root + "/Real.app/Contents", withIntermediateDirectories: true)
            NSDictionary(dictionary: ["CFBundleIdentifier": "com.example.real"]).write(
                toFile: (root as NSString).appendingPathComponent("Real.app/Contents/Info.plist"),
                atomically: true)
            defer { try? FileManager.default.removeItem(atPath: root) }

            // ① 根目录读取失败（unreadableRoots 非空）→ 必须带降级说明，且点名失败的根
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: [], bundlePrefixes: [], normalizedNames: [], executableNames: [],
                runningBundleIDs: [], appPaths: [root + "/Real.app"],
                unreadableRoots: ["/private/tmp/fake-unreadable-root"])
            let degraded = AppUpdateScanner().scanInstalledSources()
            guard !degraded.inventoryComplete else { return false }
            guard let notice = degraded.degradationNotice,
                  notice.contains("已安装应用清单不完整"),
                  notice.contains("漏项"),
                  notice.contains("fake-unreadable-root") else { return false }

            // ② 一个应用都没枚举到（bundleIDs 空）同样是不完整
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: [], bundlePrefixes: [], normalizedNames: [], executableNames: [],
                runningBundleIDs: [], appPaths: [], unreadableRoots: [])
            guard !AppInventory.current().isComplete,
                  AppUpdateScanner().scanInstalledSources().degradationNotice != nil else { return false }

            // ③ 反证：清单完整时必须没有降级说明
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: ["com.example.real"], bundlePrefixes: [], normalizedNames: [], executableNames: [],
                runningBundleIDs: [], appPaths: [root + "/Real.app"], unreadableRoots: [])
            let complete = AppUpdateScanner().scanInstalledSources()
            AppInventory.snapshotOverride = nil
            return complete.inventoryComplete && complete.degradationNotice == nil
        }
        check("AppUpdate 隐私边界：请求 URL 与 Info.plist 声明值逐字符一致，不含本机路径") {
            // 路径里带随机串：只要实现把本机路径拼进请求，这条必红
            let token = UUID().uuidString
            let root = "/private/tmp/macclean-priv-\(token)"
            let appPath = (root as NSString).appendingPathComponent("PrivateApp.app")
            let contents = (appPath as NSString).appendingPathComponent("Contents")
            try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
            let declared = "https://updates.example-fixed.org/appcast.xml"
            NSDictionary(dictionary: ["CFBundleIdentifier": "com.example.privateapp",
                                      "CFBundleShortVersionString": "1.0.0",
                                      "SUFeedURL": declared]).write(
                toFile: (contents as NSString).appendingPathComponent("Info.plist"), atomically: true)
            defer { try? FileManager.default.removeItem(atPath: root) }

            let suiteName = "macclean-selftest-appupdate-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let scanner = AppUpdateScanner(defaults: defaults)
            scanner.setEnabled(true)
            AppInventory.snapshotOverride = AppInventory.Snapshot(
                bundleIDs: [], bundlePrefixes: [], normalizedNames: [], executableNames: [],
                runningBundleIDs: [], appPaths: [appPath], unreadableRoots: [])
            defer { AppInventory.snapshotOverride = nil }

            var received: [URL] = []
            let appcast = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel><item>
              <enclosure url="https://example.com/PrivateApp-1.1.zip" sparkle:shortVersionString="1.1.0" />
            </item></channel></rss>
            """
            let out = scanner.checkUpdates(entries: scanner.scanInstalledSources().entries) { url in
                received.append(url)
                return Data(appcast.utf8)
            }
            // 恰好一条请求，URL 与声明的原值逐字符一致（没有查询串、没有路径拼接）
            guard received.count == 1, received[0].absoluteString == declared else { return false }
            // 本机路径段（随机 token、/private/tmp、主目录）绝不允许出现在任何请求 URL 里
            let allURLs = received.map { $0.absoluteString }
            guard !allURLs.contains(where: { $0.contains(token) || $0.contains("/private/tmp")
                                              || $0.contains(NSHomeDirectory()) }) else { return false }
            // 整条链路跑通：远端 1.1.0 > 本地 1.0.0 → available
            return out.first?.result == .available(latestVersion: "1.1.0")
        }
        check("AppUpdate decideResult：查不出结论必须如实报 unreachable，不许说成已最新") {
            func entry(short: String, build: String) -> AppUpdateEntry {
                AppUpdateEntry(path: "/tmp/X.app", name: "X", bundleID: "com.example.x",
                               shortVersion: short, buildVersion: build,
                               source: .sparkle(appcastURL: "https://updates.example.com/x.xml"))
            }
            func remote(short: String?, build: String?) -> AppcastParser.Item {
                AppcastParser.Item(shortVersion: short, buildVersion: build, downloadURL: nil)
            }
            // 远端更高 / 更低
            guard AppUpdateScanner.decideResult(local: entry(short: "1.2.3", build: "917"),
                                                remote: remote(short: "1.2.10", build: "920"))
                == .available(latestVersion: "1.2.10") else { return false }
            guard AppUpdateScanner.decideResult(local: entry(short: "2.0", build: "50"),
                                                remote: remote(short: "1.9.9", build: "49"))
                == .upToDate else { return false }
            // short 相同 → build 定胜负
            guard case .available = AppUpdateScanner.decideResult(local: entry(short: "1.0", build: "100"),
                                                                  remote: remote(short: "1.0", build: "101")) else { return false }
            guard AppUpdateScanner.decideResult(local: entry(short: "1.0", build: "101"),
                                                remote: remote(short: "1.0", build: "100")) == .upToDate else { return false }
            // 只有 build 号可比（远端只有 sparkle:version 的 feed）
            guard case .available = AppUpdateScanner.decideResult(local: entry(short: "", build: "100"),
                                                                  remote: remote(short: nil, build: "101")) else { return false }
            // 远端没有版本号 → unreachable
            guard case .unreachable = AppUpdateScanner.decideResult(local: entry(short: "1.0", build: "1"),
                                                                    remote: remote(short: nil, build: nil)) else { return false }
            // 本机没版本号 → unreachable
            guard case .unreachable = AppUpdateScanner.decideResult(local: entry(short: "", build: ""),
                                                                    remote: remote(short: "1.0", build: "1")) else { return false }
            // 版本信息错位（本地只有 build、远端只有 short）→ unreachable，不许判 upToDate
            guard case .unreachable = AppUpdateScanner.decideResult(local: entry(short: "", build: "917"),
                                                                    remote: remote(short: "2.0", build: nil)) else { return false }
            return true
        }

        // MARK: - v1.73.14 复审补票（v1.73.13-14-zcode-subagent #1/#2）

        check("AppUpdateScanner：系统 App 过滤走 isSystemProtected 单一判据（G18 回归锁）") {
            // 集成自检曾抓到 `hasPrefix("/System/")` 字符串护栏（G18 立禁族：漏 SIP 清单里
            // 非 /System 前缀的位置、与删除侧两套标准），当时改成了 isSystemProtected。
            // 这条钉住它不再长回来：既有正向 needle，也有违规字面禁令。
            guard FileSystem.isSystemProtected("/System/Applications") else {
                print("      前置条件失效：/System/Applications 不在 systemProtected 清单")
                return false
            }
            let path = (Selftest.sourceDirectoryPath as NSString)
                .appendingPathComponent("AppUpdateScanner.swift")
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("      AppUpdateScanner.swift 不可读")
                return false
            }
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            guard code.contains("FileSystem.isSystemProtected(path)") else {
                print("      过滤判据不再走 isSystemProtected——字符串护栏回来了？")
                return false
            }
            if code.contains("hasPrefix(\"/System") || code.contains("contains(\"/System")
                || code.contains("==\"/System") {
                print("      出现 /System 字符串护栏字面（G18 违规族）")
                return false
            }
            return true
        }

    }
}
