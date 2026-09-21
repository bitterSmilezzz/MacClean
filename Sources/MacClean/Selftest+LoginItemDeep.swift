import Foundation

// MARK: - 已卸载应用登录项与自启残存治理深度自检 (v1.67.0 · v1.73.0 加固)

extension Selftest {
    static func suiteLoginItemDeep() {
        print("--- [Suite] 已卸载应用登录项与自启残存治理深度自检 (v1.67.0) ---")

        // 1. 分类枚举与问题状态判定
        check("LoginItem: 分类枚举与问题状态判定") {
            guard LoginItemKind.launchAgent.icon == "person.crop.circle" else { return false }
            guard LoginItemKind.globalAgent.icon == "globe" else { return false }
            guard LoginItemKind.globalDaemon.icon == "gearshape.2" else { return false }

            guard LoginItemIssue.executableMissing.isOrphan == true else { return false }
            guard LoginItemIssue.validActive.isOrphan == false else { return false }
            // Apple 托管与"需确认"都不构成删除判据
            guard LoginItemIssue.appleManaged.isOrphan == false
                    && LoginItemIssue.needsReview.isOrphan == false else { return false }
            guard LoginItemIssue.executableMissing.providesDeletionEvidence else { return false }
            guard !LoginItemIssue.appleManaged.providesDeletionEvidence
                    && !LoginItemIssue.needsReview.providesDeletionEvidence
                    && !LoginItemIssue.validActive.providesDeletionEvidence else { return false }
            return true
        }

        // 2. 概要指标统计与容量精算
        check("LoginItem: 概要指标统计与容量精算") {
            let item1 = LoginItemEntry(id: "1", name: "app1", path: "/p1", targetPath: "/t1", kind: .launchAgent, issue: .executableMissing, size: 500, isSelected: true)
            let item2 = LoginItemEntry(id: "2", name: "app2", path: "/p2", targetPath: "/t2", kind: .globalAgent, issue: .executableMissing, size: 800, isSelected: true)
            let item3 = LoginItemEntry(id: "3", name: "app3", path: "/p3", targetPath: "/t3", kind: .launchAgent, issue: .validActive, size: 300, isSelected: false)

            let summary = LoginItemSummary(
                items: [item1, item2, item3],
                orphanCount: 2,
                totalSize: 1600,
                needsReviewCount: 1,
                rootManagedCount: 1
            )

            guard summary.totalSize == 1600 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.selectedSize == 1300 else { return false }
            guard summary.selectedCount == 2 else { return false }
            guard summary.needsReviewCount == 1 && summary.rootManagedCount == 1 else { return false }
            return true
        }

        // 3. Apple 官方服务保护防线
        check("LoginItem: Apple 官方服务保护防线") {
            // Apple 官方服务不判定为孤儿
            let inspection = LoginItemCleaner.inspectPlist(at: "/non_existent", name: "com.apple.metadata.mdworker")
            guard inspection.targetPath == nil, inspection.issue == .appleManaged else {
                print("    ❌ com.apple.* 标签未判为官方托管：\(inspection.issue.rawValue)")
                return false
            }
            guard inspection.issue.isOrphan == false else { return false }

            // 尝试清理 Apple 官方项应被拦截
            let appleItem = LoginItemEntry(
                id: "/tmp/com.apple.test.plist", name: "com.apple.test",
                path: "/tmp/com.apple.test.plist", targetPath: nil, kind: .launchAgent,
                issue: .validActive, size: 100, isSelected: true
            )
            let resApple = LoginItemCleaner.shared.clean(items: [appleItem], toTrash: true, journal: .none)
            guard resApple.cleanedCount == 0 && resApple.errorCount > 0 else { return false }

            // 尝试清理系统目录应被拦截
            let sysItem = LoginItemEntry(
                id: "/System/Library/LaunchDaemons/sys.plist", name: "sys",
                path: "/System/Library/LaunchDaemons/sys.plist", targetPath: nil, kind: .globalDaemon,
                issue: .validActive, size: 100, isSelected: true
            )
            let resSys = LoginItemCleaner.shared.clean(items: [sysItem], toTrash: true, journal: .none)
            guard resSys.cleanedCount == 0 && resSys.errorCount > 0 else { return false }
            return true
        }

        // 4. 模拟 LaunchAgent plist 解析与死链检测
        check("LoginItem: 模拟 LaunchAgent plist 解析与死链检测") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Scan"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let plistPath = (testDir as NSString).appendingPathComponent("com.example.ghosthelper.plist")
            let missingAppPath = "/Applications/NonExistentTestApp_12345.app/Contents/MacOS/helper"

            let plistContent: [String: Any] = [
                "Label": "com.example.ghosthelper",
                "Program": missingAppPath,
                "RunAtLoad": true
            ]
            let plistData = try? PropertyListSerialization.data(fromPropertyList: plistContent, format: .xml, options: 0)
            try? plistData?.write(to: URL(fileURLWithPath: plistPath))

            let summary = LoginItemCleaner.shared.scan(customDirectories: [
                .launchAgent: [testDir]
            ])

            guard summary.items.count == 1 else { return false }
            guard summary.orphanCount == 1 else { return false }

            let item = summary.items.first
            guard let item, item.issue == .executableMissing, item.targetPath == missingAppPath,
                  item.isSelected == true else { return false }
            // label 被保留下来，供"删除成功后再卸载"寻址
            guard item.serviceLabel == "com.example.ghosthelper" else { return false }
            return true
        }

