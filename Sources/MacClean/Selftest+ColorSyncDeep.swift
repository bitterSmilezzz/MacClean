import Foundation
import Darwin

// MARK: - 系统多显示器色彩描述与 ICC Profile 残存治理深度自检 (v1.68.0，v1.72.0 判据修复)
//
// 本轮 P0：
// ① `contains("hp")` / `contains("lg")` 式两字子串判据 —— 任何含这两个字母对的文件名
//    都会被判成"显示器/打印机配置"并进"建议清理 + 默认勾选"。
// ② 在用判据方向反了 —— 现在按硬证据链判：接驳显示器 UUID（macOS 生成的 profile 文件名
//    就是 `<显示名>-<UUID>.icc`）→ ColorSync 偏好引用 → 屏幕名整词 → 30 天内写过。
// ③ 屏幕列表为空 / 偏好解析失败时旧实现照判孤儿并默选 —— 现在一律"需确认"。
// 判定链所需的 `screens` 与 `now` 都在 `ColorSyncEvidence` 里，因此自检是真的在执行
// 判定路径，而不是往模型里塞手写标记。

extension Selftest {
    static func suiteColorSyncDeep() {
        print("--- [Suite] 系统多显示器色彩描述与 ICC Profile 残存治理深度自检 (v1.68.0) ---")

        let now = Date(timeIntervalSince1970: 1_800_000_000)          // 固定"今天"，冷热门槛可复现
        let day: TimeInterval = 86_400
        func evidence(displays: [ConnectedDisplay], readable: Bool = true,
                      referenced: Set<String> = [], preferenceReadable: Bool = true)
            -> ColorSyncEvidence {
            ColorSyncEvidence(displays: displays, displaysReadable: readable,
                              referencedProfilePaths: referenced,
                              preferenceReadable: preferenceReadable,
                              preferenceSources: preferenceReadable ? ["fixture"] : [],
                              unreadableSources: readable ? [] : ["NSScreen"],
                              now: now)
        }
        let builtIn = ConnectedDisplay(name: "Built-in Retina Display",
                                       uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230")

        // 1. 配置分类、图标与健康状态研判
        check("ColorSync: 配置分类、图标与健康状态研判") {
            guard ICCProfileKind.displayProfile.icon == "display.2" else { return false }
            guard ICCProfileKind.printerProfile.icon == "printer.fill" else { return false }
            guard ICCProfileKind.customProfile.icon == "slider.horizontal.3" else { return false }
            guard ICCProfileKind.colorSyncCache.icon == "archivebox.fill" else { return false }

            guard ICCProfileStatus.disconnectedOrphan.isOrphanOrCorrupted == true else { return false }
            guard ICCProfileStatus.corrupted.isOrphanOrCorrupted == true else { return false }
            guard ICCProfileStatus.activeConnected.isOrphanOrCorrupted == false else { return false }
            guard ICCProfileStatus.systemProtected.isOrphanOrCorrupted == false else { return false }
            // 核心：新增的两个状态都不得进默认可删集合
            guard ICCProfileStatus.recentlyActive.isOrphanOrCorrupted == false else { return false }
            guard ICCProfileStatus.recentlyActive.isInUseOrProtected == true else { return false }
            guard ICCProfileStatus.needsConfirmation.isOrphanOrCorrupted == false else { return false }
            guard ICCProfileStatus.needsConfirmation.isInUseOrProtected == false else { return false }
            return true
        }

        // 2. 概览指标统计与已选释放容量精算
        check("ColorSync: 概览指标统计与已选释放容量精算") {
            let item1 = ICCProfileItem(
                id: "/p1", name: "Dell_U2720Q.icc", path: "/p1",
                kind: .displayProfile, status: .disconnectedOrphan,
                size: 2048, modificationDate: now, isSelected: true)
            let item2 = ICCProfileItem(
                id: "/p2", name: "Corrupted.icc", path: "/p2",
                kind: .displayProfile, status: .corrupted,
                size: 0, modificationDate: now, isSelected: true)
            let item3 = ICCProfileItem(
                id: "/p3", name: "Built-in Retina.icc", path: "/p3",
                kind: .displayProfile, status: .activeConnected,
                size: 4096, modificationDate: now, isSelected: false)

            let summary = ColorSyncSummary(items: [item1, item2, item3], totalSize: 6144,
                                           orphanCount: 2, orphanSize: 2048, activeCount: 1,
                                           evidenceTrustworthy: true, needsConfirmationCount: 0,
                                           unreadableSources: [])
            guard summary.totalSize == 6144 else { return false }
            guard summary.orphanCount == 2, summary.activeCount == 1 else { return false }
            guard summary.selectedSize == 2048, summary.selectedCount == 2 else { return false }
            guard summary.evidenceTrustworthy, summary.needsConfirmationCount == 0 else { return false }
            return true
        }

        // 3. 厂商词表：短词只允许整词命中，长词才允许子串（回归护栏）
        check("ColorSync: 显式厂商词表与词边界匹配") {
            // "lg"/"hp" 只在整词时命中
            guard ColorSyncScanner.matchesVocabulary("LG UltraFine 4K.icc",
                                                    ColorSyncScanner.displayVendorVocabulary) else { return false }
            guard ColorSyncScanner.matchesVocabulary("HP_Dell_27.icc",
                                                    ColorSyncScanner.displayVendorVocabulary) else { return false }
            // 旧判据 `contains("lg")` / `contains("hp")` 会误命中的名字，现在必须放行
            guard !ColorSyncScanner.matchesVocabulary("Flagship-Studio.icc",
                                                     ColorSyncScanner.displayVendorVocabulary) else { return false }
            guard !ColorSyncScanner.matchesVocabulary("MyHpNotes.icc",
                                                     ColorSyncScanner.displayVendorVocabulary) else { return false }
            guard !ColorSyncScanner.matchesVocabulary("catalog-glossy.icc",
                                                     ColorSyncScanner.displayVendorVocabulary) else { return false }
            guard !ColorSyncScanner.matchesVocabulary("flagship.icc",
                                                     ColorSyncScanner.printerVocabulary) else { return false }
            // ≥4 字符的词允许子串（真机常见连写名）
            guard ColorSyncScanner.matchesVocabulary("DellUltraSharpU2720Q.icc",
                                                    ColorSyncScanner.displayVendorVocabulary) else { return false }
            guard !ColorSyncScanner.matchesVocabulary("BenQPD2705E-2.icc",
                                                     ColorSyncScanner.displayKindVocabulary) else { return false }
            guard ColorSyncScanner.matchesVocabulary("UltraSharp Monitor.icc",
                                                    ColorSyncScanner.displayKindVocabulary) else { return false }
            // 连写但不在词边界上的（"Promonitor"）不算命中
            guard !ColorSyncScanner.matchesVocabulary("Promonitor-X.icc",
                                                     ColorSyncScanner.displayKindVocabulary) else { return false }
            guard ColorSyncScanner.containsAtWordBoundary("epsonnet_config", "epson") else { return false }
            guard !ColorSyncScanner.containsAtWordBoundary("refuji-studio", "fuji") else { return false }
            // 整词切分本身
            guard ColorSyncScanner.tokens(of: "LG_UltraFine-4K.icc") == ["lg", "ultrafine", "4k", "icc"]
            else { return false }
            guard ColorSyncScanner.significantTokens("HP 27 4K Display").contains("display") else { return false }
            guard !ColorSyncScanner.significantTokens("HP 27 4K Display").contains("hp") else { return false }
            return true
        }

        // 4. `<显示名>-<UUID>.icc` 解析与 UUID 格式化（不依赖真实机器）
        check("ColorSync: 显示器 profile 文件名的 UUID 解析与格式化") {
            let uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
            guard ColorSyncScanner.displayUUID(in: "Color LCD-\(uuid).icc") == uuid else { return false }
            guard ColorSyncScanner.displayUUID(in: "UU远程 1-\(uuid.lowercased()).icm") == uuid else { return false }
            guard ColorSyncScanner.displayUUID(in: "Dell UltraFine.icc") == nil else { return false }
            guard ColorSyncScanner.displayUUID(in: "37D8832A-2D66-02CA-B9F7-8F30A301B230.icc") == nil
            else { return false }           // 没有显示名前缀的不算显示器 profile
            guard ColorSyncScanner.displayUUID(in: "HP-LaserJet-1234.icc") == nil else { return false }

            // CFUUID → 8-4-4-4-12 大写串：真实接驳显示器与文件名对得上的前提
            let rawBytes: [UInt8] = [0x37, 0xD8, 0x83, 0x2A, 0x2D, 0x66, 0x02, 0xCA,
                                     0xB9, 0xF7, 0x8F, 0x30, 0xA3, 0x01, 0xB2, 0x30]
            var bytes = CFUUIDBytes()
            withUnsafeMutableBytes(of: &bytes) { $0.copyBytes(from: rawBytes) }
            guard let cf = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, bytes),
                  let formatted = ColorSyncScanner.uuidString(cf) else { return false }
            guard formatted == uuid else { return false }
            return true
        }

        // 5. 在用判据链：UUID / 偏好引用 / 屏幕名整词 / 30 天窗口
        check("ColorSync: 在用判据方向与 30 天窗口") {
            let connected = "/Library/ColorSync/Profiles/Displays/Color LCD-\(builtIn.uuid).icc"
            let stale = "/Library/ColorSync/Profiles/Displays/UU远程 1-4AACECCA-D9C1-472D-8A09-48F7A8DBABBC.icc"
            let ok = evidence(displays: [builtIn])

            // ① 当前接驳显示器的 profile → 在用（受保护）
            let live = ColorSyncScanner.evaluateProfile(
                fileName: "Color LCD-\(builtIn.uuid).icc", path: connected, size: 30_000,
                modificationDate: now.addingTimeInterval(-400 * day), evidence: ok)
            guard live.status == .activeConnected else { return false }
            guard live.kind == .displayProfile else { return false }
            guard let note = live.note, note.contains("Built-in Retina Display") else { return false }

            // ② 断开显示器留下的 profile：无引用 + 超 30 天 → 才允许判残留
            let gone = ColorSyncScanner.evaluateProfile(
                fileName: "UU远程 1-4AACECCA-D9C1-472D-8A09-48F7A8DBABBC.icc", path: stale,
                size: 30_000, modificationDate: now.addingTimeInterval(-400 * day), evidence: ok)
            guard gone.status == .disconnectedOrphan, gone.kind == .displayProfile else { return false }

            // ③ 30 天内写过 → 一律视为在用，哪怕没有任何引用记录
            let fresh = ColorSyncScanner.evaluateProfile(
                fileName: "UU远程 1-4AACECCA-D9C1-472D-8A09-48F7A8DBABBC.icc", path: stale,
                size: 30_000, modificationDate: now.addingTimeInterval(-3 * day), evidence: ok)
            guard fresh.status == .recentlyActive, fresh.status.isOrphanOrCorrupted == false else { return false }

            // ④ 偏好里指向该路径 → 在用
            let referencedPath = "/Users/x/Library/ColorSync/Profiles/My Calibrated.icc"
            let byPref = ColorSyncScanner.evaluateProfile(
                fileName: "My Calibrated.icc", path: referencedPath, size: 30_000,
                modificationDate: now.addingTimeInterval(-400 * day),
                evidence: evidence(displays: [builtIn],
                                   referenced: [FileSystem.normalizePath(referencedPath)]))
            guard byPref.status == .activeConnected else { return false }

            // ⑤ 屏幕名整词命中（无 UUID 形态文件名）
            let byName = ColorSyncScanner.evaluateProfile(
                fileName: "Samsung_S27A80.icc", path: "/Library/ColorSync/Profiles/Samsung_S27A80.icc",
                size: 30_000, modificationDate: now.addingTimeInterval(-400 * day),
                evidence: evidence(displays: [ConnectedDisplay(name: "Samsung S27A80",
                                                               uuid: "00000000-0000-0000-0000-000000000000")]))
            guard byName.status == .activeConnected else { return false }

            // ⑥ 0 字节确证损坏；Apple 内置核心配置永不判残留
            let broken = ColorSyncScanner.evaluateProfile(
                fileName: "Broken.icc", path: "/Library/ColorSync/Profiles/Broken.icc",
                size: 0, modificationDate: now.addingTimeInterval(-400 * day), evidence: ok)
            guard broken.status == .corrupted else { return false }
            let srgb = ColorSyncScanner.evaluateProfile(
                fileName: "sRGB Profile.icc", path: "/Library/ColorSync/Profiles/sRGB Profile.icc",
                size: 3000, modificationDate: now.addingTimeInterval(-400 * day), evidence: ok)
            guard srgb.status == .systemProtected else { return false }
            let sysPath = ColorSyncScanner.evaluateProfile(
                fileName: "Whatever.icc", path: "/System/Library/ColorSync/Profiles/Whatever.icc",
                size: 3000, modificationDate: now.addingTimeInterval(-400 * day), evidence: ok)
            guard sysPath.status == .systemProtected else { return false }
            return true
        }

        // 6. 证据源不可读 → 一律需确认、不默选（含屏幕列表为空的真机场景）
        check("ColorSync: 证据不足时不判残留且不默选") {
            let old = now.addingTimeInterval(-400 * day)
            // ① 接驳显示器列表读不到（无头 / 窗口服务不可用）
            let blind = evidence(displays: [], readable: false)
            let a = ColorSyncScanner.evaluateProfile(
                fileName: "Dell U2720Q.icc", path: "/Library/ColorSync/Profiles/Dell U2720Q.icc",
                size: 30_000, modificationDate: old, evidence: blind)
            guard a.status == .needsConfirmation else { return false }
            guard let note = a.note, note.contains("不判定为残留") else { return false }

            // ② ColorSync 偏好解析失败
            let prefBlind = evidence(displays: [builtIn], preferenceReadable: false)
            let b = ColorSyncScanner.evaluateProfile(
                fileName: "Dell U2720Q.icc", path: "/Library/ColorSync/Profiles/Dell U2720Q.icc",
                size: 30_000, modificationDate: old, evidence: prefBlind)
            guard b.status == .needsConfirmation else { return false }

            // ③ 自定义校准配置：即使证据齐备，也没有"没在用"的证据 → 需确认
            let c = ColorSyncScanner.evaluateProfile(
                fileName: "My Custom Cal 2023.icc",
                path: "/Library/ColorSync/Profiles/My Custom Cal 2023.icc",
                size: 30_000, modificationDate: old, evidence: evidence(displays: [builtIn]))
            guard c.status == .needsConfirmation, c.kind == .customProfile else { return false }

            // ④ 打印机色彩配置：读不到 CUPS 就不许判残留
            let savedPrinterEvidence = ColorSyncScanner.printerEvidenceProvider
            ColorSyncScanner.printerEvidenceProvider = { .unreadable }
            defer { ColorSyncScanner.printerEvidenceProvider = savedPrinterEvidence }
            let p = ColorSyncScanner.evaluateProfile(
                fileName: "Epson_L805_Printer.icc",
                path: "/Library/ColorSync/Profiles/Epson_L805_Printer.icc",
                size: 30_000, modificationDate: old, evidence: evidence(displays: [builtIn]))
            guard p.kind == .printerProfile, p.status == .needsConfirmation else { return false }
            ColorSyncScanner.printerEvidenceProvider = {
                PrinterEvidence(keywords: ["canon"], sourcesReadable: true)
            }
            let q = ColorSyncScanner.evaluateProfile(
                fileName: "Epson_L805_Printer.icc",
                path: "/Library/ColorSync/Profiles/Epson_L805_Printer.icc",
                size: 30_000, modificationDate: old, evidence: evidence(displays: [builtIn]))
            guard q.status == .disconnectedOrphan else { return false }
            let r = ColorSyncScanner.evaluateProfile(
                fileName: "Canon_PROGRAF.icc", path: "/Library/ColorSync/Profiles/Canon_PROGRAF.icc",
                size: 30_000, modificationDate: old, evidence: evidence(displays: [builtIn]))
            guard r.status == .activeConnected else { return false }
            ColorSyncScanner.printerEvidenceProvider = savedPrinterEvidence
            return true
        }

        // 7. 扫描集成：判定链真的被执行（fixture + 注入 screens/now）
        check("ColorSync: 扫描结果的勾选与状态来自判定链") {
            let dir = colorSyncFixtureDir("scan")
            let profiles = (dir as NSString).appendingPathComponent("ColorSync/Profiles")
            let displays = (profiles as NSString).appendingPathComponent("Displays")
            try? FileManager.default.createDirectory(atPath: displays, withIntermediateDirectories: true)
            let caches = (dir as NSString).appendingPathComponent("Caches/com.apple.ColorSync")
            try? FileManager.default.createDirectory(atPath: caches, withIntermediateDirectories: true)

            @discardableResult
            func make(_ parent: String, _ name: String, _ body: String, ageDays: Double) -> String {
                let p = (parent as NSString).appendingPathComponent(name)
                try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: p))
                try? FileManager.default.setAttributes(
                    [.modificationDate: now.addingTimeInterval(-ageDays * day)], ofItemAtPath: p)
                return p
            }
            make(displays, "Color LCD-\(builtIn.uuid).icc", "profile-bytes-connected", ageDays: 400)
            make(displays, "UU远程 2-BD420064-B73A-491F-9D62-EB23C4385144.icc",
                 "profile-bytes-stale", ageDays: 400)
            make(profiles, "Flagship-Studio.icc", "not-an-lg-display", ageDays: 400)
            make(profiles, "Zero.icc", "", ageDays: 400)
            make(caches, "preview.data", "cache-bytes", ageDays: 400)
            make(caches, "fresh-preview.data", "cache-bytes", ageDays: 2)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let summary = ColorSyncScanner.shared.scan(
                customDirectories: [profiles, caches],
                evidence: evidence(displays: [builtIn]))

