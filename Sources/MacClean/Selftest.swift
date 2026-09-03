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
        let start = Date()

        check("byteStringCN 格式化") {
            Int64(0).byteStringCN == "0 KB" &&
            Int64(500).byteStringCN == "500 B" &&
            Int64(1500).byteStringCN == "1.5 KB" &&
            Int64(5_000_000).byteStringCN == "5 MB" &&
            Int64(1_500_000_000).byteStringCN == "1.5 GB" &&
            Int64(150_000_000_000).byteStringCN == "150 GB"
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
            return result.succeeded == 1 && !FileManager.default.fileExists(atPath: dir)
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
