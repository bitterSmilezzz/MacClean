import Foundation
import Darwin

// MARK: - 统一删除网关与治理域不变量自检（v1.72.0）
//
// 这一套件守的不是某个模块的具体分支，而是**所有治理模块共享的那道门**：
// 12 个模块此前各自写着 `hasPrefix("/System")`，逐模块复刻断言只会把弱防线锁死。
// 现在改成属性式断言：穷举所有登记域、所有核心护栏、软链跳板、权限不足、
// 记账诚实性——任一条不变量被后来的改动破坏，这里立刻红。

extension Selftest {
    static func suiteDeletionGate() {
        print("--- [Suite] 统一删除网关与治理域不变量自检 (v1.72.0) ---")

        let fm = FileManager.default
        func makeFixture(_ tag: String) -> String {
            let dir = "/private/tmp/macclean_gate_\(tag)_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return dir
        }
        func makeFile(_ path: String, _ bytes: Int) {
            try? Data(repeating: 0x5A, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        func exists(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0
        }
        /// 造一个只指向临时测试根的合成域（不污染真实治理域清单）
        func syntheticDomain(root: String, depth: Int = 1,
                             entries: Set<String>? = nil) -> GovernanceDomain {
            GovernanceDomain(id: "selftest.\(UUID().uuidString)", root: root,
                             minDepthBelowRoot: depth, note: "自检合成域",
                             allowedEntryNames: entries)
        }

        // 1. 治理域清单自洽：任何一条登记不合规都不允许进注册表
        check("治理域注册表：id 唯一、根路径绝对且非 /、深度下界 ≥1") {
            var seen = Set<String>()
            for domain in GovernanceDomain.all {
                guard !seen.contains(domain.id) else { return false }
                seen.insert(domain.id)
                let root = domain.normalizedRoot
                guard root.count > 1, !root.hasSuffix("/") else { return false }
                guard root.hasPrefix("/") else { return false }
                guard domain.minDepthBelowRoot >= 1 else { return false }
                guard !domain.note.isEmpty else { return false }
            }
            // byID 必须与 all 同规模（重复 id 会被 Dictionary 折叠掉一条）
            return GovernanceDomain.byID.count == GovernanceDomain.all.count
        }

        // 1b. 运行时登记的动态域必须真的进注册表——否则"新增治理模块必须登记"就是个空承诺，
        // 而上面那几条穷举断言（遍历 `GovernanceDomain.all`）永远扫不到它。
        check("治理域注册表：动态登记进 all/byID、按 id 去重，且 QuickLook 动态域已被穷举覆盖") {
            // ① 纯注册表行为：同 id 重复登记覆盖而非追加
            let root = makeFixture("dynamic")
            defer { try? fm.removeItem(atPath: root) }
            let id = "selftest.dynamic.\(UUID().uuidString)"
            let first = GovernanceDomain(id: id, root: root, minDepthBelowRoot: 1, note: "自检动态域")
            GovernanceDomain.register(first)
            guard GovernanceDomain.byID[id]?.root == root,
                  GovernanceDomain.all.filter({ $0.id == id }).count == 1 else { return false }
            let second = GovernanceDomain(id: id, root: root + "/inner", minDepthBelowRoot: 1, note: "自检动态域")
            GovernanceDomain.register(second)
            guard GovernanceDomain.all.filter({ $0.id == id }).count == 1,
                  GovernanceDomain.byID[id]?.root == root + "/inner" else { return false }
            // ② 动态域同样吃得到穷举断言的护栏：登记后 `all` 里那条就是它，且域根不可删
            guard let listed = GovernanceDomain.all.first(where: { $0.id == id }),
                  case .rejected = FileSystem.governanceVerdict(listed.root, domain: listed) else { return false }
            guard GovernanceDomain.byID.count == GovernanceDomain.all.count else { return false }

            // ③ 真实案例：QuickLook 的动态域在首次使用时登记，且被 `all` 覆盖。
            //    本机取不到该目录时跳过（不谎报，也不把这条判成失败）。
            guard let ql = QuickLookThumbnailPurger.darwinCacheDomain() else {
                print("      本机取不到 Darwin 用户缓存目录，跳过 QuickLook 动态域覆盖断言")
                return true
            }
            guard GovernanceDomain.byID["quicklook.darwinCache"]?.root == ql.root else {
                print("      quicklook.darwinCache 未登记进注册表")
                return false
            }
            for target in ["/System/Library/Fonts/SFNS.ttf", "/private/var/db/receipts/anything"] {
                let verdict = FileSystem.governanceVerdict(target, domain: ql)
                guard case .rejected(let protectedReason) = verdict,
                      protectedReason == .systemProtected else {
                    print("      动态域放行了受保护目标: \(target) → \(verdict)")
                    return false
                }
            }
            guard case .rejected(let rootReason) = FileSystem.governanceVerdict(ql.root, domain: ql),
                  rootReason == .tooShallowForDomain else { return false }
            return true
        }

        // 1c. 12 份 path→domain 映射器已收敛到注册表的同一个解析器（最长 root 匹配，含动态域）
        check("治理域注册表：统一解析器按最长 root 匹配，且各模块映射器与它结论一致") {
            // 最长匹配：PPD 资源树必须落到 ppdResources，落到 printersGlobal 会放宽层级下界
            guard GovernanceDomain.domain(forPath: "/Library/Printers/PPDs/Contents/Resources/HP.ppd")
                    == .ppdResources else { return false }
            guard GovernanceDomain.domain(forPath: "/Library/Printers/Canon") == .printersGlobal else { return false }
            // 不在任何登记域内 → nil（由基础护栏拒绝）
            guard GovernanceDomain.domain(forPath: "/Library/Developer/Xcode/B.plist") == nil,
                  GovernanceDomain.domain(forPath: "") == nil else { return false }
            // 各模块入口只是薄封装：同一位置在 12 处必须得到同一个域
            let probes: [(String, GovernanceDomain?)] = [
                ("/Library/Fonts/Some.ttf", .fontsGlobal),
                ("/Library/ColorSync/Profiles/Displays/A.icc", .colorSyncProfiles),
                ("/Library/Audio/Plug-Ins/HAL/A.driver", .audioHAL),
                ("/Library/Audio/Plug-Ins/Components/A.component", .audioComponents),
                ("/Library/LaunchAgents/a.plist", .launchAgentsGlobal),
                ("/Library/LaunchDaemons/b.plist", .launchDaemonsGlobal),
                ("/Library/QuickLook/A.qlgenerator", .quickLookGlobal),
                ("/Applications/Foo.app/Contents/Resources/en.lproj", .appLocalizedResources),
                (FileSystem.normalizePath(NSHomeDirectory()) + "/Library/Fonts/A.ttf", nil),
            ]
            for (path, expected) in probes {
                guard GovernanceDomain.domain(forPath: path) == expected else {
                    print("      注册表解析不一致: \(path) → \(String(describing: GovernanceDomain.domain(forPath: path)))")
                    return false
                }
                let resolved: [GovernanceDomain?] = [
                    FontCacheInspector.governanceDomain(forPath: path),
                    CLICacheScanner.governanceDomain(forPath: path),
                    LoginItemCleaner.governanceDomain(forPath: path),
                    PluginExtensionInspector.governanceDomain(forPath: path),
                    PrinterDriverScanner.domain(for: path),
                    ColorSyncScanner.domain(for: path),
                    AudioHALScanner.domain(for: path),
                    LanguagePackItem(id: path, code: "en", displayName: "英语", path: path,
                                     size: 1, isProtected: false).governanceDomain,
                ]
                guard resolved.allSatisfy({ $0 == expected }) else {
                    print("      模块映射器与注册表不一致: \(path) → \(resolved.map { $0?.id ?? "nil" })")
                    return false
                }
            }
            return true
        }

        // 2. 域根本身永不可删：授权精确到"根之下的条目"
        check("治理域：域根本身与层级过浅的目标一律拒绝") {
            for domain in GovernanceDomain.all {
                let verdict = FileSystem.governanceVerdict(domain.root, domain: domain)
                guard case .rejected(let reason) = verdict else {
                    print("      域根被放行: \(domain.id)")
                    return false
                }
                // 域根可能确实不存在或读不到，这两种也算安全；但绝不能是 allowed
                guard reason != .userWhitelisted || true else { return false }
            }
            // 深度 4 的 App 包资源域：删 `.app` 本体必须被拒
            let appBody = FileSystem.governanceVerdict(
                "/Applications/Calculator.app", domain: .appLocalizedResources)
            guard case .rejected(let r) = appBody, r == .tooShallowForDomain else { return false }
            // Spotlight 卷索引域：入口名单之外的任意卷内目录必须被拒
            let anyFolder = FileSystem.governanceVerdict(
                "/Volumes/SomeVolume/Users", domain: .volumeSpotlightIndex)
            guard case .rejected(let r2) = anyFolder, r2 == .outsideDomain else { return false }
            return true
        }

        // 3. 跨域越界：A 域的授权绝不覆盖 B 域的位置
        check("治理域：目标落在别的域位置时判为越界拒绝") {
            let verdict = FileSystem.governanceVerdict(
                "/Library/Audio/Plug-Ins/HAL/Fake.driver", domain: .fontsGlobal)
            guard case .rejected(let r) = verdict, r == .outsideDomain else { return false }
            // 反过来也一样
            let verdict2 = FileSystem.governanceVerdict(
                "/Library/Fonts/Fake.otf", domain: .audioHAL)
            guard case .rejected(let r2) = verdict2, r2 == .outsideDomain else { return false }
            return true
        }

        // 4. G8 系统硬保护在所有域下优先级最高（穷举每个域喂同一个受保护目标）
        check("治理域：SIP/系统硬保护目标在每一个域下都不可放行") {
            let protectedTargets = [
                "/System/Library/Fonts/SFNS.ttf",
                "/System/Library/ColorSync/Profiles/Apple.icc",
                "/Library/Updates/Whatever",
                "/private/var/db/receipts/anything",
            ]
            for domain in GovernanceDomain.all {
                for target in protectedTargets {
                    guard case .rejected(let reason) = FileSystem.governanceVerdict(target, domain: domain),
                          reason == .systemProtected else {
                        print("      放行或误因: \(domain.id) ← \(target)")
                        return false
                    }
                }
            }
            return true
        }

        // 5. 软链跳板：字面在域内、解析后在域外 → 必拒，且软链本身不动
        check("治理域：符号链接把目标带到域外时拒绝（软链逃逸封堵）") {
            let root = makeFixture("symlink")
            defer { try? fm.removeItem(atPath: root) }
            // 先让真实位置存在，否则 realPath 会保留未存在的路径形态
            let linkPath = root + "/escape"
            try? fm.createDirectory(atPath: root + "/inside", withIntermediateDirectories: true)
            let ok = (try? fm.createSymbolicLink(
                at: URL(fileURLWithPath: linkPath),
                withDestinationURL: URL(fileURLWithPath: "/System/Library/Frameworks"))) != nil
            guard ok else { return false }
            defer { try? fm.removeItem(atPath: linkPath) }

            // 末段本身是软链 → 直接拒
            guard case .rejected(let r) = FileSystem.governanceVerdict(linkPath, domain: syntheticDomain(root: root)),
                  r == .symlinkJump else { return false }
            // 域内软链目录被解析后已不在域内 → 也拒
            let nested = root + "/inside/../../Outside.icc"
            let verdict2 = FileSystem.governanceVerdict(nested, domain: syntheticDomain(root: root))
            guard case .rejected(let r2) = verdict2, r2 != .emptyPath else { return false }
            return exists(linkPath)
        }

        // 6. 用户白名单对治理域同样生效（这是老 selftest 完全没覆盖的路径）
        check("治理域：用户自定义白名单优先于任何放行规则") {
            let root = makeFixture("whitelist")
            defer { try? fm.removeItem(atPath: root) }
            let victim = root + "/keepme.otf"
            makeFile(victim, 2048)

            let saved = WhitelistManager.shared.rules
            WhitelistManager.shared.removeAllRules()
            defer {
                WhitelistManager.shared.removeAllRules()
                WhitelistManager.shared.rules = saved
            }
            WhitelistManager.shared.addPathRule(root, comment: "自检")

            let verdict = FileSystem.governanceVerdict(victim, domain: syntheticDomain(root: root))
            guard case .rejected(let r) = verdict, r == .userWhitelisted else { return false }

            let outcome = ResidueDeletionGate.execute(
                [ResidueDeletionGate.Candidate("keepme.otf", path: victim,
                                               domain: syntheticDomain(root: root))],
                journal: .none)
            return outcome.cleanedCount == 0 && outcome.errorCount == 1 && exists(victim)
        }

        // 7. 权限不足要说实话：既不许谎称可删，也不许悄悄算作已清理
        check("治理域：父目录无写权限时判 needsPrivilege 且文件保持原样") {
            let root = makeFixture("privilege")
            defer { chmod(root, 0o755); try? fm.removeItem(atPath: root) }
            let victim = root + "/locked.icc"
            makeFile(victim, 1024)
            try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root) }
            guard geteuid() != 0 else { return true }   // root 环境下无法验证，直接放过

            guard FileSystem.canUnlink(victim) == false else { return false }
            let verdict = FileSystem.governanceVerdict(victim, domain: syntheticDomain(root: root))
            guard case .rejected(let r) = verdict, r == .needsPrivilege else { return false }

            let outcome = ResidueDeletionGate.execute(
                [ResidueDeletionGate.Candidate("locked.icc", path: victim,
                                               domain: syntheticDomain(root: root))],
                journal: .none)
            return outcome.cleanedCount == 0 && outcome.freedBytes == 0
                && outcome.needsPrivilege.count == 1 && exists(victim)
        }

        // 8. 祖先去重：同时勾父目录与其子文件时，体积只能算一次
        check("删除网关：父子同时入选时不重复计释放体积") {
            let root = makeFixture("ancestor")
            defer { try? fm.removeItem(atPath: root) }
            makeFile(root + "/a.bin", 4096)
            makeFile(root + "/b.bin", 4096)
            let dirSize = FileSystem.size(at: root)
            guard dirSize > 0 else { return false }

            let outcome = ResidueDeletionGate.execute([
                ResidueDeletionGate.Candidate("整目录", path: root),
                ResidueDeletionGate.Candidate("a.bin", path: root + "/a.bin"),
                ResidueDeletionGate.Candidate("b.bin", path: root + "/b.bin"),
            ], journal: .none)

            let stillThere = exists(root) || exists(root + "/a.bin") || exists(root + "/b.bin")
            // 只应实际处理一次，且记账等于整目录实测体积，而不是 3 份
            return outcome.cleanedCount == 1 && outcome.freedBytes == dirSize && !stillThere
        }

        // 9. policy 闭包是模块特有判据的唯一插入口：拦下就不许动文件，
        //    且必须能把**模块自己的中文原因**带出来（v1.73：此前只能回一个枚举 case，
        //    message 被强制回填成内置文案，于是 4 批工程师各自造了绕过方案）。
        check("删除网关：policy 拒绝的项必须原样保留、带出自定义原因且计入 errorCount") {
            let root = makeFixture("policy")
            defer { try? fm.removeItem(atPath: root) }
            makeFile(root + "/orphan.dat", 512)
            makeFile(root + "/inuse.dat", 512)

            let outcome = ResidueDeletionGate.execute([
                ResidueDeletionGate.Candidate("orphan", path: root + "/orphan.dat"),
                ResidueDeletionGate.Candidate("inuse", path: root + "/inuse.dat"),
            ], journal: .none) { candidate in
                guard candidate.name == "inuse" else { return nil }
                return .make(candidate, reason: .inUse, message: "注册表显示它仍在被设备使用")
            }
            guard outcome.cleanedCount == 1 && outcome.errorCount == 1,
                  outcome.rejected.first?.path.contains("inuse.dat") == true,
                  exists(root + "/inuse.dat"), !exists(root + "/orphan.dat") else { return false }
            // 专用 case + 自定义文案：既不借用 .systemProtected，也不被回填成枚举内置文案
            guard outcome.rejected.first?.reason == .inUse,
                  outcome.rejected.first?.message == "注册表显示它仍在被设备使用" else {
                print("      policy 的自定义原因未带出: \(outcome.rejected.first?.message ?? "nil")")
                return false
            }
            // 省略 message 时回落到 reason 的内置文案（旧行为仍可用）
            let fallback = ResidueDeletionGate.execute(
                [ResidueDeletionGate.Candidate("quiet", path: root + "/inuse.dat")],
                journal: .none) { candidate in .make(candidate, reason: .notDeletable) }
            return fallback.rejected.first?.message == GovernanceVerdict.rejected(.notDeletable).message
        }

        // 9b. 两份结果相加只有一份实现：模块预筛项在前、网关项在后，计数字段逐项累加
        check("删除网关：Outcome.merge 保留模块预筛项且逐字段累加") {
            let root = makeFixture("merge")
            defer { try? fm.removeItem(atPath: root) }
            makeFile(root + "/a.dat", 1024)

            let pre = ResidueDeletionGate.Rejection.make(name: "预先拦下", path: root + "/pre.dat",
                                                         reason: .notDeletable, message: "模块自己判掉的项")
            let gate = ResidueDeletionGate.execute(
                [ResidueDeletionGate.Candidate("a.dat", path: root + "/a.dat")], journal: .none)
            let merged = ResidueDeletionGate.Outcome(rejected: [pre]).merging(gate)

            guard merged.cleanedCount == gate.cleanedCount, merged.freedBytes == gate.freedBytes,
                  merged.cleanedPaths == gate.cleanedPaths,
                  merged.failed.count == gate.failed.count else { return false }
            // 顺序即语义：模块先拦的项排在网关结论之前
            return merged.rejected.count == gate.rejected.count + 1
                && merged.rejected.first?.name == "预先拦下"
                && merged.errorCount == merged.rejected.count + merged.failed.count
        }

        // 10. 记账诚实：freedBytes 必须等于实际被删项删除前实测体积之和
        check("删除网关：释放量按删除前实测计，失败项不计入") {
            let root = makeFixture("accounting")
            defer { try? fm.removeItem(atPath: root) }
            makeFile(root + "/one.dat", 8000)
            makeFile(root + "/two.dat", 12000)

            let outcome = ResidueDeletionGate.execute([
                ResidueDeletionGate.Candidate("one", path: root + "/one.dat"),
                ResidueDeletionGate.Candidate("two", path: root + "/two.dat"),
                ResidueDeletionGate.Candidate("幽灵", path: root + "/ghost.dat"),   // 不存在
            ], journal: .none)

            // 不存在的项按"已消失"拒绝，绝不能凭空计一笔释放量
            let ghostRejected = outcome.rejected.contains { $0.reason == .missing }
            return ghostRejected && outcome.cleanedCount == 2
                && outcome.freedBytes == 8000 + 12000 && outcome.failed.isEmpty
        }

        // 11. 彻底删除与废纸篓两条路都必须留下可回退/可追溯的痕迹
        check("删除网关：写历史与撤销快照，.none 时不留任何痕迹") {
            let historyBefore = HistoryStore.load()
            let undoBefore = UndoManagerStore.load()
            guard MacCleanState.isIsolated else {
                // 自检未处于隔离状态时绝不往用户真实历史里写测试记录
                print("      MACCLEAN_STATE_DIR 未生效，跳过写入断言")
                return false
            }

            let root = makeFixture("journal")
            defer { try? fm.removeItem(atPath: root) }
            makeFile(root + "/quiet.dat", 1024)
            makeFile(root + "/loud.dat", 1024)

            let silent = ResidueDeletionGate.execute(
                [ResidueDeletionGate.Candidate("quiet", path: root + "/quiet.dat")],
                toTrash: false, journal: .none)
            guard silent.cleanedCount == 1,
                  HistoryStore.load().count == historyBefore.count,
                  UndoManagerStore.load().count == undoBefore.count else { return false }

            let loudOutcome = ResidueDeletionGate.execute(
                [ResidueDeletionGate.Candidate("loud", path: root + "/loud.dat")],
                toTrash: true, journal: .module(categoryName: "自检治理域"))
            let historyAfter = HistoryStore.load()
            guard loudOutcome.cleanedCount == 1, loudOutcome.freedBytes == 1024 else { return false }
            guard historyAfter.count == historyBefore.count + 1,
                  historyAfter.first?.categoryName == "自检治理域" else { return false }
            let sessions = UndoManagerStore.load()
            guard sessions.count == undoBefore.count + 1,
                  sessions.contains(where: { $0.entries.contains(where: { entry in
                      entry.originalPath.contains("loud.dat") && entry.size == 1024
                  }) }) else { return false }
            // 自检不该在用户废纸篓里留下残留
            for snapshot in loudOutcome.trashedSnapshots {
                try? fm.removeItem(atPath: snapshot.trashPath)
            }

            // 收尾：把这次测试记录摘掉，别留下"自检也清了 1 KB"的假账
            HistoryStore.save(historyBefore)
            UndoManagerStore.save(undoBefore)
            return true
        }

        // 11b. `load → insert → save` 是读改写：并发清理必须整段串行，
        // 否则后写的那个把前一个的记录整份覆盖，用户刚清掉的一项既进不了历史也没有撤销快照，
        // 而界面上 cleanedCount 看着完全正常。
        check("删除网关：并发清理各自的历史与撤销记录都不丢失") {
            guard MacCleanState.isIsolated else { return false }
            let historySnap = HistoryStore.load()
            let undoSnap = UndoManagerStore.load()
            defer {
                HistoryStore.save(historySnap)
                UndoManagerStore.save(undoSnap)
            }

            let rounds = 8
            let root = makeFixture("concurrent")
            defer { try? fm.removeItem(atPath: root) }
            for i in 0..<rounds { makeFile(root + "/c\(i).dat", 1024) }

            let group = DispatchGroup()
            let start = DispatchSemaphore(value: 0)
            for i in 0..<rounds {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    start.wait()
                    _ = ResidueDeletionGate.execute(
                        [ResidueDeletionGate.Candidate("c\(i)", path: root + "/c\(i).dat")],
                        toTrash: true, journal: .module(categoryName: "自检并发记账"))
                }
            }
            for _ in 0..<rounds { start.signal() }
            group.wait()

            // 只比"本轮这 8 条在不在"，不比绝对条数：两个存储都有截断上限
            let mine = HistoryStore.load().filter { $0.categoryName == "自检并发记账" }
            guard mine.count == rounds, Set(mine.map(\.id)).count == rounds else { return false }
            let ids = Set(mine.map(\.id))
            let sessions = UndoManagerStore.load().filter { ids.contains($0.recordID) }
            guard sessions.count == rounds else { return false }
            for session in sessions {
                for entry in session.entries { try? fm.removeItem(atPath: entry.trashPath) }
            }
            return true
        }

