import Foundation

// 自检套件：Mail 附件清理（v1.73.15）
//
// 夹具全部在 /private/tmp（网关的常规放行根；/var/folders 不在放行根，v1.73.14 教训），
// `rootsOverride` 注入——自检永不碰真实 Mail 目录。

extension Selftest {
    static func suiteMailAttachments() {

        check("Mail 附件：可读根下条目如实列出，且零默认勾选") {
            let root = "/private/tmp/macclean-mail-fixture-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let fm = FileManager.default
            fm.createFile(atPath: root + "/report.pdf", contents: Data(repeating: 1, count: 8192))
            fm.createFile(atPath: root + "/photo.jpg", contents: Data(repeating: 2, count: 2048))
            // 复审 P2-1 的夹具：根下嵌一个同名「Attachments」目录——「根文件直收」与
            // 「Attachments 目录收集」两条通道都会枚举到 inner.bin，去重前体积双计
            try? fm.createDirectory(atPath: root + "/Attachments", withIntermediateDirectories: true)
            fm.createFile(atPath: root + "/Attachments/inner.bin", contents: Data(repeating: 8, count: 1024))
            MailAttachmentsScanner.rootsOverride = [MailAttachmentsScanner.MailRoot(path: root, collectsRootFiles: true)]
            defer { MailAttachmentsScanner.rootsOverride = nil }

            let summary = MailAttachmentsScanner.scan()
            guard summary.items.count == 3, summary.totalSize == 8192 + 2048 + 1024 else {
                print("      items=\(summary.items.count) total=\(summary.totalSize)（双收或漏收）")
                return false
            }
            guard summary.isResultComplete, summary.unreadableRoots.isEmpty else {
                print("      可读根被报成读不到：\(summary.issues)")
                return false
            }
            // 零默认勾选是安全策略（变异：把 AttachmentItem.isSelected 默认值翻成 true，本条必须红）
            guard summary.items.allSatisfy({ !$0.isSelected }),
                  summary.selectedCount == 0, summary.selectedSize == 0 else {
                print("      出现了默认勾选——「需确认」档的承诺被破坏")
                return false
            }
            // 单文件体积来自共享入口（allocated 口径），mtime 有值（年龄只说量到的）
            guard let first = summary.items.first(where: { $0.name == "report.pdf" }),
                  first.size == 8192, first.modifiedAt != nil, first.readable else {
                print("      条目字段缺失：\(summary.items)")
                return false
            }
            return true
        }

        check("Mail 附件：Mail 本体库只收「Attachments」目录（结构标记，不是整棵树）") {
            let root = "/private/tmp/macclean-mail-tree-\(UUID().uuidString)"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: root + "/V2/Account.imapmbox/Mailboxes/INBOX.imapmbox/Attachments/42", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: root + "/V2/Account.imapmbox/Mailboxes/INBOX.imapmbox/Messages", withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            fm.createFile(atPath: root + "/V2/Account.imapmbox/Mailboxes/INBOX.imapmbox/Attachments/42/report.pdf",
                          contents: Data(repeating: 3, count: 4096))
            fm.createFile(atPath: root + "/V2/Account.imapmbox/Mailboxes/INBOX.imapmbox/Messages/42.eml",
                          contents: Data(repeating: 4, count: 512))
            MailAttachmentsScanner.rootsOverride = [MailAttachmentsScanner.MailRoot(path: root, collectsRootFiles: false)]
            defer { MailAttachmentsScanner.rootsOverride = nil }

            let summary = MailAttachmentsScanner.scan()
            guard summary.attachmentDirsFound == 1 else {
                print("      attachmentDirsFound=\(summary.attachmentDirsFound)（应恰好 1）")
                return false
            }
            // 只收 Attachments 目录里的文件；Messages 下的 .eml 是邮件本体，不是附件
            guard summary.items.count == 1, summary.items[0].name == "report.pdf",
                  summary.items[0].size == 4096 else {
                print("      items=\(summary.items.map { "\($0.name):\($0.size)" })")
                return false
            }
            return true
        }

        check("Mail 附件：根读不到时明示 + issue 翻假，绝不渲染成「这里没有附件」（G9/G13）") {
            let root = "/private/tmp/macclean-mail-locked-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: root + "/secret.pdf", contents: Data(repeating: 9, count: 1024))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
                try? FileManager.default.removeItem(atPath: root)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
            guard geteuid() != 0 else {
                print("      以 root 运行，mode 000 不生效，本条跳过（不算通过也不算失败）")
                return true
            }
            MailAttachmentsScanner.rootsOverride = [MailAttachmentsScanner.MailRoot(path: root, collectsRootFiles: false)]
            defer { MailAttachmentsScanner.rootsOverride = nil }

            let summary = MailAttachmentsScanner.scan()
            guard summary.unreadableRoots.count == 1, summary.items.isEmpty else {
                print("      unreadable=\(summary.unreadableRoots) items=\(summary.items.count)")
                return false
            }
            // 变异：把 scan() 里的 unreadableRoots/issues 分支吞掉，下面两条必须红
            guard !summary.issues.isEmpty, !summary.isResultComplete else {
                print("      读到的根被折成「结果完整、这里没附件」——G13 被违反")
                return false
            }
            guard summary.issues.contains(where: { $0.contains("完全磁盘访问权限") }) else {
                print("      授权引导措辞丢了")
                return false
            }
            return true
        }

        check("Mail 附件：清理走网关、默认移废纸篓可撤销、历史落「邮件附件」") {
            let root = "/private/tmp/macclean-mail-clean-\(UUID().uuidString)"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: root) }
            let target = root + "/big.psd"
            fm.createFile(atPath: target, contents: Data(repeating: 7, count: 16384))
            MailAttachmentsScanner.rootsOverride = [MailAttachmentsScanner.MailRoot(path: root, collectsRootFiles: true)]
            defer { MailAttachmentsScanner.rootsOverride = nil }
            let summary = MailAttachmentsScanner.scan()
            guard let item = summary.items.first(where: { $0.name == "big.psd" }) else {
                print("      夹具条目没扫出来")
                return false
            }

