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
            // 本条会真的投放**两**次卡死 body（第一次、以及清空记录后的第三次），
            // 所以归还也要两次——少一次就有一分在途令牌在本进程剩余 lifetime 内消失。
            defer { for _ in 0..<2 { gate.signal() } }
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
            // 占了几条就还几条：body 卡在 gate 上时它一直握着在途令牌，
            // 只 signal 一次等于把 3 分令牌永久吃掉——本进程后面所有门禁读取都会
            // 静默退化成"没顾上"。（这条是下一轮新增的额度归还断言替我们抓出来的。）
            defer { for _ in 0..<4 { gate.signal() } }
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

        check("软链形态的门禁目录不许绕开截止探测（C6 的缓存目录就是这一类）") {
            let fm = FileManager.default
            let base = "/private/tmp/macclean-sym-\(UUID().uuidString)"
            let target = base + "/target"
            let link = base + "/link"
            try? fm.createDirectory(atPath: target, withIntermediateDirectories: true)
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
                try? fm.removeItem(atPath: base)
            }
            // 用绝对路径建软链，normalizePath 之后仍指向同一个目标
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)
            FileSystem.resetWedgedReadsForSelftest()
            FileSystem.resetDeniedAccess()
            // `opendir` 会跟随软链走进 target 并在那里被拒/卡住，所以判类型必须用 stat。
            // 用 lstat 的话这里会被判"不是目录、不用探测"而放行，调用方接着无截止地 open 它。
            guard FileSystem.isReadableWithDeadline(link) == false else {
                print("      软链目录被当成「不用探测」放行了，截止机制在这条路径上失效")
                return false
            }
            guard FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(link)) else {
                print("      软链目录判出了读不到却没记盲区")
                return false
            }
            return true
        }

        check("产品源码里每个 enumerator(at:) 都必须带 errorHandler") {
            // 这是本轮立的不变量，也是防回归的那道闸：`errorHandler` 缺省时
            // Foundation 的语义是"第一个错误就停止遍历且不报告"，于是被权限挡掉的
            // 子树会让一份统计安静地变小，调用方还拿着"完整、可读"的结论往下走。
            // 上两轮修掉的是一份重复实现；这条钉住的是同一族写法不再长回来。
            let sourceDir = Selftest.sourceDirectoryPath
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: sourceDir)) ?? []
            let files = all.filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Selftests/") }.sorted()
            let mustBeThere: Set<String> = ["FileSystem.swift", "AudioHALScanner.swift",
                                            "PrinterDriverScanner.swift", "ColorSyncScanner.swift"]
            let missingTargets = mustBeThere.subtracting(Set(files)).sorted()
            guard missingTargets.isEmpty else {
                print("      扫描范围缺了必然存在的文件：\(missingTargets)")
                return false
            }
            guard files.count >= 50 else {
                print("      只扫到 \(files.count) 个产品源码文件，这条没有覆盖面")
                return false
            }
            var offenders: [String] = []
            var matchedCalls = 0
            var matchedByFile: [String: Int] = [:]
            for rel in files {
                let path = (sourceDir as NSString).appendingPathComponent(rel)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(rel):<不可读>")
                    continue
                }
                let raw = src.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                // 保留物理行号（`idx`），但注释行在后面的每一步都被排除：文档注释里出现
                // `recordDeniedAccess` / `errorHandler:` 不该让一次漏网遍历被误判合格。
                let lines = raw.enumerated().map { (idx: $0.offset, text: $0.element) }
                // 调用是**多行**的：`fm.enumerator(` 在一行、`at: URL(...)` 在下一行。
                // 第一版按单行找 `.enumerator(at:`，一条都没匹配上——lint 在空集上恒真通过，
                // 是 M31 那轮变异把它判红的。所以这里按 `.enumerator(` 起头、再往下取参数段。
                for (i, entry) in lines.enumerated() {
                    let t = entry.text.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                    if !t.contains(".enumerator(") { continue }
                    // `enumerator(atPath:)` 这个重载没有 errorHandler 参数，只能靠 nil 分支
                    // 上报——按**同一行**判定，别拿窗口去豁免（窗口里邻居的 atPath:
                    // 会把真正的违规免检）。它缺的是另一样东西，见 v1.73.6 待议。
                    if t.contains("atPath:") { continue }
                    matchedCalls += 1
                    matchedByFile[rel, default: 0] += 1
                    // 窗口切**下一处 `.enumerator(` 之前**——否则同函数里邻居 handler 里的
                    // `recordDeniedAccess` 会把本行漏网免检（review P2-2）。
                    var stop = lines.count
                    for j in (i + 1)..<lines.count {
                        let u = lines[j].text.trimmingCharacters(in: .whitespaces)
                        if u.hasPrefix("//") || u.hasPrefix("///") { continue }
                        if u.contains(".enumerator(") { stop = j; break }
                    }
                    let window = lines[i..<stop].map { $0.text }
                        .filter {
                            let u = $0.trimmingCharacters(in: .whitespaces)
                            return !u.hasPrefix("//") && !u.hasPrefix("///")
                        }
                        .joined(separator: "\n")
                    let squeezed = window.filter { !$0.isWhitespace }
                    // 光有 errorHandler 不算：`{ _, _ in true }` 让遍历继续但什么都不记，
                    // 结果照样是"被挡掉的子树静默消失"。判据必须是**真的留了痕**。
                    if !squeezed.contains("errorHandler:") {
                        offenders.append("\(rel):\(entry.idx + 1)<缺 errorHandler>")
                    }
                    if !squeezed.contains("recordDeniedAccess") {
                        offenders.append("\(rel):\(entry.idx + 1)")
                    }
                    if squeezed.contains("errorHandler:{_,_intrue}")
                        || squeezed.contains("errorHandler:{_,_infalse}") {
                        offenders.append("\(rel):\(entry.idx + 1)<空 handler>")
                    }
                }
            }
            // 只钉"扫到多少文件"是不够的：匹配逻辑若退化到 0 处调用，offenders 依然为空、
            // 灯照样绿。这一族假绿已经在 v1.73.6 第一版踩过一次——加"命中数下界"和
            // "每条必存在的文件各自至少命中 1 处"两道活性证据，把"整片没扫到"和
            // "扫到了但都合规"这两种状态分开。当前产品源码 11 处非 atPath 的 `.enumerator(`。
            if matchedCalls < 8 {
                print("      lint 只匹配到 \(matchedCalls) 处非 atPath 的 `.enumerator(` 调用——"
                      + "匹配逻辑可能已退化，绿灯不可信")
                return false
            }
            for must in mustBeThere {
                if (matchedByFile[must] ?? 0) < 1 {
                    print("      \(must) 里一处非 atPath 的 `.enumerator(` 都没匹配到——"
                          + "该文件的 lint 覆盖已失效")
                    return false
                }
            }
            if !offenders.isEmpty { print("      缺 errorHandler 的遍历：\(offenders)") }
            return offenders.isEmpty
        }

        check("产品源码里 `enumerator(atPath:)` 每一处都必须紧邻 nil-else 上报 unreadable") {
            // v1.73.6 复审查出的最后一个 atPath 豁免点：`Scanner.swift:974` 的 D8 Maven
            // 用的是没有 `errorHandler` 参数的 `enumerator(atPath:)`，且连 nil 分支都没有——
            // 一次根读不到就静默返回 `[]`，面板显示"这里没有失效元数据"。本轮把它换成了
            // 带 errorHandler 的 URL 重载。这条 lint 钉住"atPath 不许再裸用"，且要求
            // 现存那一处（DiagnosticReportScanner:105）保持 nil-else 上报，否则红。
            // **活性证据**：命中数必须 ≥ 1（当前只有 DiagnosticReportScanner 一处），
            // 匹配集为空等于 lint 自己失效——v1.73.6 踩过一次同族假绿，别再踩。
            // **多行排版容忍**：把注释行剔除后**整文件拼一起再 squeeze 空白**——swift-format
            // 完全可能把 `fm.enumerator(\n  atPath: p)` 折成两行，v1.73.6 复审核实过：
            // 按单行子串匹配的多行折行假绿是这一族 lint 的通病（RELEASE-CHECKLIST §"排版匹配"）。
            // **邻居不背书用大括号深度精确截 else 体**：v1.73.7 二次复审 P1-B 实测——
            // 上一版窗口切"下一处 `.enumerator(` 之前"，而 `DiagnosticReportScanner.swift`
            // 全文只有 1 处 `.enumerator(`，窗口一路开到 EOF；把 :105 的 else 上报整段
            // 删成 `else { continue }`，:134 处另一个 `rootFailed` 分支的 `kind: .unreadable`
            // 落进同一窗口，lint 判绿。所以判据必须只在**本次 else 的花括号体内**取，
            // 邻居再合规也不背书。
            let sourceDir = Selftest.sourceDirectoryPath
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: sourceDir)) ?? []
            let files = all.filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Selftests/") }.sorted()
            var hits = 0
            var offenders: [String] = []
            for rel in files {
                let path = (sourceDir as NSString).appendingPathComponent(rel)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(rel):<源文件不可读>")
                    continue
                }
                let code = Selftest.stripSwiftComments(src)
                    .filter { !$0.isWhitespace }
                var searchFrom = code.startIndex
                while let rng = code.range(of: "enumerator(atPath:", range: searchFrom..<code.endIndex) {
                    hits += 1
                    let afterCall = rng.upperBound
                    // 找**紧邻**的 `else{`；用大括号深度把 else 体精确截出来。
                    guard let elseRng = code.range(of: "else{", range: afterCall..<code.endIndex) else {
                        offenders.append("\(rel)<atPath 后无 else 分支>")
                        searchFrom = rng.upperBound
                        continue
                    }
                    var depth = 1
                    var i = elseRng.upperBound
                    var endIdx = code.endIndex
                    while i < code.endIndex {
                        let c = code[i]
                        if c == "{" { depth += 1 }
                        else if c == "}" {
                            depth -= 1
                            if depth == 0 { endIdx = i; break }
                        }
                        i = code.index(after: i)
                    }
                    let body = String(code[elseRng.upperBound..<endIdx])
                    let reports = body.contains(".unreadable")
                        || body.contains(".permissionDenied")
                        || body.contains("recordDeniedAccess")
                        || body.contains("unreadableRoots")
                        || body.contains("permissionIssues")
                    if body.isEmpty || !reports {
                        offenders.append(rel)
                    }
                    searchFrom = rng.upperBound
                }
            }
            if hits < 1 {
                print("      atPath 命中数为 \(hits)，lint 空集通过等于没在管——"
                      + "匹配逻辑或调用形态可能被改坏，绿灯不可信")
                return false
            }
            if !offenders.isEmpty {
                print("      atPath 处没有 nil-else 上报 unreadable：\(offenders)")
            }
            return offenders.isEmpty
        }

        check("求体积入口的调用方不得用无 readable 契约的 size 撑起默认勾选") {
            // 与上一条 lint 一对：一条管"遍历必须留痕"、这条管"消费遍历结果的地方必须以
            // readable 为闸"。CLICache / QuickLook / Spotlight 三处的求体积调用以前都是
            // `if size > 0 { isSelected: true }`——遍历被掐断过时那个偏小的 size 会被
            // 当成完整事实，用户看到"这个缓存 3 MB，勾选删掉"，实际上里面还有 500 MB 没读到。
            // 本轮把 `calculateDirectoryStats`/`calculateDirectoryMetrics` 的返回加了
            // `readable`，并把它提升到 item 模型；这条 lint 钉住调用方 `isSelected:` 的右值
            // **必须引用含 `readable` 的标识符**（`isSelected: readable` / `isOrphan && metricsReadable`
            // / `walkReadable` 都算），或者显式 `false`。常量 `true`、以及 review P1-4 抓到的
            // 「回退成 `isOrphan` 而不 && readable」这类"看着像闸其实没有"的形状，都要判红。
            // **活性证据**：命中数 ≥ 3。多行折行/邻居不背书的处理同上。
            let sourceDir = Selftest.sourceDirectoryPath
            let targets = ["CLICacheScanner.swift", "QuickLookThumbnailPurger.swift",
                           "SpotlightScanner.swift"]
            var offenders: [String] = []
            var checkedSites = 0
            for name in targets {
                let path = (sourceDir as NSString).appendingPathComponent(name)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(name):<不可读>")
                    continue
                }
                let code = Selftest.stripSwiftComments(src)
                    .filter { !$0.isWhitespace }
                var searchFrom = code.startIndex
                while let rng = code.range(of: "isSelected:", range: searchFrom..<code.endIndex) {
                    checkedSites += 1
                    // 抽 `isSelected:` 后面到下一个分隔符（`,` `)` `}` 或又一个 `keyWord:`）
                    // 为止的右值片段。因为已经去过空白，只需按分隔符切。
                    let after = rng.upperBound
                    var endIdx = after
                    var depth = 0
                    var i = after
                    outer: while i < code.endIndex {
                        let c = code[i]
                        switch c {
                        case "(", "[", "{": depth += 1
                        case ")", "]", "}":
                            if depth == 0 { break outer }
                            depth -= 1
                        case ",":
                            if depth == 0 { break outer }
                        default: break
                        }
                        // 允许 `&&` 继续吃进 rhs
                        i = code.index(after: i)
                        if i >= code.endIndex { break }
                        // 检测 `word:` 结束 rhs（下一个 labeled 参数）
                        let ahead = code[i...]
                        if let firstColon = ahead.firstIndex(of: ":"),
                           firstColon != i {
                            let between = code[i..<firstColon]
                            // between 若是合法标识符（含 ! ? 前缀），说明下一个 `:` 是新参数标签
                            let isIdent = between.allSatisfy {
                                $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "!" || $0 == "?"
                            }
                            if isIdent, let firstCh = between.first,
                               firstCh.isLetter || firstCh == "_" || firstCh == "." {
                                break outer
                            }
                        }
                    }
                    endIdx = i
                    let rhs = String(code[after..<min(endIdx, code.endIndex)])
                    // 允许：`false`（永不勾选）、含 `eadable` 的表达式（readable/metricsReadable/
                    // walkReadable 等，允许 &&/|| 组合）；**禁止**：`true`、不含 readable 的
                    // 任意其它表达式（比如光秃秃的 `isOrphan`——那是本轮契约之外的老形状）。
                    let ok = rhs == "false" || rhs.contains("eadable")
                    if !ok {
                        offenders.append("\(name)<rhs=\(rhs.prefix(30))>")
                    }
                    searchFrom = rng.upperBound
                }
            }
            if checkedSites < 3 {
                print("      lint 只扫到 \(checkedSites) 处 `isSelected:` 消费方，"
                      + "至少应有 3 处；匹配可能已经失效")
                return false
            }
            if !offenders.isEmpty {
                print("      默认勾选没有以 readable 为闸：\(offenders.joined(separator: ", "))")
            }
            return offenders.isEmpty
        }

        check("三张卡片的全选必须走 readable（v1.73.7 复审 P1-1）") {
            // scan 阶段把 isSelected 关到 readable 上只完成了一半：卡片顶部的
            // `selectAll(true)` / `toggleSelectAll()` 若还是 `for i in 0..<count { items[i].isSelected = true }`
            // 的老形状，用户点一次全选就把残缺项重新默认勾上——本轮 lint #2 与行为断言
            // 都只覆盖 scan 那一刻，抓不到这条退路。
            // **钉的是全选函数体本身**：只要求"整文件某处提到 readable"太松——
            // 变异里我把 `summary.items[i].isSelected = target && items[i].readable`
            // 换成 `= target`，`selectableCount` 计算属性还在文件里，那版判据照样绿。
            let sourceDir = Selftest.sourceDirectoryPath
            let cards: [(String, [String])] = [
                ("CLICacheOptimizerCard.swift", ["toggleSelectAll"]),
                ("QuickLookThumbnailPurgerCard.swift", ["toggleSelectAll"]),
                ("SpotlightOptimizerCard.swift", ["selectAll"]),
            ]
            var offenders: [String] = []
            for (name, funcs) in cards {
                let path = (sourceDir as NSString).appendingPathComponent(name)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(name):<不可读>")
                    continue
                }
                let code = Selftest.stripSwiftComments(src)
                    .filter { !$0.isWhitespace }
                for fn in funcs {
                    let key = "func\(fn)("
                    guard let rng = code.range(of: key) else {
                        offenders.append("\(name)<找不到 \(fn) 定义>")
                        continue
                    }
                    // 用**大括号深度**精确截出这一个方法的函数体——上一版按"下一处 `func` 之前"
                    // 或"往后 400 字符"取窗，被同文件里的 `selectableCount: Int {
                    //   items.filter(\.readable).count }` 蹭到了 readable 而免检
                    // （变异验证：把全选里的 `&& readable` 摘掉，判据必须变红；
                    //  如果还是绿的，就是窗口太宽，见 RELEASE-CHECKLIST §"活性证据"）。
                    let after = rng.upperBound
                    guard let braceIdx = code[after...].firstIndex(of: "{") else {
                        offenders.append("\(name)<\(fn) 找不到方法体>")
                        continue
                    }
                    var depth = 0
                    var endIdx = code.endIndex
                    var i = braceIdx
                    while i < code.endIndex {
                        let c = code[i]
                        if c == "{" { depth += 1 }
                        else if c == "}" {
                            depth -= 1
                            if depth == 0 {
                                endIdx = code.index(after: i)
                                break
                            }
                        }
                        i = code.index(after: i)
                    }
                    let body = String(code[braceIdx..<endIdx])
                    if !body.contains("readable") {
                        offenders.append("\(name)<\(fn) 方法体没按 readable 过滤>")
                    }
                }
            }
            if !offenders.isEmpty {
                print("      卡片全选没有走 readable：\(offenders)——"
                      + "scan 阶段的闸会被一次全选按钮绕过")
            }
            return offenders.isEmpty
        }

        check("Spotlight 残缺时必须同时补 issue，卡片 isResultComplete 才翻得动（v1.73.7 复审 P1-2）") {
            // 钉的是**形状**：SpotlightScanner 里 coreSpotlight 与 cachePath 两处 `!metricsReadable`
            // 都要紧跟 `issues.append(Self.readIssue(for: <参数>))`；卷索引一处 `!volReadable`
            // 同理。**每条 needle 必须带独有的参数名**（v1.73.7 二次复审 P1-C：上一版
            // 两条 `metricsReadable` needle 字面完全一样，删掉 coreSpotlight 那一处 append
            // 时 cachePath 那处还在，`code.contains` 就判绿了）。
            let sourceDir = Selftest.sourceDirectoryPath
            let path = (sourceDir as NSString).appendingPathComponent("SpotlightScanner.swift")
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("      SpotlightScanner.swift 不可读")
                return false
            }
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            // 三条唯一 needle：参数名分别是 subPath、cachePath、spotlightV100
            let needles: [(label: String, needle: String)] = [
                ("coreSpotlight", "if!metricsReadable{issues.append(Self.readIssue(for:subPath))}"),
                ("cachePath", "if!metricsReadable{issues.append(Self.readIssue(for:cachePath))}"),
                ("volumeIndex", "if!volReadable{issues.append(Self.readIssue(for:spotlightV100))}"),
            ]
            var missing: [String] = []
            for entry in needles where !code.contains(entry.needle) {
                missing.append(entry.label)
            }
            if !missing.isEmpty {
                print("      Spotlight 残缺分支没补 issue：\(missing)——"
                      + "isResultComplete 仍是 true，面板同时说\"结果完整\"与\"这条我不敢替你决定\"")
            }
            return missing.isEmpty
        }

        check("遍历被权限掐断时必须留痕，且不完整的结果不许报成 readable") {
            // mode 000 在 root（或部分 MDM/override 账号）下不拦 opendir，那会让这条
            // 以"代码没问题但自检红"的形态出现。跳过要**打印出来**，别静默 return true
            // 把一次没跑混进绿灯里。
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            let fm = FileManager.default
            func makeTree(_ base: String) -> (root: String, locked: String) {
                let root = "\(base)/tree"
                let locked = "\(root)/private"
                try? fm.createDirectory(atPath: locked + "/deep", withIntermediateDirectories: true)
                try? fm.createDirectory(atPath: root + "/open", withIntermediateDirectories: true)
                fm.createFile(atPath: root + "/open/a.bin", contents: Data(repeating: 1, count: 8192))
                fm.createFile(atPath: locked + "/deep/b.bin", contents: Data(repeating: 2, count: 8192))
                return (root, locked)
            }
            // ① CLI 缓存统计：被挡住的子树要进盲区清单
            let b1 = "/private/tmp/macclean-cli-den-\(UUID().uuidString)"
            let t1 = makeTree(b1)
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: t1.locked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t1.locked)
                try? fm.removeItem(atPath: b1)
            }
            FileSystem.resetDeniedAccess()
            let cli = CLICacheScanner.calculateDirectoryStats(at: t1.root)
            var bad: [String] = []
            if cli.size <= 0 { bad.append("可读部分也没算进来了：size=\(cli.size)") }
            if cli.readable {
                bad.append("遍历被掐断却仍报 readable=true（消费方会拿偏小的数默认勾选删除）")
            }
            if !FileSystem.deniedAccessSnapshot().contains(FileSystem.normalizePath(t1.locked)) {
                bad.append("被掐断的子树没留痕（盲区 \(FileSystem.deniedAccessSnapshot().count) 处）")
            }
            // ② AudioHAL 统计：同一棵树必须把 readable 翻成 false
            let b2 = "/private/tmp/macclean-hal-den-\(UUID().uuidString)"
            let t2 = makeTree(b2)
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: t2.locked)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: t2.locked)
                try? fm.removeItem(atPath: b2)
            }
            FileSystem.resetDeniedAccess()
            if AudioHALScanner.calculateDirectoryMetrics(at: t2.root).readable {
                bad.append("遍历被掐断却仍报 readable=true（消费方会拿偏小的数判归属）")
            }
            // ③ 反证：完整可读的树必须仍是 readable=true
            let b3 = "/private/tmp/macclean-hal-ok-\(UUID().uuidString)"
            let t3 = makeTree(b3)
            defer { try? fm.removeItem(atPath: b3) }
            FileSystem.resetDeniedAccess()
            let clean = AudioHALScanner.calculateDirectoryMetrics(at: t3.root)
            if !clean.readable { bad.append("完整可读的树被判成不可读（会把正常项整片跳过）") }
            if clean.size <= 0 || clean.fileCount != 2 {
                bad.append("完整树的统计不对：size=\(clean.size) count=\(clean.fileCount)")
            }
            if !FileSystem.deniedAccessSnapshot().isEmpty {
                bad.append("正常遍历被记了盲区")
            }
            // 收尾复位：本条会往全局盲区清单里留条目，不清就会带进后续用例里
            // 那些"快照必须为空"的断言（顺序依赖的假红）。
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("G18 不变量：产品源码里不得再出现 `hasPrefix(\"/System\")` 式字符串路径护栏") {
            // 任务书里明写的 P0 形态：`hasPrefix` 式字符串护栏。项目早就给 ColorSync 与
            // PrinterDriver 各立了一条**单文件** lint（`Selftest+ColorSyncDeep.swift:465`、
            // `Selftest+PrinterDriverDeep.swift:422`），但覆盖只到那两处——Screenshots/
            // Downloads/QuickLook/AppLocalization 四处仍是漏网的字符串护栏。本轮把
            // 这四处换成 `FileSystem.isSystemProtected`，并立这条**全仓** lint 钉死
            // 同一族写法不再长回来。为什么不能继续用字符串：
            // ① 漏：`/private/var/db`、`/private/var/vm`、`/System/Volumes`、`/Library/Updates`
            //    都是 SIP/sunlnk 保护位置，`hasPrefix("/System")` 一条都不认；
            // ② 误伤：`/SystemFoo`（假想路径）会被顺手拦下；`/System/Volumes/Data/Users/...`
            //    经 firmlink 指向真实用户数据，也被误当成系统目录；
            // ③ 归一化漂移：字符串比较对 `~/` 展开、`/private` 别名、`.`/`..` 段、尾斜杠
            //    全都不敏感，同一份文件在不同上下文（调用方 vs 网关）会得到两种形态。
            // **活性证据**：命中数必须 ≥ 0，但扫过的**产品文件数**要 ≥ 50，且必须
            // 至少覆盖到 Screenshots/Downloads/QuickLook/AppLocalization 这 4 个本轮改动文件
            //（否则 lint 只是在扫自己写的注释）。
            let sourceDir = Selftest.sourceDirectoryPath
            let all = (try? FileManager.default.subpathsOfDirectory(atPath: sourceDir)) ?? []
            let files = all.filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Selftests/") }.sorted()
            guard files.count >= 50 else {
                print("      只扫到 \(files.count) 个产品源码文件，这条 lint 没有覆盖面")
                return false
            }
            let mustBeThere: Set<String> = [
                "ScreenshotsOrganizerScanner.swift", "DownloadsOrganizerScanner.swift",
                "QuickLookThumbnailPurger.swift", "AppLocalizationScanner.swift",
                // v1.73.8 二次复审 P2 待议 2：FontCache 是本轮第 5 处修复点，也是
                // 清单里唯一"归一化 sibling"形态（`isOutsideUserFontScope`），把它钉进
                // mustBeThere 才与 README 声称的"扫描侧统一到 G8"的口径一致。
                "FontCacheInspector.swift",
            ]
            let missing = mustBeThere.subtracting(Set(files)).sorted()
            guard missing.isEmpty else {
                print("      扫描范围缺了本轮必然改过的文件：\(missing)")
                return false
            }
            // **同族字符串护栏的四种写法都要钉**（v1.73.8 二次复审 P2 逼出：一次复审
            // 抓到 `StartupItemInspector:396 path.contains("/System/")` 与
            // `SpaceArchiveService:85 path == "/System"` 两处也是"G8 判据用原始子串实现"，
            // 本轮一并修，needles 也一并扩）。挤过空白后以下 4 条字面在**非注释产品代码**
            // 里都不许再出现：
            //   · `hasPrefix("/System")` / `hasPrefix("/System/")` — 原形 + 归一化 sibling
            //   · `contains("/System")` / `contains("/System/")` — StartupItemInspector 那族
            //   · `=="/System"` — SpaceArchiveService 那族
            //   · `starts(with:"/System")` — Swift 标准 API，语义等同 hasPrefix，防绕过
            // `/Applications` 一族本轮**不钉**：`CleanPaths` 里没有对应保护清单，
            // ScreenshotsOrganizer 里保留的 `hasPrefix("/Applications")` 是 incidental
            // 策略（截图扫描根不该在这），不是 G8 判据；把它当同族收口需要先在 CleanPaths
            // 里定义"/Applications 是保护根"，与本轮"扫描侧统一到 G8"的范围不同。
            let needles = [
                "hasPrefix(\"/System\")",
                "hasPrefix(\"/System/\")",
                "contains(\"/System\")",
                "contains(\"/System/\")",
                "==\"/System\"",
                "starts(with:\"/System\")",
                "starts(with:\"/System/\")",
            ]
            var offenders: [String] = []
            var nonWsChars = 0
            // **每文件按比例的活性证据**（v1.73.8 二次复审 P2 逼出：全仓下界对"某个文件
            // 被 inBlock 吞掉"完全瞎——`Rules/CleanupRules.swift` 被吞时单文件 17,569
            // → 3,390（丢 80.7%），全仓只 -1.33%，5_000 与 300_000 都挡不住）。
            // 判据：`剥离注释+去空白` 之后的字符数应当不低于 `原文件去空白` 的 30%——
            // 真实产品文件里的注释占比不会超过 70%；一旦被 inBlock 拖到 EOF，剩下
            // 的就是文件开头那几十行，比例会远低于 30%。这条对短小但注释密集的
            // 工具文件也友好（DiskInfo.swift 467 chars 若原文件 600 chars 则 78%，稳过），
            // 不像"每文件绝对下界"会误伤合法短文件（上一版 500 阈值刚立就把 DiskInfo 判红）。
            let minKeepRatio = 0.30
            for rel in files {
                let path = (sourceDir as NSString).appendingPathComponent(rel)
                guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                    offenders.append("\(rel):<源文件不可读>")
                    continue
                }
                let rawNonWs = src.filter { !$0.isWhitespace }.count
                let code = Selftest.stripSwiftComments(src)
                let squeezed = code.filter { !$0.isWhitespace }
                nonWsChars += squeezed.count
                if rawNonWs >= 1_000 {
                    let ratio = Double(squeezed.count) / Double(rawNonWs)
                    if ratio < minKeepRatio {
                        offenders.append("\(rel)<剥离后只剩 \(squeezed.count)/\(rawNonWs)"
                                         + "（\(Int(ratio * 100))%，低于 \(Int(minKeepRatio * 100))%"
                                         + "）——注释剥离器大概率被字符串里的 `/*` 拖进了"
                                         + " inBlock 到 EOF，本文件的 lint 覆盖已失效>")
                    }
                }
                for needle in needles where squeezed.contains(needle) {
                    offenders.append("\(rel)<含 \(needle)>")
                }
                if mustBeThere.contains(rel) {
                    if !squeezed.contains("FileSystem.isSystemProtected(") {
                        offenders.append("\(rel)<没接入 isSystemProtected，护栏可能被整段删掉>")
                    }
                }
            }
            // 全仓下界（保留但只是兜底）：v1.73.8 二次复审 P2 实测——**全仓量**对"某个
            // 文件被 inBlock 吞掉"完全瞎：`Rules/CleanupRules.swift` 被吞时单文件从
            // 17,569 掉到 3,390（-80.7%），全仓只从 108 万降到 106.6 万（-1.33%），
            // 无论 5_000 还是 300_000 都挡不住。真正的活性证据是**上面每文件 30% 比例**；
            // 这条全仓阈值只防"119 个文件集体蒸发"这种极端事故。
            if nonWsChars < 300_000 {
                print("      lint 只扫到 \(nonWsChars) 个非空白字符的产品代码——阈值 300_000"
                      + "，整片丢文件的兜底"); return false
            }
            if !offenders.isEmpty {
                print("      仍有 hasPrefix(\"/System\") 式字符串路径护栏：\(offenders)")
            }
            return offenders.isEmpty
        }

        check("出厂 deadline 必须是有限且够干活的小值") {
            // 钉的是常量 `defaultGatedReadDeadline`，**不是**运行时那个可变的当前值：
            // 同文件里几条卡死模拟自检会把它临时改成 0.3 再还原，断当前值等于断别人设的值。
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
