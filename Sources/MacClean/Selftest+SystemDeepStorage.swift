import Foundation

// MARK: - 系统底层存储深度治理自检套件 (v1.48.0)

extension Selftest {
    static func suiteSystemDeepStorage() {
        print("==> 运行系统底层存储深度治理自检 (v1.48.0)...")

        // 1. APFS 本地快照输出解析
        check("底层存储深度：tmutil 本地快照输出文本解析与时间戳排序") {
            let mockOutput = """
            Snapshots for volume group /:
            com.apple.TimeMachine.2026-09-18-100000.local
            com.apple.TimeMachine.2026-09-19-153022.local
            com.apple.TimeMachine.2026-09-17-080000.local
            """

            let snapshots = SystemDeepStorageInspector.parseSnapshots(from: mockOutput, volume: "/")
            guard snapshots.count == 3 else { return false }

            // 验证按日期降序排列（最新排前）
            guard snapshots[0].dateString == "2026-09-19-153022" &&
                    snapshots[1].dateString == "2026-09-18-100000" &&
                    snapshots[2].dateString == "2026-09-17-080000" else {
                return false
            }

            guard snapshots[0].name == "com.apple.TimeMachine.2026-09-19-153022.local" else {
                return false
            }

            // 空输出容错
            let emptySnaps = SystemDeepStorageInspector.parseSnapshots(from: "", volume: "/")
            return emptySnaps.isEmpty
        }

        // 2. 休眠模式解析
        check("底层存储深度：pmset 输出中 hibernatemode 提取") {
            let mockPmset = """
            System-wide power settings:
            Currently in use:
             standbydelaylow      10800
             standby              1
             hibernatemode        3
             powernap             1
             gpuswitch            2
            """

            let mode3 = SystemDeepStorageInspector.parseHibernateMode(from: mockPmset)
            guard mode3 == 3 else { return false }

            let mockPmset0 = """
             hibernatemode        0
             sleep                10
            """
            let mode0 = SystemDeepStorageInspector.parseHibernateMode(from: mockPmset0)
            guard mode0 == 0 else { return false }

            let invalidPmset = "no hibernate mode in here"
            return SystemDeepStorageInspector.parseHibernateMode(from: invalidPmset) == nil
        }

        // 3. 休眠建议逻辑推导
        check("底层存储深度：休眠分析建议智能推导") {
            let infoMode0 = VMMemoryInfo(
                sleepimageExists: false,
                sleepimageSize: 0,
                hibernateMode: 0,
                isDesktopMac: false
            )
            guard infoMode0.suggestionText.contains("Mode 0") && infoMode0.suggestionText.contains("最省存储模式") else {
                return false
            }

            let infoDesktop = VMMemoryInfo(
                sleepimageExists: true,
                sleepimageSize: 16 * 1024 * 1024 * 1024,
                hibernateMode: 3,
                isDesktopMac: true
            )
            guard infoDesktop.suggestionText.contains("台式 Mac") && infoDesktop.suggestionText.contains("GB") else {
                return false
            }

            return true
        }

        // 4. 优化 Shell 脚本生成规范
        check("底层存储深度：休眠瘦身 Shell 脚本生成规范") {
            let script = SystemDeepStorageInspector.generateHibernateOptimizationScript(targetMode: 0)
            return script.contains("sudo pmset -a hibernatemode 0") &&
                script.contains("sudo rm -f /var/vm/sleepimage") &&
                script.contains("sudo chflags uchg /var/vm/sleepimage")
        }

        // 5. 真实宿主环境只读探查无崩溃
        check("底层存储深度：真实环境 inspectVMMemory 安全调用无崩溃") {
            // pmset 也必须走注入：自检里不启真实进程
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "Currently in use:\n hibernatemode 3\n")
            }
            let vm = SystemDeepStorageInspector.inspectVMMemory()
            return vm.swapFilesCount >= 0 && vm.totalSwapSize >= 0 && vm.hibernateMode == 3
        }

        // v1.74.0 安全加固自检 ----------------------------------------------

        // 6. tmutil 全部走 SafeProcess：清单读不到时不得报"没有快照"
        check("底层存储：tmutil 经 SafeProcess 执行且取证失败不报干净") {
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            var seen: [(String, [String])] = []

            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(
                    exitCode: 0,
                    output: "Snapshots for volume group /:\n"
                        + "com.apple.TimeMachine.2026-09-19-153022.local\n")
            }
            let ok = SystemDeepStorageInspector.snapshotInventory()
            guard ok.commandSucceeded, ok.isResultComplete, ok.snapshots.count == 1 else { return false }
            guard ok.incompletenessBanner == nil else { return false }
            guard let lastCall = seen.last,
                  lastCall == (SystemDeepStorageInspector.tmutilPath, ["listlocalsnapshots", "/"]) else {
                print("    ❌ 调的不是 tmutil listlocalsnapshots：<\(String(describing: seen.last))>")
                return false
            }

            // 非 0 退出（真机常见：需要管理员）→ 结论不完整，而不是"0 个快照"
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "getfsbyname ... Permission denied")
            }
            let denied = SystemDeepStorageInspector.snapshotInventory()
            guard denied.snapshots.isEmpty, !denied.commandSucceeded, !denied.isResultComplete else {
                print("    ❌ 命令失败被读成了「没有本地快照」")
                return false
            }
            guard denied.issues.first?.kind == .commandFailed else { return false }
            guard denied.incompletenessBanner?.contains("不完整") == true else { return false }
            // 兼容入口仍只给列表（调用方要区分就得用 snapshotInventory）
            guard SystemDeepStorageInspector.listLocalSnapshots().isEmpty else { return false }

            // 超时 / 进程没起来 / 工具不存在 → 三种"不知道"都不许说干净
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "", timedOut: true) }
            let timedOut = SystemDeepStorageInspector.snapshotInventory()
            guard !timedOut.isResultComplete, timedOut.issues.first?.kind == .commandFailed else { return false }
            SafeProcess.runner = { _, _, _ in nil }
            guard SystemDeepStorageInspector.snapshotInventory().issues.first?.kind == .commandFailed else { return false }

            let savedTool = SystemDeepStorageInspector.tmutilPath
            defer { SystemDeepStorageInspector.tmutilPath = savedTool }
            SystemDeepStorageInspector.tmutilPath = "/nonexistent/tmutil"
            let missing = SystemDeepStorageInspector.snapshotInventory()
            guard missing.issues.first?.kind == .toolUnavailable, !missing.isResultComplete else { return false }
            guard missing.incompletenessBanner?.contains("不完整") == true else { return false }
            return true
        }

        // 7. 逐条确认：没确认、不在清单里、形态异常的名字一个都不执行
        check("底层存储：快照删除只认用户逐条点名的合法快照") {
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            var deleteCalls: [[String]] = []
            SafeProcess.runner = { _, args, _ in
                if args.first == "deletelocalsnapshots" { deleteCalls.append(args) }
                return SafeProcess.Result(exitCode: 0, output: "Deleted snapshots")
            }
            let snap = APFSSnapshot(name: "com.apple.TimeMachine.2026-09-19-153022.local",
                                    dateString: "2026-09-19-153022")
            let known = [snap]

            // ① 没有用户确认 → 一条命令都不许发
            let unconfirmed = SystemDeepStorageInspector.deleteLocalSnapshots(
                known.map(\.name), confirmed: false, knownSnapshots: known)
            guard unconfirmed.succeededCount == 0, unconfirmed.skipped.count == 1 else { return false }
            guard deleteCalls.isEmpty else {
                print("    ❌ 未确认就执行了 tmutil deletelocalsnapshots")
                return false
            }
            guard unconfirmed.summary.contains("未执行") else { return false }
            // 单条入口同理
            let singleUnconfirmed = SystemDeepStorageInspector.deleteLocalSnapshot(
                snapshotName: snap.name, confirmed: false, knownSnapshots: known)
            guard singleUnconfirmed.success == false, deleteCalls.isEmpty else { return false }

            // ② 名字不在本轮清单里 → 拒（不认调用方随口给的名字）
            let forged = SystemDeepStorageInspector.deleteLocalSnapshots(
                ["com.apple.TimeMachine.1999-01-01-000000.local"], confirmed: true,
                knownSnapshots: known, verify: false)
            guard forged.succeededCount == 0, forged.skipped.count == 1, deleteCalls.isEmpty else { return false }

            // ③ 时间戳形态异常 → 绝不拼进命令行
            let weird = APFSSnapshot(name: "evil", dateString: "2026-09-19; rm -rf /")
            let injection = SystemDeepStorageInspector.deleteLocalSnapshots(
                ["evil"], confirmed: true, knownSnapshots: [weird], verify: false)
            guard injection.succeededCount == 0, injection.skipped.count == 1, deleteCalls.isEmpty else { return false }
            guard weird.hasValidDateSuffix == false else { return false }
            guard snap.hasValidDateSuffix else { return false }

            // ④ 合法且点名 → 恰好一条命令，参数只有那个日期后缀
            let res = SystemDeepStorageInspector.deleteLocalSnapshots(
                [snap.name], confirmed: true, knownSnapshots: known, verify: false)
            guard res.succeeded == [snap.name], res.failedCount == 0 else { return false }
            guard deleteCalls == [["deletelocalsnapshots", "2026-09-19-153022"]] else {
                print("    ❌ 参数不对：<\(deleteCalls)>")
                return false
            }
            return true
        }

        // 8. 命令返回 0 但快照仍在 → 不得报"已删除"
        check("底层存储：快照删除需复核，失败与超时一律不报已删除") {
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            let snap = APFSSnapshot(name: "com.apple.TimeMachine.2026-09-19-153022.local",
                                    dateString: "2026-09-19-153022")
            let listOutput = "com.apple.TimeMachine.2026-09-19-153022.local"

            // ① 删除命令返回 0，但重新取清单仍在 → 记失败
            SafeProcess.runner = { _, args, _ in
                if args.first == "listlocalsnapshots" {
                    return SafeProcess.Result(exitCode: 0, output: listOutput)
                }
                return SafeProcess.Result(exitCode: 0, output: "Deleted snapshots")
            }
            let still = SystemDeepStorageInspector.deleteLocalSnapshots(
                [snap.name], confirmed: true, knownSnapshots: [snap])
            guard still.succeededCount == 0, still.failedCount == 1 else {
                print("    ❌ 快照仍在清单里却报已删除")
                return false
            }
            guard still.failed.first?.message.contains("仍在清单") == true else { return false }
            let singleStill = SystemDeepStorageInspector.deleteLocalSnapshot(
                snapshotName: snap.name, confirmed: true, knownSnapshots: [snap])
            guard singleStill.success == false else { return false }

            // ② 复核后确实消失 → 才说已删除
            SafeProcess.runner = { _, args, _ in
                if args.first == "listlocalsnapshots" {
                    return SafeProcess.Result(exitCode: 0, output: "")
                }
                return SafeProcess.Result(exitCode: 0, output: "Deleted snapshots")
            }
            let gone = SystemDeepStorageInspector.deleteLocalSnapshots(
                [snap.name], confirmed: true, knownSnapshots: [snap])
            guard gone.succeeded == [snap.name], gone.summary.contains("复核") else { return false }

            // ③ 非 0 退出 / 超时 / 工具不存在 → 全部不报已删除
            SafeProcess.runner = { _, args, _ in
                if args.first == "listlocalsnapshots" { return SafeProcess.Result(exitCode: 0, output: "") }
                return SafeProcess.Result(exitCode: 1, output: "Operation not permitted")
            }
            let failed = SystemDeepStorageInspector.deleteLocalSnapshots(
                [snap.name], confirmed: true, knownSnapshots: [snap])
            guard failed.succeededCount == 0, failed.failed.first?.message.contains("退出码 1") == true else {
                return false
            }
            SafeProcess.runner = { _, args, _ in
                if args.first == "listlocalsnapshots" { return SafeProcess.Result(exitCode: 0, output: "") }
                return SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            let timeout = SystemDeepStorageInspector.deleteLocalSnapshots(
                [snap.name], confirmed: true, knownSnapshots: [snap])
            guard timeout.succeededCount == 0,
                  timeout.failed.first?.message.contains("结果未知") == true else { return false }

            let savedTool = SystemDeepStorageInspector.tmutilPath
            defer { SystemDeepStorageInspector.tmutilPath = savedTool }
            SystemDeepStorageInspector.tmutilPath = "/nonexistent/tmutil"
            let unavailable = SystemDeepStorageInspector.deleteLocalSnapshots(
                [snap.name], confirmed: true, knownSnapshots: [snap])
            guard unavailable.succeededCount == 0,
                  unavailable.failed.first?.message.contains("未执行删除") == true else { return false }
            return true
        }

        // 9. pmset 走 SafeProcess：读不到就不给建议，也不说"设置正常"
        check("底层存储：pmset 经 SafeProcess 执行且读不到时不给建议") {
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            var seen: [(String, [String], TimeInterval)] = []

            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 0, output: "Currently in use:\n hibernatemode 3\n")
            }
            let vm = SystemDeepStorageInspector.inspectVMMemory()
            guard vm.hibernateMode == 3, vm.isResultComplete || !vm.vmDirectoryReadable else { return false }
            guard seen.contains(where: {
                $0.0 == SystemDeepStorageInspector.pmsetPath && $0.1 == ["-g"] && $0.2 > 0
            }) else {
                print("    ❌ pmset 调用路径/参数/超时不符合预期：<\(String(describing: seen.last))>")
                return false
            }
            // /var/vm 由 root 管理：读不到时必须留下显式记录，而不是"0 个 / 0 B (无压力)"
            if !vm.vmDirectoryReadable {
                guard vm.issues.contains(where: { $0.kind == .permissionDenied }) else { return false }
                guard !vm.isResultComplete, vm.incompletenessBanner != nil else { return false }
            }

            // 命令失败 → hibernateMode 为 nil、结论不完整、建议改口
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 1, output: "") }
            let bad = SystemDeepStorageInspector.inspectVMMemory()
            guard bad.hibernateMode == nil else { return false }
            guard !bad.isResultComplete else {
                print("    ❌ pmset 失败被读成完整结论")
                return false
            }
            guard bad.suggestionText.contains("不提供任何修改建议") else { return false }
            // 也不得反过来暗示"设置正常"
            guard bad.suggestionText.contains("不代表睡眠设置正常") else {
                print("    ❌ 建议文案在证据不足时仍像下了结论")
                return false
            }

            // 输出里没有 hibernatemode 字段 → 同样是"不知道"
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "Current Power Source: AC")
            }
            let noField = SystemDeepStorageInspector.inspectVMMemory()
            guard noField.hibernateMode == nil,
                  noField.issues.contains(where: { $0.kind == .unreadable }) else { return false }

            // 工具不存在 → toolUnavailable
            let savedTool = SystemDeepStorageInspector.pmsetPath
            defer { SystemDeepStorageInspector.pmsetPath = savedTool }
            SystemDeepStorageInspector.pmsetPath = "/nonexistent/pmset"
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "hibernatemode 0") }
            let missing = SystemDeepStorageInspector.inspectVMMemory()
            guard missing.issues.contains(where: { $0.kind == .toolUnavailable }) else { return false }
            guard missing.hibernateMode == nil, !missing.isResultComplete else { return false }
            return true
        }

        // 10. /var/vm 与快照：G8 硬保护 + 本模块绝不代跑 sudo
        check("底层存储：休眠映像落在 G8 硬保护内且工具不代执行 sudo") {
            for path in ["/var/vm/sleepimage", "/private/var/vm/sleepimage",
                         "/private/var/vm/swapfile123"] {
                let verdict = FileSystem.governanceVerdict(path, domain: .systemCachesGlobal)
                guard case .rejected(let reason) = verdict, reason == .systemProtected else {
                    print("    ❌ \(path) 未被判为系统硬保护：\(verdict)")
                    return false
                }
                guard case .rejected(let homeReason) = FileSystem.governanceVerdictWithinHome(path),
                      homeReason == .systemProtected else { return false }
            }
            guard CleanPaths.systemProtected.contains("/private/var/vm") else { return false }

            // 生成脚本只是文本：不得顺手起进程
            let saved = SafeProcess.runner
            defer { SafeProcess.runner = saved }
            SafeProcess.runner = { path, args, _ in
                print("    ❌ 生成脚本时执行了真实命令：\(path) \(args)")
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            SafeProcess.resetInvokedCommands()
            let script = SystemDeepStorageInspector.generateHibernateOptimizationScript(targetMode: 0)
            guard SafeProcess.invokedCommands.isEmpty else { return false }
            // 代价与回退必须写在脚本里（不能只喊"释放数十 GB"）
            guard script.contains("sudo pmset -a hibernatemode 0"),
                  script.contains("代价提示"), script.contains("回退") else { return false }
            guard SystemDeepStorageInspector.hibernateRiskText.contains("丢失") else { return false }
            return true
        }
    }
}