        // 5. 模拟死链启动项安全清理核验
        check("LoginItem: 模拟死链启动项安全清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let p1 = (testDir as NSString).appendingPathComponent("com.test.dangling.plist")
            let payload = "dummy_plist".data(using: .utf8)!
            try? payload.write(to: URL(fileURLWithPath: p1))

            let item = LoginItemEntry(
                id: p1, name: "com.test.dangling", path: p1,
                targetPath: "/NonExistent", kind: .launchAgent, issue: .executableMissing,
                size: Int64(payload.count), isSelected: true, serviceLabel: "com.test.dangling"
            )

            let savedRunner = SafeProcess.runner
            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            defer { SafeProcess.runner = savedRunner }

            let res = LoginItemCleaner.shared.clean(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 1 && res.freedBytes == Int64(payload.count) && res.errorCount == 0 else {
                print("    ❌ cleaned=\(res.cleanedCount) freed=\(res.freedBytes) errors=\(res.errorCount)")
                return false
            }
            guard !fm.fileExists(atPath: p1) else { return false }
            // 删除成功 → 才允许碰 launchd
            guard res.unloadResults.count == 1, res.unloadResults.first?.succeeded == true else { return false }
            return true
        }

        // 6. 空目录与非法路径鲁棒性断言
        check("LoginItem: 空目录与非法路径鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Empty"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let summary = LoginItemCleaner.shared.scan(customDirectories: [
                .launchAgent: [testDir, "/non_existent_folder_path"]
            ])

            guard summary.items.isEmpty && summary.orphanCount == 0 else { return false }
            return true
        }

        // ── v1.73.0 安全加固 ──

        // 7. 白名单按**真实可执行路径**判定（旧实现拿文件名比前缀，是死代码）
        check("LoginItem: 死代码白名单修复——按 Program/ProgramArguments 解析的真实路径判托管") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Apple"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            func write(_ label: String, _ body: [String: Any]) -> String {
                let path = testDir + "/\(label).plist"
                let data = try? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                try? data?.write(to: URL(fileURLWithPath: path))
                return path
            }