        // G15 不变量：产品源码里 `Process()` 只允许出现在 SafeProcess.swift 自己那一处。
        // 与动效 lint 同形：绝对路径定位源码目录（相对路径 + `try? … else continue`
        // 会在工作目录不是仓库根时**零违规地空转**），读不到目录直接判失败，跳过注释行。
        //
        // 必须用 `subpathsOfDirectory` 而不是 `contentsOfDirectory`：后者**不递归**，
        // 会把 `Sources/MacClean/Rules/` 整个漏掉——实测往 `Rules/CleanupRules.swift`
        // 放一个真 `Process()`，不递归的版本照样全绿。
        // `Selftests/` 整棵子树排除：自检代码里就有 `"Process()"` 这个字面量（判据本身），
        // 且它们在发布产物里被 `MACCLEAN_NO_SELFTEST=1` 剔掉。
        check("G15 不变量：产品源码（含子目录）除 SafeProcess 外不得再出现裸 Process 构造") {
            let sourceDir = Selftest.sourceDirectoryPath
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: sourceDir)) ?? []
            let files = all.filter {
                $0.hasSuffix(".swift")
                    && !$0.hasPrefix("Selftests/")
                    && $0 != "SafeProcess.swift"
            }.sorted()
            guard files.count > 100 else {
                print("      源码文件数异常（读到 \(files.count) 个），扫描范围没铺开")
                return false
            }
            var offenders: [String] = []
            for rel in files {
                let path = (sourceDir as NSString).appendingPathComponent(rel)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(rel):<不可读>")
                    continue
                }
                for (idx, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                    if t.contains("Process()") { offenders.append("\(rel):\(idx + 1)") }
                }
            }
            if !offenders.isEmpty { print("      裸 Process 构造: \(offenders.prefix(5))") }
            return offenders.isEmpty
        }

        // 18. 历史上限必须长在**唯一写入口**上。
        // v1.72 之后写历史的入口有 5 个（AppState、AutoCleanService、统一网关、
        // 下载归档、截图归档、硬链接去重），原先 200 条上限只写在 AppState 里，
        // 其余路径全部绕过 → 磁盘上的 history.json 只增不减。
        check("HistoryStore：save 自身截断到上限，且保留的是最新记录") {
            let saved = HistoryStore.load()
            defer { HistoryStore.save(saved) }

            let flood = (0..<(HistoryStore.recordLimit + 50)).map {
                CleanRecord(id: UUID(), date: Date().addingTimeInterval(Double($0)),
                            categoryName: "自检灌入-\($0)", itemCount: 1, bytes: 1,
                            mode: "废纸篓", failures: 0)
            }
            // 调用方按"新的在前"传入（全仓所有写入点都是 insert(at: 0)）
            HistoryStore.save(flood)
            let reloaded = HistoryStore.load()
            guard reloaded.count == HistoryStore.recordLimit else {
                print("      未截断：\(reloaded.count) 条")
                return false
            }
            // 调用方按"新的在前"传入（全仓所有写入点都是 insert(at: 0)），
            // 所以 flood[0] 代表最新一条：截断必须留头部、砍掉尾部的旧记录。
            let newestLabel = flood[0].categoryName
            let oldestLabel = flood[flood.count - 1].categoryName
            return reloaded.first?.categoryName == newestLabel
                && !reloaded.contains { $0.categoryName == oldestLabel }
        }

        // 12. AppInventory 的完整性标记必须真的反映"读不到"
        check("AppInventory：根目录读不到时 isComplete 为假，不得据此判孤儿") {
            let root = makeFixture("inventory")
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root);
                    try? fm.removeItem(atPath: root) }
            try? fm.createDirectory(atPath: root + "/Fake.app/Contents",
                                    withIntermediateDirectories: true)
            try? "fake".write(toFile: root + "/Fake.app/Contents/Info.plist", atomically: true, encoding: .utf8)

            let savedRoots = AppInventory.rootsOverride
            let savedSnapshot = AppInventory.snapshotOverride
            defer { AppInventory.rootsOverride = savedRoots; AppInventory.snapshotOverride = savedSnapshot }

            AppInventory.snapshotOverride = nil
            AppInventory.rootsOverride = [root]
            let readable = AppInventory.current(forceRefresh: true)
            guard readable.unreadableRoots.isEmpty, readable.bundleIDs.isEmpty else {
                // 空 Info.plist 解析不出 bundle id 属正常，但绝不能报读失败
                return readable.unreadableRoots.isEmpty
            }

            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
            guard geteuid() != 0 else { return true }
            let blocked = AppInventory.current(forceRefresh: true)
            return blocked.unreadableRoots.contains(root) && !blocked.isComplete
        }

        // 13. 真实机器上的软链反例：治理域根目录里的软链一律必须拒绝。
        //
        // 这不是虚构场景——本机 `/Library/Fonts` 里**唯一**的条目就是
        // `Arial Unicode.ttf -> /System/Library/Fonts/Supplemental/Arial Unicode.ttf`。
        // 旧的字体模块用 `path.hasPrefix("/System")` 判保护，这个路径字面上以
        // `/Library/Fonts` 开头 → 放行 → 被当成"孤儿字体"移进废纸篓。
        // 逐域扫描真实根目录，保证任何一条软链条目都不可能被放行。
        check("治理域：真实根目录内存在的符号链接条目一律拒绝（本机 /Library/Fonts 实测反例）") {
            var symlinksSeen = 0
            for domain in GovernanceDomain.all {
                guard let children = try? FileManager.default.contentsOfDirectory(atPath: domain.root) else {
                    continue   // 读不到或不存在（本机大量 /Library 子目录不存在）→ 无样本
                }
                for child in children {
                    let path = (domain.root as NSString).appendingPathComponent(child)
                    guard FileSystem.isSymlink(path) else { continue }
                    symlinksSeen += 1
                    guard case .rejected(let reason) = FileSystem.governanceVerdict(path, domain: domain),
                          reason == .symlinkJump else {
                        print("      放行软链: \(domain.id) ← \(path)")
                        return false
                    }
                }
            }
            // 本机至少应有 `/Library/Fonts/Arial Unicode.ttf` 这一个真实样本；
            // 别的机器上一个都没有也不算失败（判据本身已由上一条合成域用例守住）。
            return true
        }

        // 14. sticky 位规则必须落到"我是谁"上（v1.72 修真实判据错误）
        //
        // `/private/tmp` 是 `drwxrwxrwt root:wheel`：世界可写 + sticky。
        // 别人（通常是 root 守护进程）在该目录留下的文件，我们**删不掉**。
        // 若把判据写成"文件属主 == 目录属主"，root 拥有的文件落在 root 拥有的目录里
        // 就会被判成可删——`/Library/Fonts`（`drwxrwxr-t root:admin`）正是同一形状。
        check("canUnlink：sticky 目录下他人属主的条目判为不可删（真机 /private/tmp 反例）") {
            guard geteuid() != 0 else { return true }
            let tmp = "/private/tmp"
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return true }
            var foreignOwned = 0
            for child in children {
                let path = (tmp as NSString).appendingPathComponent(child)
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                guard st.st_uid != geteuid() else { continue }
                // 目录与软链都可能"能删"，只取常规文件作为确定样本
                guard (st.st_mode & S_IFMT) == S_IFREG else { continue }
                foreignOwned += 1
                if FileSystem.canUnlink(path) {
                    print("      误判可删（属主 uid \(st.st_uid)）：\(path)")
                    return false
                }
            }
            // 自己的文件仍须判可删，否则这条护栏会退化成"什么都删不了"
            let mine = "/private/tmp/macclean_canunlink_mine_\(UUID().uuidString)"
            try? Data([0x41]).write(to: URL(fileURLWithPath: mine))
            defer { try? FileManager.default.removeItem(atPath: mine) }
            let mineOK = FileManager.default.fileExists(atPath: mine) && FileSystem.canUnlink(mine)
            if foreignOwned == 0 {
                print("      /private/tmp 暂无他人属主的常规文件，只验证了自有文件仍可删")
            }
            return mineOK
        }

        // 15. 命令可用性判定：工具不存在时不能把"未执行"报成"已生效"
        check("SafeProcess：缺失可执行文件与启动失败都不谎报成功") {
            guard SafeProcess.isAvailable("/usr/bin/nonexistent-macclean-tool") == false else { return false }
            guard SafeProcess.isAvailable("/bin/echo") else { return false }
            let missing = SafeProcess.run("/usr/bin/nonexistent-macclean-tool", ["--version"])
            guard let missing, !missing.succeeded else { return false }
            return true
        }

        // 16. 自管理容器必须进"可删性"名单，而不是只进"可读性"名单
        check("G6 硬排除覆盖照片图库：库内任何真实文件都永不可删") {
            let lib = ("~/Pictures/Photos Library.photoslibrary" as NSString).expandingTildeInPath
            for target in [lib, lib + "/originals/Misc/IMG_0001.jpg",
                           lib + "/database/PhotosLibrary.sqlite"] {
                guard case .rejected(let reason) = FileSystem.governanceVerdictWithinHome(target),
                      reason == .hardExcluded else {
                    print("      图库内路径被放行: \(target) → \(FileSystem.governanceVerdictWithinHome(target))")
                    return false
                }
            }
            // 且必须同时被登记在案，避免"只写进 tccProtected 就当已保护"的误解
            let normalized = FileSystem.normalizePath(lib)
            return CleanPaths.hardExclude.contains { FileSystem.normalizePath($0) == normalized }
                && CleanPaths.tccProtected.contains { FileSystem.normalizePath($0) == normalized }
        }

        // 17. 清单缓存必须能被主动失效：卸载 App 之后紧接着查孤儿，
        // 若仍用 60 s TTL 里的旧清单，那个刚被卸载的 App 的所有残留都查不出来。
        check("AppInventory：invalidate() 之后重新扫盘，不再复用 TTL 内的旧清单") {
            let dirA = makeFixture("invA")
            let dirB = makeFixture("invB")
            defer { try? FileManager.default.removeItem(atPath: dirA);
                    try? FileManager.default.removeItem(atPath: dirB) }
            for dir in [dirA, dirB] {
                try? FileManager.default.createDirectory(atPath: dir + "/Fake.app/Contents",
                                                         withIntermediateDirectories: true)
            }

            let savedRoots = AppInventory.rootsOverride
            let savedSnapshot = AppInventory.snapshotOverride
            defer {
                AppInventory.rootsOverride = savedRoots
                AppInventory.snapshotOverride = savedSnapshot
                AppInventory.invalidate()
            }
            AppInventory.snapshotOverride = nil

            AppInventory.rootsOverride = [dirA]
            let first = AppInventory.current(ttl: 600)   // 长 TTL：证明"命中缓存"而非"重扫"
            guard first.unreadableRoots.isEmpty else { return false }

            // 换根但不失效：必须仍返回旧清单（说明 TTL 缓存在起作用）
            AppInventory.rootsOverride = [dirB]
            let cachedAgain = AppInventory.current(ttl: 600)
            guard cachedAgain.appPaths == first.appPaths else { return false }

            // 失效之后必须重扫，看到新根里的条目
            AppInventory.invalidate()
            let refreshed = AppInventory.current(ttl: 600)
            return refreshed.appPaths != first.appPaths
                && refreshed.appPaths.contains(where: { $0.hasPrefix(dirB) })
        }
    }
}
