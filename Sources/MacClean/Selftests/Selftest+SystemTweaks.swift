import Foundation

// 自检套件：系统体验优化（读 / 写 / 还原）
//
// 这是本仓库的第一种"非删除类副作用"——它不删文件，而是改系统偏好。
// 所以这一套盯的不是路径安全，而是**三件同样致命的事**：
//
//   ① **"没看到"不许当成"没设过"**：读失败与键不存在是两个状态，
//      混在一起写进撤销记录，还原时会把一个本来有值的键删掉；
//   ② **读不到旧值就绝不写**：没有旧值就没有真的撤销，宁可什么都不发生；
//   ③ **"原本没设过"必须还原成删键**，而不是写一个看起来像默认值的数。
//
// 所有确定性用例都通过 `SafeProcess.runner` 注入假的 `defaults`，
// 自检**不会真的改这台机器的任何设置**。只有最后一条做真机**只读**体检，
// 并断言它一条写命令都没发出去。
extension Selftest {
    static func suiteSystemTweaks() {

        /// 装一个假的 `defaults`：按参数决定输出与退出码，并可记录调用序列。
        /// 非 `defaults` 的命令一律返回成功空输出（本套件不关心别的进程）。
        func withFakeDefaults(_ handler: @escaping ([String]) -> SafeProcess.Result?,
                              _ body: () -> Bool) -> Bool {
            let saved = SafeProcess.runner
            SafeProcess.runner = { path, args, _ in
                guard path.hasSuffix("defaults") else {
                    return SafeProcess.Result(exitCode: 0, output: "")
                }
                return handler(args)
            }
            defer { SafeProcess.runner = saved }
            return body()
        }

        func ok(_ output: String) -> SafeProcess.Result {
            SafeProcess.Result(exitCode: 0, output: output)
        }
        func fail(_ output: String = "") -> SafeProcess.Result {
            SafeProcess.Result(exitCode: 1, output: output)
        }

        check("值解析：布尔 0/1 与 true/false 都认，字符串去引号，解析不了就返回 nil") {
            guard TweakValue.parse(raw: "1", kind: .bool) == .bool(true),
                  TweakValue.parse(raw: "0", kind: .bool) == .bool(false),
                  TweakValue.parse(raw: "true", kind: .bool) == .bool(true),
                  TweakValue.parse(raw: "NO", kind: .bool) == .bool(false),
                  TweakValue.parse(raw: "2\n", kind: .int) == .int(2),
                  TweakValue.parse(raw: "\"scale\"\n", kind: .string) == .string("scale"),
                  TweakValue.parse(raw: "SCcf", kind: .string) == .string("SCcf") else { return false }
            // 解析不了必须是 nil，不许悄悄退化成某个默认值
            guard TweakValue.parse(raw: "maybe", kind: .bool) == nil,
                  TweakValue.parse(raw: "abc", kind: .int) == nil,
                  TweakValue.parse(raw: "   ", kind: .string) == nil else { return false }
            return true
        }

        check("「未设置」与「等于 0」必须是两个不同的状态") {
            // 混成一个的后果：撤销时会把"原本没设过"的键写上一个 0，
            // 或者把"原本就是 0"的键删掉——两种都是伪造历史。
            guard TweakValue.parse(raw: "0", kind: .int) == .int(0) else { return false }
            guard TweakValue.parse(raw: "0", kind: .int) != TweakValue.unset else { return false }
            guard TweakValue.parse(raw: "0", kind: .bool) != TweakValue.unset else { return false }
            // 展示文案也必须不同，否则用户分不清
            return TweakValue.unset.display != TweakValue.int(0).display
                && TweakValue.unset.display.contains("未设置")
        }

        check("体检结论：已推荐 / 偏离 / 读不到 三态互斥，且读不到不许猜") {
            let rec = TweakValue.bool(true)
            guard TweakFinding.status(current: .bool(true), recommended: rec) == .alreadyOptimal,
                  TweakFinding.status(current: .bool(false), recommended: rec) == .deviates,
                  // 未设置 → 偏离（工具不知道各 App 的默认值，不能替系统断言）
                  TweakFinding.status(current: .unset, recommended: rec) == .deviates,
                  // 读失败 → 读不到：既不说它要改，也不说它没问题
                  TweakFinding.status(current: nil, recommended: rec) == .unreadable else { return false }
            return true
        }

        check("目录完备性：id 唯一、domain/key 非空且 key 不含点、收益与代价都要写、kind 与推荐值同型") {
            var bad: [String] = []
            var seen = Set<String>()
            for tweak in SystemTweak.catalog {
                if !seen.insert(tweak.id).inserted { bad.append("\(tweak.id)：id 重复") }
                if tweak.domain.isEmpty || tweak.key.isEmpty { bad.append("\(tweak.id)：domain/key 为空") }
                // `defaults` 会把 key 里的点当成容器路径，写下去会落到别的地方
                if tweak.key.contains(".") { bad.append("\(tweak.id)：key 含点（defaults 会当容器路径）") }
                if tweak.benefit.trimmingCharacters(in: .whitespaces).isEmpty { bad.append("\(tweak.id)：没写收益") }
                if tweak.tradeoff.trimmingCharacters(in: .whitespaces).isEmpty { bad.append("\(tweak.id)：没写代价") }
                let sameType: Bool
                switch (tweak.kind, tweak.recommended) {
                case (.bool, .bool), (.int, .int), (.string, .string): sameType = true
                default: sameType = false
                }
                if !sameType { bad.append("\(tweak.id)：kind 与推荐值不同型") }
                // `defaults write` 的参数必须与类型一致，否则写下去的是个错类型的值
                if tweak.recommended != .unset {
                    let flag = tweak.recommended.writeArguments.first ?? ""
                    let expected = ["-bool", "-int", "-string"][["bool", "int", "string"].firstIndex(of: tweak.kind.rawValue) ?? 0]
                    if flag != expected { bad.append("\(tweak.id)：write 参数与类型不匹配（\(flag)）") }
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("读路径：键不存在 → .unset；命令根本起不来 → 读失败（nil），两者不许混") {
            let tweak = SystemTweak.catalog[0]
            let missing = withFakeDefaults({ _ in fail("The domain/default pair of (x, y) does not exist") }) {
                SystemTweakStore.read(tweak) == .unset
            }
            guard missing else { return false }
            // runner 返回 nil = 进程起不来。这时**必须**返回 nil（读失败），
            // 绝不能退化成 .unset——那会把"没看到"写成"没设过"。
            let unavailable = withFakeDefaults({ _ in nil }) {
                SystemTweakStore.read(tweak) == nil
            }
            return unavailable
        }

        check("读路径：三种「不存在」文案都要认（键/域/旧版本各一句），认不出的必须当读失败") {
            // 这三句都是真机上一条条量出来的，不是编的：
            //   旧版 macOS 键不存在：The domain/default pair of (...) does not exist
            //   macOS 27  键不存在：Error: Could not find key 'x' in domain 'y'.
            //   macOS 27  **域**不存在：Error: Domain 'y' not found.
            // 漏掉任何一句的后果都是同一种、而且很安静：所有"未设置"的键被显示成「读不到」，
            // 而"读不到"要求**拒绝写**，于是这个功能对绝大部分键根本用不了。
            // 第三句是 `--prefs-roundtrip` 真机跑出来的（域不存在的那一步）。
            let tweak = SystemTweak.catalog[0]
            let oldStyle = withFakeDefaults({ _ in
                fail("The domain/default pair of (com.apple.dock, show-recents) does not exist")
            }) { SystemTweakStore.read(tweak) == .unset }
            let newStyle = withFakeDefaults({ _ in
                fail("Error: Could not find key 'show-recents' in domain 'com.apple.dock'.")
            }) { SystemTweakStore.read(tweak) == .unset }
            let domainStyle = withFakeDefaults({ _ in
                fail("Error: Domain 'com.example.nope' not found.")
            }) { SystemTweakStore.read(tweak) == .unset }
            guard oldStyle, newStyle, domainStyle else {
                print("      三句「不存在」文案没有都被识别（旧=\(oldStyle) 新=\(newStyle) 域=\(domainStyle)）")
                return false
            }
            // 反方向：真正的失败（权限、执行错误）绝不能被当成"不存在"——
            // 那会写出一条假的撤销记录，将来还原时把一个有值的键删掉。
            let realFailure = withFakeDefaults({ _ in
                fail("Could not write to the domain because of a permission problem")
            }) { SystemTweakStore.read(tweak) == nil }
            return realFailure
        }

        check("安全底线：读不到旧值就绝不发写命令") {
            let tweak = SystemTweak.catalog[0]
            return withFakeDefaults({ _ in nil }) {
                SafeProcess.resetInvokedCommands()
                let outcome = SystemTweakStore.apply(tweak)
                guard outcome == .refusedReadingFailed else {
                    print("      读失败却继续写了：\(outcome)")
                    return false
                }
                // 一条 write / delete 都不许出现
                let writes = SafeProcess.invokedCommands.filter {
                    $0.args.first == "write" || $0.args.first == "delete"
                }
                if !writes.isEmpty {
                    print("      读失败却发了 \(writes.count) 条写命令")
                    return false
                }
                return true
            }
        }

        check("安全底线：撤销记录落不了盘就绝不写（宁可什么都没发生）") {
            let tweak = SystemTweak.catalog[0]
            let savedEnv = ProcessInfo.processInfo.environment["MACCLEAN_STATE_DIR"]
            // 指向一个必然创建失败的路径（/dev/null 下面是文件不是目录）
            setenv("MACCLEAN_STATE_DIR", "/dev/null/macclean-nope", 1)
            defer {
                if let savedEnv { setenv("MACCLEAN_STATE_DIR", savedEnv, 1) }
                else { unsetenv("MACCLEAN_STATE_DIR") }
            }
            return withFakeDefaults({ args in
                args.first == "read" ? ok("1") : ok("")
            }) {
                SafeProcess.resetInvokedCommands()
                let outcome = SystemTweakStore.apply(tweak)
                guard outcome == .refusedUndoNotPersisted else {
                    print("      撤销记录落盘失败却继续写了：\(outcome)")
                    return false
                }
                let writes = SafeProcess.invokedCommands.filter {
                    $0.args.first == "write" || $0.args.first == "delete"
                }
                if !writes.isEmpty {
                    print("      撤销记录没落盘却发了 \(writes.count) 条写命令")
                    return false
                }
                return true
            }
        }

        check("写入顺序：先读旧值 → 落撤销记录 → 才写；失败要把记录撤掉") {
            let tweak = SystemTweak.catalog[0]   // dock.show-recents，bool
            SystemTweakStore.resetRecordsForSelftest()
            var order: [String] = []
            // ① 成功路径：读 → 写，记录里 previous == 读到的值
            let applied = withFakeDefaults({ args in
                order.append(args.first ?? "")
                return args.first == "read" ? ok("1") : ok("")
            }) {
                if case .applied(let record) = SystemTweakStore.apply(tweak) {
                    return record.previous == .bool(true)
                        && record.domain == tweak.domain
                        && record.key == tweak.key
                }
                return false
            }
            guard applied else { print("      成功路径没走通"); return false }
            guard order == ["read", "write"] else {
                print("      命令顺序不对：\(order)（必须先用 read 拿到旧值）")
                return false
            }
            guard SystemTweakStore.loadRecords()?.count == 1 else {
                print("      撤销记录没落盘")
                return false
            }
            // ② 写失败：刚落的记录必须被撤掉，不许留一条"没发生过的改动"
            SystemTweakStore.resetRecordsForSelftest()
            SafeProcess.resetInvokedCommands()
            let writeFails = withFakeDefaults({ args in
                args.first == "read" ? ok("1") : fail("could not write")
            }) {
                SystemTweakStore.apply(tweak) == .writeFailed
            }
            guard writeFails else {
                print("      写失败没有被如实报出；命令序列=\(order)")
                return false
            }
            let remaining = SystemTweakStore.loadRecords()
            guard remaining?.isEmpty == true else {
                print("      写失败后仍留着 \(remaining?.count ?? -1) 条撤销记录"
                      + "；命令=\(SafeProcess.invokedCommands.map { $0.args.first ?? "?" })")
                return false
            }
            return true
        }

        check("撤销记录必须能原样读回来（编解码策略成对）") {
            // 踩过的坑：**写**的时候用 `.iso8601` 编码 Date，**读**的时候图省事用
            // `JSONDecoder()` 的默认策略（把 Date 当 double）——`.iso8601` 的字符串
            // 解不成 Date，于是**整份撤销记录永远读不回来**，撤销功能静默失效，
            // 而调用方只看到"没有记录"。
            // 所以这里做一次真正的往返：写进去 → 读出来 → 逐字段比对。
            let tweak = SystemTweak.catalog[1]   // dock.mineffect（字符串型）
            SystemTweakStore.resetRecordsForSelftest()
            var outcome: SystemTweakStore.ApplyOutcome?
            _ = withFakeDefaults({ args in
                args.first == "read" ? ok("genie") : ok("")
            }) {
                outcome = SystemTweakStore.apply(tweak)
                return true
            }
            guard let outcome, case .applied(let written) = outcome else {
                print("      应用没走通：\(String(describing: outcome))")
                return false
            }
            guard let loaded = SystemTweakStore.loadRecords(), loaded.count == 1,
                  let back = loaded.first else {
                print("      记录写进去却读不回来（编解码策略不成对？）")
                return false
            }
            guard back.id == written.id,
                  back.previous == .string("genie"),
                  back.domain == tweak.domain,
                  back.key == tweak.key,
                  back.kind == .string else {
                print("      读回来的记录与写入的不一致：\(back)")
                return false
            }
            return abs(back.appliedAt.timeIntervalSince(written.appliedAt)) < 1
        }

        check("还原语义：「原本没设过」必须是删键，而且目标已达成时不算失败") {
            let tweak = SystemTweak.catalog[0]
            SystemTweakStore.resetRecordsForSelftest()
            // ① 旧值是"未设置"，且现在键仍然不存在 → 目标已达成：不发命令也算还原成功
            let alreadyGone = ChangeRecordFixture(domain: tweak.domain, key: tweak.key,
                                                  kind: tweak.kind, previous: .unset)
            let okWhenAbsent = withFakeDefaults({ args in
                args.first == "read" ? fail("does not exist") : ok("")
            }) {
                SafeProcess.resetInvokedCommands()
                guard SystemTweakStore.revert(alreadyGone) else { return false }
                let deletes = SafeProcess.invokedCommands.filter { $0.args.first == "delete" }
                return deletes.isEmpty
            }
            guard okWhenAbsent else { print("      键已不存在时还原被误判为失败"); return false }
            // ② 旧值是"未设置"，但现在键有值 → 必须真的发 delete
            let needDelete = ChangeRecordFixture(domain: tweak.domain, key: tweak.key,
                                                 kind: tweak.kind, previous: .unset)
            let deleted = withFakeDefaults({ args in
                args.first == "read" ? ok("1") : ok("")
            }) {
                SafeProcess.resetInvokedCommands()
                guard SystemTweakStore.revert(needDelete) else { return false }
                let deletes = SafeProcess.invokedCommands.filter { $0.args.first == "delete" }
                return deletes.count == 1 && deletes[0].args.contains(tweak.key)
            }
            return deleted
        }

        check("反馈文案：三种「没有改动」都必须说清原因，成功那条必须说清要重启谁") {
            let tweak = SystemTweak.catalog[0]   // dock.show-recents，restartProcess = Dock
            let reading = SystemTweakState.outcomeMessage(for: tweak, outcome: .refusedReadingFailed)
            let undoFail = SystemTweakState.outcomeMessage(for: tweak, outcome: .refusedUndoNotPersisted)
            let writeFail = SystemTweakState.outcomeMessage(for: tweak, outcome: .writeFailed)
            // 三种拒绝必须互相可区分——否则用户分不清"没读到"和"写不进去"
            guard reading != undoFail, undoFail != writeFail, reading != writeFail else { return false }
            guard reading.contains("没有改动"), undoFail.contains("没有改动"),
                  writeFail.contains("保持原样") else { return false }
            // 成功那条必须带"需要重启哪个进程"，否则用户会以为"改了没用"
            let record = SystemTweakStore.ChangeRecord(tweakID: tweak.id, domain: tweak.domain,
                                                       key: tweak.key, kind: tweak.kind,
                                                       previous: .bool(true))
            let okText = SystemTweakState.outcomeMessage(for: tweak, outcome: .applied(record))
            guard okText.contains(tweak.title),
                  let process = tweak.restartProcess, okText.contains(process) else { return false }
            // 需要重新登录的那一类也要说清（键盘的几条就是）
            guard let relogin = SystemTweak.catalog.first(where: { $0.needsRelogin }) else { return false }
            let reloginText = SystemTweakState.outcomeMessage(for: relogin, outcome: .applied(record))
            guard reloginText.contains("重新登录") else { return false }
            // 还原 / 重启的成功与失败也要能区分
            return SystemTweakState.revertMessage(for: record, succeeded: true)
                    != SystemTweakState.revertMessage(for: record, succeeded: false)
                && SystemTweakState.restartMessage(process: "Dock", succeeded: true)
                    != SystemTweakState.restartMessage(process: "Dock", succeeded: false)
        }

        check("概览文案：必须把「读不到」说出来，不许吞进『已是推荐值』") {
            let state = SystemTweakState()
            // 空态
            guard state.summaryText.contains("重新读取") else { return false }
            // 构造：1 项已是推荐值 + 1 项偏离 + 1 项读不到
            let tweaks = SystemTweak.catalog
            let findings = [
                TweakFinding(tweak: tweaks[0], current: tweaks[0].recommended, status: .alreadyOptimal),
                TweakFinding(tweak: tweaks[1], current: nil, status: .deviates),
                TweakFinding(tweak: tweaks[2], current: nil, status: .unreadable),
            ]
            state.injectFindingsForSelftest(findings)
            guard state.deviates.count == 1, state.unreadable.count == 1 else { return false }
            let text = state.summaryText
            // 关键：读不到的条数必须出现在概览里，否则用户以为"11 项都看过了"
            guard text.contains("可优化 1 项"), text.contains("1 项读不到") else {
                print("      概览没有如实报出『读不到』：\(text)")
                return false
            }
            // 撤销记录标题：能映射回目录标题；映射不到时要退回 key 而不是显示空白
            let known = SystemTweakStore.ChangeRecord(tweakID: tweaks[0].id, domain: tweaks[0].domain,
                                                      key: tweaks[0].key, kind: tweaks[0].kind,
                                                      previous: .unset)
            let unknown = SystemTweakStore.ChangeRecord(tweakID: "not.in.catalog", domain: "x",
                                                        key: "some-key", kind: .bool, previous: .unset)
            return state.title(for: known) == tweaks[0].title
                && state.title(for: unknown) == "some-key"
        }

        check("设计约束：优化链路不得出现任何批量入口（源码 lint）") {
            // 这条不是洁癖：一次改十项系统设置，出问题时用户根本不知道是哪一条造成的，
            // 而且"清爽与否"是个人口味，不该被工具一次性替你决定。
            // 写成源码 lint 是为了防止将来有人"顺手加个全选"。
            //
            // 刻意**不检查中文文案**：页面里那句"工具不做一键优化全部"是必需的诚实说明，
            // 按文案判会把它误伤。这里查的是**能力**（API 与标识符），不是措辞。
            let storePath = Selftest.sourceDirectoryPath + "/SystemTweakStore.swift"
            let viewPath = Selftest.sourceDirectoryPath + "/SystemOptimizeView.swift"
            guard let storeSrc = try? String(contentsOfFile: storePath, encoding: .utf8),
                  let viewSrc = try? String(contentsOfFile: viewPath, encoding: .utf8) else {
                print("      读不到优化链路的源码")
                return false
            }
            let storeCode = Selftest.stripSwiftComments(storeSrc)
            let viewCode = Selftest.stripSwiftComments(viewSrc)
            // ① 写路径只接受**单个** tweak：`apply/write/revert/delete` 带数组参数一律不许。
            //
            //    判据必须落在"写"这几个函数名上，而不是"见到 [SystemTweak] 就红"——
            //    `inspect(_ tweaks: [SystemTweak])` 是**只读**体检，数组参数在那里是正当的
            //    （本文件第一次写这条 lint 时就误伤了它）。
            for line in storeCode.split(separator: "\n") where line.contains("[SystemTweak]") {
                let isWriteAPI = ["func apply", "func write", "func revert",
                                  "func delete", "func batch"]
                    .contains { line.contains($0) }
                if isWriteAPI {
                    print("      SystemTweakStore 出现了批量写签名："
                          + line.trimmingCharacters(in: .whitespaces))
                    return false
                }
            }
            // 反方向：单条写入口必须存在。没有这句，上面那条只要"把写 API 全删掉"就能满足。
            if !storeCode.contains("func apply(_ tweak: SystemTweak)") {
                print("      找不到单条 apply 入口（批量入口拆掉了，单条入口也不见了）")
                return false
            }
            // ② 视图里不得出现批量勾选/批量应用的标识符
            for banned in ["selectAll", "applyAll", "optimizeAll", "batchApply", "toggleAll"] {
                if viewCode.contains(banned) {
                    print("      优化页出现了批量入口：\(banned)")
                    return false
                }
            }
            return true
        }

        check("系统状态：三态解析穷举——认不出的输出必须落「读不到」，不许猜成开或关") {
            func parsed(_ kind: SystemStatusCheck.Kind, _ output: String,
                        exitCode: Int32 = 0) -> StatusReading {
                SystemStatusParser.parse(kind: kind,
                                         results: [StatusCommandResult(exitCode: exitCode, output: output)])
            }
            // 每一类都要：能认开启、能认关闭、认不出时是 unknown
            let cases: [(SystemStatusCheck.Kind, String, String, String)] = [
                (.sip, "System Integrity Protection status: enabled.", "System Integrity Protection status: disabled.", "wat"),
                (.gatekeeper, "assessments enabled", "assessments disabled", "wat"),
                (.fileVault, "FileVault is On.", "FileVault is Off.", "wat"),
                (.firewall, "Firewall is enabled. (State = 1)", "Firewall is disabled. (State = 0)", "wat"),
                (.spotlight, "/:\n\tIndexing enabled. ", "/:\n\tIndexing disabled.", "wat"),
                (.timeMachine, "Name : Backup\nKind : Network", "tmutil: No destinations configured.", "wat"),
            ]
            for (kind, onText, offText, junk) in cases {
                guard case .on = parsed(kind, onText) else {
                    print("      \(kind.rawValue) 的开启态没认出来")
                    return false
                }
                guard case .off = parsed(kind, offText) else {
                    print("      \(kind.rawValue) 的关闭态没认出来")
                    return false
                }
                guard case .unknown = parsed(kind, junk) else {
                    print("      \(kind.rawValue) 认不出的输出被猜成了具体状态")
                    return false
                }
            }
            // 命令根本没跑起来（缺项）也必须是 unknown，**不许**默认成"已开启"
            for kind in SystemStatusCheck.Kind.allCases {
                guard case .unknown = SystemStatusParser.parse(kind: kind, results: [nil]) else {
                    print("      \(kind.rawValue) 在探针没执行时没有落「读不到」")
                    return false
                }
            }
            // 三态的标签必须互不相同（否则界面上分不清）
            return StatusReading.on(evidence: "e").label != StatusReading.off(evidence: "e").label
                && StatusReading.off(evidence: "e").label != StatusReading.unknown(reason: "r").label
        }

        check("系统状态：退出码 0 不等于拿到答案（tmutil latestbackup 真机就是这样）") {
            // 本机实测：`tmutil latestbackup` 在目标盘没接时**退出码 0**，
            // 只在输出里打印 "Failed to mount backup destination, error: ..."。
            // 只看退出码就会把一次挂载失败当成"最近备份时间"——正是本项目反复踩的那类坑。
            let mountFailure = StatusCommandResult(
                exitCode: 0,
                output: "Failed to mount backup destination, error: Error Domain=com.apple.backupd.ErrorDomain Code=17 \"Failed to mount destination.\"")
            guard SystemStatusParser.lastBackupDetail(from: mountFailure) == nil else {
                print("      挂载失败被当成了备份时间")
                return false
            }
            // 真拿到路径时才算数
            let realBackup = StatusCommandResult(exitCode: 0,
                                                 output: "/Volumes/Backup/Backups.backupdb/Mac/2026-09-27-051200\n")
            guard let detail = SystemStatusParser.lastBackupDetail(from: realBackup),
                  detail.contains("2026-09-27") else {
                print("      真的备份路径没有被识别")
                return false
            }
            // 命令没跑起来时同样是 nil
            return SystemStatusParser.lastBackupDetail(from: nil) == nil
        }

        check("系统状态：所有探针必须只读，且这条判据真的有判别力") {
            // 反向哨兵先跑：把一条明显会改状态的命令喂进判据，必须判 false。
            // 少了这句，`isReadOnly` 写成 `return true` 也能让下面整段绿。
            let writer = StatusCommand(path: "/usr/bin/defaults", args: ["write", "com.x", "y", "-bool", "true"])
            let deleter = StatusCommand(path: "/usr/bin/defaults", args: ["delete", "com.x"])
            let enabler = StatusCommand(path: "/usr/bin/mdutil", args: ["-a", "-i", "on", "/"])
            guard !writer.isReadOnly, !deleter.isReadOnly, !enabler.isReadOnly else {
                print("      isReadOnly 没有判别力（会写状态的命令被判成了只读）")
                return false
            }
            // 正向：目录里每一条探针都必须是只读的
            for check in SystemStatusCheck.catalog {
                for command in check.commands where !command.isReadOnly {
                    print("      \(check.kind.rawValue) 的探针不是只读：\(command.path) \(command.args)")
                    return false
                }
            }
            return true
        }

        check("系统状态：目录完备性——说明与去处都要写，路径必须是绝对路径") {
            var bad: [String] = []
            var seen = Set<String>()
            for check in SystemStatusCheck.catalog {
                if !seen.insert(check.kind.rawValue).inserted { bad.append("\(check.kind.rawValue)：重复") }
                if check.title.isEmpty { bad.append("\(check.kind.rawValue)：没标题") }
                if check.whatItDoes.trimmingCharacters(in: .whitespaces).isEmpty {
                    bad.append("\(check.kind.rawValue)：没写这一项在管什么")
                }
                // 只读数不给去处的建议是废话——用户看完不知道下一步做什么
                if check.whereToChange.trimmingCharacters(in: .whitespaces).isEmpty {
                    bad.append("\(check.kind.rawValue)：没写去哪儿改")
                }
                if check.commands.isEmpty { bad.append("\(check.kind.rawValue)：没有任何探针") }
                for command in check.commands where !command.path.hasPrefix("/") {
                    bad.append("\(check.kind.rawValue)：探针路径不是绝对路径（\(command.path)）")
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("系统状态真机只读：探针能跑通、三态自洽，且一条写命令都没发出去") {
            // 这一条真跑 csrutil / spctl / fdesetup / socketfilterfw / tmutil / mdutil——
            // **全是查询命令**，不改任何状态。与 `--prefs-check` 同一条路径。
            SafeProcess.resetInvokedCommands()
            let findings = SystemStatusStore.inspect()
            guard findings.count == SystemStatusCheck.catalog.count else { return false }
            // 硬保证：跑完一整轮状态体检，不许出现任何写类命令
            let banned = ["write", "delete", "set", "enable", "disable", "remove", "reset"]
            for invocation in SafeProcess.invokedCommands {
                let args = invocation.args.map { $0.lowercased() }
                if args.contains(where: { banned.contains($0) }) {
                    print("      状态体检发了写类命令：\(invocation.path) \(invocation.args)")
                    return false
                }
            }
            // 三态自洽：unknown 不许带具体证据语义之外的 claim；已开启/未开启必须有证据文本
            for finding in findings {
                switch finding.reading {
                case .on(let e), .off(let e):
                    if e.trimmingCharacters(in: .whitespaces).isEmpty { return false }
                case .unknown(let reason):
                    if reason.trimmingCharacters(in: .whitespaces).isEmpty { return false }
                }
            }
            return true
        }

        check("真机只读：体检能跑通、条数与目录一致，且一条写命令都没发出去") {
            // 这一条会真的调 `defaults read`——**只读**，不改任何设置。
            // 与 `--prefs-check` 命令同一路径，保证"体检绝不写"这条性质在真机上成立。
            SafeProcess.resetInvokedCommands()
            let findings = SystemTweakStore.inspect()
            guard findings.count == SystemTweak.catalog.count else { return false }
            let writes = SafeProcess.invokedCommands.filter {
                $0.args.first == "write" || $0.args.first == "delete"
            }
            if !writes.isEmpty {
                print("      体检居然发了 \(writes.count) 条写命令：\(writes.prefix(2))")
                return false
            }
            // 每条都要有结论，且"读不到"必须是它自己的状态
            for finding in findings {
                switch finding.status {
                case .alreadyOptimal, .deviates:
                    if finding.current == nil { return false }
                case .unreadable:
                    if finding.current != nil { return false }
                }
            }
            // **本条是刚刚补上的**：拿一个必然不存在的键去读，必须得到 `.unset`。
            // 之前缺这句，于是 macOS 27 改了报错措辞之后，"键不存在"被误判成"读不到"
            // 而整套自检仍然全绿——真机 `--prefs-check` 才把它照出来。
            // 现在这条断言把"措辞随系统版本变化"这件事钉在真机上，不再只靠固定输入。
            let probeDomain = "com.apple.dock"
            let probeKey = "macclean-selftest-definitely-not-a-key-\(UUID().uuidString.prefix(8))"
            guard SystemTweakStore.readRaw(domain: probeDomain, key: probeKey, kind: .bool) == .unset else {
                print("      必然不存在的键没有被判为「未设置」——大概率是系统报错措辞又变了")
                return false
            }
            return true
        }
    }

    /// 造一条撤销记录（自检用；`ChangeRecord` 的字段自检拼不出来时用这个）。
    private static func ChangeRecordFixture(domain: String, key: String, kind: TweakKind,
                                            previous: TweakValue) -> SystemTweakStore.ChangeRecord {
        SystemTweakStore.ChangeRecord(tweakID: "selftest.fixture", domain: domain,
                                      key: key, kind: kind, previous: previous)
    }
}