            let beforeID = HistoryStore.load().first?.id
            // 不显式传 journal：钉的是默认值那条路径（默认值即安全策略）
            let outcome = MailAttachmentsScanner.clean(items: [item])
            guard outcome.cleanedCount == 1, outcome.freedBytes == 16384 else {
                print("      cleaned=\(outcome.cleanedCount) freed=\(outcome.freedBytes) rejected=\(outcome.rejected)")
                return false
            }
            guard !fm.fileExists(atPath: target) else {
                print("      文件还在——清理没执行")
                return false
            }
            let after = HistoryStore.load()
            guard after.first?.id != beforeID,
                  after.first?.categoryName == "邮件附件",
                  after.first?.bytes == outcome.freedBytes else {
                print("      历史缺失或字段不符：\(after.first.map { "\($0.categoryName) \($0.bytes)" } ?? "nil")")
                return false
            }
            // 默认 toTrash：必须留下撤销快照（与废纸篓自动清空的「无快照」相反）
            guard UndoManagerStore.session(for: after.first!.id) != nil else {
                print("      默认档没有撤销快照——可回退承诺被破坏")
                return false
            }
            return true
        }

        check("Mail 附件：clean 防夹带——根外路径拒绝且文件原样（复审 P2-2）") {
            let root = "/private/tmp/macclean-mail-clean2-\(UUID().uuidString)"
            let outside = "/private/tmp/macclean-mail-smuggled-\(UUID().uuidString)"
            let fm = FileManager.default
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(atPath: root)
                try? FileManager.default.removeItem(atPath: outside)
            }
            fm.createFile(atPath: root + "/real.bin", contents: Data(repeating: 6, count: 4096))
            let smuggledPath = outside + "/evil.txt"
            fm.createFile(atPath: smuggledPath, contents: Data(repeating: 5, count: 256))
            MailAttachmentsScanner.rootsOverride = [MailAttachmentsScanner.MailRoot(path: root, collectsRootFiles: true)]
            defer { MailAttachmentsScanner.rootsOverride = nil }
            let summary = MailAttachmentsScanner.scan()
            guard let legit = summary.items.first(where: { $0.name == "real.bin" }) else {
                print("      夹具条目没扫出来")
                return false
            }
            // 拼装一个根外条目夹带进清理请求
            var smuggled = legit
            smuggled = MailAttachmentsScanner.AttachmentItem(
                id: smuggledPath, name: "evil.txt", path: smuggledPath,
                size: 256, modifiedAt: nil, readable: true)

            let beforeID = HistoryStore.load().first?.id
            let outcome = MailAttachmentsScanner.clean(items: [legit, smuggled])
            guard outcome.cleanedCount == 1, outcome.freedBytes == 4096 else {
                print("      cleaned=\(outcome.cleanedCount) freed=\(outcome.freedBytes)")
                return false
            }
            guard outcome.rejected.count == 1,
                  outcome.rejected[0].path == smuggledPath,
                  outcome.rejected[0].message.contains("邮件附件根内") else {
                print("      夹带项没有被拒：\(outcome.rejected)")
                return false
            }
            guard fm.fileExists(atPath: smuggledPath) else {
                print("      根外文件被删了——防夹带失效")
                return false
            }
            guard HistoryStore.load().first?.categoryName == "邮件附件",
                  HistoryStore.load().first?.id != beforeID else {
                print("      历史缺失")
                return false
            }
            return true
        }

        check("Mail 附件：源码形状——无 /System 字符串护栏，过滤判据单一来源") {
            // 前置：G18 清单对 /System/Applications 生效（清单变更时这里先红）
            guard FileSystem.isSystemProtected("/System/Applications") else {
                print("      前置条件失效：/System/Applications 不在 systemProtected")
                return false
            }
            let path = (Selftest.sourceDirectoryPath as NSString)
                .appendingPathComponent("MailAttachmentsScanner.swift")
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("      MailAttachmentsScanner.swift 不可读")
                return false
            }
            let code = Selftest.stripSwiftComments(src).filter { !$0.isWhitespace }
            for banned in ["hasPrefix(\"/System", "contains(\"/System", "==\"/System"] {
                if code.contains(banned) {
                    print("      出现 \(banned) 字符串护栏（G18 违规族）")
                    return false
                }
            }
            // 两处非 atPath 遍历都必须带 errorHandler + recordDeniedAccess（由全仓 lint 覆盖，
            // 这里钉「遍历确实存在」防套件在空集上恒真）
            guard code.contains(".enumerator(") else {
                print("      收集遍历不见了")
                return false
            }
            return true
        }
    }
}
