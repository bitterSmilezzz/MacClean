import Foundation
import Darwin

// MARK: - 浏览器隐私痕迹矩阵自检（v1.73.15）
//
// 夹具全部在 /private/tmp 造假浏览器 profile（经 `BrowserPrivacyScanner.fixtureRoots`
// 注入——网关的常规放行根包含 /private/tmp，端到端删除才能真走），**自检永不碰
// 真实浏览器 profile**。套件覆盖：
// · 格子三态：可读出体积 / mode-000 → 读不到且不可清理不默认勾选 / 缺席族整族缺席；
// · 默认零勾选 + 「全选」只选非 danger 可读格（变异靶：danger 过滤）；
// · clean：非 danger 真删 + 历史记账；danger 未确认全拒逐条带原因（变异靶：
//   confirmedDanger 层）；未勾选拒绝；拼装夹带拒绝；白名单命中网关拒绝原样呈现；
// · 路径判据 G18：模块源码无 /System 字符串护栏字面 + isSystemProtected 前置条件；
// · G16：注入不可信清单 → 摘要降级明示。
//
// **注册说明**：套件函数待主 Agent 在 `Selftest.suites` 登记
// `("BrowserPrivacy", suiteBrowserPrivacy)` 后才会被执行（Selftest.swift 本轮不归本模块）。

