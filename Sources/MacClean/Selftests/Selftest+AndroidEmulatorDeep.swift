import Foundation
import Darwin
import SwiftUI
import ViewInspector

// MARK: - Android 模拟器与 SDK 镜像孤儿治理深度自检 (v1.73.10)

extension Selftest {
    static func suiteAndroidEmulatorDeep() {
        print("--- [Suite] Android 模拟器 AVD 与 SDK 镜像孤儿治理深度自检 (v1.73.10) ---")

        // 1. 纯判据：不碰磁盘，四分支全覆盖 + 反证
        check("evaluateAVD：孤儿/镜像已删/健康/证据不足四态判定互斥且默认勾选只给孤儿") {
            var bad: [String] = []
            // 没有描述符指向 + 描述符都读得出来 → 孤儿，且这是唯一 isProvenOrphan==true 的状态
            let orphan = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: false,
                descriptorsCertain: true, configIni: .keyMissing, imagePresent: nil, sdkRootsKnown: true)
            if orphan.status != .orphanUnused || !orphan.status.isProvenOrphan {
                bad.append("无描述符指向应判孤儿且可默勾：\(orphan.status)")
            }
            // 有描述符指向 + 镜像在 → 健康，不可默勾
            let live = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: true,
                descriptorsCertain: true, configIni: .value("system-images/android-35/x/"),
                imagePresent: true, sdkRootsKnown: true)
            if live.status != .liveHealthy || live.status.isProvenOrphan {
                bad.append("镜像在的健康 AVD 不该被列成可清理：\(live.status)")
            }
            // 有描述符指向 + 镜像已删 → brokenImageNeedsConfirm，**不可默勾**（可能想留数据盘）
            let broken = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: true,
                descriptorsCertain: true, configIni: .value("system-images/android-30/y/"),
                imagePresent: false, sdkRootsKnown: true)
            if broken.status != .brokenImageNeedsConfirm || broken.status.isProvenOrphan {
                bad.append("镜像已删应判『需确认、不默勾』：\(broken.status)")
            }
            // 有描述符指向但没有可用的 SDK 根 → 判据未生效，needsConfirmation（不是"健康"，
            // 更不是"镜像已删"）
            let unknown = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: true,
                descriptorsCertain: true, configIni: .keyMissing, imagePresent: nil, sdkRootsKnown: false)
            if unknown.status != .needsConfirmation || unknown.status.isProvenOrphan {
                bad.append("无可用 SDK 根不得判健康：\(unknown.status)")
            }
            // P0 回归：描述符读不出来时，"没人指向它"这句话不成立——一律不得判孤儿
            let uncertain = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: false,
                descriptorsCertain: false, configIni: .keyMissing, imagePresent: nil, sdkRootsKnown: true)
            if uncertain.status != .needsConfirmation || uncertain.status.isProvenOrphan {
                bad.append("有 .ini 读不出来时不得判孤儿（它可能正指向这棵目录）：\(uncertain.status)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 1a. config.ini 三态（v1.73.10 待议 #3）：两种「证据不足」的 note 必须互异，
        //     且都仍落 `.needsConfirmation`——三态化只分化文案，绝不许翻状态档位。
        //     变异 teeth：把 scanner 里两句 note 改成同一句 / 改掉「未写明」「读不出来」措辞，
        //     本条必须变红。
        check("evaluateAVD：config『读不出来』与『未写明』两种证据不足 note 互异，同落需确认不默勾") {
            let missing = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: true,
                descriptorsCertain: true, configIni: .keyMissing, imagePresent: nil, sdkRootsKnown: true)
            let blind = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: true,
                descriptorsCertain: true, configIni: .unreadable, imagePresent: nil, sdkRootsKnown: true)
            var bad: [String] = []
            for (v, label) in [(missing, "keyMissing"), (blind, "unreadable")] {
                if v.status != .needsConfirmation {
                    bad.append("\(label) 三态化后应仍落「证据不足（需确认）」，实得 \(v.status)")
                }
                if v.status.isProvenOrphan {
                    bad.append("\(label) 不得被判成可默勾的孤儿")
                }
                if v.kind != .liveAVD {
                    bad.append("\(label) 的 kind 应保持 .liveAVD（证据不足挂在状态上），实得 \(v.kind)")
                }
            }
            guard let missingNote = missing.note, let blindNote = blind.note,
                  !missingNote.isEmpty, !blindNote.isEmpty else {
                print("      两种证据不足的 note 缺失或为空："
                      + "\(String(describing: missing.note)) / \(String(describing: blind.note))")
                return false
            }
            if missingNote == blindNote {
                bad.append("两种「证据不足」共用同一句文案（把『没能看 config』与『config 没写』混为一谈）：\(missingNote)")
            }
            if !missingNote.contains("未写明") {
                bad.append("keyMissing 的 note 没说「未写明」：\(missingNote)")
            }
            if !blindNote.contains("读不出来") {
                bad.append("unreadable 的 note 没说「读不出来」：\(blindNote)")
            }
            // 反证：.value + 镜像在 → 健康——三态化不得伤到判据主链
            let live = AndroidEmulatorScanner.evaluateAVD(referencedByDescriptor: true,
                descriptorsCertain: true, configIni: .value("system-images/android-35/x/"),
                imagePresent: true, sdkRootsKnown: true)
            if live.status != .liveHealthy {
                bad.append("三态化不应影响健康判定：\(live.status)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 1b-2. readConfigIni 直读三态 + scan 接线：config 读不出来 / 未写明在条目 note 上
        //       各说各的；CRLF 写法的 config 仍要解析得出键值（既有约束的回归护栏）。
        check("readConfigIni 三态 + scan 接线：『读不出来』与『未写明』在界面上各说各的，CRLF 仍解析") {
            guard geteuid() != 0 else {
                // mode 000 在 root 下不生效，fixture 造不出来（`check` 的 return true 计入通过数）
                print("      以 root 运行，mode 000 不生效：本条跳过并计入通过数（非 root 才是真跑）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-cfg-\(UUID().uuidString)"
            let sdk = "/private/tmp/macclean-avd-cfgsdk-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: sdk + "/system-images/android-35/google_apis/arm64-v8a",
                                    withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: sdk) }
            // nokey：config 读得到、但没写 image.sysdir.1
            let nokeyDir = root + "/nokey.avd"
            try? fm.createDirectory(atPath: nokeyDir, withIntermediateDirectories: true)
            try? "avd.ini.encoding=UTF-8\navd.name=nokey\n".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: nokeyDir + "/config.ini"))
            try? "path=\(nokeyDir)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: root + "/nokey.ini"))
            // blind：config 本身读不出来（mode 000）——"这一眼没看成"与"看过了没写"必须分开说。
            // 描述符 blind.ini 必须可读并指向它：否则这台 AVD 会因"无人指向"直接判孤儿，
            // 根本轮不到 config.ini 的三态文案（那是另一条判据的事）。
            let blindDir = root + "/blind.avd"
            try? fm.createDirectory(atPath: blindDir, withIntermediateDirectories: true)
            try? "image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: blindDir + "/config.ini"))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blindDir + "/config.ini")
            defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blindDir + "/config.ini") }
            try? "path=\(blindDir)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: root + "/blind.ini"))
            // crlf：CRLF 写法的描述符与 config——R2-P2-6 那个字素簇 bug 的回归护栏
            let crlfDir = root + "/crlf.avd"
            try? fm.createDirectory(atPath: crlfDir, withIntermediateDirectories: true)
            try? "avd.name=crlf\r\nimage.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\r\n"
                .data(using: .utf8)?.write(to: URL(fileURLWithPath: crlfDir + "/config.ini"))
            try? "path=\(crlfDir)\r\npath.rel=avd/crlf.avd\r\n".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: root + "/crlf.ini"))

            var bad: [String] = []
            // readConfigIni 直读：三态各归各位
            if AndroidEmulatorScanner.readConfigIni(avdPath: nokeyDir) != .keyMissing {
                bad.append("没写键的 config 应判 .keyMissing，实得 \(AndroidEmulatorScanner.readConfigIni(avdPath: nokeyDir))")
            }
            if AndroidEmulatorScanner.readConfigIni(avdPath: blindDir) != .unreadable {
                bad.append("mode 000 的 config 应判 .unreadable，实得 \(AndroidEmulatorScanner.readConfigIni(avdPath: blindDir))")
            }
            if AndroidEmulatorScanner.readConfigIni(avdPath: root + "/never-created.avd") != .unreadable {
                bad.append("config.ini 不存在应判 .unreadable，实得 \(AndroidEmulatorScanner.readConfigIni(avdPath: root + "/never-created.avd"))")
            }
            if AndroidEmulatorScanner.readConfigIni(avdPath: crlfDir)
                != .value("system-images/android-35/google_apis/arm64-v8a/") {
                bad.append("CRLF config 的键值没解析出来：\(AndroidEmulatorScanner.readConfigIni(avdPath: crlfDir))")
            }

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [sdk])
            func item(_ n: String) -> AndroidEmulatorItem? { sum.items.first { $0.name == n } }
            if let n = item("nokey") {
                if n.status != .needsConfirmation || n.isSelected {
                    bad.append("nokey 应证据不足且不默勾：\(n.status) sel=\(n.isSelected)")
                }
                if let note = n.note {
                    if !note.contains("未写明") { bad.append("nokey 的 note 没说「未写明」：\(note)") }
                    if note.contains("读不出来") { bad.append("nokey 的 note 冒充了「读不出来」：\(note)") }
                } else {
                    bad.append("nokey 缺 note")
                }
            } else {
                bad.append("nokey.avd 没被列出来")
            }
            if let b = item("blind") {
                if b.status != .needsConfirmation || b.isSelected {
                    bad.append("blind 应证据不足且不默勾：\(b.status) sel=\(b.isSelected)")
                }
                if let note = b.note {
                    if !note.contains("读不出来") { bad.append("blind 的 note 没说「读不出来」：\(note)") }
                    if note.contains("未写明") { bad.append("blind 的 note 冒充了「未写明」：\(note)") }
                } else {
                    bad.append("blind 缺 note")
                }
            } else {
                bad.append("blind.avd 没被列出来")
            }
            if let nNote = item("nokey")?.note, let bNote = item("blind")?.note, nNote == bNote {
                bad.append("scan 出来的两条「证据不足」note 相同：\(nNote)")
            }
            if let c = item("crlf"), c.status != .liveHealthy {
                bad.append("CRLF config + 真镜像应判健康（回归护栏），实得 "
                           + "\(String(describing: item("crlf")?.status)) note=\(String(describing: item("crlf")?.note))")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 1b. 描述符配对：孤儿判据看的是 ini 的 path= 内容，不是文件名
        check("referencedAVDDirs：ini 的 path= 指向谁才算谁，改名/跨名指向都认得（P0 回归）") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-pair-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            func ini(_ name: String, _ body: String) {
                try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: "\(root)/\(name).ini"))
            }
            // 描述符名与目录名**不同**：avdmanager 实测照样列出这台 AVD（本机用真 avdmanager 验过）
            ini("zz-other-name", "avd.ini.encoding=UTF-8\npath=\(root)/targetdir.avd\npath.rel=avd/targetdir.avd\ntarget=android-35\n")
            // 只有 path.rel=：相对 ~/.android 解析
            ini("rel-only", "path.rel=avd/reltarget.avd\n")
            // 读不出来的 ini（0 字节 + 权限 000）
            ini("gone-unreadable", "path=\(root)/whatever.avd\n")
            let unreadablePath = "\(root)/mode000.ini"
            try? "path=x\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: unreadablePath))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadablePath)
            defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadablePath) }

            let p = AndroidEmulatorScanner.referencedAVDDirs(
                iniPaths: ["\(root)/zz-other-name.ini", "\(root)/rel-only.ini",
                           "\(root)/gone-unreadable.ini", unreadablePath])
            var bad: [String] = []
            let want = FileSystem.normalizePath("\(root)/targetdir.avd")
            if !p.dirs.contains(want) {
                bad.append("path= 指向的目录没进集合：\(p.dirs)")
            }
            let wantRel = FileSystem.normalizePath(CleanPaths.expand("~/.android") + "/avd/reltarget.avd")
            if !p.dirs.contains(wantRel) {
                bad.append("只有 path.rel= 时没按 ~/.android 解析：\(p.dirs)")
            }
            // CRLF 写法的描述符：值里留下 `\r` 就永远配不上对，活的 AVD 会被判孤儿
            let crlfBody = "path=\(root)/crlf.avd\r\npath.rel=avd/crlf.avd\r\n"
            try? crlfBody.data(using: .utf8)?.write(to: URL(fileURLWithPath: "\(root)/crlf.ini"))
            let crlfPair = AndroidEmulatorScanner.referencedAVDDirs(
                iniPaths: ["\(root)/crlf.ini"])
            if !crlfPair.dirs.contains(FileSystem.normalizePath("\(root)/crlf.avd")) {
                bad.append("CRLF 描述符没配上对（值里残留 \\r）：\(crlfPair.dirs)")
            }
            // `.ini` 其实是个目录：不能静默当它不存在
            if !p.unreadableInis.contains(unreadablePath) {
                bad.append("mode 000 的 ini 没被算进『读不出来』：\(p.unreadableInis)")
            }
            if p.unreadableInis.contains("\(root)/gone-unreadable.ini") {
                bad.append("能读出来的 ini 被误算成读不出来")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 1b. `path=` 只认绝对路径（`~`/`~/` 先展开）。其余形态**猜基准**会把真正被指向的
        //     那棵 AVD 判成孤儿并默认勾选（三次复审里两位评审各自独立命中：`path=~/x`、
        //     `path=avd/foo.avd`——后者按 avdRoot 拼出 `.../avd/avd/foo.avd` 永不命中）。
        //     所以这些形态必须进"未清算"清单，让整轮无人可被确证为孤儿。
        check("referencedAVDDirs：非绝对的 path= 一律算未清算并否决孤儿确证（P1 回归）") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-pathform-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root + "/live.avd", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            func ini(_ name: String, _ body: String) -> String {
                let p = "\(root)/\(name).ini"
                try? body.data(using: .utf8)?.write(to: URL(fileURLWithPath: p))
                return p
            }
            var bad: [String] = []
            for (name, value) in [("rel-bare", "live.avd"),
                                  ("rel-dotdot", "../elsewhere/live.avd"),
                                  ("tilde-user", "~otheruser/live.avd"),
                                  ("avd-relative", "avd/live.avd")] {
                let p = ini(name, "avd.name=\(name)\npath=\(value)\n")
                let pair = AndroidEmulatorScanner.referencedAVDDirs(iniPaths: [p])
                if !pair.unreadableInis.contains(p) {
                    bad.append("非绝对 path=「\(value)」被当成已清算，dirs=\(pair.dirs)"
                        + "——真正指向的 live.avd 会被判孤儿并默认勾选")
                }
                if pair.dirs.contains(FileSystem.normalizePath("\(root)/live.avd")) {
                    bad.append("猜基准拼出来的路径竟然匹配上了（\(value)）")
                }
            }
            // 反证 A：绝对写法必须照常配上，否则上面四条只是"永远否决"。
            let absP = ini("abs", "avd.name=abs\npath=\(root)/live.avd\n")
            let absPair = AndroidEmulatorScanner.referencedAVDDirs(iniPaths: [absP])
            if !absPair.dirs.contains(FileSystem.normalizePath("\(root)/live.avd")) {
                bad.append("绝对 path= 没配上：\(absPair.dirs)")
            }
            if !absPair.unreadableInis.isEmpty { bad.append("绝对写法被误算成未清算") }
            // 反证 B：`~/` 会展开成主目录下的绝对路径（这是**认得**的写法，不是猜）。
            let tildeP = ini("tilde", "avd.name=tilde\npath=~/macclean-no-such.avd\n")
            let tildePair = AndroidEmulatorScanner.referencedAVDDirs(iniPaths: [tildeP])
            if tildePair.dirs.contains(FileSystem.normalizePath(NSHomeDirectory() + "/macclean-no-such.avd")) == false {
                bad.append("`~/` 没走 CleanPaths.expand：\(tildePair.dirs)")
            }
            if !tildePair.unreadableInis.isEmpty { bad.append("`~/` 展开成功却被算成未清算") }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 2. scan 端到端：合成一棵 AVD 树，四种情形各一个，逐条核对状态与默勾
        check("scan：孤儿/健康/镜像已删/无 config 四棵 AVD 各判各的，默勾严格等于孤儿") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-scan-\(UUID().uuidString)"
            let sdk = "/private/tmp/macclean-avd-sdk-\(UUID().uuidString)"
            defer { try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: sdk) }
            func makeAVD(_ name: String, withIni: Bool, imageSysdir: String?) {
                let dir = "\(root)/\(name).avd"
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if withIni {
                    try? "path=\(dir)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: "\(root)/\(name).ini"))
                }
                var cfg = "avd.name=\(name)\n"
                if let s = imageSysdir { cfg += "image.sysdir.1=\(s)\n" }
                try? cfg.data(using: .utf8)?.write(to: URL(fileURLWithPath: dir + "/config.ini"))
                try? Data(repeating: 7, count: 2048).write(to: URL(fileURLWithPath: dir + "/userdata.img"))
            }
            // 真实镜像目录放在 SDK 根下
            try? fm.createDirectory(atPath: sdk + "/system-images/android-35/google_apis/arm64-v8a",
                                    withIntermediateDirectories: true)
            makeAVD("orphan", withIni: false, imageSysdir: nil)               // 无描述符指向 → 孤儿
            makeAVD("good", withIni: true, imageSysdir: "system-images/android-35/google_apis/arm64-v8a/")
            makeAVD("gone", withIni: true, imageSysdir: "system-images/android-99/deleted/")  // 镜像没了
            makeAVD("nocfg", withIni: true, imageSysdir: nil)                 // 有 .ini 无 image 键
            // P0 回归：`cloned.avd` **没有**同名 `cloned.ini`，但 `renamed-descriptor.ini`
            // 的 path= 指着它 —— avdmanager 认得这台 AVD，所以它绝不是孤儿。
            makeAVD("cloned", withIni: false, imageSysdir: "system-images/android-35/google_apis/arm64-v8a/")
            try? "path=\(root)/cloned.avd\npath.rel=avd/cloned.avd\n"
                .data(using: .utf8)?
                .write(to: URL(fileURLWithPath: "\(root)/renamed-descriptor.ini"))

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [sdk])
            func item(_ name: String) -> AndroidEmulatorItem? { sum.items.first { $0.name == name } }
            var bad: [String] = []
            if let o = item("orphan"), o.status != .orphanUnused || !o.isSelected || o.size <= 0 {
                bad.append("orphan: \(String(describing: item("orphan").map { "\($0.status) sel=\($0.isSelected) sz=\($0.size)" }))")
            }
            if let g = item("good"), g.status != .liveHealthy || g.isSelected {
                bad.append("good: \(String(describing: item("good").map { "\($0.status) sel=\($0.isSelected)" }))")
            }
            if let b = item("gone"), b.status != .brokenImageNeedsConfirm || b.isSelected {
                bad.append("gone(镜像已删): 期望需确认不默勾，实得 \(String(describing: item("gone").map { "\($0.status) sel=\($0.isSelected)" }))")
            }
            if let n = item("nocfg"), n.status != .needsConfirmation || n.isSelected {
                bad.append("nocfg: \(String(describing: item("nocfg").map { "\($0.status) sel=\($0.isSelected)" }))")
            }
            // 这一条是本轮 P0 的正面断言：没有同名 .ini、但被别的描述符 path= 指向 → 活的
            if let c = item("cloned"), c.status != .liveHealthy || c.isSelected {
                bad.append("cloned(被异名描述符指向): 期望健康不默勾，实得 \(String(describing: item("cloned").map { "\($0.status) sel=\($0.isSelected)" }))")
            } else if item("cloned") == nil {
                bad.append("cloned.avd 没被列出来")
            }
            if sum.items.count != 5 { bad.append("应识别到 5 个 .avd：\(sum.items.count)") }
            if sum.orphanCount != 1 { bad.append("孤儿应恰好 1（只有 orphan）：\(sum.orphanCount)") }
            if !sum.isResultComplete { bad.append("全部可读却报不完整：\(sum.issues)") }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 3. G9：AVD 根读不到时不得静默报"没有孤儿"
        check("scan：AVD 根读不到时记 issue、isResultComplete 翻假（读不到 ≠ 干净）") {
            guard geteuid() != 0 else {
                // 诚实说明：`check` 的 return true 会被**计入通过数**，所以这条在 root 下
                // 是"跳过并记为通过"，不是"没跑"。本机以普通用户跑，mode 000 真实生效。
                print("      以 root 运行，mode 000 不生效：本条跳过并计入通过数（非 root 才是真跑）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-den-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root + "/a.avd", withIntermediateDirectories: true)
            try? "x".data(using: .utf8)?.write(to: URL(fileURLWithPath: root + "/a.ini"))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
                try? fm.removeItem(atPath: root)
            }
            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            var bad: [String] = []
            if sum.isResultComplete { bad.append("根读不到却报结果完整") }
            if sum.issues.isEmpty { bad.append("issues 里一条都没有（会被渲染成『这里没有孤儿』）") }
            if !sum.items.isEmpty { bad.append("根读不到还能列出条目（不合理）") }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4. v1.73.7 契约：孤儿 AVD 内部有子目录读不到 → readable=false → 不默勾
        check("scan：孤儿 AVD 的子树被权限掐断时 readable=false，不得据偏小的 size 默认勾选") {
            guard geteuid() != 0 else {
                // 诚实说明：`check` 的 return true 会被**计入通过数**，所以这条在 root 下
                // 是"跳过并记为通过"，不是"没跑"。本机以普通用户跑，mode 000 真实生效。
                print("      以 root 运行，mode 000 不生效：本条跳过并计入通过数（非 root 才是真跑）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-walk-\(UUID().uuidString)"
            let avd = root + "/broken.avd"
            try? fm.createDirectory(atPath: avd + "/snapshots", withIntermediateDirectories: true)
            try? Data(repeating: 1, count: 4096).write(to: URL(fileURLWithPath: avd + "/userdata.img"))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: avd + "/snapshots")
            defer {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: avd + "/snapshots")
                try? fm.removeItem(atPath: root)
            }
            FileSystem.resetDeniedAccess()
            // 无同名 .ini → 孤儿；但内部 snapshots/ 读不到 → walker readable=false
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            guard let it = sum.items.first else {
                print("      残缺的孤儿 AVD 没被列出来")
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: avd + "/snapshots")
                return false
            }
            var bad: [String] = []
            if it.status != .orphanUnused { bad.append("应判孤儿：\(it.status)") }
            if it.readable { bad.append("子树被掐断却仍报 readable=true") }
            if it.isSelected { bad.append("readable=false 的残缺遍历仍被默认勾选") }
            // 残缺必须**同时**把整份结果标成不完整：只翻 item.readable 而 summary 仍报"完整"，
            // 面板就会一边显示一个下限体积、一边说"结果完整"（v1.73.7 Spotlight P1-2 同族）。
            if sum.isResultComplete {
                bad.append("有一条 AVD 没读全，isResultComplete 却还是真：\(sum.issues)")
            }
            if !sum.issues.contains(where: { $0.subject == it.path && $0.message.contains("下限") }) {
                bad.append("残缺 AVD 没生成对应的 issue（subject 应指向该条目录）：\(sum.issues.map(\.subject))")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4b. 有一份描述符读不出来时，**scan 这一侧**也不许确证任何孤儿
        //     （纯函数判对了不等于接线对：判据是从这里喂进 `evaluateAVD` 的）
        check("scan：AVD 根里有读不出来的 .ini 时，无人可被判孤儿（阴性对照：可读时确证孤儿）") {
            guard geteuid() != 0 else {
                // 诚实说明：`check` 的 return true 会被**计入通过数**，所以这条在 root 下
                // 是"跳过并记为通过"，不是"没跑"。本机以普通用户跑，mode 000 真实生效。
                print("      以 root 运行，mode 000 不生效：本条跳过并计入通过数（非 root 才是真跑）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-iniblind-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root + "/stray.avd", withIntermediateDirectories: true)
            // 一个与 stray.avd 无关、但**读不出来**的描述符：它可能正指向 stray.avd
            let blindIni = root + "/someone.ini"
            try? "path=\(root)/unknown.avd\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: blindIni))
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blindIni)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blindIni)
                try? fm.removeItem(atPath: root)
            }
            var bad: [String] = []
            let modeBits = ((try? fm.attributesOfItem(atPath: blindIni)[.posixPermissions]) as? NSNumber)?
                .uint16Value ?? 0
            if modeBits & 0o777 != 0 {
                print("      夹具没造出不可读的描述符（mode=\(String(format: "%03o", modeBits & 0o777))），本条无法验证")
                return false
            }

            FileSystem.resetDeniedAccess()
            let blind = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            guard let it = blind.items.first(where: { $0.name == "stray" }) else {
                print("      stray.avd 没被列出来"); return false
            }
            if it.status == .orphanUnused {
                bad.append("有一份 .ini 读不出来，却仍把 stray.avd 确证成孤儿并默勾")
            }
            if it.isSelected { bad.append("判据不确证时被默认勾选") }
            if blind.isResultComplete { bad.append("读不出来的描述符没记进 issues") }

            // `.ini` 是个目录（或 stat 不出来）时同样不能静默略过——它也是一份没清算的描述符
            let root2 = "/private/tmp/macclean-avd-inidir-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root2 + "/stray2.avd", withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: root2 + "/weird.ini", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root2) }
            let dirSum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root2, customSDKRoots: [])
            if dirSum.items.first(where: { $0.name == "stray2" })?.status == .orphanUnused {
                bad.append("有一个 `.ini` 条目没被清算，却仍把 stray2.avd 确证成孤儿")
            }

            // 反证：把那份描述符放开，同一棵目录就该被确证成孤儿（否则上面只是"永远需确认"）
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blindIni)
            let clear = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            if clear.items.first(where: { $0.name == "stray" })?.status != .orphanUnused {
                bad.append("反证失效：描述符全部可读时也没判成孤儿")
            }
            if !(clear.items.first(where: { $0.name == "stray" })?.isSelected ?? false) {
                bad.append("反证失效：确证孤儿没被默认勾选")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4d. SDK 根存在但读不到：判据未生效 ≠ "镜像被删"（复审 P1-2）
        check("scan：SDK 根读不到时判『证据不足』并记 issue，不得写成『镜像已删』") {
            guard geteuid() != 0 else {
                // 诚实说明：`check` 的 return true 会被**计入通过数**，所以这条在 root 下
                // 是"跳过并记为通过"，不是"没跑"。本机以普通用户跑，mode 000 真实生效。
                print("      以 root 运行，mode 000 不生效：本条跳过并计入通过数（非 root 才是真跑）")
                return true
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-sdk-\(UUID().uuidString)"
            let sdk = "/private/tmp/macclean-avd-sdkblind-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: sdk + "/system-images/android-35/google_apis/arm64-v8a",
                                    withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: sdk) }
            let dir = root + "/live.avd"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? "path=\(dir)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: root + "/live.ini"))
            try? "image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n"
                .data(using: .utf8)?.write(to: URL(fileURLWithPath: dir + "/config.ini"))
            // 镜像其实**在**，但 SDK 根整棵列不出来了
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sdk)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sdk) }

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [sdk])
            var bad: [String] = []
            guard let it = sum.items.first else {
                print("      AVD 没被列出来"); return false
            }
            if it.status == .brokenImageNeedsConfirm {
                bad.append("SDK 根读不到却写成『镜像已删』——把『没看到』报成『没了』")
            }
            if it.status != .needsConfirmation { bad.append("应判证据不足，实得 \(it.status)") }
            if it.isSelected { bad.append("判据未生效的条目被默认勾选") }
            if sum.isResultComplete { bad.append("SDK 根读不到却没记 issue，结果仍报完整") }
            if !sum.issues.contains(where: { $0.subject.contains("sdkblind") }) {
                bad.append("issue 里没点名那个读不到的 SDK 根：\(sum.issues.map(\.subject))")
            }
            if !sum.detectedSDKRoots.isEmpty {
                bad.append("读不到的 SDK 根不该进 detectedSDKRoots：\(sum.detectedSDKRoots)")
            }
            // AVD 根**不存在**时的那条早退必须把已算出来的证据原样带出去：
            // 装了 SDK 但从没建过 AVD 的机器就走这条路，早退里回 `issues: []` 等于
            // 把"某个证据根读不到"这件事抹平，面板于是报"这里没有孤儿"且结果完整。
            let ghost = AndroidEmulatorScanner.shared.scan(
                customAVDRoot: "\(root)/never-created", customSDKRoots: [sdk])
            if ghost.isResultComplete || !ghost.issues.contains(where: { $0.subject.contains("sdkblind") }) {
                bad.append("AVD 根不存在时早退丢了 SDK 根的 issue：\(ghost.issues.map(\.subject))")
            }
            // 反证：同一份清单在 SDK 根可读时必须判健康（否则上面那串断言只是"永远需确认"）
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sdk)
            let okSum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [sdk])
            if okSum.items.first?.status != .liveHealthy {
                bad.append("反证失效：SDK 根可读时该条应判健康，实得 \(String(describing: okSum.items.first?.status))")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4e. `.avd` 是软链时不得静默消失（复审 P2-9）
        check("scan：`.avd` 是软链（isDirectory=false）时记 issue 说明未判定，不静默省略") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-link-\(UUID().uuidString)"
            let real = "/private/tmp/macclean-avd-linkreal-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: real, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root); try? fm.removeItem(atPath: real) }
            try? fm.createSymbolicLink(atPath: root + "/relocated.avd", withDestinationPath: real)
            try? fm.createDirectory(atPath: root + "/normal.avd", withIntermediateDirectories: true)

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            var bad: [String] = []
            if sum.items.contains(where: { $0.name == "relocated" }) {
                bad.append("软链 `.avd` 被当成普通目录列了出来（它会指向主目录外的任意位置）")
            }
            if sum.isResultComplete {
                bad.append("有一条 `.avd` 没判定却报结果完整——面板会说『未发现孤儿 AVD』")
            }
            if !sum.issues.contains(where: { $0.message.contains("relocated") }) {
                bad.append("issue 没点名那个未判定的条目：\(sum.issues.map(\.message))")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4f. `$ANDROID_AVD_HOME` 把根挪到主目录外：必须显式说"只列示、不删"
        check("scan：AVD 根的放行面决定承诺——tmp 面内可默勾，面外只列示且不默勾（P1-2）") {
            let fm = FileManager.default
            let outside = "/private/tmp/macclean-avd-home-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: outside + "/lostdisk.avd", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: outside) }
            setenv("ANDROID_AVD_HOME", outside, 1)
            defer { unsetenv("ANDROID_AVD_HOME") }

            var bad: [String] = []
            // ① `/tmp` 虽然在主目录外，却**本来就在网关的常规放行面里**：这里不许写
            //    "删除会被护栏拒掉"那种做不到的承诺（三次复审 P1-2 原文：承诺与行为相反），
            //    也不许因为"不在主目录"就把手边的确证孤儿说成不可删。
            let sum = AndroidEmulatorScanner.shared.scan()
            if sum.avdRoot != FileSystem.normalizePath(outside) {
                bad.append("没走 $ANDROID_AVD_HOME：avdRoot=\(sum.avdRoot)")
            }
            if sum.items.count != 1 { bad.append("外部根下的 AVD 没被列出：\(sum.items.count)") }
            if sum.isResultComplete == false {
                bad.append("/tmp 是放行根，却被记成不可删面：\(sum.issues.map(\.message))")
            }
            if sum.issues.contains(where: { $0.message.contains("只列示") }) {
                bad.append("放行面内的根仍被承诺成「只列示」")
            }
            if sum.items.first?.isSelected != true {
                bad.append("放行面内的确证孤儿没被默认勾选（判据被误收紧）")
            }

            // ② 真正的放行面外根（`/Users/Shared`，网关的 allowedRoots 不含它）：必须
            //    只列示、不默勾，并且 clean() 当面拒绝——这才让"不新增可删根"成为行为。
            let far = "/Users/Shared/macclean-avd-far-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: far + "/ghost.avd", withIntermediateDirectories: true)
            guard fm.fileExists(atPath: far + "/ghost.avd") else {
                print("      /Users/Shared 造不出夹具，放行面外那半边无人验证（不判通过）")
                return false
            }
            defer { try? fm.removeItem(atPath: far) }
            setenv("ANDROID_AVD_HOME", far, 1)
            let farSum = AndroidEmulatorScanner.shared.scan()
            unsetenv("ANDROID_AVD_HOME")
            if farSum.items.first?.isSelected != false {
                bad.append("放行面外的根仍被默认勾选（界面承诺「不删」是假的）")
            }
            if !farSum.issues.contains(where: { $0.message.contains("只列示") }) {
                bad.append("放行面外的根没说明「只列示」：\(farSum.issues.map(\.message))")
            }
            if farSum.isResultComplete {
                bad.append("放行面外的根却报结果完整（面板会把它当成可删额度）")
            }
            // 删除侧同判据：调用方硬塞这条也必须拒，并说清原因（不静默）。
            if let ghost = farSum.items.first, ghost.status.isProvenOrphan {
                let outcome = AndroidEmulatorScanner.shared.clean(items: [ghost], journal: .none)
                if outcome.cleanedCount != 0 {
                    bad.append("放行面外的孤儿竟然被删了：\(outcome.cleanedCount)")
                }
                if !outcome.rejected.contains(where: { $0.message.contains("放行面") }) {
                    bad.append("拒绝没说明是根的问题：\(outcome.rejected.map(\.message))")
                }
            }

            // 反证：同一棵 /tmp 目录用注入缝扫（自检的常规走法）不该凭空长出"只列示"告警。
            let injected = AndroidEmulatorScanner.shared.scan(customAVDRoot: outside, customSDKRoots: [])
            if injected.issues.contains(where: { $0.message.contains("只列示") }) {
                bad.append("customAVDRoot 注入也被算成放行面外告警")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4h. 体积口径（R2-P2-11 收编）：本模块的求体积已换成共享的 `FileSystem.directoryStats`。
        //     稀疏文件（100 MB 逻辑大小、实际占盘约 1 块）按 **allocated** 计、软链**计 0**——
        //     谁把口径改回逻辑字节（fileSize）或让 walker 跟随软链，这里的 MB 级界线断言先红。
        check("scan：体积口径已统一 FileSystem.directoryStats——稀疏文件按 allocated 计、软链计 0") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-sparse-\(UUID().uuidString)"
            let avd = root + "/sparse.avd"
            try? fm.createDirectory(atPath: avd, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            // 稀疏文件：先写 100 字节真实数据，再 ftruncate 撑到 100 MB——文件尾是一段
            // 没有落盘的洞，实际占盘约 1 个块（本机 APFS 实测：≤8 MB 的小洞会被整段
            // 物化，只有足够大的尾部洞才真正稀疏，故用 100 MB）。
            // （FileHandle.truncate(atOffset:) 即 POSIX ftruncate，与 `dd seek=` 同族。）
            let sparsePath = avd + "/userdata.img"
            guard fm.createFile(atPath: sparsePath, contents: Data()),
                  let fh = FileHandle(forWritingAtPath: sparsePath) else {
                print("      打不开稀疏夹具文件，无法验证"); return false
            }
            fh.write(Data(repeating: 0x41, count: 100))
            // 新 SDK 上 `truncate(atOffset:)` 是 throwing 的；失败会被下面的 logicalSize 哨兵接住
            try? fh.truncate(atOffset: 100_000_000)
            fh.closeFile()
            let logicalSize = ((try? fm.attributesOfItem(atPath: sparsePath))?[.size] as? UInt64) ?? 0
            guard logicalSize >= 100_000_000 else {
                print("      稀疏文件没造出来（逻辑大小 \(logicalSize)），无法验证 allocated 口径")
                return false
            }
            // 软链指向 .avd **之外**的 3 MB 真实文件——软链自身不该被计入体积
            let external = root + "/external.img"
            try? Data(repeating: 0x42, count: 3_000_000).write(to: URL(fileURLWithPath: external))
            try? fm.createSymbolicLink(atPath: avd + "/link.img", withDestinationPath: external)

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            FileSystem.resetDeniedAccess()
            guard let it = sum.items.first(where: { $0.name == "sparse" }) else {
                print("      sparse.avd 没被列出来：\(sum.items.map(\.name))")
                return false
            }
            var bad: [String] = []
            // ① 这条**只**钉"scan 确实在调共享 walker、且调的是同一棵树"：两边都是
            //    `directoryStats`，所以它不构成"口径已统一"的证据（三次复审 P1-4：上一版把这
            //    一句写成口径承诺，是 `f(X)==f(X)` 的同义反复）。面板数与删除侧实测数的真实
            //    差异由下面「已知口径差」那条钉住。
            let shared = FileSystem.directoryStats(at: avd)
            if it.size != shared.size {
                bad.append("scan 的 size(\(it.size)) ≠ 对同一棵树直调 directoryStats(\(shared.size))"
                    + "——scan 没用共享 walker，或算的不是这一棵")
            }
            // ② allocated 口径：≥1 个实际数据块（>0），但远小于 8 MB 逻辑大小——
            //    若按逻辑字节算会 ≥8 MB；若跟随软链会再 +3 MB。两个方向都被这条 MB 级界线拦住。
            if it.size <= 0 {
                bad.append("稀疏文件的实际数据块没被计入：size=\(it.size)")
            }
            if it.size >= 1_000_000 {
                bad.append("size=\(it.size) 达到 MB 级——要么按逻辑字节算（逻辑=\(logicalSize)），"
                           + "要么软链跟着目标（3 MB）算了：口径错了")
            }
            // ③ 共享 walker 自身同样不得把软链算进去（否则①的"一致"是错的一致）
            if shared.size >= 1_000_000 {
                bad.append("FileSystem.directoryStats 把软链的目标体积算进去了：\(shared.size)")
            }
            // ④ 口径改造不许动状态/默勾契约：无描述符指向 → 孤儿且默勾；树可读 → readable
            if it.status != .orphanUnused || !it.isSelected || !it.readable {
                bad.append("walker 收编不应影响状态/默勾：\(it.status) readable=\(it.readable) sel=\(it.isSelected)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4h-2. 三次复审 P1-4 的真相版：面板数（`directoryStats`，默认跳隐藏项）与删除侧记账数
        //        （`measure`/`size(at:)`，不跳隐藏）对**同一棵树**本来就不是同一个数。
        //        上一版把 doc 里那句"两个入口必须给出同一个数"当成已成立的前提，用 `f(X)==f(X)`
        //        自证，于是差异无人执法。这条把差异**钉成事实**：谁把两侧统一了，这里会红，
        //        必须连同 `FileSystem.directoryStats` 的承诺一起改（其余四个已收编模块的历史
        //        数字也受影响，属需人批的口径取舍，见本轮复审记录 待议）。
        check("已知口径差（待议）：面板 directoryStats 跳隐藏项，删除侧 measure 不跳——同一棵树两个数") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-caliber-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            guard fm.createFile(atPath: root + "/visible.img",
                                contents: Data(repeating: 0x41, count: 1_000_000)),
                  fm.createFile(atPath: root + "/.hidden.img",
                                contents: Data(repeating: 0x42, count: 2_000_000)) else {
                print("      夹具造不出来，无法验证"); return false
            }
            let panel = FileSystem.directoryStats(at: root).size
            let deleted = FileSystem.size(at: root)
            var bad: [String] = []
            // 差异必须**真的存在**且方向已知：删除侧 ≥ 面板侧，且差额就是那个隐藏项。
            if panel >= deleted {
                bad.append("面板数(\(panel)) ≥ 删除侧实测(\(deleted))：两侧对隐藏项的处理已经一致，"
                    + "这条用例（以及 directoryStats 的默认 skipHidden）该跟着改口径了")
            }
            if deleted - panel < 1_000_000 {
                bad.append("差额 \(deleted - panel) 不足一个隐藏项的量级——隐藏项没被其中一侧计入，"
                    + "判据已经变了")
            }
            // 反证：面板数确实只到"可见项"的量级（allocated 口径会带块对齐余量，
            // 实测 1 MB 文件报 1,003,520，所以这里用区间而不是等值）。
            if panel < 900_000 || panel > 1_200_000 {
                bad.append("面板数 \(panel) 不在「仅可见项 ≈1 MB(allocated)」的区间里——"
                    + "skipHidden 语义或体积口径变了")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 4g. 产品侧的根清单本身要有覆盖：所有 scan 断言都走注入缝时，`~/Library/Android/sdk`
        //     这个字面量写错、或环境变量名写错，真机上每台 AVD 都会永远停在「证据不足」，
        //     而自检仍然全绿（二次复审 P1-2，即清单里"规则登记了却没人列过它"那一族）。
        check("defaultSDKRoots / $ANDROID_SDK_ROOT 真的进了镜像判据（无注入缝的 scan 路径）") {
            let fm = FileManager.default
            let home = "/private/tmp/macclean-avd-prodhome-\(UUID().uuidString)"
            let sdk = "/private/tmp/macclean-avd-prodsdk-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: sdk + "/system-images/android-35/google_apis/arm64-v8a",
                                    withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: home + "/live.avd", withIntermediateDirectories: true)
            try? "path=\(home)/live.avd\n".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: home + "/live.ini"))
            try? "image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/\n"
                .data(using: .utf8)?.write(to: URL(fileURLWithPath: home + "/live.avd/config.ini"))
            defer { try? fm.removeItem(atPath: home); try? fm.removeItem(atPath: sdk) }

            var bad: [String] = []
            // ① 常规 SDK 根的字面量必须还在（写错成别的字符串时本条先红）
            if AndroidEmulatorScanner.defaultSDKRoots.first != "~/Library/Android/sdk" {
                bad.append("默认 SDK 根首项不是 `~/Library/Android/sdk`：\(AndroidEmulatorScanner.defaultSDKRoots)")
            }
            setenv("ANDROID_AVD_HOME", home, 1)
            setenv("ANDROID_SDK_ROOT", sdk, 1)
            defer { unsetenv("ANDROID_AVD_HOME"); unsetenv("ANDROID_SDK_ROOT") }

            let sum = AndroidEmulatorScanner.shared.scan()
            let wantSDK = FileSystem.normalizePath(sdk)
            if !sum.detectedSDKRoots.contains(wantSDK) {
                bad.append("$ANDROID_SDK_ROOT 没进 detectedSDKRoots：\(sum.detectedSDKRoots)")
            }
            guard let it = sum.items.first(where: { $0.name == "live" }) else {
                print("      无注入缝的 scan 没列出 live.avd（avdRoot=\(sum.avdRoot)）")
                return false
            }
            // 只有 env 根真的被拿去查镜像，这一条才可能判健康；根没接上就是「证据不足」
            if it.status != .liveHealthy {
                bad.append("env SDK 根未参与镜像判据，实得 \(it.status)")
            }
            // 相对路径的 `$ANDROID_AVD_HOME` 不该被展开成 `/avd` 这种没人请求的根
            setenv("ANDROID_AVD_HOME", "avd", 1)
            let rel = AndroidEmulatorScanner.defaultAVDRoot
            if rel == "avd" || FileSystem.normalizePath(CleanPaths.expand(rel)) == "/avd" {
                bad.append("相对 `$ANDROID_AVD_HOME` 被当成绝对根使用：\(rel)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 5. 网关：孤儿 AVD 走网关删除；三种非孤儿一律拒删、文件仍在、且各自带回自己的研判结论
        check("clean：孤儿经网关删除，健康/需确认项被拒且不删文件（G14 零例外）") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-clean-\(UUID().uuidString)"
            let sdk = "\(root)/sdk"
            try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }
            func makeAVD(_ name: String, withIni: Bool, imageSysdir: String?) -> String {
                let dir = "\(root)/\(name).avd"
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? Data(repeating: 3, count: 1024).write(to: URL(fileURLWithPath: dir + "/disk.img"))
                if withIni {
                    try? "path=\(dir)\n".data(using: .utf8)?.write(to: URL(fileURLWithPath: "\(root)/\(name).ini"))
                }
                var cfg = "avd.name=\(name)\n"
                if let s = imageSysdir { cfg += "image.sysdir.1=\(s)\n" }
                try? cfg.data(using: .utf8)?.write(to: URL(fileURLWithPath: dir + "/config.ini"))
                return dir
            }
            // 与测试 2 同构：三态都得是真的，不能拿"缺 config 恰好被判需确认"冒充"健康"。
            try? fm.createDirectory(atPath: sdk + "/system-images/android-35/google_apis/arm64-v8a",
                                    withIntermediateDirectories: true)
            let orphanPath = makeAVD("orph", withIni: false, imageSysdir: nil)
            let livePath = makeAVD("live", withIni: true, imageSysdir: "system-images/android-35/google_apis/arm64-v8a/")
            let gonePath = makeAVD("gone", withIni: true, imageSysdir: "system-images/android-99/deleted/")
            let nocfgPath = makeAVD("nocfg", withIni: true, imageSysdir: nil)

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [sdk])
            func item(_ n: String) -> AndroidEmulatorItem? { sum.items.first { $0.name == n } }
            guard let o = item("orph"), let l = item("live"),
                  let g = item("gone"), let n = item("nocfg") else {
                print("      扫描没抓到 4 棵 AVD（实际 \(sum.items.map(\.name))）"); return false
            }
            // 前置：fixture 本身三态要对，否则下面的拒绝断言是在测错的输入。
            var pre: [String] = []
            if o.status != .orphanUnused { pre.append("orph 应判孤儿，实得 \(o.status)") }
            if l.status != .liveHealthy { pre.append("live 应判健康，实得 \(l.status)") }
            if g.status != .brokenImageNeedsConfirm { pre.append("gone 应判镜像已删，实得 \(g.status)") }
            if n.status != .needsConfirmation { pre.append("nocfg 应判证据不足，实得 \(n.status)") }
            if !pre.isEmpty {
                print("      fixture 状态不符，测试输入无效：\n      " + pre.joined(separator: "\n      "))
                return false
            }

            // 把三棵非孤儿全伪造进待删列表：既不能被删，也必须**各自带着原因**回到结论里。
            // 判据钉在具体的 path + reason + 该条目自己的状态文案上（不是"A 或 B 存在"式），
            // 否则原因挂到错误的条目上照样绿。
            let res = AndroidEmulatorScanner.shared.clean(items: [o, l, g, n], toTrash: false,
                                                          journal: .none)
            var bad: [String] = []
            if res.cleanedCount != 1 { bad.append("应只删掉孤儿那 1 项：cleaned=\(res.cleanedCount)") }
            if fm.fileExists(atPath: orphanPath) { bad.append("孤儿 .avd 没被删除") }
            for (path, it, label) in [(livePath, l, "健康"), (gonePath, g, "镜像已删"), (nocfgPath, n, "证据不足")] {
                if !fm.fileExists(atPath: path) { bad.append("\(label) AVD 被误删了！") }
                if let rej = res.rejected.first(where: { $0.path == path }) {
                    if rej.reason != .notDeletable {
                        bad.append("\(label) 项拒绝理由应是 .notDeletable，实得 \(rej.reason)")
                    }
                    if !rej.message.contains(it.status.rawValue) {
                        bad.append("\(label) 项拒绝文案没带出它自己的研判结论「\(it.status.rawValue)」：\(rej.message)")
                    }
                } else {
                    bad.append("\(label) 项的拒绝没带进 Outcome（用户看不到为什么没删）")
                }
            }
            // `errorCount` 的定义就是 `rejected.count + failed.count`（ResidueDeletionGate:67），
            // 比这两个数之和是恒真式，钉不住任何东西——复审 P1-4 抓出来的假断言。改成钉具体数字。
            if res.errorCount != 3 || !res.failed.isEmpty {
                bad.append("应有恰好 3 条拒绝、0 条删除失败：errorCount=\(res.errorCount) failed=\(res.failed.count)")
            }
            if !res.summary.contains("3 项被安全护栏拦下") {
                bad.append("summary 没把 3 项未删如实带出：\(res.summary)")
            }
            FileSystem.resetDeniedAccess()
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 5b. 默认 journal 锁住"写历史与撤销快照"：卡片调用时**不传** journal，
        //     默认值被改成 `.none` 时用户清完 GB 级 AVD 依然无痕可查（二次复审 P2-9）。
        check("clean 默认 journal 会写历史与撤销快照（不传参的那条生产路径）") {
            guard MacCleanState.isIsolated else {
                print("      MACCLEAN_STATE_DIR 未生效，跳过写入断言")
                return false
            }
            let fm = FileManager.default
            let root = "/private/tmp/macclean-avd-journal-\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root + "/gone.avd", withIntermediateDirectories: true)
            try? Data(repeating: 0x5A, count: 2048).write(to: URL(fileURLWithPath: root + "/gone.avd/userdata.img"))
            defer { try? fm.removeItem(atPath: root) }
            let avdPath = root + "/gone.avd"
            let sizeBefore = FileSystem.size(at: avdPath)

            let headBefore = HistoryStore.load().first?.id
            let undoCountBefore = UndoManagerStore.load().count

            FileSystem.resetDeniedAccess()
            let sum = AndroidEmulatorScanner.shared.scan(customAVDRoot: root, customSDKRoots: [])
            guard let orphan = sum.items.first, orphan.status == .orphanUnused else {
                print("      fixture 没造出孤儿：\(sum.items.map { "\($0.name):\($0.status)" })")
                return false
            }
            // 关键：**不传 journal**，走生产默认值
            let res = AndroidEmulatorScanner.shared.clean(items: [orphan], toTrash: true)
            guard res.cleanedCount == 1, !fm.fileExists(atPath: avdPath) else {
                print("      孤儿没被删：cleaned=\(res.cleanedCount)")
                return false
            }
            let newRecord = HistoryStore.load().first
            guard newRecord?.id != headBefore,
                  newRecord?.categoryName == AndroidEmulatorScanner.historyCategory,
                  newRecord?.itemCount == 1,
                  newRecord?.bytes == sizeBefore else {
                print("      历史没记或记错：\(String(describing: newRecord?.categoryName))"
                      + " itemCount=\(String(describing: newRecord?.itemCount))"
                      + " bytes=\(String(describing: newRecord?.bytes)) vs \(sizeBefore)")
                return false
            }
            // 撤销快照必须挂在同一条记录上，否则「一键放回原位」失去入口
            if UndoManagerStore.load().count <= undoCountBefore
                || UndoManagerStore.load().first(where: { $0.recordID == newRecord?.id }) == nil {
                print("      没有可撤销的快照（记录在、快照丢）")
                return false
            }
            FileSystem.resetDeniedAccess()
            return true
        }

        // 6. 域路由：主目录内外都恒 nil——本模块永不借用别的模块登记的治理域
        check("domain(forPath:) 恒返回 nil：主目录内走主目录护栏，主目录外也不借用别人的域") {
            var bad: [String] = []
            // 判别性样本：**已登记治理域根下**的路径。全局解析器对它返回非 nil，
            // 本模块必须仍返回 nil——否则 `$ANDROID_AVD_HOME` 一挪，删除就借道别的域裁决。
            let foreignDomainPath = "/Library/Fonts/macclean-probe.avd"
            if GovernanceDomain.domain(forPath: foreignDomainPath) == nil {
                bad.append("前提失效：\(foreignDomainPath) 本应命中某个登记域，这条断言就没有判别力了")
            }
            if AndroidEmulatorScanner.domain(forPath: foreignDomainPath) != nil {
                bad.append("主目录外的已登记域路径被借用了治理域")
            }
            let inHome = NSHomeDirectory() + "/.android/avd/proj.avd"
            if AndroidEmulatorScanner.domain(forPath: inHome) != nil {
                bad.append("主目录内 AVD 路径不该命中登记域")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 7. 源码接线 lint：本模块 scanner 不得出现裸删除 / 字符串护栏 / journal:.none 的卡片
        check("Android 治理 scanner/card 源码接线：无裸删除、无字符串护栏、卡片不传 journal:.none") {
            var bad: [String] = []
            guard let rawScannerSrc = SelftestSource.read("AndroidEmulatorScanner") else {
                print("      scanner 源码不可读"); return false
            }
            let scannerSrc = Selftest.stripSwiftComments(rawScannerSrc)
            if scannerSrc.contains("removeItem(") || scannerSrc.contains("trashItem(") {
                bad.append("scanner 里出现裸删除调用（删除必须只经 ResidueDeletionGate）")
            }
            if !scannerSrc.contains("ResidueDeletionGate.execute") {
                bad.append("scanner 没接网关")
            }
            if scannerSrc.contains("hasPrefix(\"/System\")") || scannerSrc.contains("standardizingPath") {
                bad.append("scanner 用了字符串路径护栏/漂移归一化（G18/G19）")
            }
            guard let rawCardSrc = SelftestSource.read("AndroidEmulatorOptimizerCard") else {
                print("      card 源码不可读"); return false
            }
            // 同下：针脚比对一律用剥掉注释的源码，注释里的诱饵文本不算数。
            let cardSrc = Selftest.stripSwiftComments(rawCardSrc)
            if cardSrc.contains("journal: .none") {
                bad.append("卡片调用 clean 传了 journal: .none（会丢历史与撤销快照）")
            }
            if !cardSrc.contains("AndroidEmulatorScanner.shared.clean(") {
                bad.append("卡片没接 scanner.clean")
            }
            // 删除面这一维必须**两侧都有闸**（三次复审 P1-2）：scan 决定默勾，
            // clean 决定"调用方硬塞进来时删不删"。判据只能取自网关那张放行根表，
            // 模块里手抄 `/tmp` 或 `hasPrefix(home)` 都算走偏。
            for needle in ["FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(avdRoot))",
                           "isSelected: verdict.status.isProvenOrphan && metrics.readable && rootDeletable",
                           "FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(item.path))",
                           "FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(cand.path))",
                           "topEnumerationBlocked: blocked.value",
                           "unreadableDescriptors: pairing.unreadableInis.count + unaccountedDescriptors"] {
                if !scannerSrc.contains(needle) { bad.append("删除面/否决闸改道：\(needle)") }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        // 8–11. ── UI 层安全契约（五层里的「卡片全选」层）──────────────────
        // scanner 判对了不代表卡片不会把非孤儿勾上。这四条把"零默选 / 受保护行无勾选框 /
        // 全选不吞残缺项 / 删除必经确认 / 降级态如实可见"钉在视图层。

        check("Android UI: 结果零默选、受保护行不给勾选框") {
            // `initiallyShowingAll`：默认「只看孤儿」会把 `.liveHealthy` 整行滤掉，那样这条断言
            // 只能看到 3 种受保护态里的 2 种，健康行勾选框长出来也不会红（复审 P2-11）。
            let card = AndroidEmulatorOptimizerCard(onClose: {},
                                                    initialSummary: androidUIMixedSummary(),
                                                    initiallyShowingAll: true)
            var bad: [String] = []
            if (try? button("androidEmulatorCleanButton", in: card).isDisabled()) != true {
                bad.append("一项都没勾时清理按钮竟可点击（存在默认可删）")
            }
            // 5 行全渲染，其中只有 2 行是孤儿 → 勾选框必须恰好 2 个
            let rows = try? card.inspect().findAll(ViewType.Text.self).map { try $0.string() }
            let rowNames = (rows ?? []).filter { androidUIMixedNames.contains($0) }
            if rowNames.count != 5 {
                bad.append("5 条清单在『显示全部』下只渲染出 \(rowNames.count) 行：\(rowNames)")
            }
            let toggles = try? card.inspect().findAll(ViewType.Toggle.self)
                .filter { (try? $0.accessibilityIdentifier()) == "androidEmulatorRowToggle" }
            if (toggles ?? []).count != 2 {
                bad.append("勾选框数量 \((toggles ?? []).count) ≠ 孤儿数 2（受保护项被允许勾选）")
            }
            // 反证：卡片不是"永远禁用"——勾上确证孤儿后必须立刻可点，否则上面的断言是空断言
            var seeded = androidUIMixedSummary()
            seeded.items[0].isSelected = true
            let armed = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: seeded)
            if (try? button("androidEmulatorCleanButton", in: armed).isDisabled()) != false {
                bad.append("已勾选确证孤儿，清理按钮仍禁用")
            }
            _ = try armed.inspect().find(text: "清理选中 (3 MB)")
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android UI: 只剩残缺孤儿时「全选」「清理」两键禁用（按钮枚举，本机不可跑）") {
            // 行为侧能观测到的只有按钮禁用态：卡片的选中态是 `@State`，`.tap()` 之后重新
            // `inspect()` 读不回新值（实测：点完全选按钮文案仍是「清理选中 (0 KB)」），
            // 所以"全选不吞残缺项"这一条**不在这里断言**，改由
            // `Selftest+ScanDiagnostics` 的「卡片全选必须走 readable」源码形状 lint 钉住函数体。
            // 本条钉的是同一契约的可观测半边：残缺项不构成可批量勾选的额度。
            let only = AndroidEmulatorSummary(
                items: [androidUIItem("OrphanPartial", .orphanAVD, .orphanUnused,
                                      size: 9_000_000, readable: false)],
                orphanCount: 1, orphanSize: 9_000_000,
                brokenImageCount: 0, liveCount: 0,
                issues: [], avdRoot: "/tmp/macclean-selftest-avd-ui", detectedSDKRoots: [])
            let card = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: only)
            var bad: [String] = []
            if (try? button("androidEmulatorSelectAllButton", in: card).isDisabled()) != true {
                bad.append("唯一孤儿子树读不到（size 只是下限）时「全选」仍可点")
            }
            if (try? button("androidEmulatorCleanButton", in: card).isDisabled()) != true {
                bad.append("残缺孤儿仍进了可删额度")
            }
            // 反证：同一份清单换成 readable=true，两个按钮必须都放开——否则上面的断言只是
            // "按钮永远禁用"，不构成证据。
            let healed = AndroidEmulatorSummary(
                items: [androidUIItem("OrphanPartial", .orphanAVD, .orphanUnused, size: 9_000_000)],
                orphanCount: 1, orphanSize: 9_000_000,
                brokenImageCount: 0, liveCount: 0,
                issues: [], avdRoot: "/tmp/macclean-selftest-avd-ui", detectedSDKRoots: [])
            let ok = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: healed)
            if (try? button("androidEmulatorSelectAllButton", in: ok).isDisabled()) != false {
                bad.append("反证失效：完整可读的孤儿也被禁用")
            }
            // 残缺项必须把"为什么没勾上"渲染出来，而且**连勾选框都不给**：
            // 给了框，用户勾上后再点「全选」会被 `select && readable` 静默取消（二次复审 P2-10）
            let rowToggles = (try? card.inspect().findAll(ViewType.Toggle.self)
                .filter { (try? $0.accessibilityIdentifier()) == "androidEmulatorRowToggle" }) ?? []
            if !rowToggles.isEmpty {
                bad.append("子树读不到的孤儿仍拿到勾选框（\(rowToggles.count) 个）")
            }
            // 「体积为下限」这句的渲染断言（含可读项反证）移到了「Android UI 渲染文案（本机可跑）」，
            // 因为本条整条依赖按钮/Toggle 枚举，在发版机上永远红，挂着也执法不了。
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android UI: 彻底删除只在确认弹窗里，不是一键直达") {
            var summary = androidUIMixedSummary()
            summary.items[0].isSelected = true
            // 未点删除时弹窗不该在视图树里；先用同一份清单证明卡片确实渲染并计了额度，
            // 否则"抽不到弹窗"可能只是抽不到任何东西（空断言）。
            let calm = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: summary)
            _ = try calm.inspect().find(text: "清理选中 (3 MB)")
            if (try? calm.inspect().vStack().confirmationDialog()) != nil {
                print("      ❌ 未点删除就有确认弹窗")
                return false
            }
            let card = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: summary,
                                                    initiallyConfirming: true)
            let dialog = try card.inspect().vStack().confirmationDialog()
            if try dialog.title().string() != "确认清理选中的孤儿 AVD 数据目录" { return false }
            _ = try dialog.actions().find(button: "取消")
            _ = try dialog.actions().find(button: "安全移入废纸篓")
            _ = try dialog.actions().find(button: "彻底删除")
            return true
        }

        check("Android UI: 证据不足时「全选」「清理」两键禁用（按钮枚举，本机不可跑）") {
            // 本条整条依赖 `findAll(ViewType.Button.self)`，macOS 27 上枚举失效（§0.2），
            // 所以它在发版机上只会红、不会抓回归。同一契约的**能跑**的那半在
            // 「Android 卡片禁用判据纯函数化」与「Android 卡片判据接线」两条里；
            // 降级横幅的文案那半也拆进了「Android UI 渲染文案（本机可跑）」。
            let card = AndroidEmulatorOptimizerCard(onClose: {},
                                                    initialSummary: androidUIDegradedSummary())
            var bad: [String] = []
            if (try? button("androidEmulatorSelectAllButton", in: card).isDisabled()) != true {
                bad.append("AVD 根读不到时「全选」仍可点，会把未证孤儿整体勾上")
            }
            if (try? button("androidEmulatorCleanButton", in: card).isDisabled()) != true {
                bad.append("降级态清理按钮可点")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android UI: 降级横幅不得把『已勾选项』说成『一项都没勾』（复审 P1-5）") {
            // 结果不完整（有一条 AVD 没读全）**同时**又有一棵确证孤儿被默认勾选，是真会发生的形态。
            // 横幅那句绝对化的"没有任何一项被默认勾选"在这时就是当面向用户撒谎。
            var summary = androidUIDegradedSummary()
            summary.items[0] = androidUIItem("ProvenOrphan", .orphanAVD, .orphanUnused, size: 3_000_000)
            summary.items[0].isSelected = true
            let card = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: summary)
            var bad: [String] = []
            _ = try card.inspect().find(text: "AVD 目录未能完整读取，下面的列表可能不完整")
            do {
                _ = try card.inspect().find(text: "因此没有一项被判定为可清理孤儿，也没有任何一项被默认勾选。")
                bad.append("已勾上 1 项孤儿时，横幅仍宣称『没有任何一项被默认勾选』")
            } catch { /* 期望抽不到这句 */ }
            _ = try card.inspect().find(text: "下面仍有 1 项被默认勾选为确证孤儿——它们各自的判据都成立，但整份清单可能不完整。")
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android UI: 清理进行中按钮禁用，防重复提交") {
            var summary = androidUIMixedSummary()
            summary.items[0].isSelected = true
            let idle = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: summary)
            guard (try? button("androidEmulatorCleanButton", in: idle).isDisabled()) == false else {
                print("      ❌ 对照组失效：已勾选且未在清理，按钮却禁用")
                return false
            }
            let busy = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: summary,
                                                    initiallyCleaning: true)
            return (try? button("androidEmulatorCleanButton", in: busy).isDisabled()) == true
        }

        // ── 同一批删除安全契约的**本机可跑**执法点 ────────────────────────
        // 上面 8–11 那批 UI 用例依赖 `findAll(ViewType.Button/Toggle.self)`，而 macOS 27 上
        // 这类枚举整体失效（docs/RELEASE-CHECKLIST.md §0.2：按钮/勾选框枚举属于那 34 条环境
        // 失败）。一条在本机永远红的断言抓不到任何回归——所以判据本身必须能在没有
        // ViewInspector 的机器上被跑到。下面四条各钉一面：
        // ① 空态措辞（`find(text:)` 本机可用）② 纯判据成立 ③ 界面只有这一个判据可抄
        // ④ 渲染文案两分支各说各话。

        check("Android UI 空态措辞（本机可跑）：结论未出时不许说「未发现孤儿 AVD」（三次复审 P1-3）") {
            // 空清单在"还没扫"和"扫了没有"两种状态下长得一模一样，卡片此前只看 `items.isEmpty`
            // 就直接下"未发现孤儿 AVD 或已删镜像"——把"没看"报成"看了、没有"，正是本仓
            // 反复收编的那一族谎报。这条用 `find(text:)`（本机可用）钉两句话的分工。
            let empty = AndroidEmulatorSummary(items: [], orphanCount: 0, orphanSize: 0,
                                               brokenImageCount: 0, liveCount: 0, issues: [],
                                               avdRoot: "/tmp/macclean-selftest-avd-ui",
                                               detectedSDKRoots: [])
            var bad: [String] = []
            let scanning = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: empty,
                                                        initiallyScanning: true, initiallyLoaded: false)
            _ = try scanning.inspect().find(text: "正在扫描 AVD 目录，结论未出")
            do {
                _ = try scanning.inspect().find(text: "未发现孤儿 AVD 或已删镜像")
                bad.append("扫描进行中就宣称「未发现孤儿 AVD」")
            } catch { /* 期望抽不到 */ }

            let notYet = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: empty,
                                                      initiallyLoaded: false)
            _ = try notYet.inspect().find(text: "正在扫描 AVD 目录，结论未出")

            // 反证：真的扫完且没有孤儿时，那句"未发现"必须出现——否则上面两条只是
            // "永远显示正在扫描"，不构成证据。
            let settled = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: empty)
            _ = try settled.inspect().find(text: "未发现孤儿 AVD 或已删镜像")
            do {
                _ = try settled.inspect().find(text: "正在扫描 AVD 目录，结论未出")
                bad.append("已经拿到扫描结果仍说「结论未出」")
            } catch { /* 期望抽不到 */ }

            // 盲区另说一句：结果不完整时空态不得用"未发现"措辞（既有分叉，别改回去）。
            let blind = AndroidEmulatorSummary(items: [], orphanCount: 0, orphanSize: 0,
                                               brokenImageCount: 0, liveCount: 0,
                                               issues: [GovernanceEvidenceIssue(kind: .permissionDenied,
                                                subject: "/tmp/macclean-selftest-avd-ui",
                                                message: "AVD 目录读不到")],
                                               avdRoot: "/tmp/macclean-selftest-avd-ui",
                                               detectedSDKRoots: [])
            let blindCard = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: blind)
            _ = try blindCard.inspect().find(text: "本轮未能确认")
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android 卡片禁用判据纯函数化：额度只给「确证孤儿∧读全∧根在放行面」，清理只给「真勾上且不在忙」") {
            let orphan = androidUIItem("Orphan", .orphanAVD, .orphanUnused, size: 3_000_000)
            let orphanPartial = androidUIItem("OrphanPartial", .orphanAVD, .orphanUnused,
                                              size: 3_000_000, readable: false)
            let broken = androidUIItem("Broken", .brokenImageAVD, .brokenImageNeedsConfirm, size: 7_000_000)
            let unsure = androidUIItem("Unsure", .liveAVD, .needsConfirmation, size: 5_000_000)
            let healthy = androidUIItem("Healthy", .liveAVD, .liveHealthy, size: 9_000_000)
            var bad: [String] = []

            let expectations: [(AndroidEmulatorItem, Bool, String)] = [
                (orphan, true, "确证孤儿且读全 → 该计入额度"),
                (orphanPartial, false, "子树读不到（size 只是下限）→ 不许计入额度"),
                (broken, false, "镜像已删只算「需确认」→ 不许批量勾"),
                (unsure, false, "证据不足 → 不许批量勾"),
                (healthy, false, "健康 AVD → 永远不许勾"),
            ]
            for (item, want, why) in expectations
            where AndroidEmulatorOptimizerCard.isSelectable(item, root: "/tmp/macclean-selftest-avd-ui") != want {
                bad.append("isSelectable(\(item.name)) 判反了：\(why)")
            }

            // 根这一维必须一起判（三次复审 P1-2）：判据来自网关那张放行根表，
            // 于是 `/tmp` 是可删面（承诺"这里不能删"就是假的），而 `/Users/Shared`、
            // 外接盘不是。同前缀不同用户那条专门拦"手写 hasPrefix(home + \"/\")"的老错。
            let orphanOnly = [orphan]
            let rootCases: [(String, Bool, String)] = [
                ("/tmp/macclean-selftest-avd-ui", true, "临时根确实在放行面内"),
                (NSHomeDirectory() + "/.android/avd", true, "主目录内的根"),
                (NSHomeDirectory() + "a/.android/avd", false, "主目录同前缀的别人家（手抄前缀会误放行）"),
                ("/Users/Shared/.android/avd", false, "放行面外的共享目录"),
                ("/Volumes/Ext/avd", false, "外接盘（网关禁区）"),
            ]
            for (root, want, why) in rootCases
            where AndroidEmulatorOptimizerCard.isSelectAllEnabled(orphanOnly, root: root) != want {
                bad.append("放行面判错（root=\(root)，期望 \(want)）：\(why)")
            }

            // 全选可用性：额度为 0 时必须禁用，额度存在时必须放开（后者是阴性对照，
            // 否则前面的"该禁用"可能只是因为按钮写死成禁用）。
            if AndroidEmulatorOptimizerCard.isSelectAllEnabled([orphanPartial, broken, unsure, healthy],
                                                               root: "/tmp/macclean-selftest-avd-ui") {
                bad.append("没有任何确证孤儿时「全选」仍判成可用")
            }
            if !AndroidEmulatorOptimizerCard.isSelectAllEnabled([orphan],
                                                                 root: "/tmp/macclean-selftest-avd-ui") {
                bad.append("对照组失效：确证孤儿存在时「全选」也被判成不可用")
            }
            if AndroidEmulatorOptimizerCard.isSelectAllEnabled([], root: "/tmp/macclean-selftest-avd-ui") {
                bad.append("空清单时「全选」判成可用")
            }

            // 清理可用性：勾了才放开，扫描中/清理中一律掐掉。
            var picked = [healthy, orphan]
            picked[1].isSelected = true
            if AndroidEmulatorOptimizerCard.isCleanEnabled([healthy, orphan], isScanning: false, isCleaning: false) {
                bad.append("一项都没勾选时「清理选中」判成可用（存在默认可删）")
            }
            if !AndroidEmulatorOptimizerCard.isCleanEnabled(picked, isScanning: false, isCleaning: false) {
                bad.append("对照组失效：已勾选且空闲时「清理选中」判成禁用")
            }
            if AndroidEmulatorOptimizerCard.isCleanEnabled(picked, isScanning: true, isCleaning: false) {
                bad.append("扫描中还能提交清理")
            }
            if AndroidEmulatorOptimizerCard.isCleanEnabled(picked, isScanning: false, isCleaning: true) {
                bad.append("清理中还能再提交一次（重复删除）")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android 卡片判据接线：四个消费点都调同一判据，源码里不存在第二份条件") {
            guard let rawSrc = SelftestSource.read("AndroidEmulatorOptimizerCard") else {
                print("      card 源码不可读"); return false
            }
            // 比对前**必须先剥注释**：针脚是字符串字面量，只要在注释里写一句
            // `// 这里走 Self.isSelectable(item, root: summary.avdRoot)` 就能骗过原始比对，
            // 而界面上那道闸早被摘掉了（三次复审 C 的 M11）。剥注释还保行号，见 Selftest.swift。
            let src = Selftest.stripSwiftComments(rawSrc)
            var bad: [String] = []
            // 消费点逐个点名：行勾选框、额度计数、「全选」禁用、「清理」禁用、全选赋值。
            // 少任何一个都意味着那里可能悄悄写回了一份条件副本。
            for needle in ["if Self.isSelectable(item, root: summary.avdRoot)",
                           "items.filter { Self.isSelectable($0, root: summary.avdRoot) }.count",
                           "Self.isSelectAllEnabled(items, root: summary.avdRoot)",
                           "Self.isCleanEnabled(items, isScanning: isScanning, isCleaning: isCleaning)",
                           ".disabled(!selectAllEnabled)",
                           ".disabled(!cleanEnabled)",
                           "Self.isSelectable(summary.items[i],"] {
                if !src.contains(needle) { bad.append("消费点缺失或改道：\(needle)") }
            }
            // 判据本体只允许出现一次（就在 `isSelectable` 里）。出现第二份就是分叉的开始。
            let copies = src.components(separatedBy: "status.isProvenOrphan && item.readable").count - 1
            if copies != 1 {
                bad.append("「确证孤儿∧读全」这份条件在卡片里出现 \(copies) 次，应为 1 次（判据本体）")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("Android UI 渲染文案（本机可跑）：残缺行标「体积为下限」，降级横幅两条分支各说各话") {
            // 这几句原先挂在依赖按钮枚举的用例里，跟着环境失败一起红；`find(text:)` 在本机可用，
            // 拆出来才有执法力。
            var bad: [String] = []
            let partialOnly = AndroidEmulatorSummary(
                items: [androidUIItem("OrphanPartial", .orphanAVD, .orphanUnused,
                                      size: 9_000_000, readable: false)],
                orphanCount: 1, orphanSize: 9_000_000,
                issues: [], avdRoot: "/tmp/macclean-selftest-avd-ui", detectedSDKRoots: [])
            let partialCard = AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: partialOnly)
            _ = try partialCard.inspect().find(text: "体积为下限")   // 残缺项要说出为什么没额度
            _ = try partialCard.inspect().find(text: "只看孤儿")      // 证明卡片整体渲染了，不是空断言

            let readableOnly = AndroidEmulatorSummary(
                items: [androidUIItem("OrphanFull", .orphanAVD, .orphanUnused, size: 9_000_000)],
                orphanCount: 1, orphanSize: 9_000_000,
                issues: [], avdRoot: "/tmp/macclean-selftest-avd-ui", detectedSDKRoots: [])
            do {
                _ = try AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: readableOnly)
                    .inspect().find(text: "体积为下限")
                bad.append("读全了的条目也被标成「体积为下限」")
            } catch { /* 期望抽不到：可读项不该带警示 */ }

            let degradedCard = AndroidEmulatorOptimizerCard(onClose: {},
                                                            initialSummary: androidUIDegradedSummary())
            _ = try degradedCard.inspect().find(text: "AVD 目录未能完整读取，下面的列表可能不完整")
            _ = try degradedCard.inspect().find(text: "因此没有一项被判定为可清理孤儿，也没有任何一项被默认勾选。")
            // 反证：清单完整时不该出现降级横幅，否则"永远显示横幅"也等于没在说任何事。
            do {
                _ = try AndroidEmulatorOptimizerCard(onClose: {}, initialSummary: androidUIMixedSummary())
                    .inspect().find(text: "AVD 目录未能完整读取，下面的列表可能不完整")
                bad.append("清单完整可读时仍显示降级横幅")
            } catch { /* 期望抽不到 */ }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }
        check("descriptorsCertain：顶层枚举中途被拦也必须否决孤儿确证（三次复审 P1-1）") {
            // 行为侧造不出"顶层枚举中途被拒"的目录（`skipsSubdirectoryDescendants` 下
            // chmod 某个子目录只会拦到那棵子树），所以这条在判据侧钉：三个输入组合、
            // 一个真值反证（否则"永远否决"也算过）。
            var bad: [String] = []
            let cases: [(Int, Bool, Bool, String)] = [
                (0, false, true, "描述符全清算且枚举完整 → 允许确证孤儿"),
                (1, false, false, "有一份 .ini 读不出来 → 不许确证"),
                (0, true, false, "都读出来了但顶层枚举中途被拦：没交出来的那份 .ini 仍是未知，不许确证"),
                (2, true, false, "两种缺口同时存在 → 不许确证"),
            ]
            for (n, blk, want, why) in cases
            where AndroidEmulatorScanner.descriptorsCertain(unreadableDescriptors: n,
                                                            topEnumerationBlocked: blk) != want {
                bad.append("判错（unreadable=\(n) blocked=\(blk)，期望 \(want)）：\(why)")
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }
    }
}

