import Foundation
import Darwin
import Security

// MARK: - 文件粉碎器（v1.73.14 · 补齐 CleanMyMac X / CCleaner 的 Shredder 主流标配）
//
// 语义与边界（与 docs/research/mainstream-parity.md §2 第 1 条对齐）：
// · 只对用户**逐条点名**的路径生效（工具页手动添加 / 清理项右键「粉碎…」）。
//   扫描结果永远不会默认勾选粉碎——带勾选框的清理页本身就是一种承诺，
//   而"不可恢复"必须由用户逐条、逐批亲手确认。
// · 每条路径**先过护栏裁决、再写任何字节**：判据与统一删除网关内部完全同一套
//   （软链防跳板 → G8 系统硬保护 → G6 用户数据硬排除 → 用户自定义白名单 →
//   治理域 / 主目录），直接调 `governanceVerdict*`，不抄第二份清单。
//   任何字节写出之前，路径必须已被裁决允许。
// · **软链一律拒绝跟随**（拒绝文案明示"要粉碎目标，请直接点名目标文件本身"）。
//   这是最诚实且防跳板的语义：覆写软链等于覆写它指向的别人家的文件，
//   而网关对软链的删除判定同样是"末段是软链即拒"。
// · 多遍覆写只针对 `S_IFREG` 普通文件：目录先递归枚举收集普通文件（软链不跟随、
//   不计入），每文件 3 遍（全 0 → 全随机 → 全 0），每遍后 `fsync`；
//   写多少字节 = 该文件**覆写那一刻**的大小。任一遍失败立即停，
//   如实报「文件内容已被部分覆写，可能已损坏但可能仍占空间」，且该路径不再删除。
// · **枚举被权限掐断 ≠ 干净**：目录枚举带 `errorHandler` 并 `recordDeniedAccess`，
//   一旦不完整，该子树不计入成功、不覆写、不删除，逐条上报。
//
// ## APFS / SSD 诚实声明（本注释与 UI 确认弹窗同文）
//
// 在**写时复制**卷（APFS）上，多遍覆写不提供"数据已不可恢复"的额外保证：
// 覆写可能被 CoW 写到新块（旧块经快照/垃圾回收延迟释放），SSD 的 FTL 也可能
// 把写入落到别的物理页。3 遍（全 0 → 全随机 → 全 0）是业界惯例档位，
// **不是"军方级安全"**——本功能不宣称任何超出"尽力覆写"的保证。
// 用户得到的不可恢复性主要来自随后经由统一删除网关的 unlink：文件没了。

enum ShredderService {

    /// 清理历史类名（`ResidueDeletionGate.Journal.module(categoryName:)`）。
    /// 网关对彻底删除落的历史 `mode` 是其内部固定的「彻底删除」文案（本模块
    /// 无权指定 mode 文案），因此「不可恢复」这层语义由结果摘要与本模块注释补齐。
    static let historyCategory = "文件粉碎"

    /// APFS / SSD 诚实声明（UI 确认弹窗直接引用，保持与实现注释同源）。
    static let apfsDisclosure =
        "在 APFS 等写时复制卷和 SSD 上，多遍覆写不提供额外保证；3 遍（全 0 → 全随机 → 全 0）"
        + "是业界惯例，不是「军方级安全」。粉碎后的文件不可恢复、没有撤销快照。"

    // MARK: 自检注入缝（QuickLookThumbnailPurger.qlmanagePath 风格）

    /// 覆写遍次计划。**生产定义是 3 遍**；自检用它做"遍数被改"的变异靶，
    /// 也可替换后演练特定遍序（生产代码不许赋值）。
    static var overwritePasses: [OverwritePass] = [.zeroFilled, .random, .zeroFilled]

