import Foundation

// 自检套件：进程占用事实来源 + 「未知 ≠ 没在用」接缝不变量
//
// 这一套专门盯住本项目最贵的一个建模错误：把"查不到归属"（未知）折叠成
// "确定没在运行"（事实），于是"不知道"变成了"可以删"。
//
// 为什么原先 649 项自检全绿却漏了它：旧断言全部停在 `deriveRecommendation` 的**入参之后**，
// 而入参本身（`UseState.ownerIsRunning`）已经是错的——把 `Bool` 的 false 当成
// "没在用"的证据，就无法区分"查过了没在跑"和"根本没查出来"。
// 所以这一套同时锁三样东西：
//   ① 三态真值表（只有一种组合允许得出"没在用"）；
//   ② 接缝不变量（`.active` 在任何 nature / 任何占用状态下都不得拿到可删结论）；
//   ③ 那条旧自检**恰好停在内侧**的回归格（1 小时前刚被写过的缓存）。
extension Selftest {
    static func suiteProcessOccupancy() {

        check("ProcessOccupancy.parse：字段流解析、进程归属、非路径条目过滤") {
            // 固定输入，不依赖真机当前的进程表——真机输出每次都不一样，
            // 拿它当断言等于什么都没测。
            let dump = """
            p100
            cGoogle Chrome
            f4
            n/Users/me/Library/Caches/Google/Chrome/Default/Cache/data_0
            f5
            n/Users/me/Library/Caches/Google/Chrome/Default/Cache/data_1
            p200
            cGeoServices
            f7
            n/Users/me/Library/Caches/GeoServices
            p300
            cnode
            f9
            nanon_inode:[eventpoll]
            f10
            n/Users/me/Library/Caches/GeoServices
            p400
            f11
            n192.168.1.5:52341->93.184.216.34:443
            p500
            f12
            n/Users/me/Library/Caches/NoCommand
            """
            let parsed = ProcessOccupancy.parse(dump)

            // ① 非绝对路径（匿名 inode / socket 端点）必须被丢掉：它们永远匹配不到清理项
            guard parsed.paths.allSatisfy({ $0.hasPrefix("/") }) else { return false }
            guard !parsed.paths.contains("anon_inode:[eventpoll]") else { return false }
            guard parsed.paths.count == 4 else { return false }

            // ② 同一路径被两个进程持有 → 两个名字都要在
            let geo = Set(parsed.holders["/Users/me/Library/Caches/GeoServices"] ?? [])
            guard geo == ["GeoServices", "node"] else { return false }

            // ③ `p` 必须清空 command：缺 `c` 的进程块不得把文件记到上一个进程头上
            guard parsed.holders["/Users/me/Library/Caches/NoCommand"] == Set(["未知进程"]) else {
                return false
            }

            // ④ 排序保证：holders(of:) 的前缀区间扫描依赖它
            guard parsed.paths == parsed.paths.sorted() else { return false }

            // ⑤ 前缀确实定位到连续区间（两个 Chrome 缓存文件）
            let under = parsed.paths.filter { $0.hasPrefix("/Users/me/Library/Caches/Google/") }
            return under.count == 2
        }

        check("三态真值表：只有『认出归属 + 没在跑 + 无人持有』才允许判『没在用』") {
            var bad: [String] = []
            for known in [true, false] {
                for running in [true, false] {
                    for holders in [[String](), ["GeoServices"]] {
                        let state = Scanner.deriveOwnerState(ownerKnown: known,
                                                             ownerRunning: running,
                                                             holders: holders)
                        let label = "known=\(known) running=\(running) holders=\(holders.count)"
                        if running, state != .running { bad.append("\(label)：在跑却不是 running") }
                        if !running, !holders.isEmpty, state != .running {
                            bad.append("\(label)：有实测持有者却不是 running")
                        }
                        if !known, !running, holders.isEmpty, state != .unknown {
                            bad.append("\(label)：未知被折叠成了 \(state)")
                        }
                        if known, !running, holders.isEmpty, state != .notRunning {
                            bad.append("\(label)：有证据的『没在用』被误判为 \(state)")
                        }
                    }
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("三态：默认是『没有证据』，显式 Bool 才代表『已查明』") {
            let defaulted = UseState()
            guard defaulted.ownerState == .unknown, !defaulted.ownerIsKnown,
                  !defaulted.ownerIsRunning else { return false }

            let knownIdle = UseState(ownerIsRunning: false)
            guard knownIdle.ownerState == .notRunning, knownIdle.ownerIsKnown,
                  !knownIdle.ownerIsRunning else { return false }

            let knownRunning = UseState(ownerIsRunning: true)
            guard knownRunning.ownerState == .running, knownRunning.ownerIsRunning else { return false }

            // 老代码的坏形状 `owner?.isRunning ?? false` 必须映射到 .unknown。
            // 这一行就是整个 bug 的最小复现。
            return Scanner.deriveOwnerState(ownerKnown: false, ownerRunning: false, holders: []) == .unknown
        }

        check("接缝不变量：太新鲜（<3 天）或正被持有的项，绝不出现在任何可删结论上") {
            // 这一条锁的是**门槛本身**，不只是"档位"。
            //
            // 门槛位置是实测选的（见 `UseState.cleanableIdleWindow` 的表格）：
            // 真机上体积几乎全部压在 3 天以内，门槛留在 7 天则"可清理"只剩 0.13 GB。
            // 所以这里用**真实的 lastUsed 偏移**穷举，而不是只穷举 `UsageLevel` 档位——
            // 旧版只穷举档位，恰好绕过了"5 天前写过但档位是 .active"这一格，
            // 而那一格正是门槛从 7 天下调到 3 天时唯一会变的格子。
            let natures: [ItemNature] = [.losslessCache, .rebuildable, .staleArtifact,
                                         .inferredUnused, .redownloadable,
                                         .orphanedResidue, .userData, .systemCritical]
            let states: [OwnerState] = [.running, .notRunning, .unknown]
            // 单位：天。0 与 1 天必须被拦住；3 天之后才允许出可删结论。
            let ageDays: [Double] = [0, 1.0 / 24, 2.9, 3.1, 5, 10, 40, 200]
            // 档位也要一起穷举：T0 会把 safe 升级成 garbage，那条路径同样不许被"太新鲜"穿透
            let rules: [String?] = [nil, "L4", "C1", "D7"]
            let now = Date()

            var violations: [String] = []
            for nature in natures {
                for state in states {
                    for age in ageDays {
                        for rule in rules {
                            let lastUsed = now.addingTimeInterval(-age * 86400)
                            let use = UseState(ownerState: state, ownerName: "某应用",
                                               lastUsed: lastUsed,
                                               level: age < 3 ? .active : .dormant,
                                               observedAt: now)
                            let rec = CleanItem.deriveRecommendation(nature: nature, use: use,
                                                                     consequence: "说明",
                                                                     rule: rule)
                            let label = "\(nature.rawValue)/\(state)/\(age)天/rule=\(rule ?? "-")"
                            // ① 有进程持有 → 一律不许判可删
                            if state == .running, rec.isSafe {
                                violations.append("\(label)：正被持有却判 \(rec.label)")
                            }
                            // ② 距今不到门槛 → 不许判可删（这正是本次要划清的线）
                            if age < 3, rec.isSafe {
                                violations.append("\(label)：太新鲜却判 \(rec.label)")
                            }
                            // ③ 门槛之外**必须**能判可删，否则这条闸门就是"什么都不放行"
                            //    （没有这条反证，把门槛设成 9999 天也能让本检查通过）
                            if age >= 5, state != .running, nature == .losslessCache, rule == "C1",
                               rec.kind != .safe {
                                violations.append("\(label)：够久了却仍不放行（\(rec.label)）")
                            }
                            // 理由不能是空字符串（每个结论都要能展示依据）
                            if rec.reason.trimmingCharacters(in: .whitespaces).isEmpty {
                                violations.append("\(label)：理由为空")
                            }
                        }
                    }
                }
            }
            if !violations.isEmpty {
                print("      " + violations.prefix(8).joined(separator: "\n      "))
            }
            return violations.isEmpty
        }

        check("回归：1 小时前刚被写过的缓存，不得再拿到任何可删结论（旧自检恰好停在这一格的内侧）") {
            // 旧自检构造了完全相同的 fixture（`lastUsed = now - 3600, level = .active`），
            // 然后只断言 `!stale.isBeingWrittenNow`——对结论不作任何要求，
            // 于是"窗口关闭之后一律可清理"这条错误行为被留在了断言之外。
            // 真机后果：`~/Library/Caches/@deepseek-aidsh-desktop-updater`（1 小时前写过）
            // 挂着绿色「可清理」徽标，而依据那一行自己印着「最近 7 天内有过写入」。
            let now = Date()
            let use = UseState(ownerState: .notRunning, ownerName: nil,
                               lastUsed: now.addingTimeInterval(-3600),
                               level: .active, observedAt: now)
            guard !use.isBeingWrittenNow else { return false }   // 前提：已超出 10 分钟窗口
            let rec = CleanItem.deriveRecommendation(nature: .losslessCache, use: use,
                                                     consequence: "缓存")
            // 核心性质：既不是「可清理」也不是「确定是垃圾」——不能出现在"全选"里。
            guard !rec.isSafe else {
                print("      1 小时前被写过的缓存仍被判：\(rec.label) — \(rec.reason)")
                return false
            }
            // 具体落点：弱信号 → 「需确认」（不是"使用中"，因为此刻确实没有人持有它）。
            guard rec.kind == .review else {
                print("      期望「需确认」，实际：\(rec.label)")
                return false
            }
            return true
        }

        check("回归：T2 规则自带更精确的降级判据，不得被「近 7 天有写入」盖掉") {
            // `.gradle/caches`（D7）是 T2：结论本身就该是「需确认」，理由是
            // "重建要重下 GB 级内容，而本工具不探测网络可达性"。
            // 若这条闸门一律判「使用中」，规则自带的精确判据就被一句更含糊的话替代了。
            let use = UseState(ownerState: .notRunning, ownerName: nil,
                               lastUsed: Date().addingTimeInterval(-86400),
                               level: .active)
            let item = CleanItem(name: "caches", path: "/tmp/caches", size: 10,
                                 nature: .losslessCache, category: .devResidue,
                                 use: use, rule: "D7")
            let rec = item.recommendation
            guard rec.kind == .review else {
                print("      D7 期望「需确认」，实际：\(rec.label)")
                return false
            }
            guard rec.reason.contains("降级依据") else {
                print("      D7 丢了规则自带的降级说明：\(rec.reason)")
                return false
            }
            return true
        }

        check("回归：三重 nature 在 `.active` 下结论一致（缓存不再比构建产物宽松）") {
            // 修复前 `.rebuildable`（构建产物）认 7 天，`.losslessCache`（缓存）只认 10 分钟——
            // 同一个时间证据，只因为 nature 不同就推翻了结论。现在必须一致。
            var bad: [String] = []
            let use = UseState(ownerState: .notRunning, ownerName: nil,
                               lastUsed: Date().addingTimeInterval(-86400),
                               level: .active)
            for nature in [ItemNature.losslessCache, .rebuildable, .staleArtifact] {
                let rec = CleanItem.deriveRecommendation(nature: nature, use: use, consequence: "说明")
                if rec.kind != .review { bad.append("\(nature.rawValue) → \(rec.label)") }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "；")) }
            return bad.isEmpty
        }

        check("接缝：归属表覆盖范围之外的路径，annotateUsage 不得写出『没在用』") {            // `/private/tmp` 不在 CleanPaths.ownerApp 的 7 个根目录里。
            // 老代码 `owner?.isRunning ?? false` 在这里必然给出 false = "没在用"。
            guard CleanPaths.ownerApp(of: "/private/tmp") == nil else { return false }
            let item = CleanItem(name: "tmp", path: "/private/tmp", size: 0,
                                 nature: .losslessCache, category: .logsAndTemp)
            let annotated = Scanner.annotateUsage(item)
            guard annotated.use.ownerState != .notRunning else {
                print("      认不出归属的路径被写成了 .notRunning —— 老 bug 复活")
                return false
            }
            return true
        }

        check("真机：lsof 转储可用，且反查表能回查到真实被打开的文件") {
            guard ProcessOccupancy.refresh() else {
                // 这台机器上 lsof 不可用（裁剪系统/沙盒）。不能假装测过，如实说明后放行。
                print("      lsof 不可用，本机无法验证占用事实（接口语义仍由固定输入那两条守住）")
                return true
            }
            let diag = ProcessOccupancy.diagnostics()
            guard diag.succeeded, diag.pathCount > 0 else {
                print("      转储成功但反查表为空：pathCount=\(diag.pathCount)")
                return false
            }
            // 往返验证：从真实转储里取一条被打开的路径，查询接口必须能找回它的持有者。
            // 只用固定输入测解析器是不够的——那只证明解析器自洽，不证明索引真的能查。
            //
            // 取样要跳过 `"/"`：lsof 会把进程的 cwd=根目录报成 `n/`，排序后它正好排第一。
            // `holders(of: "/")` 刻意返回空——它的前缀区间是整个表，而清理项不可能是根目录，
            // 放行只会让每个项都在全表上扫一遍。
            let samples = ProcessOccupancy.sampleOpenPaths(limit: 50)
            guard !samples.isEmpty else { return false }
            guard let probe = samples.first(where: { $0 != "/" }) else { return false }
            let holders = ProcessOccupancy.holders(of: probe)
            guard !holders.isEmpty else {
                print("      反查失败：\(probe) 在表里却查不到持有者")
                return false
            }
            return true
        }

        check("一键推荐不得勾中『太新鲜（<3 天）』的项（结论修复的自然结果，锁住防回归）") {
            // 这条不是新写的防护，而是**结论修复顺带堵死的一条路**：
            // `selectSmartRecommendations()` 只按 `isSafe + 档位` 勾选，从不看"最近是否写过"
            // （它比还有 `!isRecentlyUsed` 一道 30 天闸的 `applyQuickCleanSelection` 宽松，
            // 而 `QuickCleanPanel` 的分支顺序恰好把它排在前面）。
            // 结论层把"太新鲜"判成「需确认」之后，这条更宽松的路径就再也没法勾中它们了。
            // 用断言钉住：否则哪天有人把门槛改回去，这里会立刻红。
            let app = AppState()
            let st = app.state(for: .userCaches)
            st.isScanned = true
            st.items = [
                CleanItem(name: "active", path: "/tmp/macclean-active", size: 900_000_000,
                          rule: "C1", category: .userCaches,
                          use: UseState(ownerState: .notRunning,
                                        lastUsed: Date().addingTimeInterval(-3600),
                                        level: .active)),
                CleanItem(name: "dormant", path: "/tmp/macclean-dormant", size: 900_000_000,
                          rule: "C1", category: .userCaches,
                          use: UseState(ownerState: .notRunning,
                                        lastUsed: Date().addingTimeInterval(-200 * 86400),
                                        level: .dormant)),
            ]
            app.selectSmartRecommendations()
            let selected = st.items.filter(\.isSelected).map(\.name)
            guard selected == ["dormant"] else {
                print("      一键推荐勾中了：\(selected)（只应勾中 dormant）")
                return false
            }
            return true
        }
    }
}
