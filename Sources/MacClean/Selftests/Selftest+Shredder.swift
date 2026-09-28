import Foundation
import Darwin

// MARK: - 文件粉碎器自检（v1.73.14）
//
// 两层：
// · 判定层——覆写之前必须被护栏拦下（G8 / 白名单 / 软链 / 不存在）。这些路径
//   一个字节都不该被写出，因此直接对真路径断言"拒绝 + 目标原样"，不需要替身；
//   其中「白名单文件内容原样」与「软链拒绝跟随文案」是两条变异靶：
//   摘掉 shred 里的覆写前裁决后它们必须变红（白名单文件会被真的覆写掉）。
// · 端到端层——临时目录真文件真跑（真覆写 + 真删除），含历史落「文件粉碎」、
//   无撤销快照、目录内软链不跟随、枚举被掐断不上报成功。
//   覆写遍次的可观测性走 `ShredderService.passObserver` 注入缝：在每遍 fsync 之后
//   读回内容比对——这是"3 遍里真的有一遍是随机"的唯一可证伪观测点，
//   变异（3 遍改 2 遍去随机遍）会让 [true, false, true] 序列断言变红。

extension Selftest {
    static func suiteShredder() {
        print("--- [Suite] 文件粉碎器自检 (v1.73.14) ---")

        let fm = FileManager.default
        func makeFixture(_ tag: String) -> String {
            let dir = "/private/tmp/macclean_shred_\(tag)_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            return dir
        }
        func makeFile(_ path: String, _ bytes: Int, fill: UInt8 = 0x5A) {
            try? Data(repeating: fill, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        func readAll(_ path: String) -> Data? {
            try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        func exists(_ path: String) -> Bool {
            var st = stat()
            return lstat(path, &st) == 0
        }

        // MARK: 判定层（覆写之前的裁决）

        check("判定层：G8 系统保护路径在任何字节写出之前被拒，文件原样") {
            let target = "/System/Library/CoreServices/SystemVersion.plist"
            guard exists(target) else {
                print("      本机不存在 \(target)，跳过")
                return true
            }
            let out = ShredderService.shred(paths: [target], journal: .none)
            guard out.shredded.isEmpty, out.failed.isEmpty else { return false }
            guard out.rejected.count == 1,
                  out.rejected[0].path == target,
                  out.rejected[0].reason == .systemProtected,
                  !out.rejected[0].message.isEmpty else { return false }
            return exists(target)
        }

        check("判定层：用户白名单命中即拒，且文件内容一个字节都没被写") {
            let root = makeFixture("whitelist")
            defer { try? fm.removeItem(atPath: root) }
            let victim = root + "/keepme.bin"
            let original = Data(repeating: 0xC3, count: 2048)
            try? original.write(to: URL(fileURLWithPath: victim))

            let saved = WhitelistManager.shared.rules
            WhitelistManager.shared.removeAllRules()
            defer {
                WhitelistManager.shared.removeAllRules()
                WhitelistManager.shared.rules = saved
            }
            WhitelistManager.shared.addPathRule(victim, comment: "自检保护")

            let out = ShredderService.shred(paths: [victim], journal: .none)
            guard out.shredded.isEmpty, out.failed.isEmpty else { return false }
            guard out.rejected.count == 1,
                  out.rejected[0].path == FileSystem.normalizePath(victim),
                  out.rejected[0].reason == .userWhitelisted else { return false }
            // 关键：覆写前的裁决若被摘掉，这里的内容比对就会变红（文件已被真的覆写掉）
            return readAll(victim) == original && exists(victim)
        }

        check("判定层：软链拒绝跟随（专属文案），指向的目标内容原样") {
            let root = makeFixture("symlink")
            defer { try? fm.removeItem(atPath: root) }
            let target = root + "/real-target.bin"
            let original = Data(repeating: 0x7E, count: 1024)
            try? original.write(to: URL(fileURLWithPath: target))
            let link = root + "/jump.lnk"
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: target)

            let out = ShredderService.shred(paths: [link], journal: .none)
            guard out.shredded.isEmpty, out.failed.isEmpty else { return false }
            guard out.rejected.count == 1,
                  out.rejected[0].reason == .symlinkJump,
                  out.rejected[0].message.contains("拒绝跟随"),
                  out.rejected[0].message.contains("点名目标文件本身") else {
                print("      软链拒绝文案不达标：\(out.rejected.first?.message ?? "无")")
                return false
            }
            // 目标一个字节都没被动
            return readAll(target) == original && exists(target)
        }

        check("判定层：不存在的路径拒绝（.missing），不产出成功也不沉默") {
            let ghost = "/private/tmp/macclean_shred_missing_\(UUID().uuidString)"
            let out = ShredderService.shred(paths: [ghost], journal: .none)
            guard out.shredded.isEmpty, out.failed.isEmpty else { return false }
            guard out.rejected.count == 1,
                  out.rejected[0].path == FileSystem.normalizePath(ghost),
                  out.rejected[0].reason == .missing else { return false }
            return !exists(ghost)
        }

        // MARK: 端到端（临时目录真文件，真覆写 + 真删除）

        check("端到端：目录粉碎后文件消失、历史落「文件粉碎」、无撤销快照、摘要含「不可恢复」") {
            let root = makeFixture("e2e")
            defer { try? fm.removeItem(atPath: root) }
            let sub = root + "/sub"
            try? fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
            makeFile(root + "/a.bin", 4096)
            makeFile(sub + "/b.bin", 2048)

            let historyBefore = HistoryStore.load()
            let undoBefore = UndoManagerStore.load()

            let out = ShredderService.shred(paths: [root])   // 默认 journal：真写历史
            defer {
                HistoryStore.replaceAllForSelftest(historyBefore)
                UndoManagerStore.replaceAllForSelftest(undoBefore)
            }

            guard out.shredded.count == 1,
                  out.shredded[0].fileCount == 2,
                  out.freedBytes > 0 else { return false }
            guard out.rejected.isEmpty, out.failed.isEmpty else {
                print("      意外拒绝/失败：\(out.rejected.map(\.message)) \(out.failed.map(\.message))")
                return false
            }
            guard !exists(root) else { return false }
            guard out.summary.contains("不可恢复") else { return false }

            // 历史落了一条「文件粉碎」，mode 是网关固定文案「彻底删除」
            let after = HistoryStore.load()
            guard after.count == historyBefore.count + 1 else { return false }
            let record = after[0]
            guard record.categoryName == ShredderService.historyCategory,
                  record.mode == "彻底删除",
                  record.itemCount == 1,
                  record.bytes == out.freedBytes,
                  record.failures == 0 else { return false }

            // 不可恢复是本功能的定义：**无撤销快照**
            return UndoManagerStore.load().count == undoBefore.count
        }

        check("端到端：目录内的软链不被跟随、不计数，指向的外部文件存活") {
            let root = makeFixture("e2elink")
            defer { try? fm.removeItem(atPath: root) }
            let external = "/private/tmp/macclean_shred_external_\(UUID().uuidString).bin"
            let original = Data(repeating: 0x11, count: 1024)
            try? original.write(to: URL(fileURLWithPath: external))
            defer { try? fm.removeItem(atPath: external) }

            makeFile(root + "/real.bin", 512)
            try? fm.createSymbolicLink(atPath: root + "/jump.lnk", withDestinationPath: external)

            // 注入缝直接观测枚举：软链不进普通文件清单
            let walk = ShredderService.collectRegularFiles(at: root)
            guard walk.files.count == 1,
                  FileSystem.normalizePath(walk.files[0]) == FileSystem.normalizePath(root + "/real.bin"),
                  !walk.blocked else { return false }

            let out = ShredderService.shred(paths: [root], journal: .none)
            guard out.shredded.count == 1, out.shredded[0].fileCount == 1,
                  out.rejected.isEmpty, out.failed.isEmpty else { return false }
            guard !exists(root) else { return false }
            // 外部目标一个字节都没被动
            return readAll(external) == original && exists(external)
        }

        check("端到端：覆写遍次可观测——3 遍（全 0 → 全随机 → 全 0），每遍写满当前大小") {
            let root = makeFixture("passes")
            defer { try? fm.removeItem(atPath: root) }
            let file = root + "/victim.bin"
            let size = 4096
            makeFile(file, size, fill: 0xAB)

            var observed: [(allZeros: Bool, byteCount: Int)] = []
            ShredderService.passObserver = { path, _ in
                guard path == file, let data = readAll(path) else { return }
                observed.append((data.allSatisfy { $0 == 0 }, data.count))
            }
            defer { ShredderService.passObserver = nil }

            // 直接调覆写缝（不删文件）：覆写后、删除前的内容比对在这里做
            do { try ShredderService.overwriteFile(at: file) } catch {
                print("      覆写抛错：\(error)")
                return false
            }

            // 变异靶：把生产 3 遍改成 2 遍（去随机遍）后，这条序列断言必红
            guard observed.count == ShredderService.overwritePasses.count,
                  observed.count == 3 else { return false }
            guard observed[0].allZeros, !observed[1].allZeros, observed[2].allZeros else {
                print("      遍序内容序列不达标：\(observed.map(\.allZeros))")
                return false
            }
            // 每遍读回的字节数 == 覆写那一刻的文件大小（写多少字节 = 当前大小）
            guard observed.allSatisfy({ $0.byteCount == size }) else { return false }
            // 覆写缝只覆写不删除；最终内容全 0
            return exists(file) && (readAll(file)?.allSatisfy { $0 == 0 } ?? false)
        }

        check("端到端：成功与拒绝同批时拒绝不折成沉默（逐条带原因）") {
            let root = makeFixture("mixed")
            defer { try? fm.removeItem(atPath: root) }
            let real = root + "/real.bin"
            makeFile(real, 256)
            let ghost = root + "/ghost-\(UUID().uuidString).bin"

            let out = ShredderService.shred(paths: [real, ghost], journal: .none)
            guard out.shredded.count == 1, out.shredded[0].path == FileSystem.normalizePath(real) else { return false }
            guard out.rejected.count == 1,
                  out.rejected[0].path == FileSystem.normalizePath(ghost),
                  out.rejected[0].reason == .missing,
                  !out.rejected[0].message.isEmpty else { return false }
            return out.failed.isEmpty && out.summary.contains("被拒绝")
        }

        check("端到端：枚举被权限掐断时该子树不计入成功并逐条上报（读不到 ≠ 干净）") {
            guard geteuid() != 0 else {
                print("      root 环境下 chmod 000 拦不住枚举，本条按环境跳过")
                return true
            }
            let root = makeFixture("denied")
            defer { try? fm.removeItem(atPath: root) }
            let locked = root + "/locked"
            try? fm.createDirectory(atPath: locked, withIntermediateDirectories: true)
            makeFile(root + "/open.bin", 256)
            makeFile(locked + "/hidden.bin", 256)
            try? fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
            defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }

            // 注入缝：枚举器直接可断言 blocked 且被掐断的子树不在清单里
            let walk = ShredderService.collectRegularFiles(at: root)
            guard walk.blocked else { return false }
            guard walk.files.count == 1,
                  walk.files[0].hasSuffix("/open.bin") else { return false }

            let original = readAll(root + "/open.bin")
            let out = ShredderService.shred(paths: [root], journal: .none)
            // 该点名路径不计入成功、不覆写、不删除，逐条上报
            guard out.shredded.isEmpty, out.rejected.isEmpty, out.failed.count == 1,
                  out.failed[0].message.contains("枚举不完整"),
                  out.failed[0].path == FileSystem.normalizePath(root) else {
                print("      掐断分支结果不达标：\(out.summary)")
                return false
            }
            return exists(root) && exists(root + "/open.bin") && readAll(root + "/open.bin") == original
        }

        // MARK: 页面模型（列表态在外部对象上，可不经渲染直接测）

        check("页面模型：添加/去重/移除/不存在路径反馈，列表态读得回") {
            let root = makeFixture("model")
            defer { try? fm.removeItem(atPath: root) }
            let file = root + "/a.bin"
            makeFile(file, 1024)

            let model = ShredderModel()
            guard model.add(path: file) else { return false }
            guard model.entries.count == 1,
                  model.entries[0].path == FileSystem.normalizePath(file),
                  model.entries[0].kind == .file,
                  model.entries[0].size == 1024,
                  model.entries[0].sizeText != nil else { return false }

            // 重复添加拒绝
            guard !model.add(path: file), model.entries.count == 1 else { return false }
            // 不存在的路径拒绝且给反馈
            guard !model.add(path: root + "/nope.bin"),
                  model.entries.count == 1,
                  model.inputError?.isEmpty == false else { return false }
            // 目录条目：类型与大小口径
            guard model.add(path: root), model.entries.count == 2,
                  model.entries[1].kind == .directory else { return false }
            // 移除
            model.remove(model.entries[0].id)
            return model.entries.count == 1 && model.entries[0].kind == .directory
        }
    }
}
