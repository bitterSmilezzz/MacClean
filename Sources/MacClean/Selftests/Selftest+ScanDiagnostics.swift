import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：扫描完整度与测量缓存
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 2337–2394）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteScanDiagnostics() {
        // MARK: - 扫描完整度（"读不到" ≠ "很干净"）

        check("扫描诊断：权限不足的目录被判为「读不到」而不是「空」") {
            // 这是整个诊断层的前提。历史缺陷：扫描链路里没有任何一处区分这两者，
            // 缺「完全磁盘访问权限」时废纸篓稳定返回 0 项，界面上和"空"一模一样。
            let dir = "/private/tmp/macclean-permprobe-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir + "/inside.bin", contents: Data(repeating: 1, count: 1024))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
                try? FileManager.default.removeItem(atPath: dir)
            }
            // 内容存在但不可读
            // 先确认内容真的在那里（chmod 之后就再也看不到它了）
            let hadContent = FileManager.default.fileExists(atPath: dir + "/inside.bin")
                && !(FileSystem.children(of: dir).isEmpty)
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
            let nowUnreadable = FileSystem.isPermissionDenied(dir)
            // 关键对比：目录里确实有东西，但现在读不到、也列不出来 ——
            // 只看 `children` 的返回值会得到"0 项"，这正是"读不到"骗成"很干净"的机制。
            let looksEmpty = FileSystem.children(of: dir).isEmpty
            return hadContent && nowUnreadable && looksEmpty
        }

        check("测量缓存：清理后路径与其父目录都不会给出过期体积") {
            // 缓存的前提是"一次扫描会话内体积不变"，而清理恰好会打破这个前提。
            // 只失效被删路径本身是不够的：删掉 dir/a.bin 之后 dir 自己的体积也变了，
            // 若父目录还留着旧值，重新扫描就会报出已经释放掉的字节。
            let dir = "/private/tmp/macclean-measure-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let file = dir + "/a.bin"
            FileManager.default.createFile(atPath: file, contents: Data(repeating: 0, count: 200_000))
            defer { try? FileManager.default.removeItem(atPath: dir) }

            FileSystem.beginMeasurementSession()
            let before = FileSystem.size(at: dir)
            guard before > 0 else { return false }

            let item = CleanItem(name: "a.bin", path: file, size: 200_000,
                                 rule: "C1", category: .userCaches)
            _ = Cleaner.clean([item], permanently: true) { _ in }

            // 父目录必须反映"已经空了"，而不是缓存里的旧体积
            return FileSystem.size(at: dir) < before
        }

        check("测量缓存：新一轮扫描会话会清空上一轮的结果") {
            let dir = "/private/tmp/macclean-session-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            FileSystem.beginMeasurementSession()
            FileManager.default.createFile(atPath: dir + "/x.bin", contents: Data(repeating: 0, count: 50_000))
            let withFile = FileSystem.size(at: dir)
            try? FileManager.default.removeItem(atPath: dir + "/x.bin")
            FileSystem.beginMeasurementSession()   // 新会话
            return withFile > 0 && FileSystem.size(at: dir) == 0
        }

        // MARK: - 规则 v2 步骤 6：子目录级权限盲区必须显式报出

        /// 建一个"父目录可读、某个子目录被权限拒掉"的 fixture。
        /// 这正是 `~/Library/Caches` 与 `CloudKit`、沙盒容器与 TCC 的真实关系：
        /// 根目录探测一切正常，盲区藏在根下面，只有遍历过程看得见。
        func withDeniedChild(_ body: (_ parent: String, _ locked: String) -> [String]) -> Bool {
            let parent = "/private/tmp/macclean-s6-\(UUID().uuidString)"
            let locked = parent + "/locked"
            try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: locked + "/secret.bin",
                                           contents: Data(repeating: 3, count: 2048))
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            let bad = body(parent, locked)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: parent)
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("步骤6：测量遍历把「存在但读不到」的子目录记进盲区，而不是当成空") {
            FileSystem.resetDeniedAccess()
            return withDeniedChild { parent, locked in
                var bad: [String] = []
                // 体积测算就是那次会撞上 EACCES 的遍历
                _ = FileSystem.size(at: parent)
                let seen = FileSystem.deniedAccessSnapshot()
                if !seen.contains(FileSystem.normalizePath(locked)) {
                    bad.append("被拒的子目录没进盲区清单，实际记录：\(seen)")
                }
                // 反证：可读的位置不许被记成盲区
                if seen.contains(FileSystem.normalizePath(parent)) {
                    bad.append("可读的父目录被误记成盲区")
                }
                return bad
            }
        }

        check("步骤6：children(of:) 读不到时也记账，且只有权限类错误才算盲区") {
            var bad: [String] = []
            // ① 直接调用 children(of:) 的那条路（扫描器大量用它）：被拒的子目录要进账
            let childPath = "/private/tmp/macclean-s6-child-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: childPath, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: childPath)
            FileSystem.resetDeniedAccess()
            let listed = FileSystem.children(of: childPath)
            let recorded = FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(childPath))
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: childPath)
            try? FileManager.default.removeItem(atPath: childPath)
            if !listed.isEmpty || !recorded {
                bad.append("children(of:) 读不到时没记账：listed=\(listed)")
            }
            // ② 非权限错误不进账：文件不存在 / 非 POSIX 错误域
            FileSystem.resetDeniedAccess()
            FileSystem.recordDeniedAccess(URL(fileURLWithPath: "/private/tmp/ghost-\(UUID().uuidString)"),
                                          error: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)))
            FileSystem.recordDeniedAccess(URL(fileURLWithPath: "/private/tmp/whatever"),
                                          error: NSError(domain: "NSCocoaErrorDomain", code: 260))
            if !FileSystem.deniedAccessSnapshot().isEmpty {
                bad.append("ENOENT / 非 POSIX 错误被当成权限盲区：\(FileSystem.deniedAccessSnapshot())")
            }
            return bad.isEmpty
        }

        check("步骤6：盲区清单父子合并、有条目上限、硬排除位置不算盲区") {
            FileSystem.resetDeniedAccess()
            defer { FileSystem.resetDeniedAccess() }
            func url(_ p: String) -> URL { URL(fileURLWithPath: p, isDirectory: true) }
            let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            var bad: [String] = []

            // ① 先记深处再记浅处 → 只留浅处（同一件事不占两个额度）
            FileSystem.recordDeniedAccess(url("/Users/x/Library/Caches/A/B"), error: err)
            FileSystem.recordDeniedAccess(url("/Users/x/Library/Caches/A"), error: err)
            var snap = FileSystem.deniedAccessSnapshot()
            if snap != ["/Users/x/Library/Caches/A"] {
                bad.append("父子没合并：\(snap)")
            }
            // ② 先记浅处再记深处 → 深处不重复入账
            FileSystem.resetDeniedAccess()
            FileSystem.recordDeniedAccess(url("/Users/x/Library/Caches/A"), error: err)
            FileSystem.recordDeniedAccess(url("/Users/x/Library/Caches/A/B"), error: err)
            snap = FileSystem.deniedAccessSnapshot()
            if snap.count != 1 { bad.append("子项重复占额度：\(snap)") }
            // ③ 上限
            FileSystem.resetDeniedAccess()
            for i in 0..<(FileSystem.deniedAccessLimit * 3) {
                FileSystem.recordDeniedAccess(url("/Users/x/other-\(i)"), error: err)
            }
            if FileSystem.deniedAccessSnapshot().count != FileSystem.deniedAccessLimit {
                bad.append("盲区条目没封顶：\(FileSystem.deniedAccessSnapshot().count)")
            }
            // ④ 我们本来就不该读的位置（G6 硬排除 / G8 系统保护）不得报成"去授权"
            FileSystem.resetDeniedAccess()
            FileSystem.recordDeniedAccess(url(NSHomeDirectory() + "/Pictures/Photos Library.photoslibrary/private"),
                                          error: err)
            FileSystem.recordDeniedAccess(url("/System/Volumes/Data/locked"), error: err)
            if !FileSystem.deniedAccessSnapshot().isEmpty {
                bad.append("硬排除/系统保护的位置被当成可授权盲区：\(FileSystem.deniedAccessSnapshot())")
            }
            return bad.isEmpty
        }

        check("步骤6：盲区按分类的根过滤，一条位置不会报到邻居账上") {
            FileSystem.resetDeniedAccess()
            defer { FileSystem.resetDeniedAccess() }
            let err = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
            FileSystem.recordDeniedAccess(
                URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches/CloudKit", isDirectory: true),
                error: err)
            let cacheIssues = Scanner.permissionIssues(for: .userCaches)
            let logIssues = Scanner.permissionIssues(for: .logsAndTemp)
            var bad: [String] = []
            if !cacheIssues.contains(where: { $0.path.hasSuffix("Library/Caches/CloudKit") }) {
                bad.append("用户缓存分类没报出 CloudKit 盲区：\(cacheIssues.map(\.path))")
            }
            if !logIssues.isEmpty {
                bad.append("日志分类把别人的盲区报成了自己的：\(logIssues.map(\.path))")
            }
            return bad.isEmpty
        }

        check("步骤6：补救措辞分权限口径——没授权才说「去授权」，已授权不得再让用户重复授权") {
            let p = NSHomeDirectory() + "/Library/Containers/com.apple.Safari/Data/Library/Caches"
            let needsAuth = PermissionGuide.remedy(path: p, needsFDA: true)
            let authed = PermissionGuide.remedy(path: p, needsFDA: false)
            var bad: [String] = []
            if needsAuth == authed { return false }
            if !needsAuth.contains("完全磁盘访问权限") || !needsAuth.contains("重新扫描") {
                bad.append("未授权分支没给出可执行的两步（授权 + 重扫）：\(needsAuth)")
            }
            if authed.contains("勾选 MacClean") {
                bad.append("已授权分支还在让用户重复授权：\(authed)")
            }
            if !authed.contains("沙盒") && !authed.contains("管理员") {
                bad.append("已授权分支没说清「为什么授权也解决不了」：\(authed)")
            }
            // 路径标签要能看懂：不能塌缩成 "Caches"
            let label = PermissionGuide.label(p)
            if label == "Caches" || label.isEmpty {
                bad.append("盲区标签没有信息量：\(label)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("步骤6：无人值守那一轮必须关掉主动探测（模态授权框没人点会挂住扫描）") {
            let locked = "/private/tmp/macclean-s6-gate-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: locked + "/a.bin", contents: Data([1]))
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            let saved = FileSystem.proactiveBlindSpotProbe
            var bad: [String] = []
            FileSystem.resetDeniedAccess()
            FileSystem.proactiveBlindSpotProbe = false
            if FileSystem.recordBlindSpotIfNeeded(at: locked) {
                bad.append("关掉开关后仍然去主动打开被拒目录")
            }
            if !FileSystem.deniedAccessSnapshot().isEmpty {
                bad.append("关掉开关后还记了盲区：\(FileSystem.deniedAccessSnapshot())")
            }
            FileSystem.proactiveBlindSpotProbe = true
            if !FileSystem.recordBlindSpotIfNeeded(at: locked) {
                bad.append("开关打开后不探测了（用户亲手扫描时盲区就永远看不见）")
            }
            FileSystem.proactiveBlindSpotProbe = saved
            FileSystem.resetDeniedAccess()
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? FileManager.default.removeItem(atPath: locked)
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("步骤6：真机端到端——未授予 FDA 时，用户缓存分类必须报出盲区") {
            guard !FileSystem.hasFullDiskAccess() else {
                print("      本机已授予完全磁盘访问权限，本条按通过处理（盲区本就不存在）")
                return true
            }
            // 显式开主动探测：本条钉的是**用户亲手点扫描**那一路（`AppState.scan` 就开着它）。
            // 默认值是关的（无人值守开探测会被模态授权框挂死），不写这一行的话
            // 探测根本不会发生，"一条盲区都没有"就成了正确行为——那就是个假绿。
            let savedProbe = FileSystem.proactiveBlindSpotProbe
            FileSystem.proactiveBlindSpotProbe = true
            defer { FileSystem.proactiveBlindSpotProbe = savedProbe }
            FileSystem.beginMeasurementSession()
            let outcome = Scanner.scanDetailed(.userCaches)
            let denied = outcome.issues.filter { $0.kind == .permissionDenied }
            guard !denied.isEmpty else {
                print("      没有 FDA 却一条盲区都没报出——子目录级记账失效了")
                return false
            }
            // 至少要说清"这是没看到，不是没有"
            guard denied.allSatisfy({ !$0.message.isEmpty }) else { return false }
            print("      本机实测盲区 \(denied.count) 处，例如：\(denied[0].path)")
            return true
        }

        check("步骤6：有盲区时空结果页不得写「此分类当前是干净的」") {
            let app = AppState()
            let st = app.state(for: .appResidue)
            st.isScanned = true
            st.items = []
            st.issues = [ScanIssue(kind: .permissionDenied, path: "/Users/x/Library/Application Support/Knowledge",
                                   message: "读不到", remedy: "去授权")]
            let view = CategoryDetailView(category: .appResidue).environmentObject(app)
            guard let root = try? view.inspect() else { return false }
            let texts = root.findAll(ViewType.Text.self).compactMap { try? $0.string() }
            var bad: [String] = []
            if texts.contains("此分类当前是干净的。") {
                bad.append("结果不完整时仍然说「干净」")
            }
            if !texts.contains(where: { $0.contains("结果不完整") }) {
                bad.append("空结果页没说明本次结果不完整")
            }
            if !texts.contains(where: { $0.contains("打开系统设置") }) {
                bad.append("横幅上没有可执行的授权入口")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // MARK: - 目录读取的截止时间
        //
        // 起因是实测：`~/Downloads` 上挂着一个再没人应答的 TCC 授权请求时，
        // `opendir` / `contentsOfDirectory` 不返回错误，而是停在内核 `__open` 上永不返回，
        // 于是 `--scan`、`--selftest`、GUI 点「扫描」全部 0% CPU 卡死（采样 2335/2335 同一帧）。

        check("读取卡死时必须在 deadline 内脱身，并且记成盲区而不是「这里没东西」") {
            let saved = FileSystem.gatedReadDeadline
            FileSystem.gatedReadDeadline = 0.3
            FileSystem.resetWedgedReadsForSelftest()
            defer { FileSystem.gatedReadDeadline = saved }
            FileSystem.resetDeniedAccess()
            let wedge = "/private/tmp/macclean-wedge-selftest"
            // body 在 deadline 之内**确实永不返回**，但断言做完后由测试自己放行：
            // 不放行就会永久占掉一个并发令牌，攒满 4 个之后同轮后面的门禁读取
            // "没试就跳过"，会把步骤6 的端到端盲区自检饿成假红。
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let start = Date()
            let got: [String]? = FileSystem.readWithinDeadline(wedge) {
                gate.wait()
                return ["never reached"]
            }
            let elapsed = Date().timeIntervalSince(start)
            guard got == nil else {
                print("      卡死的读取被当成成功，返回了 \(got?.count ?? -1) 项")
                return false
            }
            // 两头都要钉：等太久 = 没兜住；几乎不等 = deadline 被设成 0，
            // 那会把所有可读目录一并报成盲区，是另一种假。
            guard elapsed >= 0.1, elapsed < 2.0 else {
                print("      等待时长不对：\(String(format: "%.2f", elapsed)) s（deadline 0.3 s）")
                return false
            }
            guard FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(wedge)) else {
                print("      超时的目录没进盲区清单：\(FileSystem.deniedAccessSnapshot())")
                return false
            }
            return true
        }

        check("卡过的目录在 TTL 内不重试，清空记录后又要真的重试一次") {
            let saved = FileSystem.gatedReadDeadline
            FileSystem.gatedReadDeadline = 0.3
            FileSystem.resetWedgedReadsForSelftest()
            defer { FileSystem.gatedReadDeadline = saved }
            let wedge = "/private/tmp/macclean-wedge-\(UUID().uuidString)"
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let body: () -> [String] = { gate.wait(); return [] }
            let first: [String]? = FileSystem.readWithinDeadline(wedge, body)
            let start = Date()
            let second: [String]? = FileSystem.readWithinDeadline(wedge, body)
            let again = Date().timeIntervalSince(start)
            guard first == nil, second == nil else { return false }
            guard again < 0.05 else {
                print("      同一目录第二轮又等了一次 deadline：\(String(format: "%.2f", again)) s")
                return false
            }
            // 跨轮不清：每轮扫描都 `resetDeniedAccess()`，若它也清了这份记录，
            // 就等于每轮对每个仍然卡死的目录重新漏一条收不回来的线程。
            FileSystem.resetDeniedAccess()
            let t0 = Date()
            let afterRoundReset: [String]? = FileSystem.readWithinDeadline(wedge, body)
            let resetWait = Date().timeIntervalSince(t0)
            guard afterRoundReset == nil, resetWait < 0.05 else {
                print("      resetDeniedAccess() 把卡死记录一起清了："
                      + "同一目录在下一轮又被试了一次（等了 \(String(format: "%.2f", resetWait)) s）")
                return false
            }
            // 反证：显式清空这份记录之后，同一个目录要**真的再被试一次**。
            // 少了这一句，"立即返回"也可能只是因为 body 被彻底短路、从此再也不会跑。
            FileSystem.resetWedgedReadsForSelftest()
            let t1 = Date()
            let third: [String]? = FileSystem.readWithinDeadline(wedge, body)
            let thirdWait = Date().timeIntervalSince(t1)
            guard third == nil, thirdWait >= 0.1 else {
                print("      清空记录后没有重新试：third=\(String(describing: third))，"
                      + "等了 \(String(format: "%.2f", thirdWait)) s")
                return false
            }
            return true
        }

        check("超时给 nil、空目录给 []：两者不许混成同一个结论") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-bounded-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root + "/empty", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: root + "/full", withIntermediateDirectories: true)
            fm.createFile(atPath: root + "/full/a.bin", contents: Data([1]))
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
                    try? fm.removeItem(atPath: root) }
            FileSystem.resetDeniedAccess()
            let empty = FileSystem.childrenBounded(of: root + "/empty")
            let full = FileSystem.childrenBounded(of: root + "/full")
            var bad: [String] = []
            if empty != [] { bad.append("空目录应返回 [] 而不是 nil：\(String(describing: empty))") }
            if full != [root + "/full/a.bin"] {
                bad.append("可读目录没列到那一个条目：\(String(describing: full))")
            }
            if !FileSystem.deniedAccessSnapshot().isEmpty {
                bad.append("正常读取被记成了盲区：\(FileSystem.deniedAccessSnapshot())")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("T2 顶层列举与 T3 根探测保持带截止写法（Scanner 的两处门禁根接线）") {
            let src = (try? String(contentsOfFile:
                (Selftest.sourceDirectoryPath as NSString).appendingPathComponent("Scanner.swift"),
                encoding: .utf8)) ?? ""
            guard src.count > 4000 else {
                print("      读不到 Scanner.swift 正文（\(src.count) 字符），这条无从判定")
                return false
            }
            var bad: [String] = []
            if !src.contains("childrenBounded(of: downloads)") {
                bad.append("T2 不再用带截止的列举读 ~/Downloads")
            }
            if !src.contains("canOpenDirectoryBounded(rootPath)") {
                bad.append("T3 的 bigFileRoots 少了带截止的根探测")
            }
            if src.contains("FileSystem.children(of: downloads)") {
                bad.append("T2 残留无截止的 children(of:) 列举")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("被明确拒绝（mode 000）的目录同样要进盲区：探测不许只回答能不能开") {
            let fm = FileManager.default
            let locked = "/private/tmp/macclean-locked-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
            fm.createFile(atPath: locked + "/a.bin", contents: Data([1]))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
                try? fm.removeItem(atPath: locked)
            }
            FileSystem.resetDeniedAccess()
            guard FileSystem.canOpenDirectoryBounded(locked) == false else {
                print("      mode 000 的目录没被判成「打不开」")
                return false
            }
            guard FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(locked)) else {
                print("      判出了打不开却没记盲区——界面上这里就等于「没东西」")
                return false
            }
            return true
        }

        check("并发问同一个卡死目录：body 只许跑一次（查询与占位必须同临界区）") {
            final class Counter {
                let lock = NSLock()
                private var _runs = 0
                func bump() { lock.lock(); _runs += 1; lock.unlock() }
                // 读也必须走同一把锁：写侧持锁、读侧裸取，TSan 判的是货真价实的 data race
                // （本条自检第一版就是这么红的）。
                var runs: Int { lock.lock(); defer { lock.unlock() }; return _runs }
            }
            let saved = FileSystem.gatedReadDeadline
            FileSystem.gatedReadDeadline = 0.3
            FileSystem.resetWedgedReadsForSelftest()
            defer { FileSystem.gatedReadDeadline = saved }
            let wedge = "/private/tmp/macclean-race-\(UUID().uuidString)"
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let counter = Counter()
            let body: () -> [String] = {
                counter.bump()
                gate.wait()
                return []
            }
            // 必须用**起跑屏障**让 8 个线程同一瞬间进入：不加屏障时它们被 dispatch 错开，
            // 第一个线程早就占好位了，"先查后占"这种坏写法也能每次只跑一个 body——
            // 实测就是这样漏掉一次变异（自检全绿而 race 仍在）。
            // `Application Support` 同时属于 .appResidue 与 .browserAndSystem，
            // 6 个分类并发扫描时两个线程会同时问到同一个 key，这条钉的就是那个瞬间。
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    start.wait()
                    _ = FileSystem.readWithinDeadline(wedge, body)
                }
            }
            for _ in 0..<8 { start.signal() }
            group.wait()
            guard counter.runs == 1 else {
                print("      同一个卡死目录跑了 \(counter.runs) 次 body：查询与占位不在同一次临界区，"
                      + "并发扫描会为同一个目录漏 \(counter.runs) 条收不回来的线程")
                return false
            }
            return true
        }

        check("并发令牌耗尽时跳过但不记盲区：没碰过的目录不许被说成读不到") {
            let saved = FileSystem.gatedReadDeadline
            FileSystem.gatedReadDeadline = 0.3
            FileSystem.resetWedgedReadsForSelftest()
            FileSystem.resetDeniedAccess()
            defer { FileSystem.gatedReadDeadline = saved }
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            // 用 4 个各自卡死的目录把在途额度占满（上限见 gatedReadSlots）
            for i in 0..<4 {
                let p = "/private/tmp/macclean-slot-\(UUID().uuidString)-\(i)"
                _ = FileSystem.readWithinDeadline(p) { () -> [String] in
                    gate.wait()
                    return []
                }
            }
            // 现在来问一个**完全可读**的目录
            let fm = FileManager.default
            let ok = "/private/tmp/macclean-ok-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: ok, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: ok) }
            FileSystem.resetDeniedAccess()
            let got = FileSystem.childrenBounded(of: ok)
            let snap = FileSystem.deniedAccessSnapshot()
            guard got == nil else {
                print("      额度耗尽却仍读到了（返回 \(String(describing: got))），这条没在测限流")
                return false
            }
            guard !snap.contains(FileSystem.normalizePath(ok)) else {
                print("      根本没去 open 的目录被记成「读不到」——凭空造了一条权限告警")
                return false
            }
            return true
        }

        check("卡死去重：查询与占位必须在同一次临界区（源码形状）") {
            // 上面那条并发行为自检钉的是"同一个 key 只跑一次 body"，但**它分辨不了原子性**：
            // 把查询与占位拆成两次临界区，窗口只有几条指令，8 个线程实测仍然只跑 1 次 body
            // ——变异验不出来（试过，全绿）。所以这里用形状钉住那个不变量本身：
            // 占位那一行不许自带一次新的 lock/unlock，否则就是 check-then-act。
            let src = (try? String(contentsOfFile:
                (Selftest.sourceDirectoryPath as NSString).appendingPathComponent("FileSystem.swift"),
                encoding: .utf8)) ?? ""
            guard src.count > 4000 else {
                print("      读不到 FileSystem.swift 正文（\(src.count) 字符）")
                return false
            }
            var bad: [String] = []
            guard let line = src.split(separator: "\n").first(where: {
                $0.contains("inFlightReads.insert(key)")
            }) else {
                print("      找不到 inFlightReads.insert(key) 这一行")
                return false
            }
            if line.contains("wedgedLock.") {
                bad.append("占位与查询被拆成两次临界区（check-then-act）：\(line.trimmingCharacters(in: .whitespaces))")
            }
            if !src.contains("if inFlightReads.contains(key)") {
                bad.append("在途占位的查询消失了，同一个卡死目录可能被并发放行多次")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("C1/C6/A1 三处候选目录都要有截止跳过（探测关掉时跳过语义不能一起消失）") {
            let src = (try? String(contentsOfFile:
                (Selftest.sourceDirectoryPath as NSString).appendingPathComponent("Scanner.swift"),
                encoding: .utf8)) ?? ""
            guard src.count > 4000 else {
                print("      读不到 Scanner.swift 正文（\(src.count) 字符）")
                return false
            }
            // 三处 recordBlindSpotIfNeeded 都必须紧跟一道不受 proactiveBlindSpotProbe 管的
            // isReadableWithDeadline：否则探测一关，`continue` 永不发生，
            // 紧接着的 size(at:) 就去无截止地开同一个目录。
            let lines = src.split(separator: "\n").map(String.init)
            var bad: [String] = []
            let probeLines = lines.enumerated().filter { $0.element.contains("recordBlindSpotIfNeeded(at:") }
            if probeLines.count != 3 {
                bad.append("recordBlindSpotIfNeeded 调用点变成 \(probeLines.count) 处（期望 3）")
            }
            for (idx, _) in probeLines {
                let window = lines[idx..<min(idx + 3, lines.count)]
                if !window.contains(where: { $0.contains("isReadableWithDeadline(") }) {
                    bad.append("探测调用后三行内没有有截止跳过：\(lines[idx].trimmingCharacters(in: .whitespaces))")
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("出厂 deadline 必须是有限且够干活的小值") {
            // 钉的是常量 `defaultGatedReadDeadline`，**不是**运行时那个可变的当前值：
            // 同文件前两条自检会把它临时改成 0.3 再还原，断当前值等于断别人设的值。
            // 设成 .infinity / 3600 就等于没有截止，卡死原样回来；设成 0 则把可读目录
            // 一口全报成盲区——两头都要钉住。
            let d = FileSystem.defaultGatedReadDeadline
            guard d > 0, d <= 30 else {
                print("      defaultGatedReadDeadline = \(d)，不在 (0, 30] 内")
                return false
            }
            return true
        }

    }
}
