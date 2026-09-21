import Foundation
import Darwin

// MARK: - 废弃打印机驱动与 PPD 描述文件治理深度自检 (v1.71.0，v1.72.0 加固)
//
// 覆盖本轮修掉的三个真机缺陷，每条都跑在 `NSTemporaryDirectory()` 造的 fixture 上：
// ① 读不到 CUPS 配置（真机上 `printers.conf` 是 `-rw------- root:_cups`）→
//    不判孤儿、一项都不默认勾；
// ② PPD 厂商分组只删自己的成员文件，共享的 Resources 根必须完好无损；
// ③ 删除全部走 `ResidueDeletionGate`：软链跳板必拒、越界必拒、
//    删除失败不得计入 freedBytes/cleanedCount、CUPS 重载命令与结果如实断言。

extension Selftest {
    static func suitePrinterDriverDeep() {
        print("--- [Suite] 废弃打印机驱动与 PPD 描述文件治理深度自检 (v1.71.0) ---")

        // 1. 驱动分类、图标与健康状态枚举判定
        check("PrinterDriver: 驱动分类、图标与健康状态枚举判定") {
            guard PrinterDriverKind.vendorDriverBundle.icon == "printer.fill" else { return false }
            guard PrinterDriverKind.ppdResource.icon == "doc.text.fill" else { return false }
            guard PrinterDriverKind.cupsQueue.icon == "list.bullet.rectangle" else { return false }
            guard PrinterDriverKind.scannerDriver.icon == "scanner.fill" else { return false }

            guard PrinterDriverStatus.orphanUnused.isOrphanOrCorrupted == true else { return false }
            guard PrinterDriverStatus.corrupted.isOrphanOrCorrupted == true else { return false }
            guard PrinterDriverStatus.activeConfigured.isOrphanOrCorrupted == false else { return false }
            guard PrinterDriverStatus.systemProtected.isOrphanOrCorrupted == false else { return false }
            // 核心：证据不足**不是**孤儿也不是损坏，因此永不进默认可删集合
            guard PrinterDriverStatus.needsConfirmation.isOrphanOrCorrupted == false else { return false }
            guard PrinterDriverStatus.needsConfirmation.isInUseOrProtected == false else { return false }
            guard PrinterDriverStatus.allCases.contains(.needsConfirmation) else { return false }

            return true
        }

        // 2. 概要指标统计与已选释放容量精算
        check("PrinterDriver: 概要指标统计与已选释放容量精算") {
            let date = Date()
            let item1 = PrinterDriverItem(
                id: "/p1", name: "hp", vendor: "惠普 (HP)", path: "/p1",
                kind: .vendorDriverBundle, status: .orphanUnused,
                size: 2048, fileCount: 15, modificationDate: date, isSelected: true
            )
            let item2 = PrinterDriverItem(
                id: "/p2", name: "corrupted.ppd", vendor: "通用/第三方厂商", path: "/p2",
                kind: .ppdResource, status: .corrupted,
                size: 0, fileCount: 0, modificationDate: date, isSelected: true
            )
            let item3 = PrinterDriverItem(
                id: "/p3", name: "Canon_MF4700", vendor: "佳能 (Canon)", path: "/p3",
                kind: .cupsQueue, status: .activeConfigured,
                size: 4096, fileCount: 2, modificationDate: date, isSelected: false
            )

            let summary = PrinterDriverSummary(
                items: [item1, item2, item3],
                totalSize: 6144,
                orphanCount: 2,
                orphanSize: 2048,
                activeCount: 1,
                cupsEvidenceReadable: true,
                needsConfirmationCount: 0,
                unreadableSources: []
            )

            guard summary.totalSize == 6144 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.orphanSize == 2048 else { return false }
            guard summary.activeCount == 1 else { return false }
            guard summary.selectedSize == 2048 else { return false }
            guard summary.selectedCount == 2 else { return false }
            guard summary.cupsEvidenceReadable else { return false }
            guard summary.needsConfirmationCount == 0 else { return false }

            return true
        }

        // 3. 厂商推导与队列关键词匹配（两字词只做整词，杜绝任意子串）
        check("PrinterDriver: 厂商词表整词匹配与队列关键词命中") {
            guard PrinterDriverScanner.inferVendor(from: "Hewlett-Packard.bundle") == "惠普 (HP)" else { return false }
            guard PrinterDriverScanner.inferVendor(from: "Canon_MF_Series") == "佳能 (Canon)" else { return false }
            guard PrinterDriverScanner.inferVendor(from: "EpsonNet_Config") == "爱普生 (Epson)" else { return false }
            guard PrinterDriverScanner.inferVendor(from: "hp") == "惠普 (HP)" else { return false }
            // "hp" 是两字词：只允许整词/边界命中，绝不再做任意子串（phone-utils 不是惠普）
            guard PrinterDriverScanner.inferVendor(from: "phone-utils") == "通用/第三方厂商" else { return false }
            guard PrinterDriverScanner.inferVendor(from: "refuji-studio") == "通用/第三方厂商" else { return false }

            let kw: Set<String> = ["canon", "mf4700", "hp"]
            guard PrinterDriverScanner.matchesConfigured(keywords: kw, text: "Canon_MF4700.ppd") else { return false }
            guard !PrinterDriverScanner.matchesConfigured(keywords: kw, text: "MyHPLaserGun.icc") else { return false }
            guard PrinterDriverScanner.matchesConfigured(keywords: kw, text: "hp") else { return false }

            return true
        }

        // 4. CUPS 证据可信度：源读不到时 sourcesReadable 必须为 false
        check("PrinterDriver: CUPS 证据读不到时 sourcesReadable 为 false") {
            let dir = printerFixtureDir("evidence")
            let cups = (dir as NSString).appendingPathComponent("cups")
            let ppd = (cups as NSString).appendingPathComponent("ppd")
            try? FileManager.default.createDirectory(atPath: ppd, withIntermediateDirectories: true)
            let conf = (cups as NSString).appendingPathComponent("printers.conf")
            try? "<Printer HP_OfficeJet>\n</Printer>".write(toFile: conf, atomically: true, encoding: .utf8)
            // 真机上 printers.conf 是 `-rw------- root:_cups`：这里用 chmod 000 复现同一后果
            chmod(conf, 0o000)
            defer {
                chmod(conf, 0o600)
                try? FileManager.default.removeItem(atPath: dir)
            }

            let blocked = PrinterDriverScanner.collectActivePrinterEvidence(customCupsDir: cups)
            guard blocked.sourcesReadable == false else { return false }
            guard blocked.unreadableSources.contains(where: { $0.contains("printers.conf") }) else { return false }
            guard blocked.keywords.isEmpty || !blocked.keywords.contains("hp_officejet") else { return false }

            // 证据源都可读时：sourcesReadable = true，且队列名/PPD 名都进关键词
            chmod(conf, 0o644)
            let canonPPD = (ppd as NSString).appendingPathComponent("Canon_Office.ppd")
            try? "*PPD-Adobe: 4.3".data(using: .utf8)?.write(to: URL(fileURLWithPath: canonPPD))
            let openEvidence = PrinterDriverScanner.collectActivePrinterEvidence(customCupsDir: cups)
            guard openEvidence.sourcesReadable else { return false }
            guard openEvidence.keywords.contains("canon"), openEvidence.keywords.contains("office") else { return false }
            guard openEvidence.keywords.contains("hp_officejet") else { return false }

            // 证据源**不存在**（真的没配打印机）算"已读"，不是"读不到"
            let missing = PrinterDriverScanner.collectActivePrinterEvidence(
                customCupsDir: (dir as NSString).appendingPathComponent("no-cups-here"))
            guard missing.sourcesReadable, missing.keywords.isEmpty else { return false }

            return true
        }

        // 5. 状态判据：证据读不到 → 一律需确认，绝不判孤儿
        check("PrinterDriver: 证据不足降级为需确认（不判孤儿/不默选）") {
            let unreadable = PrinterEvidence.unreadable
            let hp = PrinterDriverScanner.evaluateDriverEntry(
                name: "hp", path: "/Library/Printers/hp", size: 5_000_000, evidence: unreadable)
            guard hp.status == .needsConfirmation else { return false }
            guard hp.status.isOrphanOrCorrupted == false else { return false }
            guard let note = hp.note, note.contains("无法读取 CUPS") else { return false }

            // 系统位置与"量不出来"都不该被判成可清理
            let sys = PrinterDriverScanner.evaluateDriverEntry(
                name: "Fax", path: "/System/Library/Printers/Fax", size: 5_000_000, evidence: unreadable)
            guard sys.status == .systemProtected else { return false }
            let blind = PrinterDriverScanner.evaluateDriverEntry(
                name: "Canon", path: "/Library/Printers/Canon", size: 0,
                evidence: PrinterEvidence(keywords: [], sourcesReadable: true),
                metricsReadable: false)
            guard blind.status == .needsConfirmation else { return false }

            // 证据齐了才允许给出在用/孤儿/损坏三种结论
            let ok = PrinterEvidence(keywords: ["canon"], sourcesReadable: true)
            guard PrinterDriverScanner.evaluateDriverEntry(
                name: "Canon", path: "/Library/Printers/Canon", size: 900, evidence: ok).status == .activeConfigured
            else { return false }
            guard PrinterDriverScanner.evaluateDriverEntry(
                name: "Xerox", path: "/Library/Printers/Xerox", size: 900, evidence: ok).status == .orphanUnused
            else { return false }
            guard PrinterDriverScanner.evaluateDriverEntry(
                name: "Epson", path: "/Library/Printers/Epson", size: 0, evidence: ok).status == .corrupted
            else { return false }

            return true
        }

        // 6. 完整扫描：真机式"CUPS 读不到"场景下一项都不勾；证据齐备时才出现可删项
        check("PrinterDriver: 扫描在证据缺失/齐备两种场景下的勾选差异") {
            let dir = printerFixtureDir("scan")
            let printers = (dir as NSString).appendingPathComponent("Printers")
            let userPrinters = (dir as NSString).appendingPathComponent("UserPrinters")
            let cups = (dir as NSString).appendingPathComponent("cups")
            try? FileManager.default.createDirectory(atPath: (cups as NSString).appendingPathComponent("ppd"),
                                                     withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: printers, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: userPrinters, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let hpDir = (printers as NSString).appendingPathComponent("hp")
            try? FileManager.default.createDirectory(atPath: hpDir, withIntermediateDirectories: true)
            try? "mock_hp_bytes".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: (hpDir as NSString).appendingPathComponent("hp_driver.bin")))
            try? "mock_queue".data(using: .utf8)?.write(
                to: URL(fileURLWithPath: (userPrinters as NSString).appendingPathComponent("Old_Epson_Queue")))

            // 场景 A：读不到 CUPS（真机默认状态）→ 全部需确认、零勾选
            let blind = PrinterDriverScanner.shared.scan(
                customPrinterDirs: [printers], customUserPrinterDirs: [userPrinters],
                customCupsDir: nil, evidence: .unreadable)
            guard blind.cupsEvidenceReadable == false else { return false }
            guard blind.orphanCount == 0, blind.orphanSize == 0 else { return false }
            guard blind.items.count == 2, blind.needsConfirmationCount == 2 else { return false }
            guard blind.items.allSatisfy({ $0.status == .needsConfirmation && !$0.isSelected }) else { return false }
            guard blind.selectedCount == 0 && blind.selectedSize == 0 else { return false }

            // 场景 B：证据齐备 → hp 命中队列变在用，旧队列成孤儿
            let evidence = PrinterEvidence(keywords: ["hp", "hp_officejet"], sourcesReadable: true)
            let seen = PrinterDriverScanner.shared.scan(
                customPrinterDirs: [printers], customUserPrinterDirs: [userPrinters],
                customCupsDir: nil, evidence: evidence)
            guard seen.cupsEvidenceReadable else { return false }
            guard let hpItem = seen.items.first(where: { $0.name == "hp" }),
                  hpItem.status == .activeConfigured, !hpItem.isSelected else { return false }
            guard let queue = seen.items.first(where: { $0.name == "Old_Epson_Queue" }),
                  queue.status == .orphanUnused, queue.isSelected else { return false }
            guard seen.orphanCount == 1, seen.activeCount == 1 else { return false }

            return true
        }

