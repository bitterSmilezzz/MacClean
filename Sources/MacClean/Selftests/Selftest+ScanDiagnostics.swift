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

    }
}