            let names = summary.items.map { $0.name }
            guard names.count == Set(names).count else { return false }
            // 接驳显示器的配置受保护
            guard let liveItem = summary.items.first(where: { $0.name.contains(builtIn.uuid) }),
                  liveItem.status == .activeConnected, !liveItem.isSelected else { return false }
            // 断开显示器的陈旧 profile 才是残留
            guard let staleItem = summary.items.first(where: { $0.name.contains("BD420064") }),
                  staleItem.status == .disconnectedOrphan, staleItem.isSelected else { return false }
            // "Flagship" 不再因含 "lg" 被当成显示器配置
            guard let flagship = summary.items.first(where: { $0.name == "Flagship-Studio.icc" }),
                  flagship.status == .needsConfirmation, flagship.kind == .customProfile,
                  !flagship.isSelected else { return false }
            guard let zero = summary.items.first(where: { $0.name == "Zero.icc" }),
                  zero.status == .corrupted, zero.isSelected else { return false }
            // 缓存：30 天内写过的不算残留
            guard let oldCache = summary.items.first(where: { $0.name == "preview.data" }),
                  oldCache.kind == .colorSyncCache, oldCache.status == .disconnectedOrphan
            else { return false }
            guard let newCache = summary.items.first(where: { $0.name == "fresh-preview.data" }),
                  newCache.status == .recentlyActive, !newCache.isSelected else { return false }
            // 残留 = 断开显示器的陈旧 profile + 0 字节损坏 + 超窗口的缓存
            guard summary.orphanCount == 3, summary.needsConfirmationCount == 1 else { return false }
            guard summary.evidenceTrustworthy else { return false }
            // 域归因：fixture 路径不属于任何真实域；真实全局目录归 .colorSyncProfiles
            guard staleItem.domainID == nil else { return false }
            guard ColorSyncScanner.domain(for: "/Library/ColorSync/Displays/x.icc") == nil else { return false }
            guard ColorSyncScanner.domain(for: "/Library/ColorSync/Profiles/Displays/x.icc")
                == GovernanceDomain.colorSyncProfiles else { return false }
            return true
        }

        // 8. 网关护栏：软链跳板必拒、目标完好，域根禁删
        check("ColorSync: 删除网关拒绝软链跳板与系统位置") {
            let dir = colorSyncFixtureDir("gate")
            let domain = makeFixtureDomain(id: "selftest.colorsync.profiles", root: dir)
            let victim = (dir as NSString).appendingPathComponent("Stale Display.icc")
            try? "profile-bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: victim))
            let jump = (dir as NSString).appendingPathComponent("system-link")
            try? FileManager.default.createSymbolicLink(atPath: jump,
                                                       withDestinationPath: "/System/Library/ColorSync")
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let orphan = ICCProfileItem(id: victim, name: "Stale Display.icc", path: victim,
                                        kind: .displayProfile, status: .disconnectedOrphan,
                                        size: 13, modificationDate: now, isSelected: true)
            let link = ICCProfileItem(id: jump, name: "system-link", path: jump,
                                     kind: .displayProfile, status: .disconnectedOrphan,
                                     size: 800_000_000, modificationDate: now, isSelected: true)
            let protected = ICCProfileItem(id: "/System/Library/ColorSync/Profiles/x.icc",
                                           name: "x.icc", path: "/System/Library/ColorSync/Profiles/x.icc",
                                           kind: .displayProfile, status: .disconnectedOrphan,
                                           size: 1, modificationDate: now, isSelected: true)
            let out = ColorSyncScanner.shared.clean(items: [orphan, link, protected],
                                                    toTrash: false, journal: .none,
                                                    domainOverride: domain)
            guard out.cleanedCount == 1 else { return false }
            guard out.rejected.contains(where: { $0.reason == .symlinkJump }) else { return false }
            guard out.rejected.contains(where: { $0.reason == .systemProtected }) else { return false }
            guard FileManager.default.fileExists(atPath: "/System/Library/ColorSync") else { return false }
            guard FileManager.default.fileExists(atPath: jump) else { return false }
            guard !FileManager.default.fileExists(atPath: victim) else { return false }

            // 域根自身永不是删除目标（真机只读判定）
            let rootVerdict = FileSystem.governanceVerdict(
                "/Library/ColorSync/Profiles", domain: GovernanceDomain.colorSyncProfiles)
            guard case .rejected(let reason) = rootVerdict, reason == .tooShallowForDomain else { return false }
            return true
        }

        // 9. 删除失败不得计入 cleanedCount / freedBytes
        check("ColorSync: 删除失败不计账，成功后按实测体积计账") {
            let dir = colorSyncFixtureDir("failed")
            let domain = makeFixtureDomain(id: "selftest.colorsync.failed", root: dir)
            let stuck = (dir as NSString).appendingPathComponent("stuck.icc")
            try? String(repeating: "z", count: 3000).data(using: .utf8)?
                .write(to: URL(fileURLWithPath: stuck))
            guard Darwin.chflags(stuck, UInt32(UF_IMMUTABLE)) == 0 else {
                try? FileManager.default.removeItem(atPath: dir)
                return false
            }
            defer {
                Darwin.chflags(stuck, 0)
                try? FileManager.default.removeItem(atPath: dir)
            }

            let item = ICCProfileItem(id: stuck, name: "stuck.icc", path: stuck,
                                      kind: .displayProfile, status: .disconnectedOrphan,
                                      size: 700_000_000, modificationDate: now, isSelected: true)
            let failed = ColorSyncScanner.shared.clean(items: [item], toTrash: false,
                                                       journal: .none, domainOverride: domain)
            guard failed.cleanedCount == 0, failed.freedBytes == 0 else { return false }
            guard failed.failed.count == 1, failed.errorCount == 1 else { return false }
            guard FileManager.default.fileExists(atPath: stuck) else { return false }

            Darwin.chflags(stuck, 0)
            let ok = ColorSyncScanner.shared.clean(items: [item], toTrash: false,
                                                   journal: .none, domainOverride: domain)
            guard ok.cleanedCount == 1, ok.freedBytes > 0, ok.freedBytes != item.size else { return false }
            guard !FileManager.default.fileExists(atPath: stuck) else { return false }
            guard ok.trashedSnapshots.isEmpty else { return false }   // 彻底删除不该留撤销快照
            return true
        }

        // 10. 证据采集的两个注入点（screens / now）与偏好解析
        check("ColorSync: 证据采集注入点与偏好引用解析") {
            let dir = colorSyncFixtureDir("evidence")
            let prefs = (dir as NSString).appendingPathComponent("ColorSync Preferences.plist")
            let connectedReference
                = "/Library/ColorSync/Profiles/Displays/Color LCD-37D8832A-2D66-02CA-B9F7-8F30A301B230.icc"
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Current Profiles</key>
              <dict>
                <key>37D8832A-2D66-02CA-B9F7-8F30A301B230</key>
                <string>\(connectedReference)</string>
                <key>Other</key>
                <string>/Users/x/My Calibrated.icm</string>
                <key>NotAProfile</key>
                <string>/Users/x/nothing.txt</string>
              </dict>
            </dict>
            </plist>
            """
            try? xml.write(toFile: prefs, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            switch ColorSyncScanner.collectReferencedProfiles(at: prefs) {
            case .ok(let paths, let existed):
                guard existed else { return false }
                guard paths.contains(connectedReference) else { return false }
                guard paths.contains("my calibrated.icm") else { return false }
                guard !paths.contains("/users/x/nothing.txt") else {
                    return false
                }
            case .failed:
                return false
            }

            // 不存在 = 真的没有引用记录（不是"读不到"）
            switch ColorSyncScanner.collectReferencedProfiles(
                at: (dir as NSString).appendingPathComponent("missing.plist")) {
            case .ok(let set, let existed):
                guard set.isEmpty, !existed else {
                    return false
                }
            case .failed:
                return false
            }

            // 存在但读不到 → 必须显式降级，不能当成"没有引用记录"
            let locked = (dir as NSString).appendingPathComponent("locked.plist")
            try? xml.write(toFile: locked, atomically: true, encoding: .utf8)
            chmod(locked, 0o000)
            defer { chmod(locked, 0o644) }
            var degraded = false
            if case .failed = ColorSyncScanner.collectReferencedProfiles(at: locked) { degraded = true }
            guard degraded else { return false }
            // evidenceProvider 注入：自检从此不依赖真实 NSScreen
            let saved = ColorSyncScanner.evidenceProvider
            ColorSyncScanner.evidenceProvider = {
                ColorSyncEvidence(displays: [ConnectedDisplay(name: "Fixture Display", uuid: "F")],
                                  displaysReadable: true, referencedProfilePaths: [],
                                  preferenceReadable: true, now: now)
            }
            defer { ColorSyncScanner.evidenceProvider = nil }
            let collected = ColorSyncScanner.collectEvidence(now: now)
            guard collected.displays.first?.name == "Fixture Display", collected.now == now else {
                return false
            }
            ColorSyncScanner.evidenceProvider = saved

            // 真实通路：无头/权限受限时也必须标成"读不到"，而不是"没有引用"
            let (realDisplays, readable) = ColorSyncScanner.currentDisplays()
            guard readable == !realDisplays.isEmpty else { return false }
            guard realDisplays.allSatisfy({ !$0.name.isEmpty }) else {
                return false
            }
            return true
        }

        // 11. 卡片如实呈现证据降级与 root 无权限原因
        check("ColorSync: 卡片如实呈现证据降级与 root 无权限原因") {
            guard let src = SelftestSource.read("ColorSyncProfileCard") else { return false }
            guard src.contains("无法读全「当前接驳显示器 / ColorSync 偏好引用」") else { return false }
            guard src.contains("outcome.needsPrivilege") else { return false }
            guard src.contains("evidenceNote") else { return false }
            guard src.contains("selectableItems") else { return false }
            guard !src.contains("hasPrefix(\"/System\")") else { return false }
            guard !src.contains("trashItem") else { return false }
            let message = GovernanceVerdict.rejected(.needsPrivilege).message
            guard message.contains("root 管理"), message.contains("无删除权限") else { return false }
            return true
        }

        // 12. 非 profile 杂项文件过滤
        check("ColorSync: 空目录与非 profile 杂项文件过滤") {
            let dir = colorSyncFixtureDir("filter")
            try? "readme".data(using: .utf8)?.write(to: URL(
                fileURLWithPath: (dir as NSString).appendingPathComponent("readme.txt")))
            try? "plist".data(using: .utf8)?.write(to: URL(
                fileURLWithPath: (dir as NSString).appendingPathComponent("config.plist")))
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let summary = ColorSyncScanner.shared.scan(
                customDirectories: [dir], evidence: evidence(displays: [builtIn]))
            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0, summary.orphanCount == 0 else { return false }
            return true
        }
    }
}

// MARK: - ColorSync 套件自检辅助

/// 在 `NSTemporaryDirectory()` 下建干净的 fixture 目录（绝不碰真实 /Library/ColorSync）
func colorSyncFixtureDir(_ name: String) -> String {
    let base = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("MacCleanSelftest/ColorSync/\(name)")
    try? FileManager.default.removeItem(atPath: base)
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return FileSystem.normalizePath(base)
}