            // ① Program 指向 /System/Library —— 真实路径命中，判 Apple 托管、不判孤儿
            let sysPath = write("SystemLibraryGhost", [
                "Label": "SystemLibraryGhost",
                "Program": "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            ])
            let sysInspection = LoginItemCleaner.inspectPlist(at: sysPath, name: "SystemLibraryGhost")
            guard sysInspection.issue == .appleManaged, !sysInspection.issue.isOrphan else {
                print("    ❌ /System/Library 托管项被判成 \(sysInspection.issue.rawValue)")
                return false
            }

            // ② ProgramArguments[0] 指向 /usr/libexec —— 同样命中
            let execPath = write("LibexecGhost", [
                "Label": "LibexecGhost",
                "ProgramArguments": ["/usr/libexec/xpcproxy", "com.apple.x"],
            ])
            let execInspection = LoginItemCleaner.inspectPlist(at: execPath, name: "LibexecGhost")
            guard execInspection.issue == .appleManaged,
                  execInspection.targetPath == "/usr/libexec/xpcproxy" else { return false }

            // ③ 裸命令名解析到 /bin —— 也判托管（旧实现：文件名不含前缀 → 死代码不命中）
            let barePath = write("BareGhost", ["Label": "BareGhost", "Program": "launchctl"])
            let bareInspection = LoginItemCleaner.inspectPlist(at: barePath, name: "BareGhost")
            guard bareInspection.issue == .appleManaged,
                  bareInspection.targetPath == "/bin/launchctl" else {
                print("    ❌ 裸命令未解析/未判托管: \(bareInspection.targetPath ?? "nil")")
                return false
            }

            // ④ 裸命令解析不出来 → 需确认，**不是**孤儿（读不到 ≠ 可以删）
            let unknownPath = write("UnknownGhost", ["Label": "UnknownGhost", "Program": "definitely-not-a-command-9x7"])
            let unknownInspection = LoginItemCleaner.inspectPlist(at: unknownPath, name: "UnknownGhost")
            guard unknownInspection.issue == .needsReview, !unknownInspection.issue.isOrphan else { return false }

            // ⑤ 非 plist / 缺 Program → 需确认而不是孤儿
            let emptyPath = write("NoProgram", ["Label": "NoProgram", "RunAtLoad": true])
            guard LoginItemCleaner.inspectPlist(at: emptyPath, name: "NoProgram").issue == .needsReview else { return false }
            guard LoginItemCleaner.inspectPlist(at: testDir + "/missing.plist", name: "Missing").issue == .needsReview else { return false }

            // ⑥ 即使调用方伪造 issue=.executableMissing，删除判据也必须按真实路径挡住
            let forged = LoginItemEntry(
                id: execPath, name: "LibexecGhost", path: execPath,
                targetPath: "/usr/libexec/xpcproxy", kind: .launchAgent,
                issue: .executableMissing, size: 100, isSelected: true)
            let res = LoginItemCleaner.shared.clean(items: [forged], toTrash: false, journal: .none)
            guard res.cleanedCount == 0 && res.errorCount > 0 else { return false }
            guard res.gate.rejected.first?.message.contains("Apple 托管") == true else { return false }
            guard fm.fileExists(atPath: execPath) else { return false }
            // 前缀判定作用于可执行路径而不是文件名
            guard LoginItemCleaner.appleManagedExecutable("/System/Library/Foo"),
                  LoginItemCleaner.appleManagedExecutable("/usr/libexec/foo"),
                  !LoginItemCleaner.appleManagedExecutable("/opt/homebrew/bin/foo"),
                  !LoginItemCleaner.appleManagedExecutable("/usr/local/bin/foo") else { return false }
            return true
        }

        // 8. 顺序即安全：先删成功再 unload；删除被拦/失败就完全不碰 launchd
        check("LoginItem: 删除成功才 bootout，被拦项绝不调用 launchctl") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Order"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let savedRunner = SafeProcess.runner
            let savedLaunchctl = LoginItemCleaner.launchctlPath
            defer {
                SafeProcess.runner = savedRunner
                LoginItemCleaner.launchctlPath = savedLaunchctl
            }
            LoginItemCleaner.launchctlPath = "/bin/launchctl"
            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }

