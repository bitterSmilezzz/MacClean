import Foundation
import Darwin

// MARK: - 启动项与后台守护全景治理深度自检 (v1.47.0 / v1.74.0 加固)

extension Selftest {
    static func suiteStartupItemsDeep() {
        print("==> 运行启动项与后台服务治理深度自检 (v1.47.0)...")

        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacCleanStartupTest_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // 本套件**绝不允许真跑 launchctl**：一律注入 runner，只断言命令与参数。
        let savedRunner = SafeProcess.runner
        SafeProcess.runner = { _, _, _ in
            SafeProcess.Result(exitCode: 113, output: "Could not find service in domain for user")
        }
        defer { SafeProcess.runner = savedRunner }

        let mockHome = tempDir.appendingPathComponent("UserHome")
        let userAgentsDir = mockHome.appendingPathComponent("Library/LaunchAgents")
        let globalAgentsDir = tempDir.appendingPathComponent("GlobalAgents")
        let globalDaemonsDir = tempDir.appendingPathComponent("GlobalDaemons")

        try? fm.createDirectory(at: userAgentsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: globalAgentsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: globalDaemonsDir, withIntermediateDirectories: true)

        let manager = StartupItemManager()
        manager.overrideHomeDirectory = mockHome.path
        manager.overrideGlobalAgentsDir = globalAgentsDir.path
        manager.overrideGlobalDaemonsDir = globalDaemonsDir.path

        // 创建一个真实存在的 dummy 可执行文件
        let binDir = tempDir.appendingPathComponent("bin")
        try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        let validBin = binDir.appendingPathComponent("valid_tool")
        try? "echo hello".write(to: validBin, atomically: true, encoding: .utf8)

        // 1. Plist 属性解析与状态诊断
        check("启动项深度：Program 与 ProgramArguments 解析及正常激活判定") {
            let plistContent: [String: Any] = [
                "Label": "com.test.validagent",
                "Program": validBin.path,
                "RunAtLoad": true,
                "KeepAlive": true
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.test.validagent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.test.validagent.plist", location: .userAgent) else {
                return false
            }

            return item.label == "com.test.validagent" &&
                item.programPath == validBin.path &&
                item.runAtLoad == true &&
                item.keepAlive == true &&
                item.status == .valid &&
                item.isDisabled == false
        }

        // 2. 幽灵启动项识别（可执行文件缺失）
        check("启动项深度：目标可执行文件不存在判定为幽灵残留 (missingExecutable)") {
            let plistContent: [String: Any] = [
                "Label": "com.test.ghostagent",
                "ProgramArguments": ["/usr/local/bin/non_existent_ghost_binary", "--daemon"],
                "RunAtLoad": true
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.test.ghostagent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.test.ghostagent.plist", location: .userAgent) else {
                return false
            }

            return item.status == .missingExecutable &&
                item.status.isDangling == true &&
                item.programPath == "/usr/local/bin/non_existent_ghost_binary"
        }

        // 3. 宿主 App 已被卸载识别 (orphanedApp)
        check("启动项深度：宿主应用包已被卸载判定为 orphanedApp") {
            let plistContent: [String: Any] = [
                "Label": "com.uninstalled.app.helper",
                "ProgramArguments": ["/Applications/DeletedFakeApp.app/Contents/MacOS/Helper"],
                "RunAtLoad": true
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.uninstalled.app.helper.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.uninstalled.app.helper.plist", location: .userAgent) else {
                return false
            }

            return item.status == .orphanedApp &&
                item.status.isDangling == true
        }

        // 4. 系统受保护启动项
        check("启动项深度：com.apple 前缀判定为系统受保护 (systemProtected)") {
            let plistContent: [String: Any] = [
                "Label": "com.apple.coreservices.agent",
                "Program": "/usr/bin/true"
            ]
            let plistURL = globalAgentsDir.appendingPathComponent("com.apple.coreservices.agent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.apple.coreservices.agent.plist", location: .globalAgent) else {
                return false
            }

            return item.status == .systemProtected &&
                item.vendor == "Apple 原生/系统"
        }

        // 5. 禁用与恢复状态机 (toggleDisabled)
        check("启动项深度：通过重命名 .disabled 实现平滑停用与恢复") {
            let plistContent: [String: Any] = [
                "Label": "com.test.toggleagent",
                "Program": validBin.path
            ]
            let plistURL = userAgentsDir.appendingPathComponent("com.test.toggleagent.plist")
            let data = try! PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try! data.write(to: plistURL)

            guard let item = manager.parseStartupItem(path: plistURL.path, filename: "com.test.toggleagent.plist", location: .userAgent) else {
                return false
            }

            // 1) 停用
            guard let disabledItem = try? manager.toggleDisabled(item: item) else {
                return false
            }
            guard disabledItem.isDisabled == true &&
                disabledItem.path.hasSuffix(".disabled") &&
                fm.fileExists(atPath: disabledItem.path) &&
                !fm.fileExists(atPath: plistURL.path) else {
                return false
            }

            // 2) 恢复
            guard let restoredItem = try? manager.toggleDisabled(item: disabledItem) else {
                return false
            }
            return restoredItem.isDisabled == false &&
                restoredItem.status == .valid &&
                !restoredItem.path.hasSuffix(".disabled") &&
                fm.fileExists(atPath: plistURL.path)
        }

        // 6. 全局扫描与幽灵残留排序
        check("启动项深度：scanAll 全局聚合与幽灵项优先排序") {
            let allItems = manager.scanAll()
            guard !allItems.isEmpty else { return false }

            // 幽灵项应排在前面
            if let first = allItems.first {
                return first.status.isDangling
            }
            return true
        }

        // v1.74.0 安全加固自检 ----------------------------------------------

        // 7. launchctl 证据只走 SafeProcess：非 0 / 超时 / 不可用都不得判"已停止"
        check("启动项：launchctl 经 SafeProcess 执行且证据不足时不判已停止") {
            let probe = StartupItemManager()
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            var seen: [(String, [String], TimeInterval)] = []

            // 命令成功且打印出服务详情 = 仍在会话中加载
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 0, output: "com.demo.agent = {\n  state = running\n}")
            }
            guard probe.launchdEvidence(for: "com.demo.agent") == .loaded else { return false }
            guard seen.last?.0 == StartupItemManager.launchctlPath,
                  seen.last?.1.first == "print",
                  seen.last?.1.last == "gui/\(getuid())/com.demo.agent" else {
                print("    ❌ 调的不是 launchctl print gui/<uid>/<label>：<\(String(describing: seen.last))>")
                return false
            }
            guard (seen.last?.2 ?? 0) > 0 else {
                print("    ❌ launchctl 调用没有超时保护")
                return false
            }