        // 7. PPD 整目录误删回归：分组只携带成员文件，Resources 根必须完好
        check("PrinterDriver: PPD 分组仅删成员文件，资源根完好无损") {
            let dir = printerFixtureDir("ppd")
            let printers = (dir as NSString).appendingPathComponent("Printers")
            let resources = (printers as NSString)
                .appendingPathComponent("PPDs/Contents/Resources")
            try? FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
            let langDir = (resources as NSString).appendingPathComponent("HP_LanguagePack")
            try? FileManager.default.createDirectory(atPath: langDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(atPath: dir)
            }

            func write(_ parent: String, _ name: String, _ body: String) -> String {
                let p = (parent as NSString).appendingPathComponent(name)
                try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: p))
                return p
            }
            let hpA = write(resources, "HP_DeskJet_2700.ppd", "*PPD-Adobe: 4.3 hp-a")
            let hpB = write(resources, "HP_LaserJet_1020.ppd.gz", "*PPD-Adobe: 4.3 hp-b")
            let hpSub = write(langDir, "HP_OfficeJet_4650.ppd", "*PPD-Adobe: 4.3 hp-sub")
            let canon = write(resources, "Canon_MF4700.ppd", "*PPD-Adobe: 4.3 canon")
            let notes = write(resources, "readme.txt", "不属于 PPD 的杂项文件")

            let evidence = PrinterEvidence(keywords: ["canon"], sourcesReadable: true)
            let summary = PrinterDriverScanner.shared.scan(
                customPrinterDirs: [printers], customUserPrinterDirs: [],
                customCupsDir: nil, evidence: evidence)

            guard let hpGroup = summary.items.first(where: { $0.kind == .ppdResource && $0.vendor == "惠普 (HP)" })
            else { return false }
            // ① 成员文件粒度：3 个 HP PPD（含语言子目录里那个），不含 Canon 与 txt
            guard Set(hpGroup.memberPaths) == Set([hpA, hpB, hpSub]) else { return false }
            guard !hpGroup.memberPaths.contains(canon), !hpGroup.memberPaths.contains(notes) else { return false }
            // ② 分组自身**不是**删除目标：path 仍是展示用的资源根，但 deletionTargets 只有成员文件
            guard hpGroup.path == FileSystem.normalizePath(resources)
                || hpGroup.path == resources else { return false }
            guard hpGroup.deletionTargets == hpGroup.memberPaths,
                  !hpGroup.deletionTargets.contains(resources) else { return false }
            guard hpGroup.status == .orphanUnused, hpGroup.isSelected else { return false }
            // Canon 组命中在用队列关键词 → 不许删
            guard let canonGroup = summary.items.first(where: { $0.vendor == "佳能 (Canon)" }),
                  canonGroup.status == .activeConfigured, !canonGroup.isSelected else { return false }

            let domain = makeFixtureDomain(id: "selftest.ppd.resources", root: resources)
            let outcome = PrinterDriverScanner.shared.clean(
                items: [hpGroup, canonGroup], toTrash: false,
                journal: .none, domainOverride: domain)
            guard outcome.cleanedCount == 3, outcome.freedBytes > 0 else { return false }
            guard FileManager.default.fileExists(atPath: resources) else { return false }
            guard FileManager.default.fileExists(atPath: langDir) else { return false }
            guard FileManager.default.fileExists(atPath: canon) else { return false }
            guard FileManager.default.fileExists(atPath: notes) else { return false }
            guard !FileManager.default.fileExists(atPath: hpA),
                  !FileManager.default.fileExists(atPath: hpB),
                  !FileManager.default.fileExists(atPath: hpSub) else { return false }
            // 受保护的 Canon 组被 policy 拦下（即便调用方误传）
            guard outcome.rejected.contains(where: { $0.reason == .blockedByBaseGate }) else { return false }
            return true
        }

        // 8. 网关护栏：软链跳板与越界必拒，且目标文件仍在
        check("PrinterDriver: 删除网关拒绝软链跳板与越出治理域") {
            let dir = printerFixtureDir("gate")
            let domain = makeFixtureDomain(id: "selftest.printers.fixture", root: dir)
            let vendor = (dir as NSString).appendingPathComponent("Brother_Legacy")
            try? FileManager.default.createDirectory(atPath: vendor, withIntermediateDirectories: true)
            let real = (vendor as NSString).appendingPathComponent("driver.pkg")
            try? "mock_brother_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: real))
            // 跳板：fixture 内一个指向系统字体目录的软链
            let jump = (dir as NSString).appendingPathComponent("fonts-link")
            try? FileManager.default.createSymbolicLink(
                atPath: jump, withDestinationPath: "/System/Library/Fonts")
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let item = PrinterDriverItem(
                id: jump, name: "fonts-link", vendor: "兄弟 (Brother)", path: jump,
                kind: .vendorDriverBundle, status: .orphanUnused, size: 1_000_000_000,
                modificationDate: Date(), isSelected: true)
            let active = PrinterDriverItem(
                id: vendor, name: "Brother_Legacy", vendor: "兄弟 (Brother)", path: vendor,
                kind: .vendorDriverBundle, status: .activeConfigured, size: 20,
                modificationDate: Date(), isSelected: true)

            let outcome = PrinterDriverScanner.shared.clean(
                items: [item, active], toTrash: false, journal: .none, domainOverride: domain)
            guard outcome.cleanedCount == 0 else { return false }
            guard outcome.freedBytes == 0 else { return false }
            guard outcome.rejected.contains(where: { $0.reason == .symlinkJump }) else { return false }
            guard outcome.rejected.contains(where: { $0.reason == .blockedByBaseGate }) else { return false }
            // 软链与被指向的真实位置都还在
            guard FileManager.default.fileExists(atPath: jump) else { return false }
            guard FileManager.default.fileExists(atPath: "/System/Library/Fonts") else { return false }
            guard FileManager.default.fileExists(atPath: vendor) else { return false }

            // 越出治理域：同一条目换个不在 fixture 根下的路径也必须被拒
            // 越界：真实存在的目录，但不在声明的治理域内
            let elsewhere = printerFixtureDir("elsewhere")
            let outside = PrinterDriverItem(
                id: elsewhere, name: "elsewhere", vendor: "通用/第三方厂商", path: elsewhere,
                kind: .vendorDriverBundle, status: .orphanUnused, size: 1,
                modificationDate: Date(), isSelected: true)
            let out2 = PrinterDriverScanner.shared.clean(
                items: [outside], toTrash: false, journal: .none, domainOverride: domain)
            guard out2.cleanedCount == 0, out2.freedBytes == 0 else { return false }
            guard out2.rejected.first?.reason == .outsideDomain else { return false }
            guard FileManager.default.fileExists(atPath: elsewhere) else { return false }
            try? FileManager.default.removeItem(atPath: elsewhere)

            // 治理域归因：真实 PPD 资源归 .ppdResources，主目录队列不带域
            guard PrinterDriverScanner.domain(for: "/Library/Printers/PPDs/Contents/Resources/HP.ppd")
                == GovernanceDomain.ppdResources else { return false }
            guard PrinterDriverScanner.domain(for: "/Library/Printers/Canon") == GovernanceDomain.printersGlobal
            else { return false }
            guard PrinterDriverScanner.domain(
                for: NSString(string: "~/Library/Printers/Old").expandingTildeInPath) == nil else { return false }

            return true
        }

        // 9. 删除失败不得计入 cleanedCount / freedBytes
        check("PrinterDriver: 删除失败不计账，成功后按实测体积计账") {
            let dir = printerFixtureDir("failed")
            let domain = makeFixtureDomain(id: "selftest.printers.failed", root: dir)
            let victim = (dir as NSString).appendingPathComponent("stuck.pkg")
            try? String(repeating: "x", count: 4096).data(using: .utf8)?
                .write(to: URL(fileURLWithPath: victim))
            // uchg：父目录可写（网关判 allowed），但 unlink 必然 EPERM → 真实删除失败
            guard chmod(victim, 0o644) == 0, Darwin.chflags(victim, UInt32(UF_IMMUTABLE)) == 0 else {
                try? FileManager.default.removeItem(atPath: dir)
                return false
            }
            defer {
                Darwin.chflags(victim, 0)
                try? FileManager.default.removeItem(atPath: dir)
            }

            let item = PrinterDriverItem(
                id: victim, name: "stuck.pkg", vendor: "通用/第三方厂商", path: victim,
                kind: .vendorDriverBundle, status: .orphanUnused,
                size: 999_999_999,          // 扫描期的旧缓存值，不得被当成释放量
                modificationDate: Date(), isSelected: true)

            let failed = PrinterDriverScanner.shared.clean(
                items: [item], toTrash: false, journal: .none, domainOverride: domain)
            guard failed.cleanedCount == 0 else { return false }
            guard failed.freedBytes == 0 else { return false }
            guard failed.errorCount == 1, failed.failed.count == 1 else { return false }
            guard FileManager.default.fileExists(atPath: victim) else { return false }

            // 解除锁定后重删：按**删除前实测**的真实体积计账，而不是 item.size
            Darwin.chflags(victim, 0)
            let ok = PrinterDriverScanner.shared.clean(
                items: [item], toTrash: false, journal: .none, domainOverride: domain)
            guard ok.cleanedCount == 1, ok.failed.isEmpty, ok.rejected.isEmpty else { return false }
            // 记账用删除前实测的真实体积，而不是扫描时缓存的 item.size
            guard ok.freedBytes > 0, ok.freedBytes != item.size else { return false }
            guard !FileManager.default.fileExists(atPath: victim) else { return false }
            guard ok.cleanedPaths.count == 1 else { return false }
            return true
        }

        // 10. CUPS 重载走 SafeProcess，命令与真实结果都要如实上报
        check("PrinterDriver: CUPS 重载经 SafeProcess 执行且失败不谎报") {
            let saved = SafeProcess.runner
            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            defer { SafeProcess.runner = saved }

            let ok = PrinterDriverScanner.shared.refreshCUPS()
            guard ok.success else { return false }
            guard seen.last?.0 == PrinterDriverScanner.killallPath else { return false }
            guard seen.last?.1 == ["-HUP", "cupsd"] else { return false }

            // cupsd 由 root 运行：非 0 返回码必须是失败 + 给出真实原因
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "You have no permission to kill cupsd.")
            }
            let denied = PrinterDriverScanner.shared.refreshCUPS()
            guard !denied.success else { return false }
            guard denied.message.contains("root"), denied.message.contains("不提权") else { return false }
            guard denied.message.contains("no permission") else { return false }

            // 超时不得算成功
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            let slow = PrinterDriverScanner.shared.refreshCUPS()
            guard !slow.success, slow.message.contains("超时") else { return false }
            return true
        }

        // 11. 卡片如实呈现降级与 root 无权限（源码级把住文案，防回归）
        check("PrinterDriver: 卡片如实呈现证据降级与 root 无权限原因") {
            guard let src = SelftestSource.read("PrinterDriverOptimizerCard") else { return false }
            guard src.contains("无法读取 CUPS 打印机配置（需 root），本模块仅提供定位与建议") else { return false }
            guard src.contains("outcome.needsPrivilege") else { return false }
            // 不再自己写护栏，一律交给网关
            guard !src.contains("hasPrefix(\"/System\")") else { return false }
            guard src.contains("PrinterDriverScanner.shared.clean(") else { return false }
            guard src.contains("仅删") && src.contains("memberPaths") else { return false }

            // 模型侧：PPD 分组的删除目标只能是成员文件
            let group = PrinterDriverItem(
                id: "/Library/Printers/PPDs/Contents/Resources#ppd/惠普 (HP)",
                name: "HP group", vendor: "惠普 (HP)",
                path: "/Library/Printers/PPDs/Contents/Resources",
                kind: .ppdResource, status: .orphanUnused, size: 10,
                modificationDate: Date(),
                memberPaths: ["/Library/Printers/PPDs/Contents/Resources/HP_a.ppd"],
                isSelected: true)
            guard group.deletionTargets.count == 1,
                  !group.deletionTargets.contains("/Library/Printers/PPDs/Contents/Resources") else { return false }
            return true
        }

        // 12. 空目录与非驱动杂项文件鲁棒性断言
        check("PrinterDriver: 空目录与非驱动杂项文件鲁棒性断言") {
            let dir = printerFixtureDir("filter")
            // 只放隐藏项：非驱动杂项文件不该出现在结果里（此处以 .DS_Store 覆盖过滤逻辑）
            let hidden = (dir as NSString).appendingPathComponent(".DS_Store")
            try? "hidden".data(using: .utf8)?.write(to: URL(fileURLWithPath: hidden))

            let summary = PrinterDriverScanner.shared.scan(
                customPrinterDirs: [dir],
                customUserPrinterDirs: [dir + "/empty"],
                customCupsDir: dir + "/nocups")
            defer { try? FileManager.default.removeItem(atPath: dir) }

            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0 else { return false }
            guard summary.orphanCount == 0 else { return false }
            return true
        }
    }
}

