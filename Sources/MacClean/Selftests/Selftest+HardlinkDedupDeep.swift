import Foundation
import Darwin

// MARK: - APFS 硬链接 / 写时复制去重自检套件 (v1.47.0 / v1.72.0 安全加固)

extension Selftest {
    static func suiteHardlinkDedupDeep() {
        print("==> 运行 APFS 硬链接无损去重深度自检 (v1.47.0)...")

        let fm = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacCleanHardlinkTest_\(UUID().uuidString)")
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        let fileA = tempDir.appendingPathComponent("original_movie.mp4")
        let fileB = tempDir.appendingPathComponent("redundant_copy.mp4")
        let fileC = tempDir.appendingPathComponent("different_size.mp4")

        let sampleContent = "MacClean APFS Hardlink Lossless Deduplication Test Content 1234567890"
        // fixture 一律拨老 30 天：刚写下的文件按"可能正在被写"处理，不参与去重
        HardlinkTestSupport.writeAged(fileA, sampleContent)
        HardlinkTestSupport.writeAged(fileB, sampleContent)
        HardlinkTestSupport.writeAged(fileC, "different")

        // 1. 验证初始状态是两个独立的 inode
        check("硬链接去重：初始两份完全相同文件拥有不同 inode") {
            guard let a = HardlinkDedupService.fingerprint(ofPath: fileA.path),
                  let b = HardlinkDedupService.fingerprint(ofPath: fileB.path) else { return false }
            return a.inodeKey != b.inodeKey && a.nlink == 1 && b.nlink == 1
                && a.size == b.size && a.size == Int64(sampleContent.utf8.count)
        }

        // 2. 执行硬链接原子替换（成功路径必须留下 nlink ≥ 2 的复核证据）
        check("硬链接去重：dedup 成功合并 inode 并释放物理字节") {
            guard let (succeeded, freed) = try? HardlinkDedupService.dedup(
                sourcePath: fileA.path, targetPath: fileB.path, journal: .none) else {
                print("    dedup 抛错（被稳定性/在用判据挡住？）")
                return false
            }
            guard succeeded && freed == Int64(sampleContent.utf8.count) else { return false }

            // 检查内容完整性
            guard let readBack = try? String(contentsOf: fileB, encoding: .utf8), readBack == sampleContent else {
                return false
            }
            let src = HardlinkDedupService.fingerprint(ofPath: fileA.path)
            let tgt = HardlinkDedupService.fingerprint(ofPath: fileB.path)
            guard HardlinkDedupService.isLinkVerified(source: src, target: tgt) else {
                print("    链接后复核未通过：\(String(describing: src?.nlink)) / \(String(describing: tgt?.nlink))")
                return false
            }
            return src?.inodeKey == tgt?.inodeKey && tgt?.nlink == 2
        }

        // 3. 幂等性：已是硬链接时安全跳过且不报错
        check("硬链接去重：对已是硬链接的目标执行去重安全跳过 (freedBytes=0)") {
            let before = HardlinkDedupService.fingerprint(ofPath: fileB.path)
            guard let (succeeded, freed) = try? HardlinkDedupService.dedup(
                sourcePath: fileA.path, targetPath: fileB.path, journal: .none) else { return false }
            guard succeeded == true && freed == 0 else { return false }
            let after = HardlinkDedupService.fingerprint(ofPath: fileB.path)
            // 已是硬链接 → 一个字节都不该再计，inode 也不变
            return before?.inodeKey == after?.inodeKey && after?.nlink == 2
        }

        // 4. 安全防护：内容/大小不一致的文件拒绝去重
        check("硬链接去重：大小不一致的目标文件被安全拒绝") {
            do {
                _ = try HardlinkDedupService.dedup(sourcePath: fileA.path, targetPath: fileC.path, journal: .none)
                return false // 应该抛出错误
            } catch {
                guard case .rejected = HardlinkDedupService.performDedup(
                    sourcePath: fileA.path, targetPath: fileC.path, journal: .none).status else { return false }
                return error.localizedDescription.contains("大小不一致")
            }
        }

        // 5. 批量组去重逻辑测试 (dedupSelected)：必须带上扫描期指纹一起复核
        check("硬链接去重：DuplicateGroup 批量无损去重与结果统计") {
            let fileD = tempDir.appendingPathComponent("batch_source.bin")
            let fileE = tempDir.appendingPathComponent("batch_target.bin")
            let data = "BatchBinaryDataTesting123456"
            HardlinkTestSupport.writeAged(fileD, data)
            HardlinkTestSupport.writeAged(fileE, data)

            let itemD = DuplicateFileItem(
                path: fileD.path,
                name: "batch_source.bin",
                size: Int64(data.utf8.count),
                modificationDate: HardlinkDedupService.fingerprint(ofPath: fileD.path)?.mtime,
                isSelected: false,
                isOriginal: true,
                inodeKey: HardlinkDedupService.fingerprint(ofPath: fileD.path)?.inodeKey
            )
            let itemE = DuplicateFileItem(
                path: fileE.path,
                name: "batch_target.bin",
                size: Int64(data.utf8.count),
                modificationDate: HardlinkDedupService.fingerprint(ofPath: fileE.path)?.mtime,
                isSelected: true,
                isOriginal: false,
                inodeKey: HardlinkDedupService.fingerprint(ofPath: fileE.path)?.inodeKey
            )
            let group = DuplicateGroup(hash: "dummy_hash", fileSize: Int64(data.utf8.count),
                                       items: [itemD, itemE], matchKind: .exact)

            let result = HardlinkDedupService.dedupSelected(in: [group], journal: .none)
            guard result.succeededCount == 1, result.freedBytes == Int64(data.utf8.count),
                  result.notDoneCount == 0 else {
                print("    批量结果失真：\(result.summaryText)")
                return false
            }
            return HardlinkDedupService.isLinkVerified(
                source: HardlinkDedupService.fingerprint(ofPath: fileD.path),
                target: HardlinkDedupService.fingerprint(ofPath: fileE.path))
        }

        // 6. 扫描之后文件被改写 → 指纹不符，必须跳过且不动内容
        check("硬链接去重：目标在扫描后被改写时必须跳过") {
            let src = tempDir.appendingPathComponent("fingerprint_src.bin")
            let tgt = tempDir.appendingPathComponent("fingerprint_tgt.bin")
            let other = tempDir.appendingPathComponent("late_user_edit.bin")
            let content = String(repeating: "A", count: 4096)
            HardlinkTestSupport.writeAged(src, content)
            HardlinkTestSupport.writeAged(tgt, content)
            HardlinkTestSupport.writeAged(other, content)

            // 扫描期指纹（全部按 30 天前的老副本记录）
            let recordedTarget = HardlinkDedupService.fingerprint(ofPath: tgt.path)
            let recordedSource = HardlinkDedupService.fingerprint(ofPath: src.path)
            guard recordedTarget != nil, recordedSource != nil else { return false }

            // ① 用户改了副本内容（同长度、mtime 变新）
            try? content.data(using: .utf8)?.write(to: URL(fileURLWithPath: other.path))
            HardlinkTestSupport.age(tgt.path, days: 0)
            let edited = HardlinkDedupService.performDedup(sourcePath: src.path, targetPath: tgt.path,
                                                           sourceFingerprint: recordedSource,
                                                           targetFingerprint: recordedTarget, journal: .none)
            guard case .skipped(let reason) = edited.status, reason.contains("文件已变化") else {
                print("    mtime 漂移未拦：\(edited.status)")
                return false
            }
            // ② 扫描期指纹里记的 inode 与当前不符（副本被换成了另一个文件）
            let currentOther = HardlinkDedupService.fingerprint(ofPath: other.path)
            let staleInode = HardlinkDedupService.fingerprint(ofPath: src.path)
            guard let currentOther, let staleInode else { return false }
            let second = HardlinkDedupService.performDedup(sourcePath: src.path, targetPath: other.path,
                                                           sourceFingerprint: recordedSource,
                                                           targetFingerprint: currentOther.withInodeKey(staleInode.inodeKey),
                                                           journal: .none)
            guard case .skipped(let reason2) = second.status, reason2.contains("文件已变化") else {
                print("    inode 漂移未拦：\(second.status)")
                return false
            }
            // ③ 源与目标都还在、内容没被改坏
            guard let readBack = try? String(contentsOf: tgt, encoding: .utf8), readBack == content else { return false }
            guard HardlinkDedupService.fingerprint(ofPath: src.path)?.nlink == 1 else {
                print("    跳过的判定却已经做了链接？")
                return false
            }
            return true
        }

        // 7. G6 硬排除与受保护位置一律拒绝（照片库 / iCloud / 云盘 / 邮件 / SIP）
        check("硬链接去重：G6 硬排除与受保护位置必须拒绝") {
            let home = NSHomeDirectory()
            for path in [
                home + "/Library/Mail/Mail Downloads/dup.mov",
                home + "/Library/Mobile Documents/com~apple~CloudDocs/副本.key",
                home + "/Library/CloudStorage/GoogleDrive-acc/Backup/副本.png",
                home + "/Library/Group Containers/group.com.apple.notes/dup",
                home + "/Library/Keychains/whatever.db",
                home + "/Pictures/Photos Library.photoslibrary/database/dup.heic",
                home + "/Pictures/Photos Library.photoslibrary/originals/4/IMG_0004.mov",
                "/System/Library/PrivateFrameworks/X.framework/dup",
                "/usr/share/misc/dup",
            ] {
                guard HardlinkDedupService.guardRejection(forPath: path) != nil else {
                    print("    受保护位置未拦：\(path)")
                    return false
                }
            }
            // 用户白名单同样拒绝（本轮之前它对去重完全无效）
            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            defer { wm.rules = savedRules }
            let guarded = tempDir.appendingPathComponent("whitelist_guard.bin")
            HardlinkTestSupport.writeAged(guarded, "guard-me")
            _ = wm.addPathRule(guarded.path, comment: "自检保护")
            guard HardlinkDedupService.guardRejection(forPath: guarded.path) == .userWhitelisted else { return false }

            // 整对里任一头踩线 → 拒绝执行，且不动源文件
            let srcOK = tempDir.appendingPathComponent("guard_source.bin")
            HardlinkTestSupport.writeAged(srcOK, "same-payload")
            let outcome = HardlinkDedupService.performDedup(
                sourcePath: srcOK.path,
                targetPath: home + "/Library/Mail/Mail Downloads/same-payload",
                journal: .none)
            guard case .rejected = outcome.status,
                  HardlinkDedupService.fingerprint(ofPath: srcOK.path)?.nlink == 1 else {
                print("    邮件库目标未被拒：\(outcome.status)")
                return false
            }
            return true
        }

        // 8. `nlink < 2` 判据：链接后复核不过就绝不记已释放
        check("硬链接去重：nlink < 2 一律不得计成已释放") {
            let aged = tempDir.appendingPathComponent("nlink_probe.bin")
            HardlinkTestSupport.writeAged(aged, "probe")
            guard let real = HardlinkDedupService.fingerprint(ofPath: aged.path) else { return false }
            // 同一 inode 但 nlink 仍是 1 → 说明 link/rename 没并成一项 → 不算成功
            let fakeLinked = DedupFingerprint(inodeKey: real.inodeKey, size: real.size, mtime: real.mtime, nlink: 1)
            guard HardlinkDedupService.isLinkVerified(source: fakeLinked, target: fakeLinked) == false else { return false }
            let unlinked = DedupFingerprint(inodeKey: real.inodeKey + "-other", size: real.size, mtime: real.mtime, nlink: 5)
            guard HardlinkDedupService.isLinkVerified(source: real, target: unlinked) == false else { return false }
            let verified = DedupFingerprint(inodeKey: real.inodeKey, size: real.size, mtime: real.mtime, nlink: 2)
            return HardlinkDedupService.isLinkVerified(source: verified, target: verified)
        }

        // 9. 内容一致性不再只信上游 `.exact`：同大小不同内容必须拒
        check("硬链接去重：同大小不同内容必须拒绝（内容抽查）") {
            let a = tempDir.appendingPathComponent("probe_a.bin")
            let b = tempDir.appendingPathComponent("probe_b.bin")
            let size = 300_000            // 跨过 64 KB 取样窗口
            HardlinkTestSupport.writeRaw(a, Data(repeating: 0x41, count: size))
            var mutated = Data(repeating: 0x41, count: size)
            mutated[size - 1] = 0x42
            HardlinkTestSupport.writeRaw(b, mutated)
            HardlinkTestSupport.age(a.path, days: 30)
            HardlinkTestSupport.age(b.path, days: 30)

            guard HardlinkDedupService.contentProbeMatches(a.path, b.path) == false else {
                print("    尾部差异没抽查出来")
                return false
            }
            let outcome = HardlinkDedupService.performDedup(sourcePath: a.path, targetPath: b.path, journal: .none)
            guard case .rejected(let reason) = outcome.status, reason.contains("内容抽查") else { return false }
            // 头尾都一致时才允许（同一份内容）
            let c = tempDir.appendingPathComponent("probe_c.bin")
            HardlinkTestSupport.writeRaw(c, Data(repeating: 0x41, count: size))
            HardlinkTestSupport.age(c.path, days: 30)
            guard HardlinkDedupService.contentProbeMatches(a.path, c.path) else { return false }
            let ok = HardlinkDedupService.performDedup(sourcePath: a.path, targetPath: c.path, journal: .none)
            guard case .linked(let freed) = ok.status, freed == Int64(size) else {
                print("    一致内容被误拒：\(ok.status)")
                return false
            }
            return true
        }

        // 10. 在用判据：刚被写过、或采样期间还在变的文件必须跳过
        check("硬链接去重：正在被写入的文件必须跳过去重") {
            let src = tempDir.appendingPathComponent("inflight_src.bin")
            let tgt = tempDir.appendingPathComponent("inflight_tgt.bin")
            let payload = "inflight-writer-probe"
            HardlinkTestSupport.writeAged(src, payload)
            HardlinkTestSupport.writeAged(tgt, payload)

            // ① 目标刚被写过（mtime = 现在）→ 跳过
            try? payload.write(to: URL(fileURLWithPath: tgt.path), atomically: true, encoding: .utf8)
            let fresh = HardlinkDedupService.performDedup(sourcePath: src.path, targetPath: tgt.path, journal: .none)
            guard case .skipped(let reason) = fresh.status, reason.contains("刚被写入") else {
                print("    刚写入的目标未拦：\(fresh.status)")
                return false
            }

            // ② 双采样窗口内还在增长 → 稳定性判据必须失败
            HardlinkTestSupport.age(tgt.path, days: 30)
            let growing = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            growing.schedule(deadline: .now(), repeating: .milliseconds(20))
            growing.setEventHandler {
                if let handle = FileHandle(forWritingAtPath: tgt.path) {
                    handle.seekToEndOfFile()
                    handle.write(Data(repeating: 0x7a, count: 16))
                    handle.closeFile()
                }
            }
            growing.resume()
            usleep(60_000)
            let stable = HardlinkDedupService.isStable(path: tgt.path, sampleInterval: 0.4)
            growing.cancel()
            guard stable == false else {
                print("    持续增长的文件被判定为稳定")
                return false
            }
            // ③ 未加锁的正常文件不得误判为"被占用"
            let idle = tempDir.appendingPathComponent("idle-probe.bin")
            HardlinkTestSupport.writeAged(idle, payload)
            guard HardlinkDedupService.advisoryLockHolderPID(idle.path) == nil else { return false }
            return HardlinkDedupService.isStable(path: idle.path, sampleInterval: 0.05)
        }

        // 11. 不可逆操作必须留痕：成功写历史、失败与跳过如实计数
        check("硬链接去重：历史记录与失败/跳过分别如实上报") {
            let savedOverride = HistoryStore.fileURLOverride
            let historyURL = tempDir.appendingPathComponent("history.json")
            HistoryStore.fileURLOverride = historyURL
            defer { HistoryStore.fileURLOverride = savedOverride }

            let src = tempDir.appendingPathComponent("history_src.bin")
            let tgt = tempDir.appendingPathComponent("history_tgt.bin")
            let payload = "history-trace-payload"
            HardlinkTestSupport.writeAged(src, payload)
            HardlinkTestSupport.writeAged(tgt, payload)

            let sourceItem = DuplicateFileItem(
                path: src.path, name: "history_src.bin", size: Int64(payload.utf8.count),
                modificationDate: HardlinkDedupService.fingerprint(ofPath: src.path)?.mtime,
                inodeKey: HardlinkDedupService.fingerprint(ofPath: src.path)?.inodeKey)
            let targetItem = DuplicateFileItem(
                path: tgt.path, name: "history_tgt.bin", size: Int64(payload.utf8.count),
                modificationDate: HardlinkDedupService.fingerprint(ofPath: tgt.path)?.mtime,
                isSelected: true,
                inodeKey: HardlinkDedupService.fingerprint(ofPath: tgt.path)?.inodeKey)
            let group = DuplicateGroup(hash: "h", fileSize: Int64(payload.utf8.count),
                                       items: [sourceItem, targetItem], matchKind: .exact)

            let result = HardlinkDedupService.dedupSelected(in: [group])
            guard result.succeededCount == 1, result.freedBytes == Int64(payload.utf8.count) else { return false }

            let records = HistoryStore.load()
            guard let record = records.first,
                  record.categoryName == HardlinkDedupService.historyCategory,
                  record.bytes == Int64(payload.utf8.count),
                  record.mode.contains("不可撤销") else {
                print("    历史未落盘：\(records)")
                return false
            }

            // 失败/跳过绝不计成已释放
            let badGroup = DuplicateGroup(hash: "h2", fileSize: 10,
                                          items: [sourceItem, DuplicateFileItem(
                                            path: NSHomeDirectory() + "/Library/Mail/x.bin", name: "x.bin",
                                            size: 10, modificationDate: Date(), isSelected: true)],
                                          matchKind: .exact)
            let rejected = HardlinkDedupService.dedupSelected(in: [badGroup], journal: .none)
            guard rejected.succeededCount == 0, rejected.freedBytes == 0,
                  rejected.notDoneCount == 1, !rejected.rejections.isEmpty else {
                print("    受保护目标被计成了成功：\(rejected.summaryText)")
                return false
            }
            return HistoryStore.load().count == records.count   // 被拒的项不得再多写一条
        }
    }
}

/// 硬链接去重自检 fixture 工具
enum HardlinkTestSupport {
    /// 写入并把 mtime 拨老 30 天（避开"刚被写入 = 可能在用"保护窗口）
    static func writeAged(_ url: URL, _ content: String) {
        try? content.write(to: url, atomically: true, encoding: .utf8)
        age(url.path, days: 30)
    }

    static func writeRaw(_ url: URL, _ data: Data) {
        try? data.write(to: url)
    }

    static func age(_ path: String, days: Int) {
        let date = days == 0 ? Date() : Date().addingTimeInterval(-Double(days) * 86400)
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }
}

extension DedupFingerprint {
    /// 自检用：造一个"inode 已经变了"的指纹
    func withInodeKey(_ key: String) -> DedupFingerprint {
        DedupFingerprint(inodeKey: key, size: size, mtime: mtime, nlink: nlink)
    }
}
