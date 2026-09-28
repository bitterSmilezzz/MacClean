import Foundation

// 自检套件：可清理量的口径（数字必须说人话）
//
// 用户原话里有两类"不准"：一类是**判定错了**（正在用的东西被判可删，已在
// `Selftest+ProcessOccupancy` 锁定），另一类是**数字错了**——判定全对，但界面上那个
// 大字在骗人。
//
// 真机实测（修复前）：仪表盘大字写「可清理 8.91 GB」，而点"全选"实际只勾得动 5.75 GB；
// 差额里还含一个 0.62 GB **明确标着「勿删」**的文件。原因是那个数字取的是
// `Σ 所有项`，而不是 `Σ 结论为可清理的项`——虚高 55%。
//
// 这一套把三个数字的定义与关系钉死：
//   ① `totalScannedSize`     = 这次扫到了多少（含「使用中 / 需确认 / 勿删」）
//   ② `totalCleanable`       = 其中**真的建议你清掉**的量（只含「可清理 / 确定是垃圾」）
//   ③ `quickCleanableBytes`  = "一键安全速清"真正会清的量
//
// ② 与 ③ 的关系：**同一条 3 天线**（`UseState.cleanableIdleWindow`），差异只剩白名单。
// 一键速清原先没有二次确认，所以它额外要求 30 天；现在它有了确认弹窗
// （`AppState.requestQuickClean` → 预览 → 确认），就不必再用年龄门槛来代替确认。
// 真正"没人看着"的那两条（`AutoCleanService` / `DiskMonitor`）仍然保留 30 天，
// 那是另一套判据，不在本套件的范围里。
//
// 关键不变量：**③ 必须逐字等于 `applyQuickCleanSelection` 实际勾出来的量**。
// 否则就会出现"按钮承诺 8 GB、点下去清 0.01 GB"这种错位。
extension Selftest {
    static func suiteCleanableAccounting() {

        /// 造一个分类，放齐五类：可清理 / 使用中 / 需确认 / 勿删 / 可清理但近期动过。
        ///
        /// 结论一律由 `deriveRecommendation` 推导，**不手写 label**——
        /// 手写 label 就等于把被测对象当成已知，测了个寂寞。
        func makeCategory() -> CategoryState {
            let st = CategoryState(category: .userCaches)
            st.isScanned = true
            // 200 天没动、归属已确认没在跑 → 稳定落在「可清理」，且"近期使用"为假
            let idle = UseState(ownerState: .notRunning, ownerName: "某应用",
                                lastUsed: Date().addingTimeInterval(-200 * 86400),
                                level: .dormant)
            // 10 天前动过 → 够久，判「可清理」；但 30 天内动过，**不在一键速清的自动范围**里
            let recent = UseState(ownerState: .notRunning, ownerName: "某应用",
                                  lastUsed: Date().addingTimeInterval(-10 * 86400),
                                  level: .recent)
            // 1 天前动过 → 太新鲜（< 3 天门槛）→ 只配「需确认」，由人来定
            let fresh = UseState(ownerState: .notRunning, ownerName: "某应用",
                                 lastUsed: Date().addingTimeInterval(-1 * 86400),
                                 level: .active)
            let running = UseState(ownerState: .running, ownerName: "某应用",
                                   lastUsed: Date(), level: .active)
            st.items = [
                CleanItem(name: "safe", path: "/tmp/macclean-acc-safe", size: 100, rule: "C1",
                          category: .userCaches, use: idle),
                CleanItem(name: "inUse", path: "/tmp/macclean-acc-inuse", size: 50, rule: "C1",
                          category: .userCaches, use: running),
                CleanItem(name: "review", path: "/tmp/macclean-acc-review", size: 25, rule: "A1",
                          category: .userCaches, use: idle),
                CleanItem(name: "keep", path: "/tmp/macclean-acc-keep", size: 10,
                          nature: .systemCritical, category: .userCaches, use: idle),
                CleanItem(name: "recent", path: "/tmp/macclean-acc-recent", size: 200, rule: "C1",
                          category: .userCaches, use: recent),
                CleanItem(name: "fresh", path: "/tmp/macclean-acc-fresh", size: 400, rule: "C1",
                          category: .userCaches, use: fresh),
            ]
            return st
        }

        check("口径：大字「可清理」只算可清理项，不把「勿删 / 使用中 / 需确认」算进去") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = makeCategory().items

            // 扫到 785 = 100 + 50 + 25 + 10 + 200 + 400
            // 可清理 300 = safe(100, 200 天) + recent(200, 10 天)
            //        ← 不含 inUse(50) / review(25) / keep(10) / fresh(400, 仅 1 天)
            guard app.totalScannedSize == 785 else {
                print("      totalScannedSize 期望 785，实际 \(app.totalScannedSize)")
                return false
            }
            guard app.totalCleanable == 300 else {
                print("      totalCleanable 期望 300（不含勿删/使用中/需确认/太新鲜的），实际 \(app.totalCleanable)")
                return false
            }
            // 单独的定性断言：1 天前动过的那一项必须落在「需确认」
            guard let freshItem = st.items.first(where: { $0.name == "fresh" }),
                  freshItem.recommendation.kind == .review else {
                print("      1 天前动过的项没有被判入「需确认」")
                return false
            }
            // 关系不变量：可清理量永远不超过扫到的量
            guard app.totalCleanable <= app.totalScannedSize else { return false }
            return true
        }

