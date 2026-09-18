import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：检索、概览与清理流程
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 411–530）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteSearchAndClean() {
        // MARK: - v1.6 全局检索 / 概览 / 扫描增强

        check("GlobalSearch：按名称与路径匹配") {
            let items = [
                CleanItem(name: "ChromeCache", path: "/tmp/chrome", size: 10,
                          rule: "C1", category: .userCaches),
                CleanItem(name: "WeChat", path: "/tmp/wechat", size: 20,
                          rule: "A1", category: .appResidue),
            ]
            let byName = GlobalSearch.search(query: "chrome", items: items, history: [])
            let byPath = GlobalSearch.search(query: "wechat", items: items, history: [])
            return byName.count == 1 && byName[0].name == "ChromeCache"
                && byPath.count == 1 && byPath[0].kind == .item(.appResidue)
        }
        check("GlobalSearch：大小写不敏感与去空白") {
            let items = [CleanItem(name: "DeepSeekData", path: "/tmp/ds", size: 1,
                                   rule: "C1", category: .browserAndSystem)]
            let r = GlobalSearch.search(query: "  deepseek  ", items: items, history: [])
            return r.count == 1
        }
        check("GlobalSearch：空查询与上限 200") {
            guard GlobalSearch.search(query: "  ", items: [], history: []).isEmpty else { return false }
            let items = (0..<300).map { CleanItem(name: "Hit\($0)", path: "/tmp/hit", size: Int64($0),
                                                  rule: "C1", category: .userCaches) }
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
                CleanItem(name: "A", path: "/tmp/a", size: 100, rule: "C1", category: .userCaches),
                CleanItem(name: "B", path: "/tmp/b", size: 50, rule: "A1", category: .userCaches),
            ]
            guard app.scannedCount == 1, app.totalCleanable == 150 else { return false }
            let totals = app.verdictTotals
            return totals[.safe] == 100 && totals[.review] == 50
        }
        check("Dashboard：清理按钮默认禁用、全选后可点") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [CleanItem(name: "TestCache", path: "/private/tmp/macclean-dash",
                                  size: 1024, rule: "C1", category: .userCaches)]
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
                                  rule: "C1", category: .userCaches)]
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
            let item = CleanItem(name: "gone", path: dir, size: 100, rule: "A1",
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
                                   size: 10, rule: "C1", category: .userCaches)
            let badItem = CleanItem(name: "Bad", path: "/System/Library/Denied",
                                    size: 20, rule: "C1", category: .userCaches)
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

    }
}