// MARK: - Android 卡片 UI 自检夹具

/// 造一条 AVD 条目。路径指向不存在的临时目录，绝不含真实文件——UI 断言只读渲染结果，
/// 不会触达磁盘（卡片的 `loadData()` 挂在 `onAppear`，inspect() 不触发它）。
private func androidUIItem(_ name: String, _ kind: AndroidEmulatorKind, _ status: AndroidEmulatorStatus,
                           size: Int64, readable: Bool = true) -> AndroidEmulatorItem {
    let path = "/tmp/macclean-selftest-avd-ui/\(name).avd"
    return AndroidEmulatorItem(id: path, name: name, path: path, kind: kind, status: status,
                               size: size, readable: readable,
                               imageSysdir: nil, note: nil, isSelected: false)
}

/// 混合清单：2 条确证孤儿 + 1 条镜像已删 + 1 条需确认 + 1 条健康。默认可删集合必须是 0。
/// 计数位必须与 items 逐条对得上——测试 5 明确拒绝跑在自相矛盾的夹具上，UI 夹具同理，
/// 否则"渲染出 5 行"这类断言可能只是在数自己写错的字段。
private func androidUIMixedSummary() -> AndroidEmulatorSummary {
    AndroidEmulatorSummary(
        items: [androidUIItem("OrphanA", .orphanAVD, .orphanUnused, size: 3_000_000),
                androidUIItem("OrphanB", .orphanAVD, .orphanUnused, size: 2_000_000),
                androidUIItem("ImageGone", .brokenImageAVD, .brokenImageNeedsConfirm, size: 7_000_000),
                androidUIItem("NoEvidence", .liveAVD, .needsConfirmation, size: 5_000_000),
                androidUIItem("Healthy", .liveAVD, .liveHealthy, size: 9_000_000)],
        orphanCount: 2, orphanSize: 5_000_000,
        brokenImageCount: 1, liveCount: 1,
        issues: [], avdRoot: "/tmp/macclean-selftest-avd-ui", detectedSDKRoots: [])
}

/// `androidUIMixedSummary` 里每行的展示名，供"5 行都渲染出来了"这类断言点名核对。
private let androidUIMixedNames: Set<String> = ["OrphanA", "OrphanB", "ImageGone", "NoEvidence", "Healthy"]

/// 降级态：AVD 根读不到 → 全部条目落"证据不足"，一条都不许批量勾上。
private func androidUIDegradedSummary() -> AndroidEmulatorSummary {
    AndroidEmulatorSummary(
        items: [androidUIItem("UnknownA", .liveAVD, .needsConfirmation, size: 3_000_000),
                androidUIItem("UnknownB", .liveAVD, .needsConfirmation, size: 2_000_000)],
        orphanCount: 0, orphanSize: 0,
        brokenImageCount: 0, liveCount: 0,
        issues: [GovernanceEvidenceIssue(kind: .permissionDenied, subject: "/Users/test/.android/avd",
                                         message: "AVD 目录读不到，无法判定是否有孤儿")],
        avdRoot: "/tmp/macclean-selftest-avd-ui", detectedSDKRoots: [])
}
