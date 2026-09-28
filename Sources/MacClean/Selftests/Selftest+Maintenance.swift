import Foundation

// MARK: - 系统维护自检 (v1.73.15)
//
// 模型层套件，不碰 ViewInspector（macOS 27 上那族断言本机跑不了，与本套件无关）。
// 覆盖：
// * 命令形状（假 runner）：调的是哪个命令、带哪些参数、timeout 多少——每个外部命令
//   调用点的 timeout 都有「钉常量本身 + 绝对值下界」的断言（参照 dittoTimeout 那条）；
// * 卷 ID 解析白名单：正常/快照形态能解析，空/异常/花哨值一律拒绝，绝不把没把握的
//   值传给 verifyVolume（不许传空参或 "/" 字面）；
// * 可用性预判：命令不存在 → 「未执行」，不是失败也不是成功；
// * 变异靶：① 摘掉 verifyVolume 的 timeout 实参 → 本套件红；
//           ② 摘掉卷 ID 白名单校验（或往本文件塞插值 shell 串）→ 注入面断言红；
// * 真命令一条：`diskutil list`（只读）真跑一次，证明 SafeProcess 链路真通
//   （RELEASE-CHECKLIST：断言外部工具参数组合时，至少跑一次真命令）。

extension Selftest {
    static func suiteMaintenance() {
        print("--- [Suite] 系统维护面板 (v1.73.15) ---")

        // 1. 超时常量：按真实耗时设（实测 Data 卷 verify 33.6 s、快照 6.6 s、mdutil -E 分钟级）
        check("Maintenance: 超时常量钉值——常量本身有绝对下界，不许缩成摆设") {
            guard MaintenanceService.verifyTimeout >= 5 * 60 else { return false }
            guard MaintenanceService.spotlightRebuildTimeout >= 5 * 60 else { return false }
            guard MaintenanceService.volumeProbeTimeout >= 10 else { return false }
            guard MaintenanceService.excerptMaxLines >= 1 else { return false }
            return true
        }

        // 2. 卷 ID 解析：白名单形状（disk3s1 / 快照形态 disk3s1s1），异常输入一律拒绝
        check("Maintenance: 卷 ID 解析——正常与快照形态可解析，空/异常/花哨值拒绝") {
            let plain = "   Device Identifier:         disk3s1\n"
                + "   Device Node:               /dev/disk3s1\n"
                + "   Volume Name:               Macintosh HD\n"
            guard MaintenanceService.parseVolumeIdentifier(fromInfoOutput: plain) == "disk3s1" else {
                return false
            }
            // 本机 2026-09-28 实测：diskutil info / 报的是封存快照形态 disk3s1s1，
            // diskutil verifyVolume 能正确把它解析回真身卷（实测 exit 0）
            let snapshot = "   Device Identifier:         disk3s1s1\n"
                + "   Device Node:               /dev/disk3s1s1\n"
                + "   Volume Read-Only:          Yes (read-only mount flag set)\n"
                + "   Sealed:                    Yes\n"
            guard MaintenanceService.parseVolumeIdentifier(fromInfoOutput: snapshot) == "disk3s1s1" else {
                return false
            }
            // 空输出 / 缺行 / 缺值
            guard MaintenanceService.parseVolumeIdentifier(fromInfoOutput: "") == nil else { return false }
            guard MaintenanceService.parseVolumeIdentifier(fromInfoOutput: "No such disk\n") == nil else {
                return false
            }
            guard MaintenanceService.parseVolumeIdentifier(
                fromInfoOutput: "   Device Identifier:         \n") == nil else { return false }
            // 形状不对：不是 disk<N>s<M>(s<K>)? 一律拒绝——解析出什么就信什么是要不得的
            let hostile = ["disk3s1; rm -rf /", "/dev/disk3s1", "disk99", "diskXs1",
                           "disk3s1 extra", "$(reboot)", "disk3s1s1s1s1"]
            for value in hostile {
                let output = "   Device Identifier:         \(value)\n"
                guard MaintenanceService.parseVolumeIdentifier(fromInfoOutput: output) == nil else {
                    print("    ❌ 花哨卷 ID 竟被放行：\(value)")
                    return false
                }
            }
            return true
        }

        // 3. First Aid 命令形状：info 解析 + verifyVolume，命令/参数/timeout 逐项断言
        check("Maintenance: First Aid 命令形状——diskutil info / + verifyVolume <解析卷>，timeout 钉常量") {
            let savedRunner = SafeProcess.runner
            let savedPath = MaintenanceService.diskutilPath
            defer {
                SafeProcess.runner = savedRunner
                MaintenanceService.diskutilPath = savedPath
            }
            var seen: [(path: String, args: [String], timeout: TimeInterval)] = []
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                if args == ["info", "/"] {
                    return SafeProcess.Result(exitCode: 0,
                                              output: "   Device Identifier:         disk3s1\n"
                                                    + "   Volume Name:               Macintosh HD\n")
                }
                if args.count == 2, args[0] == "verifyVolume" {
                    return SafeProcess.Result(
                        exitCode: 0,
                        output: "Checking the container superblock\n"
                              + "warning: inode (id 1): minor issue\n"
                              + "The volume /dev/rdisk3s1 appears to be OK\n"
                              + "File system check exit code is 0\n")
                }
                return SafeProcess.Result(exitCode: -1, output: "unexpected command \(args)")
            }

            let service = MaintenanceService()
            let outcome = service.perform(.firstAid)
            guard outcome.status == .succeeded, outcome.timedOut == false else { return false }
            guard outcome.duration >= 0 else { return false }

            // 第一跳：diskutil info /（解析卷目标），timeout 钉 volumeProbeTimeout
            guard seen.count == 2 else { return false }
            guard seen[0].path == MaintenanceService.diskutilPath,
                  seen[0].args == ["info", "/"],
                  seen[0].timeout == MaintenanceService.volumeProbeTimeout else {
                print("    ❌ info 调用形状不对：\(seen[0])")
                return false
            }
            // 第二跳：verifyVolume + 解析出的卷 ID，timeout 钉 verifyTimeout（见第 1 条的下界）
            guard seen[1].path == MaintenanceService.diskutilPath,
                  seen[1].args == ["verifyVolume", "disk3s1"],
                  seen[1].timeout == MaintenanceService.verifyTimeout else {
                print("    ❌ verifyVolume 调用形状不对：\(seen[1])")
                return false
            }
            // 成功结论也要把解析出的卷 ID 说出来，且摘录原样带上 warning 与结论行
            guard outcome.message.contains("disk3s1") else { return false }
            guard let excerpt = outcome.outputExcerpt,
                  excerpt.contains("warning: inode"),
                  excerpt.contains("appears to be OK") else {
                print("    ❌ 输出摘录丢了原文：\(String(describing: outcome.outputExcerpt))")
                return false
            }

            // 非 0 退出 → 失败，退出码与输出原样带回，不得谎报成功。
            // info 照常给出合法卷：这样失败只能来自 verifyVolume 本身（单一条件可证伪）
            SafeProcess.runner = { _, args, _ in
                seen.append(("diskutil", args, 0))
                if args == ["info", "/"] {
                    return SafeProcess.Result(exitCode: 0,
                                              output: "   Device Identifier:         disk3s1\n")
                }
                return SafeProcess.Result(exitCode: 1, output: "The volume was found to be corrupt")
            }
            seen.removeAll()
            let failed = MaintenanceService().perform(.firstAid)
            guard failed.status == .failed,
                  failed.message.contains("退出码 1"),
                  failed.outputExcerpt?.contains("corrupt") == true else { return false }
            guard seen.count == 2, seen[1].args == ["verifyVolume", "disk3s1"] else { return false }

            // 超时 → 失败。夹具给 exitCode 0 + timedOut true（单一条件可证伪，防 A||B 假断言）
            SafeProcess.runner = { _, args, _ in
                seen.append(("diskutil", args, 0))
                if args == ["info", "/"] {
                    return SafeProcess.Result(exitCode: 0,
                                              output: "   Device Identifier:         disk3s1\n")
                }
                return SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            let timedOut = MaintenanceService().perform(.firstAid)
            guard timedOut.status == .failed, timedOut.timedOut,
                  timedOut.message.contains("超时") else { return false }
            return true
        }

        // 4. 卷解析失败 → 「无法确定系统卷」，verifyVolume 绝不执行（不许传空参或 "/" 字面）
        check("Maintenance: 解析不出系统卷时如实报「未执行」，绝不瞎猜卷目标") {
            let savedRunner = SafeProcess.runner
            defer { SafeProcess.runner = savedRunner }
            var verifyCalls: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                if args.count == 2, args[0] == "verifyVolume" {
                    verifyCalls.append((path, args))
                }
                // 两种真实形态：空输出 / 非零退出（diskutil info 失败）
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            let service = MaintenanceService()
            let empty = service.perform(.firstAid)
            guard empty.status == .notExecuted,
                  empty.message.contains("无法确定系统卷"),
                  verifyCalls.isEmpty else {
                print("    ❌ 空输出时仍执行了 verifyVolume：\(verifyCalls)")
                return false
            }

            verifyCalls.removeAll()
            SafeProcess.runner = { _, args, _ in
                if args.count == 2, args[0] == "verifyVolume" {
                    verifyCalls.append((args[0], args))
                }
                return SafeProcess.Result(exitCode: 3, output: "Could not access disk")
            }
            let failedInfo = MaintenanceService().perform(.firstAid)
            guard failedInfo.status == .notExecuted,
                  failedInfo.message.contains("无法确定系统卷"),
                  verifyCalls.isEmpty else { return false }
            return true
        }

        // 5. 可用性预判：命令不存在 → 「未执行」（不是失败也不是成功），且一条命令都不发
        check("Maintenance: 工具不存在时三动作都报「未执行」且零调用") {
            let savedRunner = SafeProcess.runner
            let savedDiskutil = MaintenanceService.diskutilPath
            let savedDscacheutil = NetworkPrivacyInspector.dscacheutilPath
            let savedProbe = MaintenanceService.spotlightToolAvailable
            defer {
                SafeProcess.runner = savedRunner
                MaintenanceService.diskutilPath = savedDiskutil
                NetworkPrivacyInspector.dscacheutilPath = savedDscacheutil
                MaintenanceService.spotlightToolAvailable = savedProbe
            }
            var anyCall = false
            SafeProcess.runner = { _, _, _ in
                anyCall = true
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            let service = MaintenanceService()

            MaintenanceService.diskutilPath = "/usr/sbin/diskutil-definitely-missing"
            // 反证：注入的缺失路径确实过不了预判（防桩路径在本机碰巧存在导致用例空转）
            guard SafeProcess.isAvailable(MaintenanceService.diskutilPath) == false else { return false }
            let firstAid = service.perform(.firstAid)
            guard firstAid.status == .notExecuted,
                  firstAid.message.contains("未执行"), anyCall == false else {
                print("    ❌ diskutil 缺失时未按「未执行」处理：\(firstAid.status)、anyCall=\(anyCall)")
                return false
            }

            NetworkPrivacyInspector.dscacheutilPath = "/usr/bin/dscacheutil-definitely-missing"
            anyCall = false
            let dns = service.perform(.dnsFlush)
            guard dns.status == .notExecuted, dns.message.contains("未执行"), anyCall == false else {
                print("    ❌ dscacheutil 缺失时未按「未执行」处理：\(dns.status)、anyCall=\(anyCall)")
                return false
            }

            MaintenanceService.spotlightToolAvailable = { false }
            anyCall = false
            let spotlight = service.perform(.spotlightRebuild)
            guard spotlight.status == .notExecuted,
                  spotlight.message.contains("未执行"), anyCall == false else {
                print("    ❌ mdutil 缺失时未按「未执行」处理：\(spotlight.status)、anyCall=\(anyCall)")
                return false
            }

            // 默认预判缝必须连着真路径：本机 diskutil / dscacheutil / mdutil 都真实存在
            MaintenanceService.diskutilPath = savedDiskutil
            NetworkPrivacyInspector.dscacheutilPath = savedDscacheutil
            MaintenanceService.spotlightToolAvailable = savedProbe
            guard MaintenanceService.spotlightToolAvailable() else { return false }
            guard FileManager.default.isExecutableFile(atPath: MaintenanceService.diskutilPath),
                  FileManager.default.isExecutableFile(atPath: savedDscacheutil),
                  FileManager.default.isExecutableFile(atPath: SpotlightScanner.mdutilPath) else {
                return false
            }
            return true
        }

        // 6. DNS 转发形状：调的就是 NetworkPrivacyInspector 的 dscacheutil -flushcache，timeout 10（现网值）
        check("Maintenance: DNS 转发——dscacheutil -flushcache，timeout 10 与现网一致，失败如实回传") {
            let savedRunner = SafeProcess.runner
            defer { SafeProcess.runner = savedRunner }
            var seen: [(path: String, args: [String], timeout: TimeInterval)] = []
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            let service = MaintenanceService()
            let outcome = service.perform(.dnsFlush)
            guard outcome.status == .succeeded else { return false }
            guard seen.count == 1,
                  seen[0].path == NetworkPrivacyInspector.dscacheutilPath,
                  seen[0].args == ["-flushcache"],
                  seen[0].timeout == 10 else {
                print("    ❌ DNS 调用形状不对：\(String(describing: seen.first))")
                return false
            }

            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "operation not permitted")
            }
            let failed = MaintenanceService().perform(.dnsFlush)
            guard failed.status == .failed,
                  failed.message.contains("operation not permitted") else { return false }
            return true
        }

