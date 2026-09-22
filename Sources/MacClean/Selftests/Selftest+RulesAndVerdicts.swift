import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：清理规则与结论不变量
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1967–2336）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteRulesAndVerdicts() {
        // MARK: - v1.1 清理规则一致性（防止文档 / 规则源头 / 扫描实现三者再次脱节）
        //
        // 背景：v1.0 曾出现三类脱节 ——
        //   ① 文档引用不存在的 `Sources/MacClean/Rules/CleanupRules.swift`；
        //   ② `Models` 声称 `B1–B4` 而实现只有 B1–B3（幽灵规则）；
        //   ③ README 写「23 条」而文档实际 32 条、代码 35 条。
        // 下列自检把这类不一致变成可自动发现的失败。

        check("清理规则：登记条数与分类分布一致（6 大类 52 条）") {
            // 49 → 52：v1.44.0 新增 L7(CrashReporter)、A4(Saved Application State)、A5(ByHost Preferences)
            guard CleanupRules.count == 52 else { return false }
            // 顺序对应 CleanCategory.allCases：C / L / D / A / T / B
            let byCategory = CleanCategory.allCases.map { CleanupRules.rules(in: $0).count }
            return byCategory == [7, 7, 23, 5, 5, 5]
        }

        // MARK: - 结论一致性不变量
        //
        // 用户的原话：「很多标记高频使用中的文件 还标记了安全 这种我都不敢删」。
        // 下面这几条把那个矛盾锁死在测试里：只要有人再把"正在使用"和"可清理"凑到一起，
        // 自检立刻失败。

        check("不变量：「可清理」蕴含所属应用未在运行（穷举 nature × usage × running）") {
            let natures: [ItemNature] = [.losslessCache, .rebuildable, .staleArtifact,
                                         .inferredUnused, .redownloadable,
                                         .orphanedResidue, .userData, .systemCritical]
            let levels: [UsageLevel] = [.active, .recent, .occasional, .dormant, .unknown]
            for nature in natures {
                for level in levels {
                    for running in [true, false] {
                        let use = UseState(ownerIsRunning: running, ownerName: "某应用",
                                           lastUsed: nil, level: level)
                        let rec = CleanItem.deriveRecommendation(nature: nature, use: use,
                                                                 consequence: "说明")
                        // 核心不变量
                        if rec.kind == .safe && running { return false }
                        // 每个结论都必须带一句可展示的理由，不能是空字符串
                        if rec.reason.trimmingCharacters(in: .whitespaces).isEmpty { return false }
                    }
                }
            }
            return true
        }

        check("不变量：正在运行的应用，其缓存/构建产物一律不判「可清理」") {
            for nature in [ItemNature.losslessCache, .rebuildable, .staleArtifact] {
                let use = UseState(ownerIsRunning: true, ownerName: "Xcode",
                                   lastUsed: nil, level: .dormant)
                let rec = CleanItem.deriveRecommendation(nature: nature, use: use,
                                                         consequence: "缓存")
                guard rec.kind == .inUse else { return false }
                guard rec.reason.contains("Xcode") else { return false }
            }
            return true
        }

        check("不变量：「不建议删除」只由 systemCritical 产生") {
            let natures: [ItemNature] = [.losslessCache, .rebuildable, .staleArtifact,
                                         .inferredUnused, .redownloadable,
                                         .orphanedResidue, .userData, .systemCritical]
            for nature in natures {
                let rec = CleanItem.deriveRecommendation(nature: nature, use: UseState(),
                                                         consequence: "说明")
                if (rec.kind == .keep) != (nature == .systemCritical) { return false }
            }
            return true
        }

        check("不变量：靠推断的规则永不自动判「可清理」（L3/D8/D12/D15/T4）") {
            for id in ["L3", "D8", "D12", "D15", "T4"] {
                guard let rule = CleanupRules.rule(id), rule.nature == .inferredUnused else { return false }
                // 即便"没在运行、长期未用"，也只能是「需确认」
                let use = UseState(ownerIsRunning: false, ownerName: nil,
                                   lastUsed: nil, level: .dormant)
                let rec = CleanItem.deriveRecommendation(nature: rule.nature, use: use,
                                                         consequence: rule.consequence)
                guard rec.kind == .review else { return false }
            }
            return true
        }

        check("B4/B5：DRM 与语音组件不再被标为「可清理」") {
            // 拆分本身
            guard CleanupRules.rule("B4")?.nature == .losslessCache else { return false }
            guard CleanupRules.rule("B5")?.nature == .redownloadable else { return false }
            // 功能组件不得再出现在"下载缓存"名单里
            for name in ["WidevineCdm", "WasmTtsEngine", "SODALanguagePacks"] {
                guard CleanupRules.chromiumFunctionalComponents.contains(name) else { return false }
                guard !CleanupRules.chromiumDownloadCaches.contains(name) else { return false }
            }
            // 且无论应用是否运行，都只能落在「需确认」
            for running in [true, false] {
                let use = UseState(ownerIsRunning: running, ownerName: "Codex",
                                   lastUsed: nil, level: .active)
                let rec = CleanItem.deriveRecommendation(nature: .redownloadable, use: use,
                                                         consequence: "按需下载的功能组件")
                guard rec.kind == .review else { return false }
            }
            return true
        }

        check("全选只勾「可清理」项，绝不碰「使用中/需确认/不建议删除」") {
            let st = CategoryState(category: .userCaches)
            func make(_ name: String, _ size: Int64, _ nature: ItemNature, running: Bool) -> CleanItem {
                CleanItem(name: name, path: "/tmp/\(name)", size: size, nature: nature,
                          consequence: "说明", category: .userCaches,
                          use: UseState(ownerIsRunning: running, ownerName: "某应用",
                                        lastUsed: nil, level: running ? .active : .dormant))
            }
            st.items = [
                make("safe", 1, .losslessCache, running: false),
                make("inUse", 2, .losslessCache, running: true),
                make("review", 4, .orphanedResidue, running: false),
                make("keep", 8, .systemCritical, running: false),
            ]
            st.selectAllSafe()
            return st.selectedCount == 1 && st.selectedSize == 1
                && st.selectedItems.allSatisfy { $0.recommendation.isSafe }
        }

        check("在用检测：目录名与 App 本地化名不一致时仍能判出「正在运行」") {
            // 实测回归：/Applications/Tabbit Browser.app 的 CFBundleName 是英文
            // "Tabbit Browser"，数据目录因此叫 ~/Library/Application Support/Tabbit Browser/；
            // 但 NSRunningApplication.localizedName 返回本地化名「Tabbit浏览器」。
            // 只比对 localizedName 会漏判，于是"浏览器正在写这个缓存"被判成"没在用"→标可清理。
            let aliases = CleanPaths.runningAppAliases
            // 本机此刻若没跑任何 App，这条断言无从验证，直接跳过（不算失败）
            guard !aliases.isEmpty else { return true }
            // 别名集合必须至少覆盖每种运行中 App 的 bundleURL 目录名
            for app in NSWorkspace.shared.runningApplications {
                guard let url = app.bundleURL else { continue }
                let dirName = CleanPaths.normalize(url.deletingPathExtension().lastPathComponent)
                guard !dirName.isEmpty else { continue }
                if !aliases.contains(dirName) { return false }
            }
            return true
        }

        check("在用检测：刚刚被写过的目录不会被判「可清理」（不依赖名称匹配）") {
            // 名称匹配可能因为各种原因失败；"刚刚被写过"是独立于名称的在用证据
            let now = Date()
            for nature in [ItemNature.losslessCache, .rebuildable, .staleArtifact] {
                let use = UseState(ownerIsRunning: false, ownerName: nil,
                                   lastUsed: now.addingTimeInterval(-60),
                                   level: .active, observedAt: now)
                guard use.isBeingWrittenNow else { return false }
                let rec = CleanItem.deriveRecommendation(nature: nature, use: use,
                                                         consequence: "缓存")
                guard rec.kind == .inUse else { return false }
            }
            // 超过时间窗则不应再触发
            let stale = UseState(ownerIsRunning: false, ownerName: nil,
                                 lastUsed: now.addingTimeInterval(-3600),
                                 level: .active, observedAt: now)
            return !stale.isBeingWrittenNow
        }

        check("端到端：正在运行的 App 的 DRM 组件，界面上只显示一个「需确认」") {
            // 复现用户真实看到的那一行：Codex 正在运行时的 WidevineCdm。
            // 修复前这里会渲染出「安全」+「频繁使用中」两枚互相打架的徽标。
            let item = CleanItem(
                name: "Codex WidevineCdm",
                path: "/tmp/macclean-widevine", size: 21_000_000,
                rule: "B5", category: .browserAndSystem,
                use: UseState(ownerIsRunning: true, ownerName: "Codex",
                              lastUsed: Date(), level: .active,
                              observedAt: Date())
            )
            guard item.recommendation.kind == .review else { return false }
            // 徽标只有一枚，文案是「需确认」；理由里点名了是哪个 App、删了会怎样
            let badge = try VerdictBadge(recommendation: item.recommendation)
                .inspect().text().string()
            guard badge == "需确认" else { return false }
            guard item.recommendation.reason.contains("Codex") else { return false }
            guard item.recommendation.reason.contains("重新下载") else { return false }

            let row = ItemRowView(item: item, isSelected: false) { _ in }
            let texts = try row.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
            // 不得出现与结论矛盾的"安全"或"频繁使用中"字样
            return !texts.contains("安全") && !texts.contains("频繁使用中")
        }

        check("未知规则编号退化为「需确认」，不会变成「可清理」") {
            // CleanItem(rule:) 查不到编号时必须往保守方向倒——
            // 规则编号写错绝不能把东西标成可安全删除
            let item = CleanItem(name: "x", path: "/tmp/x", size: 1, rule: "ZZZ",
                                 category: .userCaches)
            return item.nature == .userData && item.recommendation.kind == .review
        }

        check("每条规则都带非空后果说明（否则用户看不到「为什么」）") {
            CleanupRules.all.allSatisfy {
                !$0.consequence.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }

        check("扫描结果：同一路径不得跨分类重复出现（防字节双计）") {
            // 历史风险：C1 扫 ~/Library/Caches/* 全量，D10 又单独针对
            // ~/Library/Caches/org.swift.swiftpm —— 两条规则落在不同分类，
            // 各自 seen 去重管不到对方，同一个目录会被两个分类各计一次字节。
            var owner: [String: String] = [:]
            var dupes: [String] = []
            for cat in CleanCategory.allCases {
                for item in (try? Scanner.scan(cat)) ?? [] {
                    for path in item.paths {
                        let key = FileSystem.normalizePath(path)
                        if let prev = owner[key], prev != cat.rawValue {
                            dupes.append("\(key) 同时属于 \(prev) 与 \(cat.rawValue)")
                        } else {
                            owner[key] = cat.rawValue
                        }
                    }
                }
            }
            if !dupes.isEmpty {
                print("      跨分类重复：\(dupes.prefix(5).joined(separator: "；"))")
            }
            return dupes.isEmpty
        }

        check("清理规则：声明与实现一一对应（无幽灵规则、无未登记实现）") {
            // 规则表 = 声明，Scanner.implementedRuleIDs = 实现。
            // 两者曾经脱节而不自知：A3 登记却从未实现、C5 只有声明、pip/Homebrew 被错标成 C5。
            let declared = Set(CleanupRules.all.map(\.id))
            let implemented = Scanner.implementedRuleIDs
            let phantom = declared.subtracting(implemented).sorted()       // 声明了没实现
            let unregistered = implemented.subtracting(declared).sorted()  // 实现了没登记
            if !phantom.isEmpty { print("      幽灵规则（已声明未实现）：\(phantom)") }
            if !unregistered.isEmpty { print("      未登记实现：\(unregistered)") }
            return phantom.isEmpty && unregistered.isEmpty
        }

        check("清理规则：全表 ID 唯一（无重复登记）") {
            let ids = CleanupRules.all.map(\.id)
            return Set(ids).count == ids.count
        }

        // ── 规则 v2 四维权度（docs/CLEANUP-RULES-V2.md）──
        // 这一组只锁"登记是否自洽"，不改任何删除决策（那是步骤 3/4 的事）。

        // G17 永不归属词元表
        check("G17：系统级/共享状态词元一律不得判为某 app 的残留") {
            // 这些名字都躺在 ~/Library/Application Support 或 Preferences 下，
            // 删了不可重建：iOS 设备备份、系统知识库、崩溃取证材料、SwiftPM 状态。
            let must = ["MobileSync", "mobilesync", "Knowledge", "CrashReporter",
                        "com.apple.Spotlight", "org.swift.swiftpm", "ByHost",
                        "com.google.Keystone.Agent", "WebKit", "Sparkle", "Sentry"]
            var bad = must.filter { !CleanupRules.isNeverAttributable($0) }
            // 反证：普通第三方 bundle 不许被顺手挡掉，否则整张表就是"恒真"在空转
            let mayNot = ["com.acme.widgetstudio", "com.example.todo-app",
                          "com.duckduckgo.macos", "org.videolan.vlc",
                          // `.ShipIt.` 是 L6 认定的确定垃圾（T0），所以 ShipIt 标识
                          // 绝不能被 G17 当成"永不归属"吞掉——这两条规则必须能共存。
                          "com.minimax.agent.cn.ShipIt", "ai.opencode.desktop.ShipIt"]
            bad += mayNot.filter { CleanupRules.isNeverAttributable($0) }.map { "误拒 " + $0 }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("G17：孤儿判定入口确实读到这张表（不是只存在于表里）") {
            // 用一个"清单完整且不含该 id"的数据库直接打判定入口：
            // 表加对了但没接线，这条会红。
            let db = OrphanScanner.InstalledDatabase(
                bundleIDs: ["com.acme.widgetstudio"], bundlePrefixes: ["com.acme"],
                normalizedNames: ["widgetstudio"], executableNames: ["WidgetStudio"],
                runningBundleIDs: [], inventoryComplete: true)
            guard OrphanScanner.isInstalledOrProtected(identifier: "MobileSync", db: db),
                  OrphanScanner.isInstalledOrProtected(identifier: "org.swift.swiftpm", db: db),
                  OrphanScanner.isInstalledOrProtected(identifier: "com.apple.Spotlight", db: db)
            else { return false }
            // 反证：真孤儿仍然要能被查出来
            return !OrphanScanner.isInstalledOrProtected(identifier: "com.gone.awayapp", db: db)
        }

        // ── 规则 v2 步骤 3：档位接进结论引擎 ──

        check("规则 v2 步骤3：档位既升级也降级（只升级的话，新档位就是装饰品）") {
            func item(_ rule: String, _ nature: ItemNature,
                      running: Bool = false) -> CleanItem {
                CleanItem(name: "x", path: "/tmp/x", size: 10, nature: nature,
                          category: .userCaches,
                          use: UseState(ownerIsRunning: running, ownerName: nil,
                                        lastUsed: nil, level: .dormant),
                          rule: rule)
            }
            var bad: [String] = []
            // ① T0 + 未在写 → 从「可清理」升级为「确定是垃圾」
            let up = item("L4", .losslessCache).recommendation
            if up.kind != .garbage { bad.append("L4 未升级：\(up.kind.rawValue)") }
            if !up.reason.contains("确定是垃圾的依据") {
                bad.append("升级后没说明依据：\(up.reason)")
            }
            // ② T2 → 降级为需确认，且必须写明缺哪一维
            let down = item("D7", .losslessCache).recommendation
            if down.kind != .review { bad.append("D7 未降级：\(down.kind.rawValue)") }
            if !down.reason.contains("降级依据") { bad.append("D7 降级没写依据：\(down.reason)") }
            // ③ T3 → 勿删
            if item("D23", .inferredUnused).recommendation.kind != .keep {
                bad.append("D23 未进勿删")
            }
            // ④ T1 不升级：可清理就是可清理，不能什么都能混进「确定是垃圾」
            if item("C1", .losslessCache).recommendation.kind != .safe {
                bad.append("C1（T1）被误升级")
            }
            // ⑤ 没有规则编号的项（治理模块产出）一律不得进最高档
            let noRule = CleanItem(name: "x", path: "/tmp/x", size: 10, nature: .losslessCache,
                                   category: .userCaches,
                                   use: UseState(ownerIsRunning: false, ownerName: nil,
                                                 lastUsed: nil, level: .dormant))
            if noRule.recommendation.kind != .safe { bad.append("无规则编号被误判") }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("规则 v2 步骤3：运行时事实压过档位——T0 的项在宿主运行中仍是使用中") {
            // 这是升级路径上最危险的一种坏法：把"依据很硬"误当成"现在就能删"。
            let running = CleanItem(name: "x", path: "/tmp/x", size: 10, nature: .losslessCache,
                                    category: .userCaches,
                                    use: UseState(ownerIsRunning: true, ownerName: "Finder",
                                                  lastUsed: nil, level: .active),
                                    rule: "L4")
            guard running.recommendation.kind == .inUse else {
                print("      T0 规则在宿主运行中仍被判为 \(running.recommendation.kind.rawValue)")
                return false
            }
            return true
        }

        check("规则 v2 步骤3：「确定是垃圾」仍属安全结论，可批量勾选（但默认仍不勾，见步骤 4）") {
            let g = Recommendation(kind: .garbage, reason: "x")
            return g.isSafe && !g.blocksBulkSelection && g.label == "确定是垃圾"
        }

        check("规则 v2 步骤3：T0 名单里有 4 条依据尚未落地，不得假装已生效") {
            // 结论引擎只在 nature 能产出 safe 时才升级。T0 名单里有 4 条的 nature 还是
            // 「推断/孤儿」，今天仍然落在需确认——这是**如实的缺口**，不是 bug：
            // L3 要等步骤 5 换成「属主==euid 且 >3 天」的结构判据，D8/D12 要等实现侧
            // 补上工具契约证据，A4 要等 nature 从 orphanedResidue 改为 staleArtifact。
            // 把它们写成断言，是为了防止下一轮有人直接改 nature 让名单"看起来"全部生效。
            let promotable: Set<ItemNature> = [.losslessCache, .rebuildable, .staleArtifact]
            let t0 = CleanupRules.all.filter { $0.tier == .t0 }
            let live = Set(t0.filter { promotable.contains($0.nature) }.map(\.id))
            let pending = Set(t0.filter { !promotable.contains($0.nature) }.map(\.id))
            guard live == ["C7", "L4", "L5", "L6", "D11", "D13", "D14"] as Set<String> else {
                print("      今天真能进「确定是垃圾」的规则变了：\(live.sorted())")
                return false
            }
            guard pending == ["L3", "D8", "D12", "A4"] as Set<String> else {
                print("      T0 里待补证据的规则变了：\(pending.sorted())")
                return false
            }
            return true
        }

        check("规则 v2 步骤3：「确定是垃圾」分组真的渲染出来（不只是算对了）") {
            // 分组标题、颜色、是否给批量勾选，都是 VerdictGroup 里的数据；
            // 只测 deriveRecommendation 测不到"界面上真有一组"。这里直接把视图渲染出来查。
            let app = AppState()
            let st = app.state(for: .logsAndTemp)
            st.isScanned = true
            st.items = [
                CleanItem(name: "ModuleCache", path: "/private/tmp/ModuleCache", size: 900_000_000,
                          nature: .losslessCache, category: .logsAndTemp,
                          use: UseState(ownerIsRunning: false, ownerName: nil,
                                        lastUsed: nil, level: .dormant),
                          rule: "D13"),
                CleanItem(name: "some.app.data", path: "/private/tmp/some.app.data", size: 4_000,
                          nature: .orphanedResidue, category: .logsAndTemp,
                          use: UseState(ownerIsRunning: false, ownerName: nil,
                                        lastUsed: nil, level: .dormant),
                          rule: "A1"),
            ]
            let view = CategoryDetailView(category: .logsAndTemp).environmentObject(app)
            guard let root = try? view.inspect() else { return false }
            let texts = root.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            var bad: [String] = []
            if !texts.contains(where: { $0.contains("确定是垃圾") }) {
                bad.append("没有「确定是垃圾」分组标题")
            }
            if !texts.contains(where: { $0.contains("OS 契约或结构标记背书") }) {
                bad.append("分组副标题缺失（用户看不到这一组凭什么更硬）")
            }
            if !texts.contains(where: { $0.contains("需确认") }) {
                bad.append("A1（T2）没有落在需确认组")
            }
            // 反证：两组必须同时存在，否则"升级"是把项从旧组搬丢而不是搬过去
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("规则 v2：每条规则的档位都与它自己的四维登记自洽") {


            var bad: [String] = []
            for rule in CleanupRules.all {
                if let why = CleanupRules.tierViolation(rule) { bad.append("\(rule.id)：\(why)") }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("规则 v2：T0 名单逐条点名（增删 T0 必须同时改规格）") {
            // T0 是唯一允许默认勾选的档，所以这里用**白名单点名**而不是只查数量：
            // 悄悄把某条改成 T0，即使四维看着自洽，也会在这里红。
            let expected: Set<String> = ["C7", "L3", "L4", "L5", "L6",
                                         "D8", "D11", "D12", "D13", "D14", "A4"]
            let actual = Set(CleanupRules.all.filter { $0.tier == .t0 }.map(\.id))
            guard actual == expected else {
                print("      多出的 T0：\(actual.subtracting(expected).sorted())；"
                    + "被移出的 T0：\(expected.subtracting(actual).sorted())")
                return false
            }
            return true
        }

        check("规则 v2：档位分布与规格一致（11 / 16 / 17 / 8）") {
            let count: (CleanupRules.Tier) -> Int = { t in CleanupRules.all.filter { $0.tier == t }.count }
            let got = (count(.t0), count(.t1), count(.t2), count(.t3))
            guard got == (11, 16, 17, 8) else {
                print("      实际档位分布 T0/T1/T2/T3 = \(got.0)/\(got.1)/\(got.2)/\(got.3)")
                return false
            }
            // 四档之和必须等于全表：不能有规则漏填档位或被重复计档
            return got.0 + got.1 + got.2 + got.3 == CleanupRules.all.count
        }

        check("规则 v2：反证——数据契约或高重建代价伪装 T0 必须被拒") {
            func fake(id: String, contract: CleanupRules.Contract,
                      restore: CleanupRules.RestoreCost,
                      ownership: CleanupRules.Ownership = .uniqueBundle) -> CleanupRules.Rule {
                CleanupRules.Rule(id: id, category: .userCaches, nature: .losslessCache,
                                  consequence: "", summary: "",
                                  contract: contract, ownership: ownership,
                                  hostState: .unknown, restore: restore, tier: .t0)
            }
            // ① 位置语义是数据 → 即使归属唯一、重建零成本，也不许进 T0
            guard CleanupRules.tierViolation(
                fake(id: "X1", contract: .userData, restore: .none)) != nil else { return false }
            // ② 重建要重下 GB 级 → 不许进 T0（owner 已定不做联网探测，所以"能重建"不等于"便宜"）
            guard CleanupRules.tierViolation(
                fake(id: "X2", contract: .appleCaches, restore: .autoExpensive)) != nil else { return false }
            // ③ 会丢状态（登录态、字体注册…）→ 不许进 T0
            guard CleanupRules.tierViolation(
                fake(id: "X3", contract: .appleCaches, restore: .stateLoss)) != nil else { return false }
            // ④ 纯靠"名字像垃圾"且归属完全未知 → 不许进 T0
            guard CleanupRules.tierViolation(
                fake(id: "X4", contract: .namedPattern, restore: .none, ownership: .unknown)) != nil else { return false }
            // 反证的反证：合法 T0 形态必须放行，否则上面四条是"恒拒"在空转
            guard CleanupRules.tierViolation(
                fake(id: "X5", contract: .tempDir, restore: .none, ownership: .unknown)) == nil else { return false }
            // T3 也不能当垃圾桶：把可删项塞进"只报告"同样要红
            let wrongT3 = CleanupRules.Rule(id: "X6", category: .userCaches, nature: .losslessCache,
                                            consequence: "", summary: "",
                                            contract: .appleCaches, ownership: .shared,
                                            hostState: .unknown, restore: .autoCheap, tier: .t3)
            return CleanupRules.tierViolation(wrongT3) != nil
        }

        check("清理规则：各分类编号连续无缺号，ruleRef 与实际登记一致") {
            for category in CleanCategory.allCases {
                let ids = CleanupRules.rules(in: category).map(\.id)
                guard !ids.isEmpty, let prefix = ids.first?.first else { return false }
                // ① 同分类编号前缀一致
                guard ids.allSatisfy({ $0.first == prefix }) else { return false }
                // ② 数字部分为 1...n 连续（缺号会让区间声明失真，如曾出现的 "B1–B4"）
                let numbers = ids.compactMap { Int($0.dropFirst()) }
                guard numbers == Array(1...ids.count) else { return false }
                // ③ UI 展示的 ruleRef 必须与登记区间相符
                let expected = ids.count == 1 ? ids[0] : "\(ids[0])–\(ids[ids.count - 1])"
                guard category.ruleRef == expected else { return false }
            }
            return true
        }

        check("安全护栏：$TMPDIR 受限放行只认已知残留，不放行整体") {
            let tmp = CleanPaths.userTempDir
            // 应放行：ShipIt 更新残留 / clang 模块缓存 / node 编译缓存
            guard FileSystem.isKnownTempResidue("\(tmp)/com.example.app.ShipIt.a1B2c3") else { return false }
            guard FileSystem.isKnownTempResidue(CleanPaths.clangModuleCache) else { return false }
            guard FileSystem.isKnownTempResidue(CleanPaths.nodeCompileCache) else { return false }
            // /private 前缀别名形式也应识别
            guard FileSystem.isKnownTempResidue("/private" + CleanPaths.nodeCompileCache) else { return false }
            // 不得放行：$TMPDIR 本身、普通活跃子项、畸形 ShipIt 命名
            guard !FileSystem.isKnownTempResidue(tmp) else { return false }
            guard !FileSystem.isKnownTempResidue("\(tmp)/some-active-build-output") else { return false }
            guard !FileSystem.isKnownTempResidue("\(tmp)/.ShipIt.abc") else { return false }      // 缺 bundle-id 段
            guard !FileSystem.isKnownTempResidue("\(tmp)/com.a.ShipIt.a-b") else { return false }  // 后缀含连字符
            guard !FileSystem.isKnownTempResidue("\(tmp)/com.a.ShipIt.") else { return false }     // 后缀为空
            return true
        }

        check("安全护栏：全局 node_modules 只放行废弃包目录，不放行整根或整个 scope") {
            guard let root = CleanPaths.globalNodeModulesRoots.first else { return false }
            // 应放行：命中废弃标记且标记后紧跟版本号/日期（含 @scope 形式）
            guard FileSystem.isRetiredGlobalPackage("\(root)/dsh.old-0.1.2") else { return false }
            guard FileSystem.isRetiredGlobalPackage("\(root)/@deepseek-ai/dsh.global-retired-20260906") else { return false }
            guard FileSystem.isRetiredGlobalPackage("\(root)/pkg.disabled-2") else { return false }
            // 不得放行：整根、整个 scope 目录、普通包、深层子路径
            guard !FileSystem.isRetiredGlobalPackage(root) else { return false }
            guard !FileSystem.isRetiredGlobalPackage("\(root)/@deepseek-ai") else { return false }
            guard !FileSystem.isRetiredGlobalPackage("\(root)/typescript") else { return false }
            guard !FileSystem.isRetiredGlobalPackage("\(root)/dsh.old-1.0/lib/index.js") else { return false }
            // 不得放行：含标记词但非版本形态（防 bold-italic / is-old-school 类误伤）
            guard !FileSystem.isRetiredGlobalPackage("\(root)/bold-italic") else { return false }
            guard !FileSystem.isRetiredGlobalPackage("\(root)/is-old-school") else { return false }
            return true
        }

        check("安全护栏：符号链接不得成为绕过系统保护的跳板") {
            // 攻击形态：在允许的根目录（家目录）下放一个软链，指向受保护位置。
            // `isSafeToClean` 只看路径字符串，`~/xxx-link/Library/CoreServices` 字面上在家目录内，
            // 于是被判为可清理；但 removeItem 会顺着软链删到 /System 里去。
            let linkPath = NSHomeDirectory() + "/macclean-symlink-probe-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: linkPath) }
            do {
                try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/System")
            } catch {
                return true   // 环境不允许建软链则跳过，不算失败
            }
            // 经由软链抵达的受保护路径必须被拒绝
            let throughLink = linkPath + "/Library/CoreServices"
            guard !FileSystem.isSafeToClean(throughLink) else { return false }
            // 软链本身也不应是可清理目标（删除它不释放任何空间，列出来只会误导）
            guard !FileSystem.isSafeToClean(linkPath) else { return false }
            return true
        }

        check("安全护栏：软链指向目录时不计入体积（避免虚报可释放空间）") {
            // 目标必须是可写目录 —— 用 /System 会因为权限读不到而"碰巧"返回 0，
            // 那样测的是权限而不是软链语义。
            let base = "/private/tmp/macclean-sizeprobe-\(UUID().uuidString)"
            let realDir = base + "/real"
            let linkPath = base + "/link"
            try? FileManager.default.createDirectory(atPath: realDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: realDir + "/inner", withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: realDir + "/inner/blob.bin",
                                           contents: Data(repeating: 7, count: 512 * 1024))
            defer { try? FileManager.default.removeItem(atPath: base) }
            guard (try? FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: realDir)) != nil else {
                return true
            }
            // 真实目录有体积、软链没有：删掉软链一个字节都不会释放
            return FileSystem.size(at: realDir) > 0 && FileSystem.size(at: linkPath) == 0
        }

        check("安全护栏：目录枚举不穿过软链（防扫描到受保护位置）") {
            let base = "/private/tmp/macclean-walk-\(UUID().uuidString)"
            let victim = base + "/victim"
            let link = base + "/link"
            try? FileManager.default.createDirectory(atPath: victim, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: victim + "/payload.bin", contents: Data(repeating: 0, count: 4096))
            defer { try? FileManager.default.removeItem(atPath: base) }
            do {
                try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: victim)
            } catch {
                return true
            }
            // subdirs 不得把软链当成子目录（否则递归扫描会顺着它走到别处）
            let subs = FileSystem.subdirs(of: base)
            return !subs.contains(link)
        }

        check("Cleaner：拒绝经由软链抵达的受保护目标（行为级，不只看断言函数）") {
            let linkPath = NSHomeDirectory() + "/macclean-cleaner-probe-\(UUID().uuidString)"
            defer { try? FileManager.default.removeItem(atPath: linkPath) }
            guard (try? FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/System")) != nil else {
                return true
            }
            // 字面上在家目录内，实际指向 /System —— 执行器必须拒绝，且要报失败而不是静默跳过
            let sneaky = linkPath + "/Library/CoreServices"
            let item = CleanItem(name: "CoreServices", path: sneaky, size: 1,
                                 rule: "C1", category: .userCaches)
            let result = Cleaner.clean([item], permanently: true) { _ in }
            return result.succeeded == 0 && result.failedPaths.contains(sneaky)
        }

        check("Cleaner：正常路径仍能删除（软链加固没有误伤常规清理）") {
            let dir = "/private/tmp/macclean-cleaner-ok-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let file = dir + "/junk.bin"
            FileManager.default.createFile(atPath: file, contents: Data(repeating: 0, count: 2048))
            let item = CleanItem(name: "junk.bin", path: file, size: 2048,
                                 rule: "C1", category: .userCaches)
            let result = Cleaner.clean([item], permanently: true) { _ in }
            let gone = !FileManager.default.fileExists(atPath: file)
            try? FileManager.default.removeItem(atPath: dir)
            return gone && result.succeeded == 1
        }

        check("深度开发残留：D16–D19 规则本质与 CocoaPods/Docker/Cargo/Gradle 路径映射正确") {
            guard let d16 = CleanupRules.rule("D16"), d16.nature == .losslessCache else { return false }
            guard let d17 = CleanupRules.rule("D17"), d17.nature == .losslessCache else { return false }
            guard let d18 = CleanupRules.rule("D18"), d18.nature == .losslessCache else { return false }
            guard let d19 = CleanupRules.rule("D19"), d19.nature == .staleArtifact else { return false }

            // 跨分类防双计：userCachesClaimedBySpecificRules 必须包含 cocoapodsCache
            guard CleanupRules.userCachesClaimedBySpecificRules.contains(CleanPaths.cocoapodsCache) else { return false }

            // 规则与实现一致
            for id in ["D16", "D17", "D18", "D19"] {
                guard Scanner.implementedRuleIDs.contains(id) else { return false }
            }
            return true
        }

        // G5 运行态快照（v1.72.3）：四个访问器共用一份 5 秒快照。
        // 要同时守住两件相反的事——**复用**（性能：原先每个清理项枚举一次运行中应用，
        // 本机 1260 个日志项 = 2500+ 次 NSWorkspace 调用）与**可刷新**（安全：刚启动的
        // App 必须很快被看见，否则它的在用缓存会被列成可清理）。
        check("G5 运行态快照：TTL 内复用同一份，invalidate 后立刻重取且语义不丢") {
            let first = CleanPaths.runningSnapshot
            let second = CleanPaths.runningSnapshot
            guard first.takenAt == second.takenAt else {
                print("      TTL 内重复枚举了运行中应用（快照未复用）")
                return false
            }
            // 语义不能因为合并而丢失：每个在跑的 bundle id 都必须进别名集合，
            // 否则"目录名英文、App 显示中文"那一类又会漏判。
            for bid in first.bundleIDs where !first.aliases.contains(CleanPaths.normalize(bid)) {
                print("      bundle id 未进入别名集合: \(bid)")
                return false
            }
            guard first.bundleIDs.isEmpty
                    || first.namesByBundleID.count > 0 || first.displayNames.count > 0 else { return false }

            CleanPaths.invalidateRunningSnapshot()
            let refreshed = CleanPaths.runningSnapshot
            guard refreshed.takenAt != first.takenAt else {
                print("      invalidate 未生效")
                return false
            }
            // 三个派生视图必须与快照同源
            return CleanPaths.runningBundleIDs == refreshed.bundleIDs
                && CleanPaths.runningAppAliases == refreshed.aliases
                && CleanPaths.runningDisplayNames == refreshed.displayNames
        }

    }
}