// MARK: - 打印机套件自检辅助

/// 造一个把 root 指到临时目录的治理域。
/// 网关只认「已声明的域」，自检绝不能拿真实 `/Library` 目录当删除目标。
func makeFixtureDomain(id: String, root: String, depth: Int = 1) -> GovernanceDomain {
    GovernanceDomain(id: id, root: FileSystem.normalizePath(root),
                     minDepthBelowRoot: depth, note: "自检 fixture 专用治理域")
}

/// 在 `NSTemporaryDirectory()` 下建一个干净的 fixture 目录并返回其绝对路径。
func printerFixtureDir(_ name: String) -> String {
    let base = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("MacCleanSelftest/Printer/\(name)")
    try? FileManager.default.removeItem(atPath: base)
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return FileSystem.normalizePath(base)
}

/// 读源码做文案级断言（沿用 `Selftest+Accessibility` 的既有做法）。
/// 用 `#filePath` 定位模块目录，因此**不依赖运行时的工作目录**。
enum SelftestSource {
    static func read(_ file: String, from here: String = #filePath) -> String? {
        let dir = (here as NSString).deletingLastPathComponent
        let probe = (dir as NSString).appendingPathComponent("\(file).swift")
        if let src = try? String(contentsOfFile: probe, encoding: .utf8) { return src }
        return try? String(contentsOfFile: "Sources/MacClean/\(file).swift", encoding: .utf8)
    }
}