            // 明确"找不到该服务" → 才算未加载
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 113, output: "Could not find service \"com.demo.agent\"")
            }
            guard probe.launchdEvidence(for: "com.demo.agent") == .notLoaded else { return false }

            // 非 0 但原因不明（权限/域不可读）→ 无证据，不得当成"没在跑"
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "Could not read domain: Operation not permitted")
            }
            guard probe.launchdEvidence(for: "com.demo.agent") == .unavailable else {
                print("    ❌ 命令失败被读成了「服务未加载」")
                return false
            }

            // 超时 / 进程根本没起来 → 无证据
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            guard probe.launchdEvidence(for: "com.demo.agent") == .unavailable else { return false }
            SafeProcess.runner = { _, _, _ in nil }
            guard probe.launchdEvidence(for: "com.demo.agent") == .unavailable else { return false }

            // 空 label 直接拒绝，不拼一条 `launchctl print gui/<uid>/`
            SafeProcess.runner = { path, args, _ in
                print("    ❌ 空 label 仍执行了命令：\(path) \(args)")
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            guard probe.launchdEvidence(for: "   ") == .unavailable else { return false }
            guard seen.count == 1 else { return false }
            return true
        }

        // 8. 「已停用」区分文件声明与会话证据；模型层不再持有 SwiftUI 颜色
        check("启动项：已停用需 launchd 证据且语义色板替代 Color") {
            let base = StartupItem(
                name: "com.demo.agent.plist", path: "/tmp/MacCleanStartup/com.demo.agent.plist",
                label: "com.demo.agent", location: .userAgent, programPath: "/bin/true",
                isDisabled: true, status: .disabled)

            var loaded = base
            loaded.serviceEvidence = .loaded
            guard loaded.isConfirmedDisabled == false, loaded.needsConfirmation == true else {
                print("    ❌ 服务仍在加载却可被宣称为已停用")
                return false
            }
            var unknown = base
            unknown.serviceEvidence = .unavailable
            guard unknown.isConfirmedDisabled == false, unknown.needsConfirmation == true else { return false }
            var confirmed = base
            confirmed.serviceEvidence = .notLoaded
            guard confirmed.isConfirmedDisabled == true, confirmed.needsConfirmation == false else { return false }

            // 提示语跟着证据走
            guard StartupItemManager.evidenceNote(isDisabled: true, evidence: .loaded)?
                .contains("仍加载") == true else { return false }
            guard StartupItemManager.evidenceNote(isDisabled: true, evidence: .unavailable)?
                .contains("无法确认") == true else { return false }
            guard StartupItemManager.evidenceNote(isDisabled: true, evidence: .notLoaded) == nil else { return false }
            guard StartupItemManager.evidenceNote(isDisabled: false, evidence: .unavailable) == nil else { return false }

            // 分层：模型只给语义色，具体 Color 由视图映射（这里断言语义齐备）
            guard StartupItemStatus.valid.tone == .positive else { return false }
            guard StartupItemStatus.disabled.tone == .neutral else { return false }
            guard StartupItemStatus.missingExecutable.tone == .caution else { return false }
            guard StartupItemStatus.orphanedApp.tone == .caution else { return false }
            guard StartupItemStatus.systemProtected.tone == .accent else { return false }
            guard Set(StartupItemStatus.allCases.map(\.tone)).count == 4 else { return false }
            // 系统受保护项不该出现"需确认"（它根本不给删）
            var sys = base
            sys.status = .systemProtected
            guard sys.needsConfirmation == false else { return false }
            return true
        }

        // 9. 自启目录读不到 → 报"结果不完整"，不报"系统自启配置健康"
        check("启动项：目录权限不足时降级为结果不完整") {
            let localFM = FileManager.default
            let base = "/tmp/MacCleanStartupDenied_\(UUID().uuidString)"
            let home = base + "/UserHome"
            let userAgents = home + "/Library/LaunchAgents"
            let lockedAgents = base + "/GlobalAgents"
            let daemons = base + "/GlobalDaemons"
            try? localFM.createDirectory(atPath: userAgents, withIntermediateDirectories: true)
            try? localFM.createDirectory(atPath: lockedAgents, withIntermediateDirectories: true)
            try? localFM.createDirectory(atPath: daemons, withIntermediateDirectories: true)
            defer {
                chmod(lockedAgents, 0o755)
                try? localFM.removeItem(atPath: base)
            }
            let plist: [String: Any] = ["Label": "com.demo.readable", "Program": "/bin/true"]
            let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try! data.write(to: URL(fileURLWithPath: userAgents + "/com.demo.readable.plist"))

            let probe = StartupItemManager()
            probe.overrideHomeDirectory = home
            probe.overrideGlobalAgentsDir = lockedAgents
            probe.overrideGlobalDaemonsDir = daemons

            guard chmod(lockedAgents, 0o000) == 0 else { return true }   // root 环境造不出"读不到"
            let items = probe.scanAll()
            guard items.count == 1, items.first?.label == "com.demo.readable" else { return false }
            guard probe.isResultComplete == false else {
                print("    ❌ 读不到的自启目录被当成完整结果")
                return false
            }
            guard probe.lastScanIssues.first?.kind == .permissionDenied else { return false }
            guard probe.incompletenessBanner?.contains("不完整") == true else { return false }

            // 恢复权限后同一套目录就是完整结论（证明不是"永远报不完整"）
            chmod(lockedAgents, 0o755)
            _ = probe.scanAll()
            guard probe.isResultComplete, probe.incompletenessBanner == nil else {
                print("    ❌ 读得到时仍在报不完整")
                return false
            }
            return true
        }

        // 10. 删除一律过网关：白名单 / G6 硬排除 / 系统项 / 伪造全局位置都拦得住
        check("启动项：白名单与硬排除及系统受保护项必被清理网关拒绝") {
            let localFM = FileManager.default
            let base = "/tmp/MacCleanStartupGate_\(UUID().uuidString)"
            try? localFM.createDirectory(atPath: base, withIntermediateDirectories: true)
            defer { try? localFM.removeItem(atPath: base) }
            let plistPath = base + "/com.demo.wl.plist"
            let data = try! PropertyListSerialization.data(
                fromPropertyList: ["Label": "com.demo.wl", "Program": "/bin/true"],
                format: .xml, options: 0)
            try! data.write(to: URL(fileURLWithPath: plistPath))

            let probe = StartupItemManager()
            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            defer { wm.rules = savedRules }

            // ① 用户白名单
            wm.removeAllRules()
            wm.addPathRule(plistPath, comment: "自检保护")
            let wlItem = StartupItem(name: "com.demo.wl.plist", path: plistPath,
                                     label: "com.demo.wl", location: .userAgent,
                                     programPath: "/bin/true", status: .missingExecutable)
            let wl = probe.deleteOutcome([wlItem], toTrash: false, journal: .none)
            guard wl.cleanedCount == 0, wl.errorCount > 0 else { return false }
            guard wl.rejected.first?.reason == .userWhitelisted else { return false }
            guard localFM.fileExists(atPath: plistPath) else {
                print("    ❌ 白名单里的启动项定义被删除")
                return false
            }
            // 单个删除入口也必须抛错而不是静默成功
            var threw = false
            do { try probe.moveToTrash(item: wlItem) } catch { threw = true }
            guard threw else { return false }

            // ② G6：照片图库（自管理容器）里的 plist
            let insideLibrary = CleanPaths.expand("~/Pictures/Photos Library.photoslibrary/com.demo.in.plist")
            let g6 = probe.deleteOutcome(
                [StartupItem(name: "com.demo.in.plist", path: insideLibrary, label: "com.demo.in",
                             location: .userAgent, programPath: "/bin/true", status: .orphanedApp)],
                toTrash: false, journal: .none)
            guard g6.cleanedCount == 0, g6.errorCount > 0 else { return false }
            guard g6.rejected.first?.reason == .hardExcluded else { return false }

            // ③ com.apple.* 系统受保护项（即使在可写的临时目录里）
            let applePath = base + "/com.apple.demo.plist"
            try! data.write(to: URL(fileURLWithPath: applePath))
            let apple = probe.deleteOutcome(
                [StartupItem(name: "com.apple.demo.plist", path: applePath, label: "com.apple.demo",
                             location: .userAgent, programPath: "/bin/true", status: .systemProtected)],
                toTrash: false, journal: .none)
            guard apple.cleanedCount == 0, apple.rejected.first?.reason == .systemProtected else { return false }
            guard localFM.fileExists(atPath: applePath) else { return false }

            // ④ 自报"全局守护"位置的伪造条目：域判定直接拒，不认调用方给的字符串
            let forged = StartupItem(name: "com.demo.forged.plist", path: base + "/com.demo.forged.plist",
                                     label: "com.demo.forged", location: .globalDaemon,
                                     programPath: "/bin/true", status: .orphanedApp)
            try! data.write(to: URL(fileURLWithPath: forged.path))
            let forgedRes = probe.deleteOutcome([forged], toTrash: false, journal: .none)
            guard forgedRes.cleanedCount == 0, forgedRes.errorCount > 0 else { return false }
            guard forgedRes.rejected.first?.reason == .outsideDomain else { return false }

            // ⑤ 域根与"整个目录"永不可删
            guard case .rejected(let rootReason) = FileSystem.governanceVerdict(
                "/Library/LaunchDaemons", domain: .launchDaemonsGlobal),
                rootReason == .tooShallowForDomain else { return false }
            // ⑥ 非定义文件扩展名不给删（防把用户 .txt/.json 当 plist 清掉）
            let txt = base + "/notes.txt"
            try! "note".write(toFile: txt, atomically: true, encoding: .utf8)
            let txtItem = StartupItem(name: "notes.txt", path: txt, label: "notes",
                                      location: .userAgent, programPath: "/bin/true",
                                      status: .missingExecutable)
            let txtRes = probe.deleteOutcome([txtItem], toTrash: false, journal: .none)
            guard txtRes.cleanedCount == 0, txtRes.rejected.first?.reason == .notDeletable else { return false }
            guard localFM.fileExists(atPath: txt) else { return false }
            return true
        }

        // 11. 删除失败不计账；成功项按网关实测计（旧实现自己 trashItem 后凭空累加）
        check("启动项：删除失败不计入 removedCount 与 freedBytes") {
            let localFM = FileManager.default
            let base = "/tmp/MacCleanStartupFail_\(UUID().uuidString)"
            let agents = base + "/UserHome/Library/LaunchAgents"
            try? localFM.createDirectory(atPath: agents, withIntermediateDirectories: true)
            let plistPath = agents + "/com.demo.stuck.plist"
            let data = try! PropertyListSerialization.data(
                fromPropertyList: ["Label": "com.demo.stuck", "Program": "/nonexistent/stuck"],
                format: .xml, options: 0)
            try! data.write(to: URL(fileURLWithPath: plistPath))
            defer {
                lchflags(plistPath, 0)
                try? localFM.removeItem(atPath: base)
            }
            guard lchflags(plistPath, UInt32(UF_IMMUTABLE)) == 0 else { return true }

            let probe = StartupItemManager()
            probe.overrideHomeDirectory = base + "/UserHome"
            probe.overrideGlobalAgentsDir = base + "/EmptyAgents"
            probe.overrideGlobalDaemonsDir = base + "/EmptyDaemons"
            let scanned = probe.scanAll()
            guard let ghost = scanned.first(where: { $0.label == "com.demo.stuck" }) else { return false }
            guard ghost.status == .missingExecutable, ghost.status.isDangling else { return false }

            let res = probe.deleteOutcome([ghost], toTrash: false, journal: .none)
            guard res.cleanedCount == 0, res.freedBytes == 0 else {
                print("    ❌ 删除失败却记了 \(res.cleanedCount)/\(res.freedBytes)")
                return false
            }
            guard res.errorCount > 0, res.failed.count == 1 else { return false }
            // 批量入口同样不计数
            guard probe.cleanAllDangling(items: scanned).removedCount == 0 else { return false }
            guard localFM.fileExists(atPath: plistPath) else { return false }

            // 解除不可变标记后才计为成功（证明 0 不是"永远删不掉"）
            lchflags(plistPath, 0)
            let ok = probe.deleteOutcome([ghost], toTrash: false, journal: .none)
            guard ok.cleanedCount == 1, ok.errorCount == 0 else { return false }
            guard localFM.fileExists(atPath: plistPath) == false else { return false }
            return true
        }
    }
}
