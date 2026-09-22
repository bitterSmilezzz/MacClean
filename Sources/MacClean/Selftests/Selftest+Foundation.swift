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

    }
}