            // ① 只有被拦项：一条 launchctl 都不许调（旧实现是先 unload 再删，顺序反了）
            let blockedOnly = [
                LoginItemEntry(id: "/System/Library/LaunchDaemons/x.plist", name: "x",
                               path: "/System/Library/LaunchDaemons/x.plist", targetPath: "/nope",
                               kind: .globalDaemon, issue: .executableMissing, size: 10, isSelected: true),
                LoginItemEntry(id: NSHomeDirectory() + "/Library/Mail/V9/y.plist", name: "y",
                               path: NSHomeDirectory() + "/Library/Mail/V9/y.plist", targetPath: "/nope",
                               kind: .launchAgent, issue: .executableMissing, size: 10, isSelected: true),
            ]
            let resBlocked = LoginItemCleaner.shared.clean(items: blockedOnly, toTrash: false, journal: .none)
            guard resBlocked.cleanedCount == 0 && resBlocked.errorCount == 2 else { return false }
            guard seen.isEmpty else {
                print("    ❌ 删除未成功仍调用了 launchctl: \(seen)")
                return false
            }
            guard resBlocked.unloadResults.isEmpty else { return false }

            // ② 真删成功后：按 gui/<uid>/<label> 卸载，且**不带** -w（不再永久写禁用）
            let plistPath = testDir + "/com.example.removed.plist"
            let data = try? PropertyListSerialization.data(
                fromPropertyList: ["Label": "com.example.removed", "Program": "/Applications/Ghost.app/x"],
                format: .xml, options: 0)
            try? data?.write(to: URL(fileURLWithPath: plistPath))
            let scanned = LoginItemCleaner.shared.scan(customDirectories: [.launchAgent: [testDir]])
            guard let entry = scanned.items.first, entry.issue.isOrphan, entry.isSelected else { return false }
            let resOK = LoginItemCleaner.shared.clean(items: [entry], toTrash: false, journal: .none)
            guard resOK.cleanedCount == 1, !fm.fileExists(atPath: plistPath) else { return false }
            guard seen.count == 1, seen.first?.0 == "/bin/launchctl" else {
                print("    ❌ launchctl 调用不符: \(seen)")
                return false
            }
            let uid = getuid()
            guard seen.first?.1 == ["bootout", "gui/\(uid)/com.example.removed"] else {
                print("    ❌ 卸载参数不符: \(seen.first?.1 ?? [])")
                return false
            }
            guard seen.first?.1.contains("-w") == false else { return false }
            guard resOK.unloadResults.first?.succeeded == true, resOK.errorCount == 0 else { return false }