extension Selftest {
    static func suiteBrowserPrivacy() {
        print("--- [Suite] 浏览器隐私痕迹矩阵自检 (v1.73.15) ---")
        let fm = FileManager.default

        // MARK: 夹具（/private/tmp：网关常规放行根；体积用 4096 的倍数对齐 allocated 口径）

        func makeFixtureRoot(_ tag: String) -> String {
            let root = "/private/tmp/macclean-bp-\(tag)-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            return root
        }
        func makeFile(_ path: String, _ bytes: Int, modifiedAt: Date? = nil) {
            try? Data(repeating: 0x5A, count: bytes).write(to: URL(fileURLWithPath: path))
            if let m = modifiedAt {
                try? fm.setAttributes([.modificationDate: m], ofItemAtPath: path)
            }
        }
        /// 造一个 Chrome 布局的假 profile 根（数据根下直接是 Default / Profile N）
        func makeChromeFixture(tag: String, profile: String = "Default",
                               files: [String: Int], dirs: [String: [String: Int]] = [:]) -> String {
            let root = makeFixtureRoot(tag)
            let profileDir = (root as NSString).appendingPathComponent(profile)
            try? fm.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
            for (rel, bytes) in files {
                let p = (profileDir as NSString).appendingPathComponent(rel)
                try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                        withIntermediateDirectories: true)
                makeFile(p, bytes)
            }
            for (dir, inner) in dirs {
                let d = (profileDir as NSString).appendingPathComponent(dir)
                try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                for (name, bytes) in inner {
                    let p = (d as NSString).appendingPathComponent(name)
                    // 内层文件可能还带着子目录段（如 Cache_Data/f.bin），中间层要真的建出来
                    try? fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                            withIntermediateDirectories: true)
                    makeFile(p, bytes)
                }
            }
            return root
        }
        func cell(_ summary: BrowserPrivacySummary, _ family: BrowserFamily,
                  _ kind: BrowserDataKind) -> BrowserPrivacyCell? {
            summary.blocks.first { $0.family == family }?.cells.first { $0.kind == kind }
        }
        func pathExists(_ p: String) -> Bool {
            var st = stat()
            return lstat(p, &st) == 0
        }

        // MARK: 1. kind 元数据红线（固定警示文案与 danger 配对）

        check("kind 元数据：savedLogins/sessionRestore 永远 danger，警示文案固定且与 danger 一一配对") {
            var bad: [String] = []
            for kind in BrowserDataKind.allCases {
                // 不变量：warning 非 nil ⇔ danger（BleachBit <warning> 范式的配对关系）
                if (kind.warning != nil) != kind.danger {
                    bad.append("\(kind.rawValue) 的 warning/danger 配对断裂")
                }
            }
            guard let saved = BrowserDataKind.savedLogins.warning,
                  let session = BrowserDataKind.sessionRestore.warning else {
                return false
            }
            if !BrowserDataKind.savedLogins.danger { bad.append("savedLogins 必须永远 danger") }
            if !BrowserDataKind.sessionRestore.danger { bad.append("sessionRestore 必须是 danger 格") }
            if saved != "删除后已保存的登录状态全部丢失" {
                bad.append("savedLogins 警示文案不是任务书钉死的那句：\(saved)")
            }
            if session.isEmpty { bad.append("sessionRestore 警示文案为空") }
            for safe in [BrowserDataKind.cookies, .history, .cache, .formHistory, .crashReports] {
                if safe.danger { bad.append("\(safe.rawValue) 不应是 danger 格") }
            }
            return bad.isEmpty
        }

        check("kind 路径表：各族每个在列 kind 都有路径条目；Safari 不提供 savedLogins/crashReports 行") {
            var bad: [String] = []
            for family in BrowserFamily.allCases {
                for kind in family.supportedKinds where family.kindPaths(for: kind).isEmpty {
                    bad.append("\(family.rawValue)×\(kind.rawValue) 路径表为空")
                }
            }
            let safariKinds = BrowserFamily.safari.supportedKinds
            if safariKinds.contains(.savedLogins) || safariKinds.contains(.crashReports) {
                bad.append("Safari 不应提供 savedLogins/crashReports 行（钥匙串 G6 / 无专属位置）")
            }
            // Chromium ≥96 把 Cookies 挪进 Network/，两代布局都要覆盖
            let chromeCookies = BrowserFamily.chrome.kindPaths(for: .cookies).map(\.relative)
            if !chromeCookies.contains("Cookies") || !chromeCookies.contains("Network/Cookies") {
                bad.append("Chromium cookies 路径表缺 Cookies 或 Network/Cookies：\(chromeCookies)")
            }
            // Firefox cache2 在独立缓存根的同名 profile 目录里
            let fxCaches = BrowserFamily.firefox.kindPaths(for: .cache)
            if !fxCaches.contains(where: { $0.anchor == .profileCache && $0.relative == "cache2" }) {
                bad.append("Firefox cache 缺 profileCache 锚点的 cache2 条目")
            }
            return bad.isEmpty
        }

        // MARK: 2. 格子三态

        let backdated = Date(timeIntervalSinceNow: -86_400)
        let chromeRoot = makeChromeFixture(tag: "chrome", files: [
            "Cookies": 4096,
            "Network/Cookies": 4096,
            "History": 8192,
            "Login Data": 4096,
        ], dirs: [
            "Cache": ["Cache_Data/f.bin": 8192],
            "Sessions": ["Session_1": 4096],
        ])
        // 给 History 一个回拨过的 mtime：判龄判据必须是 mtime（本仓红线：绝不用 atime）。
        // 注意别把回拨落在 Cookies 上——那格有两条路径，新写的 Network/Cookies 会让
        // "树内最新 mtime"变成现在，判龄断言得挑单路径的格子来钉。
        try? fm.setAttributes([.modificationDate: backdated],
                              ofItemAtPath: (chromeRoot as NSString).appendingPathComponent("Default/History"))

        let bpFixture: [BrowserFamily: BrowserPrivacyScanner.FamilyFixture] = [
            .chrome: .init(dataRoot: chromeRoot, cacheRoot: nil)
        ]

        var bpSummary: BrowserPrivacySummary? = nil

        check("scan（fixture）：正常 profile 读出体积与 mtime 判龄；全格默认零勾选") {
            BrowserPrivacyScanner.fixtureRoots = bpFixture
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            bpSummary = summary

            guard let cookies = cell(summary, .chrome, .cookies) else { return false }
            if cookies.status != .readable { return false }
            // Cookies = Default/Cookies + Network/Cookies 各 4096（allocated 口径，逐字节相等）
            if cookies.size != 4096 + 4096 { return false }
            if cookies.existingPathCount != 2 { return false }
            // 判龄 = mtime：回拨过的 mtime 必须原样呈现在单路径的浏览历史格上
            guard let history = cell(summary, .chrome, .history) else { return false }
            guard let newest = history.newestModification else { return false }
            if abs(newest.timeIntervalSince(backdated)) > 2 { return false }

            guard let cache = cell(summary, .chrome, .cache) else { return false }
            if cache.status != .readable || cache.size != 8192 { return false }

            // 红线：体积与年龄只是呈现信息——所有格子默认全不选
            if summary.allCells.contains(where: \.isSelected) { return false }
            // 夹具里 savedLogins 与 sessionRestore 都真实存在，也必须保持未勾选
            guard let logins = cell(summary, .chrome, .savedLogins),
                  let session = cell(summary, .chrome, .sessionRestore) else { return false }
            return logins.status == .readable && !logins.isSelected
                && session.status == .readable && !session.isSelected
        }

        check("scan（fixture）：mode-000 目录 → 读不到，且不计入可清理、不默认勾选、clean 拒绝") {
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效：本条跳过并计入通过数（非 root 才是真跑）")
                return true
            }
            let root = makeChromeFixture(tag: "mode000", files: ["Cookies": 4096])
            let cacheDir = (root as NSString).appendingPathComponent("Default/Cache")
            try? fm.createDirectory(atPath: cacheDir + "/Cache_Data", withIntermediateDirectories: true)
            makeFile(cacheDir + "/Cache_Data/f.bin", 8192)
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cacheDir)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheDir) }

            BrowserPrivacyScanner.fixtureRoots = [.chrome: .init(dataRoot: root, cacheRoot: nil)]
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            guard let cache = cell(summary, .chrome, .cache) else { return false }
            // G9：读不到 ≠ 空——不是 .absent 也不是 0 字节的 readable
            guard cache.status == .unreadable, !cache.isCleanable, !cache.isSelected else {
                return false
            }
            // 同一 summary 里可读的 Cookies 不受牵连（三态互不污染）
            guard let cookies = cell(summary, .chrome, .cookies),
                  cookies.status == .readable else { return false }
            // 就算调用方强行把读不到的格子标成已选，clean 也必须拒之门外
            var forced = cache
            forced.isSelected = true
            let out = BrowserPrivacyScanner.clean(cells: [forced])
            let nonAbsent = cache.paths.filter { $0.state != .absent }
            // mode-000 目录内部无法 lstat（父目录无 x 权），先还原权限再验文件原样
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cacheDir)
            guard out.cleanedCount == 0, out.failed.isEmpty,
                  out.rejected.count == nonAbsent.count,
                  out.rejected.allSatisfy({ !$0.message.isEmpty }) else { return false }
            return pathExists(cacheDir + "/Cache_Data/f.bin")
        }

        check("scan（fixture）：不在注入表里的族整族缺席，而不是全 0 的行") {
            // 上一个用例已把 fixtureRoots 清空；这里只注入 chrome → 其余族不得出现
            BrowserPrivacyScanner.fixtureRoots = bpFixture
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            if summary.scannedFamilies != [.chrome] { return false }
            if summary.blocks.count != 1 { return false }
            for absent in [BrowserFamily.safari, .edge, .brave, .arc, .firefox] {
                if summary.scannedFamilies.contains(absent) { return false }
            }
            return true
        }

        // MARK: 3. 默认零勾选 + 全选判据（变异靶：摘掉 danger 过滤必须变红）

        check("「全选可清理项」只选非 danger 且可读的格子；danger 格可读也不进全选") {
            guard let summary = bpSummary else { return false }
            let cells = summary.allCells
            let targets = Set(cells.selectAllCleanableTargets())
            // 危险格即便可读也不在全选里——它们唯一被排除的原因就是 danger 过滤
            for c in cells where c.kind.danger {
                if c.isCleanable && targets.contains(c.id) { return false }
            }
            // 非 danger 且可读的格子必须全部进入全选
            for c in cells where !c.kind.danger {
                if c.isCleanable != targets.contains(c.id) { return false }
            }
            // 反证：danger 格本身是 isCleanable 的——证明排除它的不是"读不到"
            let dangerCells = cells.filter { $0.kind.danger }
            guard !dangerCells.isEmpty, dangerCells.allSatisfy(\.isCleanable) else { return false }
            // 未勾选判据与全选判据必须同源：勾选框对读不到/缺席格子关闭
            for c in cells where !c.isCleanable {
                if c.includedInSelectAll { return false }
            }
            return true
        }

        // MARK: 4. clean：非 danger 真删 + 历史记账（默认移废纸篓可撤销）

        check("clean：非 danger 格经网关真删，历史落「浏览器隐私」、废纸篓模式、撤销快照在") {
            let root = makeChromeFixture(tag: "clean", files: [
                "Cookies": 4096, "History": 2048,
            ])
            BrowserPrivacyScanner.fixtureRoots = [.chrome: .init(dataRoot: root, cacheRoot: nil)]
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            guard let cookies = cell(summary, .chrome, .cookies),
                  cookies.status == .readable else { return false }
            let cookiePath = cookies.paths.first { $0.state == .measured }?.path ?? ""
            guard pathExists(cookiePath) else { return false }

            let before = HistoryStore.load()
            var selected = cookies
            selected.isSelected = true
            // journal 不显式传：clean() 内部钉死 .module(categoryName: "浏览器隐私")，
            // 自检不喂实参，默认值被改坏时这里必须红（RELEASE-CHECKLIST 变异验证条）
            let out = BrowserPrivacyScanner.clean(cells: [selected])
            guard out.cleanedCount == 1, out.errorCount == 0 else { return false }
            guard out.freedBytes == 4096 else { return false }
            guard !pathExists(cookiePath) else { return false }
            // 历史记账：比对**新记录的身份**，不比绝对条数（HistoryStore 有 200 条上限）
            let after = HistoryStore.load()
            guard let newestRecord = after.first else { return false }
            if newestRecord.id == before.first?.id { return false }
            return newestRecord.categoryName == BrowserPrivacyScanner.categoryName
                && newestRecord.mode == "废纸篓"
                && newestRecord.itemCount == 1
                && newestRecord.bytes == 4096
                && out.trashedSnapshots.count == 1
        }

        check("clean：未勾选的格子被拒（只接受用户点选），文件原样") {
            let root = makeChromeFixture(tag: "unselected", files: ["Cookies": 4096])
            BrowserPrivacyScanner.fixtureRoots = [.chrome: .init(dataRoot: root, cacheRoot: nil)]
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            guard let cookies = cell(summary, .chrome, .cookies) else { return false }
            let cookiePath = cookies.paths.first?.path ?? ""
            let out = BrowserPrivacyScanner.clean(cells: [cookies])   // isSelected == false
            guard out.cleanedCount == 0, out.rejected.count == 1,
                  out.rejected[0].message.contains("未被勾选") else { return false }
            return pathExists(cookiePath)
        }

        // MARK: 5. clean：danger 未确认 → 整格拒绝逐条带原因（变异靶：摘掉这层必须变红）

        check("clean：danger 格未带 confirmedDanger → 全拒、逐条带固定警示原因、文件原样") {
            let root = makeChromeFixture(tag: "danger", files: ["Login Data": 4096],
                                         dirs: ["Sessions": ["Session_1": 2048]])
            BrowserPrivacyScanner.fixtureRoots = [.chrome: .init(dataRoot: root, cacheRoot: nil)]
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            var selected: [BrowserPrivacyCell] = []
            for kind in [BrowserDataKind.savedLogins, .sessionRestore] {
                guard var c = cell(summary, .chrome, kind), c.status == .readable else { return false }
                c.isSelected = true
                selected.append(c)
            }
            let loginPath = selected[0].paths.first?.path ?? ""
            let sessionPath = selected[1].paths.first { $0.state == .measured }?.path ?? ""

            let out = BrowserPrivacyScanner.clean(cells: selected, confirmedDanger: false)
            // 两条路径逐条拒绝，每条都带上固定警示文案
            guard out.cleanedCount == 0, out.failed.isEmpty else { return false }
            guard out.rejected.count == 2 else { return false }
            let messages = out.rejected.map(\.message)
            guard messages.allSatisfy({ $0.contains("危险项未确认") }) else { return false }
            // 每条拒绝都要带上该数据类自己的固定警示文案（savedLogins / sessionRestore 各自那句）
            guard messages.allSatisfy({ $0.contains("登录状态全部丢失") || $0.contains("恢复状态丢失") })
            else { return false }
            guard Set(out.rejected.map(\.path)) == Set([loginPath, sessionPath].filter { !$0.isEmpty })
            else { return false }
            // 关键证据：文件一个都没少
            return pathExists(loginPath) && pathExists(sessionPath)
        }

        check("clean：danger 格带 confirmedDanger → 真删（正向对照，证明拦截层就是确认层）") {
            let root = makeChromeFixture(tag: "danger-ok", files: ["Login Data": 4096])
            BrowserPrivacyScanner.fixtureRoots = [.chrome: .init(dataRoot: root, cacheRoot: nil)]
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            guard var logins = cell(summary, .chrome, .savedLogins), logins.status == .readable else {
                return false
            }
            logins.isSelected = true
            let out = BrowserPrivacyScanner.clean(cells: [logins], confirmedDanger: true)
            guard out.cleanedCount == 1, out.errorCount == 0 else { return false }
            return !(logins.paths.first.map { pathExists($0.path) } ?? true)
        }

        // MARK: 6. 网关拒绝原样呈现（白名单）与模块判据（拼装夹带）

        check("clean：白名单命中的路径 → 网关拒绝原样呈现，文件原样") {
            let root = makeChromeFixture(tag: "whitelist", files: ["Cookies": 4096])
            BrowserPrivacyScanner.fixtureRoots = [.chrome: .init(dataRoot: root, cacheRoot: nil)]
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let summary = BrowserPrivacyScanner.scan()
            guard var cookies = cell(summary, .chrome, .cookies), cookies.status == .readable else {
                return false
            }
            cookies.isSelected = true
            let cookiePath = cookies.paths.first?.path ?? ""

            let savedRules = WhitelistManager.shared.rules
            WhitelistManager.shared.removeAllRules()
            defer {
                WhitelistManager.shared.removeAllRules()
                WhitelistManager.shared.rules = savedRules
            }
            WhitelistManager.shared.addPathRule(cookiePath, comment: "自检保护")

            let out = BrowserPrivacyScanner.clean(cells: [cookies])
            guard out.cleanedCount == 0, out.failed.isEmpty, out.rejected.count == 1 else {
                return false
            }
            guard out.rejected[0].reason == .userWhitelisted,
                  !out.rejected[0].message.isEmpty else { return false }
            return pathExists(cookiePath)
        }

        check("clean：拼装格子夹带登记表之外的主目录路径 → 模块判据拒绝，目标原样") {
            let smuggled = makeFixtureRoot("smuggled") + "/not-a-browser-path.bin"
            makeFile(smuggled, 4096)
            let fakeCell = BrowserPrivacyCell(
                family: .chrome, kind: .history,
                paths: [BrowserCellPath(path: smuggled, ownerRoot: smuggled, relative: "",
                                        state: .measured,
                                        stats: .init(size: 4096, fileCount: 1,
                                                     newestModification: nil, readable: true),
                                        protection: nil)],
                status: .readable, size: 4096, newestModification: nil,
                isSelected: true)
            let out = BrowserPrivacyScanner.clean(cells: [fakeCell])
            guard out.cleanedCount == 0, out.failed.isEmpty, out.rejected.count == 1,
                  out.rejected[0].reason == .outsideDomain,
                  out.rejected[0].message.contains("不是本模块登记的浏览器数据位置") else { return false }
            return pathExists(smuggled)
        }

        // MARK: 7. G16：清单不可信 → 摘要降级明示

        check("G16：注入不可信清单（unreadableRoots 非空）→ isResultComplete 翻假并明示降级") {
            BrowserPrivacyScanner.fixtureRoots = bpFixture
            defer { BrowserPrivacyScanner.fixtureRoots = nil }
            let untrusted = AppInventory.Snapshot(
                bundleIDs: ["com.google.chrome"], bundlePrefixes: [], normalizedNames: [],
                executableNames: [], runningBundleIDs: [], appPaths: [],
                unreadableRoots: ["/Applications"])
            let summary = BrowserPrivacyScanner.scan(inventory: untrusted)
            guard !summary.isResultComplete, !summary.issues.isEmpty else { return false }
            guard summary.issues.contains(where: { $0.contains("清单不完整") && $0.contains("降级") })
            else { return false }
            // 正向对照：完整清单上不得凭空长出降级告警
            let trusted = AppInventory.Snapshot(
                bundleIDs: ["com.google.chrome"], bundlePrefixes: [], normalizedNames: [],
                executableNames: [], runningBundleIDs: [], appPaths: [], unreadableRoots: [])
            let cleanRun = BrowserPrivacyScanner.scan(inventory: trusted)
            return cleanRun.isResultComplete && cleanRun.issues.isEmpty
        }

        // MARK: 8. 路径判据（G18 / G14 / 零默认勾选形状）

        check("G18：模块源码无 /System 字符串护栏字面；求体积走 directoryStats；无裸删除调用") {
            // 前置条件：/System/Applications 确实命中 isSystemProtected（判据本体活着）
            guard FileSystem.isSystemProtected("/System/Applications") else {
                print("      前置条件失效：/System/Applications 不在 systemProtected 清单")
                return false
            }
            var bad: [String] = []
            var checkedFiles = 0
            for name in ["BrowserPrivacyModels.swift", "BrowserPrivacyScanner.swift"] {
                let path = (Selftest.sourceDirectoryPath as NSString).appendingPathComponent(name)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    bad.append("\(name) 不可读")
                    continue
                }
                checkedFiles += 1
                let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
                if code.contains("hasPrefix(\"/System") || code.contains("contains(\"/System")
                    || code.contains("==\"/System") {
                    bad.append("\(name) 出现 /System 字符串护栏字面（G18 违规族）")
                }
                if code.contains("FileManager.default.trashItem")
                    || code.contains("FileManager.default.removeItem") {
                    bad.append("\(name) 出现裸删除调用（G14：删除必须走 ResidueDeletionGate）")
                }
                if code.contains("isSelected: true") {
                    bad.append("\(name) 把勾选硬编成 true（默认零勾选是安全策略）")
                }
            }
            // 活性下界：两个文件都真的被扫到了
            if checkedFiles != 2 { bad.append("源码扫描只覆盖 \(checkedFiles)/2 个文件") }
            // 正向 needle：G6/G8 注记与求体积必须读共享判据/唯一 walker
            let scannerPath = (Selftest.sourceDirectoryPath as NSString)
                .appendingPathComponent("BrowserPrivacyScanner.swift")
            if let src = try? String(contentsOfFile: scannerPath, encoding: .utf8) {
                let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
                if !code.contains("FileSystem.directoryStats") {
                    bad.append("scanner 未走 FileSystem.directoryStats（全仓唯一模块级 walker）")
                }
                if !code.contains("isSystemProtected") {
                    bad.append("scanner 未读共享系统保护判据（G19：不许自抄清单）")
                }
            } else {
                bad.append("BrowserPrivacyScanner.swift 不可读")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // MARK: 收尾

        try? fm.removeItem(atPath: chromeRoot)

        // 复审 P2-3 的防漂移钉（独立于夹具，钉的是 G6 清单本身）
        checkSafariHistoryG6Pin()
    }
}

extension Selftest {
    /// 复审 P2-3 的防漂移钉：浏览器矩阵的 Safari History 行「照常呈现、删除必被网关拒」
    /// 依赖 `~/Library/Safari/History.db` 在 G6 硬排除清单里这**一行**——清单漂移时该安全
    /// 语义会静默消失而自检照绿。这里直接钉可观察契约（走护栏判据，不读清单实现）。
    static func checkSafariHistoryG6Pin() {
        check("G6 清单钉死：Safari History.db 在硬排除内（浏览器矩阵「删不掉」行的前提）") {
            let p = NSHomeDirectory() + "/Library/Safari/History.db"
            guard !FileSystem.isSafeToClean(p) else {
                print("      History.db 已不在 G6 硬排除——Safari 历史行会从「呈现但删不掉」变成可删！")
                return false
            }
            return true
        }
    }
}