        check("口径：大字里绝不能出现「勿删」的体积（0.62 GB 那个真机反例）") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            let idle = UseState(ownerState: .notRunning, ownerName: "某应用",
                                lastUsed: Date().addingTimeInterval(-200 * 86400),
                                level: .dormant)
            // 只有一条"勿删"，没有任何可清理项
            st.items = [
                CleanItem(name: "keepOnly", path: "/tmp/macclean-acc-keeponly", size: 630_000_000,
                          nature: .systemCritical, category: .userCaches, use: idle),
            ]
            guard app.totalCleanable == 0 else {
                print("      只有「勿删」时 totalCleanable 应为 0，实际 \(app.totalCleanable)")
                return false
            }
            guard app.totalScannedSize == 630_000_000 else { return false }
            return true
        }

        check("一键安全速清：按钮承诺的量必须逐字等于实际会勾掉的量") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = makeCategory().items

            // 实际会勾掉的量：走生产路径的那一个函数，不另写一份判据
            let selected = AppState.applyQuickCleanSelection(st.items) { path in
                app.whitelist.isWhitelisted(path: path)
            }
            let actual = selected.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.size }

            guard app.quickCleanableBytes == actual else {
                print("      按钮承诺 \(app.quickCleanableBytes)，实际会清 \(actual) —— 数字与动作分叉了")
                return false
            }
            // 具体值：safe(100, 200 天) + recent(200, 10 天) = 300。
            // 一键速清现在与「全选」同一条 3 天线（它已经有了二次确认，不再需要
            // 用更严的年龄门槛来代替确认）；fresh(400, 1 天) 是「需确认」，不在其中。
            guard app.quickCleanableBytes == 300 else {
                print("      quickCleanableBytes 期望 300，实际 \(app.quickCleanableBytes)")
                return false
            }
            // 与 totalCleanable 的关系不再是"更严"：两者现在同口径。
            // 真正让它们分叉的只剩白名单——所以下面用白名单来验证这一点。
            guard app.quickCleanableBytes <= app.totalCleanable else {
                print("      一键速清的口径不该宽于「可清理」总量")
                return false
            }
            let whitelistedOut = AppState.applyQuickCleanSelection(st.items) { path in
                path.contains("macclean-acc-safe")
            }.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.size }
            guard whitelistedOut == 200 else {
                print("      白名单命中的项没有被排除，实际剩 \(whitelistedOut)")
                return false
            }
            return true
        }

        check("一键速清：先预览再确认——预览不改状态，0 项时不弹空确认") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = makeCategory().items

            // ① 预览是**只读**的：不勾选、不清理
            let preview = app.previewQuickClean(.safe)
            guard preview.count == 2, preview.bytes == 300 else {
                print("      预览结果不对：count=\(preview.count) bytes=\(preview.bytes)")
                return false
            }
            guard st.items.allSatisfy({ !$0.isSelected }), !app.isCleaning else {
                print("      预览居然改动了状态（勾选或清理）")
                return false
            }
            // ② 其中"30 天内还动过"的条数必须如实算出来——那是确认弹窗要展示的代价
            guard preview.recentlyUsedCount == 1 else {
                print("      recentlyUsedCount 期望 1，实际 \(preview.recentlyUsedCount)")
                return false
            }
            // ③ 请求后才进入待确认态
            app.requestQuickClean(.safe)
            guard app.pendingQuickClean == preview else {
                print("      requestQuickClean 没有把预览放进待确认态")
                return false
            }
            // ④ 取消要能清干净，且不执行清理
            app.cancelQuickClean()
            guard app.pendingQuickClean == nil, !app.isCleaning else { return false }
            // ⑤ 一条都不够格时**不许弹空确认**，要如实说明
            let empty = AppState()
            empty.state(for: .userCaches).isScanned = true
            empty.requestQuickClean(.safe)
            guard empty.pendingQuickClean == nil,
                  empty.lastCleanSummary?.contains("没有可直接速清的项") == true else {
                print("      没有可清项时仍然弹出了确认，或没有给出说明")
                return false
            }
            return true
        }

        check("一键速清的确认文案：必须写出代价（多少项最近还动过）") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = makeCategory().items
            let preview = app.previewQuickClean(.safe)
            let text = QuickCleanConfirmText.message(preview)
            guard text.contains("\(preview.count) 项"),
                  text.contains("移入废纸篓"),
                  // 代价句：这是用户真正需要权衡的部分，不能省
                  text.contains("30 天内还动过"),
                  text.contains("不含「使用中 / 需确认 / 勿删」") else {
                print("      确认文案缺了关键信息：\(text)")
                return false
            }
            // 没有"最近还动过"的项时不该硬造这句
            let clean = AppState()
            let cst = clean.state(for: .userCaches)
            cst.isScanned = true
            let idle = UseState(ownerState: .notRunning, ownerName: "某应用",
                                lastUsed: Date().addingTimeInterval(-200 * 86400),
                                level: .dormant)
            cst.items = [CleanItem(name: "a", path: "/tmp/macclean-acc-clean-a", size: 10,
                                   rule: "C1", category: .userCaches, use: idle)]
            let cleanText = QuickCleanConfirmText.message(clean.previewQuickClean(.safe))
            return !cleanText.contains("30 天内还动过")
        }

        check("一键安全速清：只勾「可清理」，绝不碰「使用中 / 需确认 / 勿删」") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = makeCategory().items

            let selected = AppState.applyQuickCleanSelection(st.items) { _ in false }
            let picked = selected.filter(\.isSelected).map(\.name).sorted()
            // safe(200 天) 与 recent(10 天) 都是「可清理」→ 都够格；
            // fresh(1 天) 是「需确认」，inUse / review / keep 都不是 isSafe。
            guard picked == ["recent", "safe"] else {
                print("      一键安全速清勾中了：\(picked)（只应勾中 recent / safe）")
                return false
            }
            // 反方向也要守：白名单命中的项不许被自动勾选
            let whitelisted = AppState.applyQuickCleanSelection(st.items) { _ in true }
            guard whitelisted.allSatisfy({ !$0.isSelected }) else {
                print("      白名单命中项仍被自动勾选")
                return false
            }
            return true
        }

        check("口径边界：全部项都可清理时，两个数字必须相等（不许在数字上做手脚）") {
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            let idle = UseState(ownerState: .notRunning, ownerName: "某应用",
                                lastUsed: Date().addingTimeInterval(-200 * 86400),
                                level: .dormant)
            st.items = [
                CleanItem(name: "a", path: "/tmp/macclean-acc-all-a", size: 70, rule: "C1",
                          category: .userCaches, use: idle),
                CleanItem(name: "b", path: "/tmp/macclean-acc-all-b", size: 30, rule: "C1",
                          category: .userCaches, use: idle),
            ]
            guard app.totalCleanable == 100, app.totalScannedSize == 100 else {
                print("      全可清理时两值应相等：cleanable=\(app.totalCleanable) scanned=\(app.totalScannedSize)")
                return false
            }
            return true
        }
    }
}