            // ③ bootout 失败：文件已删但必须如实报出，不能"看起来全好"
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 5, output: "Could not find service in domain")
            }
            let plist2 = testDir + "/com.example.fail.plist"
            try? "<plist><dict><key>Label</key><string>com.example.fail</string></dict></plist>"
                .data(using: .utf8)?.write(to: URL(fileURLWithPath: plist2))
            let entry2 = LoginItemEntry(id: plist2, name: "com.example.fail", path: plist2,
                                        targetPath: "/Applications/Ghost.app/x", kind: .launchAgent,
                                        issue: .executableMissing, size: 40, isSelected: true,
                                        serviceLabel: "com.example.fail")
            let resFail = LoginItemCleaner.shared.clean(items: [entry2], toTrash: false, journal: .none)
            guard resFail.cleanedCount == 1 else { return false }
            guard resFail.errorCount == 1, resFail.unloadWarnings.count == 1 else {
                print("    ❌ 卸载失败未被计入: errors=\(resFail.errorCount)")
                return false
            }
            guard resFail.unloadWarnings.first?.contains("launchd 卸载失败") == true else { return false }
            return true
        }

        // 9. 全局自启目录声明治理域；root 只读位置如实上报 needsPrivilege
        check("LoginItem: /Library/Launch* 声明治理域且 root 只读项不得被删") {
            let home = FileSystem.normalizePath(NSHomeDirectory())
            guard LoginItemCleaner.governanceDomain(forPath: "/Library/LaunchAgents/a.plist") == .launchAgentsGlobal else { return false }
            guard LoginItemCleaner.governanceDomain(forPath: "/Library/LaunchDaemons/b.plist") == .launchDaemonsGlobal else { return false }
            guard LoginItemCleaner.governanceDomain(forPath: "\(home)/Library/LaunchAgents/c.plist") == nil else { return false }
            guard LoginItemCleaner.governanceDomain(forPath: "/System/Library/LaunchDaemons/d.plist") == nil else { return false }
            // 两个域都必须在登记表里（否则网关无从裁决）
            guard GovernanceDomain.byID["launchagents.global"]?.root == "/Library/LaunchAgents",
                  GovernanceDomain.byID["launchdaemons.global"]?.root == "/Library/LaunchDaemons" else { return false }

            // 真实 root 只读位置：拿一个已存在的 plist 走网关，必须被 needsPrivilege 拦下
            let agentsDir = "/Library/LaunchAgents"
            let plists = ((try? FileManager.default.contentsOfDirectory(atPath: agentsDir)) ?? [])
                .filter { $0.hasSuffix(".plist") }.sorted()
            guard let first = plists.first else {
                print("    ⚠️ /Library/LaunchAgents 为空，跳过真机权限断言")
                return true
            }
            let realPath = agentsDir + "/" + first
            // 用中性名字，避免真实 label 是 com.apple.* 时被模块判据先挡掉、测不到网关的提权结论
            let entry = LoginItemEntry(id: realPath, name: "selftest.probe", path: realPath,
                                       targetPath: "/nonexistent-ghost",
                                       kind: .globalAgent, issue: .executableMissing,
                                       size: 100, isSelected: true, serviceLabel: "selftest.probe")
            let savedRunner = SafeProcess.runner
            var launchCalls = 0
            SafeProcess.runner = { _, _, _ in launchCalls += 1
                return SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let res = LoginItemCleaner.shared.clean(items: [entry], toTrash: false, journal: .none)
            guard res.cleanedCount == 0, res.gate.rejected.first?.reason == .needsPrivilege else {
                print("    ❌ root 只读项未被判 needsPrivilege: \(res.gate.rejected.map { $0.reason })")
                return false
            }
            guard res.needsPrivilege.count == 1,
                  res.needsPrivilege.first?.message.contains("root") == true else { return false }
            guard launchCalls == 0 else { return false }
            guard FileManager.default.fileExists(atPath: realPath) else { return false }
            // 扫描阶段也不该替用户预选这类注定失败的勾
            let scanned = LoginItemCleaner.shared.scan(customDirectories: [.globalAgent: [agentsDir]])
            guard scanned.rootManagedCount == scanned.items.count,
                  scanned.items.allSatisfy({ !$0.isSelected }),
                  scanned.items.allSatisfy({ ($0.note ?? "").contains("不提权") }) else { return false }
            return true
        }

        // 10. 软链跳板：LaunchAgents 里指向系统位置的软链必被拒，且不碰 launchd
        check("LoginItem: 自启目录软链跳板被网关拒绝且未调用 launchctl") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Link"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir + "/agents", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: testDir + "/outside", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let victim = testDir + "/outside/real.plist"
            try? "real".data(using: .utf8)?.write(to: URL(fileURLWithPath: victim))
            let link = testDir + "/agents/com.example.escape.plist"
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: victim)

            let savedRunner = SafeProcess.runner
            var launchCalls = 0
            SafeProcess.runner = { _, _, _ in launchCalls += 1
                return SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let entry = LoginItemEntry(id: link, name: "com.example.escape", path: link,
                                       targetPath: "/nonexistent-ghost", kind: .launchAgent,
                                       issue: .executableMissing, size: 4, isSelected: true,
                                       serviceLabel: "com.example.escape")
            let res = LoginItemCleaner.shared.clean(items: [entry], toTrash: false, journal: .none)
            guard res.cleanedCount == 0, res.errorCount == 1 else { return false }
            guard res.gate.rejected.first?.reason == .symlinkJump else {
                print("    ❌ 未按软链跳板拒绝: \(res.gate.rejected.map { $0.reason })")
                return false
            }
            guard launchCalls == 0 else { return false }
            guard fm.fileExists(atPath: victim), fm.fileExists(atPath: link) else { return false }
            return true
        }

        // 11. 白名单 / G6 硬排除在登录项模块下必被拒，且一条 launchd 命令都不发
        check("LoginItem: 白名单与硬排除自启项必被拦下且文件完好") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir + "/protected", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let wm = WhitelistManager.shared
            wm.removeAllRules()
            defer { wm.removeAllRules() }

            let keep = testDir + "/protected/com.keep.me.plist"
            try? "keep".data(using: .utf8)?.write(to: URL(fileURLWithPath: keep))
            wm.addPathRule(testDir + "/protected", comment: "自启项网关自检")

            let targets: [(String, String)] = [
                ("com.keep.me", keep),
                ("com.mail.host", NSHomeDirectory() + "/Library/Mail/V9/com.mail.host.plist"),
                ("sys.daemon", "/System/Library/LaunchDaemons/com.apple.sys.plist"),
            ]
            let entries = targets.map { name, path in
                LoginItemEntry(id: path, name: name, path: path, targetPath: "/nonexistent-ghost",
                               kind: .launchAgent, issue: .executableMissing, size: 4, isSelected: true,
                               serviceLabel: name)
            }
            let savedRunner = SafeProcess.runner
            var launchCalls = 0
            SafeProcess.runner = { _, _, _ in launchCalls += 1
                return SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let res = LoginItemCleaner.shared.clean(items: entries, toTrash: false, journal: .none)
            guard res.errorCount > 0 && res.cleanedCount == 0 && res.freedBytes == 0 else { return false }
            let reasons = Set(res.gate.rejected.map { $0.reason })
            guard reasons.contains(.userWhitelisted) || reasons.contains(.hardExcluded) else {
                print("    ❌ 未见白名单/硬排除拒绝原因: \(res.gate.rejected.map { $0.reason })")
                return false
            }
            guard reasons.contains(.systemProtected) else { return false }
            guard launchCalls == 0 else { return false }
            guard fm.fileExists(atPath: keep) else { return false }
            return true
        }

        // 12. 删除失败/目标不存在不计入 cleanedCount 与 freedBytes
        check("LoginItem: 目标不存在不计入清理数与释放量") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_LoginItem_Partial"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let savedRunner = SafeProcess.runner
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            defer { SafeProcess.runner = savedRunner }

            let ghost = testDir + "/com.ghost.gone.plist"
            try? "abc".data(using: .utf8)?.write(to: URL(fileURLWithPath: ghost))
            let live = testDir + "/com.ghost.live.plist"
            try? "abcdef".data(using: .utf8)?.write(to: URL(fileURLWithPath: live))
            // 扫描之后、删除之前就消失的文件：不得按扫描时的 size 记账
            try? fm.removeItem(atPath: ghost)

            let ghostEntry = LoginItemEntry(id: ghost, name: "com.ghost.gone", path: ghost,
                                            targetPath: "/nope", kind: .launchAgent,
                                            issue: .executableMissing, size: 4096, isSelected: true,
                                            serviceLabel: "com.ghost.gone")
            let liveEntry = LoginItemEntry(id: live, name: "com.ghost.live", path: live,
                                           targetPath: "/nope", kind: .launchAgent,
                                           issue: .executableMissing, size: 4096, isSelected: true,
                                           serviceLabel: "com.ghost.live")
            let res = LoginItemCleaner.shared.clean(items: [ghostEntry, liveEntry], toTrash: false, journal: .none)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == 6 else {
                print("    ❌ 释放量应为删除前实测的 6 字节，实际 \(res.freedBytes)")
                return false
            }
            guard res.errorCount == 1, res.gate.rejected.first?.reason == .missing else { return false }
            // 只对被真正删掉的那一项发卸载命令
            guard res.unloadResults.count == 1, res.unloadResults.first?.label == "com.ghost.live" else { return false }
            return true
        }
    }
}