    /// 每遍写完（fsync 之后）的观测回调 `(文件路径, 遍序号)`。
    /// 生产为 nil。自检在回调里读回文件内容，实现「覆写后、删除前」的内容比对
    /// ——这是"3 遍里真的有一遍是随机"的唯一可证伪观测点。
    static var passObserver: ((_ path: String, _ passIndex: Int) -> Void)?

    enum OverwritePass: Equatable {
        /// 全 0
        case zeroFilled
        /// 全随机（`SecRandomCopyBytes`；系统拒绝时回落 `SystemRandomNumberGenerator`）
        case random
    }

    // MARK: - 结果

    struct ShredEntry: Equatable {
        let name: String
        let path: String
        /// 实际覆写过的普通文件数（目录含其子树；软链与目录本身不计）
        let fileCount: Int
    }

    struct FailedEntry: Equatable {
        let name: String
        let path: String
        let message: String
    }

    struct Outcome {
        var shredded: [ShredEntry] = []
        /// 覆写之前的裁决拒绝 + 网关删除阶段的拒绝。拒绝不许折成沉默。
        var rejected: [ResidueDeletionGate.Rejection] = []
        var failed: [FailedEntry] = []
        /// 释放量取**网关删除前实测**的体积（与本仓所有治理模块同一口径）
        var freedBytes: Int64 = 0

        /// 一句可直接放进结果摘要的结论。
        /// 历史记录的 mode 文案是网关内部固定的「彻底删除」，这里必须把
        /// 「已粉碎，不可恢复」这层语义补在摘要里。
        var summary: String {
            var parts: [String] = []
            if !shredded.isEmpty {
                parts.append("已粉碎 \(shredded.count) 项 / \(freedBytes.byteStringCN)，已粉碎不可恢复、无撤销快照")
            }
            if !rejected.isEmpty {
                parts.append("\(rejected.count) 项被拒绝")
            }
            if !failed.isEmpty {
                parts.append("\(failed.count) 项失败")
            }
            return parts.isEmpty ? "没有可粉碎的项目" : parts.joined(separator: "；")
        }
    }

    // MARK: - 入口

    /// 对用户逐条点名的路径逐条处理：裁决 → 覆写 → 网关删除。
    /// 顺序保持用户点名的顺序；每条路径独立裁决，拒绝/失败不影响其余路径。
    /// - Parameter journal: 历史写入策略。**不写撤销快照**（不可恢复是本功能的定义，
    ///   网关只在 `toTrash: true` 时落 Undo 快照）；自检传 `.none` 避免污染历史。
    @discardableResult
    static func shred(paths: [String],
                      journal: ResidueDeletionGate.Journal = .module(categoryName: historyCategory)) -> Outcome {
        var out = Outcome()
        for raw in paths {
            shredOne(raw, into: &out, journal: journal)
        }
        return out
    }

