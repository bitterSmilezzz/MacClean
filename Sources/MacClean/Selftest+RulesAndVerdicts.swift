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

    }
}