        // 7. Spotlight 转发形状：mdutil -E /，timeout 钉 spotlightRebuildTimeout
        check("Maintenance: Spotlight 转发——mdutil -E /（复用 SpotlightScanner，timeout 钉常量）") {
            let savedRunner = SafeProcess.runner
            defer { SafeProcess.runner = savedRunner }
            var seen: [(path: String, args: [String], timeout: TimeInterval)] = []
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 0, output: "Erasing and reindexing /")
            }
            let service = MaintenanceService()
            let outcome = service.perform(.spotlightRebuild)
            guard outcome.status == .succeeded, outcome.message.contains("重建") else { return false }
            guard seen.count == 1,
                  seen[0].path == SpotlightScanner.mdutilPath,
                  seen[0].args == ["-E", "/"],
                  seen[0].timeout == MaintenanceService.spotlightRebuildTimeout else {
                print("    ❌ Spotlight 调用形状不对：\(String(describing: seen.first))")
                return false
            }

            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            let timed = MaintenanceService().perform(.spotlightRebuild)
            guard timed.status == .failed, timed.message.contains("超时") else { return false }
            return true
        }

        // 8. 摘录函数：只取尾部原文，行数封顶，不做美化
        check("Maintenance: 输出摘录取尾部原文且行数封顶") {
            let lines = (1...20).map { "line-\($0)" }
            let tail = MaintenanceService.excerptTail(of: lines.joined(separator: "\n"))
            let tailLines = tail.components(separatedBy: "\n")
            guard tailLines.count == MaintenanceService.excerptMaxLines else { return false }
            guard tailLines.first == "line-\(20 - MaintenanceService.excerptMaxLines + 1)" else {
                return false
            }
            guard tailLines.last == "line-20" else { return false }
            // 不超上限时原样保留；空输出给空串
            guard MaintenanceService.excerptTail(of: "a\nb") == "a\nb" else { return false }
            guard MaintenanceService.excerptTail(of: "") == "" else { return false }
            return true
        }

        // 9. 注入面：花哨卷 ID 在运行时也拦在 verifyVolume 之前 + 本模块不拼提权 shell 串
        check("Maintenance: 注入面——解析结果过白名单才进命令参数；本模块无提权 shell 串") {
            let savedRunner = SafeProcess.runner
            defer { SafeProcess.runner = savedRunner }
            var verifyArgs: [String] = []
            SafeProcess.runner = { _, args, _ in
                if args.count == 2, args[0] == "verifyVolume" {
                    verifyArgs = args
                    return SafeProcess.Result(exitCode: 0, output: "")
                }
                // info 返回被篡改过的设备标识（带 shell 元字符）：
                // 正确行为 = 白名单拒绝解析 → notExecuted，verifyVolume 一次都不执行
                return SafeProcess.Result(
                    exitCode: 0,
                    output: "   Device Identifier:         disk3s1; touch /tmp/pwned\n")
            }
            let service = MaintenanceService()
            let outcome = service.perform(.firstAid)
            guard outcome.status == .notExecuted, verifyArgs.isEmpty else {
                print("    ❌ 篡改的卷标识流进了命令参数：\(verifyArgs)")
                return false
            }

            // 源码形状 lint（注释剥离后）：本模块不得出现提权 shell 串/插值进 shell 的形状；
            // 同时钉住白名单门真的在源码里（防 lint 空转：文件删空也会「零违规」）
            guard let src = try? String(contentsOfFile: Selftest.sourceDirectoryPath
                + "/MaintenanceService.swift", encoding: .utf8) else { return false }
            let code = Selftest.stripSwiftComments(src)
            guard code.contains("verifyVolume"), code.contains("isAvailable"),
                  code.contains("volumeIDPattern") else {
                print("    ❌ lint 空转：白名单形状在源码里找不到了")
                return false
            }
            let banned = ["osascript", "do shell script", "with administrator privileges"]
            for word in banned where code.contains(word) {
                print("    ❌ 维护模块里出现了提权 shell 串形状：\(word)")
                return false
            }
            return true
        }

        // 10. 真命令一条（RELEASE-CHECKLIST：断言外部命令参数组合时至少跑一次真命令）：
        //     `diskutil list`（只读）真跑，证明 SafeProcess 链路（管道排空/超时/退出码）真通
        check("Maintenance: 真命令——diskutil list 真跑 exit 0，输出含分区表证据") {
            let savedRunner = SafeProcess.runner
            defer { SafeProcess.runner = savedRunner }
            SafeProcess.runner = nil   // 生产路径，不受其他用例的桩影响
            guard SafeProcess.isAvailable("/usr/sbin/diskutil") else { return false }
            guard let result = SafeProcess.run("/usr/sbin/diskutil", ["list"], timeout: 60) else {
                return false
            }
            guard !result.timedOut else { return false }
            guard result.exitCode == 0 else {
                print("    ❌ diskutil list 退出码 \(result.exitCode)：\(result.output.prefix(200))")
                return false
            }
            guard result.output.contains("GUID_partition_scheme") || result.output.contains("APFS") else {
                return false
            }
            return true
        }
    }
}