    private static func shredOne(_ raw: String, into out: inout Outcome,
                                 journal: ResidueDeletionGate.Journal) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            out.rejected.append(.make(name: "", path: raw, reason: .emptyPath))
            return
        }
        let normalized = FileSystem.normalizePath(trimmed)
        let displayName = (normalized as NSString).lastPathComponent

        // ① 软链拒绝跟随——专属文案，放在最前面（防跳板 + 最诚实的语义）。
        //    用户想粉碎的是软链指向的目标时，请点名目标文件本身。
        if FileSystem.isSymlink(normalized) {
            out.rejected.append(.make(
                name: displayName, path: normalized, reason: .symlinkJump,
                message: "拒绝跟随符号链接：它可能指向任何位置。要粉碎目标，请直接点名目标文件本身"))
            return
        }

        // ② 覆写前的护栏裁决——与网关同一套判据（复用 `governanceVerdict*`，
        //    不抄第二份清单）。任何字节写出之前必须被裁决允许。
        let domain = GovernanceDomain.domain(forPath: normalized)
        let verdict: GovernanceVerdict = domain.map {
            FileSystem.governanceVerdict(normalized, domain: $0)
        } ?? FileSystem.governanceVerdictWithinHome(normalized)
        guard case .allowed = verdict else {
            let reason: GovernanceVerdict.Reason
            if case .rejected(let r) = verdict { reason = r } else { reason = .blockedByBaseGate }
            out.rejected.append(.make(name: displayName, path: normalized,
                                      reason: reason, message: verdict.message))
            return
        }

        // ③ 收集普通文件。枚举被权限掐断 → 子树不计入成功，不覆写、不删除，逐条上报。
        let walk = collectRegularFiles(at: normalized)
        guard walk.shreddable else {
            out.rejected.append(.make(
                name: displayName, path: normalized, reason: .notDeletable,
                message: "不是普通文件或目录（可能是正在使用的管道、套接字等），粉碎器不处理"))
            return
        }
        guard !walk.blocked else {
            out.failed.append(FailedEntry(
                name: displayName, path: normalized,
                message: "目录枚举不完整（部分内容因权限读不到）。「读不到」不等于「干净」："
                    + "为免谎报已粉碎，该目录未覆写、未删除任何文件"))
            return
        }

        // ④ 多遍覆写。任一文件失败 → 立即停（该路径后续文件不再覆写），如实上报，
        //    且该路径**不进入删除**——已覆写的文件保持"已损坏但仍在"的状态。
        var overwritten = 0
        for file in walk.files {
            do {
                try overwriteFile(at: file)
                overwritten += 1
            } catch {
                out.failed.append(FailedEntry(
                    name: displayName, path: file,
                    message: "覆写失败，已停止对该路径的操作：文件内容已被部分覆写，"
                        + "可能已损坏但可能仍占空间（\(error.localizedDescription)）"
                        + (overwritten > 0 ? "。此前已覆写 \(overwritten) 个文件" : "")))
                return
            }
        }

        // ⑤ 最终删除走统一删除网关：受护栏 unlink + 删除前实测体积 + 历史记账
        //    （journal 默认写一条 categoryName=「文件粉碎」的历史；toTrash=false
        //    故无撤销快照）。policy 双保险：只有本轮覆写完成的路径才允许删除。
        let gateOutcome = ResidueDeletionGate.execute(
            [ResidueDeletionGate.Candidate(displayName, path: normalized, domain: domain)],
            toTrash: false,
            journal: journal,
            policy: { candidate in
                guard FileSystem.normalizePath(candidate.path) == normalized else {
                    return .make(candidate, reason: .blockedByBaseGate,
                                 message: "路径不在本轮覆写完成名单里，拒绝删除")
                }
                return nil
            })

        if gateOutcome.cleanedCount > 0 {
            out.shredded.append(ShredEntry(name: displayName, path: normalized,
                                           fileCount: overwritten))
            out.freedBytes += gateOutcome.freedBytes
        }
        out.rejected.append(contentsOf: gateOutcome.rejected)
        out.failed.append(contentsOf: gateOutcome.failed.map {
            FailedEntry(name: $0.name, path: $0.path, message: $0.message)
        })
    }

    // MARK: - 枚举（自检可对临时夹具直接调用本函数）

    /// 递归收集**普通文件**（`S_IFREG`）。软链不跟随也不计入；目录本身不计入。
    /// - Returns:
    ///   · `files`：收集到的普通文件；
    ///   · `blocked`：枚举被权限掐断过 → `files` **不完整**，调用方不得据此行动；
    ///   · `shreddable`：false = 目标既不是普通文件也不是目录（socket/FIFO/设备）。
    static func collectRegularFiles(at path: String) -> (files: [String], blocked: Bool, shreddable: Bool) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            // 存在性已由裁决验过；这里读不到一律按"不完整"处理，绝不按"干净"处理
            return ([], true, true)
        }
        let type = st.st_mode & S_IFMT
        if type == S_IFREG { return ([path], false, true) }
        guard type == S_IFDIR else { return ([], false, false) }

        var files: [String] = []
        let blocked = FileSystem.WalkBlockFlag()
        // errorHandler 必须带：Foundation 的默认语义是第一个错误就**静默**停止遍历，
        // "只读到一半"和"就这么大"会给出同一个清单。这里留痕（盲区记账 + blocked 标记）
        // 并继续走完能走的部分，由调用方对 blocked 清单拒绝行动。
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { url, error in
                FileSystem.recordDeniedAccess(url, error: error)
                blocked.set()
                return true
            }
        ) else {
            // 枚举器建不起来：与 `directoryStats` 同一处理——无条件记账（一手失败证据；
            // `isPermissionDenied` 在"在途额度满、根本没去 open"时会漏报）
            FileSystem.recordDeniedAccess(
                URL(fileURLWithPath: path, isDirectory: true),
                error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                               userInfo: [NSFilePathErrorKey: path]))
            return ([], true, true)
        }
        for case let url as URL in enumerator {
            var est = stat()
            guard lstat(url.path, &est) == 0 else {
                // 枚举报得出、lstat 读不到：清单不完整，如实标记
                blocked.set()
                continue
            }
            let entryType = est.st_mode & S_IFMT
            if entryType == S_IFLNK { continue }          // 软链：不跟随、不计入
            if entryType == S_IFREG { files.append(url.path) }
        }
        return (files, blocked.value, true)
    }

    // MARK: - 覆写（自检可对临时夹具直接调用本函数）

    /// 单次覆写的字节块大小
    static let chunkSize = 1 << 20

    /// 把文件就地覆写 `overwritePasses` 遍：每遍从偏移 0 写满**当前文件大小**，每遍结束 `fsync`。
    /// - `O_WRONLY | O_NOFOLLOW` 打开：裁决之后文件若被换成软链，`open` 以 ELOOP 失败，
    ///   而不是顺着新软链去踩别人家的文件。
    /// - 任一遍失败立即抛出。调用方必须把该文件按「可能已损坏」如实上报，且不得再删除它。
    static func overwriteFile(at path: String) throws {
        let fd = open(path, O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError(errno, "打开文件失败") }
        defer { close(fd) }

        var st = stat()
        guard fstat(fd, &st) == 0 else { throw posixError(errno, "读取文件大小失败") }
        let size = Int64(st.st_size)          // 写多少字节 = 该文件当前大小

        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: chunkSize, alignment: MemoryLayout<UInt8>.alignment)
        defer { buffer.deallocate() }

        for (index, pass) in overwritePasses.enumerated() {
            guard lseek(fd, 0, SEEK_SET) >= 0 else { throw posixError(errno, "定位到文件头失败") }
            var written: Int64 = 0
            while written < size {
                let want = Int(min(Int64(chunkSize), size - written))
                fill(pass, into: buffer.baseAddress!, count: want)
                var done = 0
                while done < want {
                    let n = write(fd, buffer.baseAddress! + done, want - done)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw posixError(errno, "覆写写入失败")
                    }
                    done += n
                }
                written += Int64(done)
            }
            guard fsync(fd) == 0 else { throw posixError(errno, "fsync 失败") }
            passObserver?(path, index)
        }
    }

    private static func fill(_ pass: OverwritePass, into buf: UnsafeMutableRawPointer, count: Int) {
        switch pass {
        case .zeroFilled:
            memset(buf, 0, count)
        case .random:
            if SecRandomCopyBytes(kSecRandomDefault, count, buf) == errSecSuccess { return }
            var gen = SystemRandomNumberGenerator()
            var offset = 0
            while offset < count {
                var value = UInt64.random(in: .min ... .max, using: &gen)
                let n = min(8, count - offset)
                memcpy(buf + offset, &value, n)
                offset += n
            }
        }
    }

    private static func posixError(_ code: Int32, _ what: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "\(what)（errno \(code)：\(String(cString: strerror(code)))）"])
    }
}
