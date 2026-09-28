import Foundation

// MARK: - Mail 附件清理 (v1.73.15，对标 CleanMyMac「Mail Attachments」)
//
// 两个根（都是 TCC 保护位，无完全磁盘访问权限时**读不到**——G9/G13 语义）：
// - `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads`：打开邮件附件时的本地缓存；
// - `~/Library/Mail`：Mail 本体库，递归收集名为 `Attachments` 的目录（各账户/邮箱的附件存储）。
//
// **结论档位**：附件是用户数据本体，「体积大 / 年代久」不构成"是垃圾"（规则 v2 D-3 的分流
// 原则：带勾选框的页面本身是一种承诺）——所有条目一律「需确认」、**零默认勾选**、
// 不设「全选可清理」档。删除默认移废纸篓可撤销，走统一删除网关（G14）；
// 「邮件若仍在服务器，附件可重新下载」是唯一合理的删除理由，必须由用户逐条勾选确认。
enum MailAttachmentsScanner {

    struct AttachmentItem: Identifiable, Equatable {
        let id: String          // 路径
        let name: String
        let path: String
        let size: Int64
        let modifiedAt: Date?
        /// 收集这条附件的遍历被权限掐断过 → 体积是下限（v1.73.7 四侧契约）
        let readable: Bool
        /// 零默认勾选是安全策略：调用方删掉显式实参也不许无声走 true
        var isSelected: Bool = false
    }

    struct Summary: Equatable {
        var items: [AttachmentItem] = []
        /// 读不到的根（TCC）——界面必须明示 + 授权引导，不许渲染成"这里没有附件"
        var unreadableRoots: [String] = []
        /// 本轮没顾上读的根（在途额度等）——与"读不到"分开说
        var deferredRoots: [String] = []
        var scannedRoots: [String] = []
        var attachmentDirsFound = 0
        var issues: [String] = []
        var isResultComplete: Bool { issues.isEmpty }
        var totalSize: Int64 { items.reduce(Int64(0)) { $0 + $1.size } }
        var selectedCount: Int { items.filter(\.isSelected).count }
        var selectedSize: Int64 { items.filter(\.isSelected).reduce(Int64(0)) { $0 + $1.size } }
    }

    /// 一个附件根。`collectsRootFiles` 是**结构性的**：Mail Downloads 根下直接是附件文件，
    /// `~/Library/Mail` 根下只收名为 `Attachments` 的目录——判据由调用方声明，不靠路径
    /// 后缀字符串猜（v1.73.15 自检教训：夹具根不叫 "Mail Downloads" 时后缀判断整个落空）。
    struct MailRoot: Equatable {
        let path: String
        let collectsRootFiles: Bool
    }

    /// 自检注入缝：自检**永不**碰真实 Mail 目录。
    static var rootsOverride: [MailRoot]? = nil

    static var defaultRoots: [MailRoot] {
        let home = NSHomeDirectory()
        return [
            MailRoot(path: (home as NSString).appendingPathComponent("Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
                     collectsRootFiles: true),
            MailRoot(path: (home as NSString).appendingPathComponent("Library/Mail"),
                     collectsRootFiles: false),
        ]
    }

    /// Mail 本体库里承载附件的目录名（各账户/邮箱下的固定结构标记，非安全护栏）
    static let attachmentsDirName = "Attachments"

    /// 清理历史的类目名
    static let historyCategory = "邮件附件"

    // MARK: 扫描（只读）

    static func scan() -> Summary {
        var summary = Summary()
        for root in rootsOverride ?? defaultRoots {
            let norm = FileSystem.normalizePath(root.path)
            summary.scannedRoots.append(norm)
            switch FileSystem.probeDirectory(norm) {
            case .unreadable:
                summary.unreadableRoots.append(norm)
                summary.issues.append("邮件附件根读不到（需要完全磁盘访问权限）：\(norm)")
            case .deferred:
                // G9：「本轮没去试」≠「读不到」≠「空」，三种话不能混
                summary.deferredRoots.append(norm)
                summary.issues.append("邮件附件根本轮没能读取（请稍后重扫）：\(norm)")
            case .readable:
                collect(in: norm, collectsRootFiles: root.collectsRootFiles, into: &summary)
            }
        }
        summary.items.sort { $0.size > $1.size }
        return summary
    }

    /// 收集一个可读根下的附件文件。Mail Downloads 根下直接是文件；`~/Library/Mail` 根下
    /// 要先找到名为 `Attachments` 的目录再收它里面的文件——统一走一条遍历：
    /// `enumerator` **必须带 errorHandler 并 recordDeniedAccess**（全仓 lint 盯着）。
    private static func collect(in root: String, collectsRootFiles: Bool, into summary: inout Summary) {
        let fm = FileManager.default
        let blocked = FileSystem.WalkBlockFlag()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey]
        guard let en = fm.enumerator(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                FileSystem.recordDeniedAccess(url, error: error)
                blocked.set()
                return true
            }
        ) else {
            // 枚举器建不起来：先过 `isPermissionDenied` 预筛、命中才用 EACCES 形状记账
            // （`recordDeniedAccess` 吞自造 domain 的 error，v1.73.7 P1-A 的教训）。
            if FileSystem.isPermissionDenied(root) {
                FileSystem.recordDeniedAccess(
                    URL(fileURLWithPath: root, isDirectory: true),
                    error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                                   userInfo: [NSFilePathErrorKey: root]))
            }
            summary.unreadableRoots.append(root)
            summary.issues.append("邮件附件根读不到：\(root)")
            return
        }
        let isMailDownloads = collectsRootFiles
        var pendingAttachmentsDirs: [String] = []
        var appended: Set<String> = []
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if url.lastPathComponent == attachmentsDirName {
                    pendingAttachmentsDirs.append(url.path)
                }
                continue
            }
            if isMailDownloads {
                appendItem(at: url.path, appended: &appended, blocked: blocked, into: &summary)
            }
        }
        for dir in pendingAttachmentsDirs {
            summary.attachmentDirsFound += 1
            for f in filesUnder(dir, blocked: blocked) {
                appendItem(at: f, appended: &appended, blocked: blocked, into: &summary)
            }
        }
        if blocked.value {
            summary.issues.append("根下有子项本轮读不到，结果不完整：\(root)")
        }
    }

    /// 收集一个 `Attachments` 目录下的普通文件（软链不计——删软链释放 0 字节）。
    /// blocked 用**外层共享的标记**：内层被掐断时外层根的"结果不完整"一样要翻。
    private static func filesUnder(_ dir: String, blocked: FileSystem.WalkBlockFlag) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: URL(fileURLWithPath: dir, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { url, error in
                FileSystem.recordDeniedAccess(url, error: error)
                blocked.set()
                return true
            }
        ) else {
            if FileSystem.isPermissionDenied(dir) {
                FileSystem.recordDeniedAccess(
                    URL(fileURLWithPath: dir, isDirectory: true),
                    error: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES),
                                   userInfo: [NSFilePathErrorKey: dir]))
            }
            blocked.set()
            return []
        }
        var files: [String] = []
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { continue }
            if v?.isRegularFile == true { files.append(url.path) }
        }
        return files
    }

    /// 单文件体积/时间用共享入口的**非目录分支**（一次 lstat）；不写第二份求体积 walker。
    /// `appended` 按路径去重（复审 P2-1）：Mail Downloads 根下的 `Attachments` 子目录会被
    /// 「根文件直收」与「Attachments 目录收集」两条通道各枚举一次，不去重就是体积双计。
    private static func appendItem(at path: String, appended: inout Set<String>,
                                   blocked: FileSystem.WalkBlockFlag,
                                   into summary: inout Summary) {
        let norm = FileSystem.normalizePath(path)
        guard appended.insert(norm).inserted else { return }
        let stats = FileSystem.directoryStats(at: path)
        summary.items.append(AttachmentItem(
            id: path,
            name: (path as NSString).lastPathComponent,
            path: path,
            size: stats.size,
            modifiedAt: stats.newestModification,
            readable: stats.readable && !blocked.value
        ))
    }

    // MARK: 清理（用户逐条点选；默认移废纸篓可撤销）

    @discardableResult
    static func clean(items: [AttachmentItem], toTrash: Bool = true,
                      journal: ResidueDeletionGate.Journal = .module(categoryName: historyCategory)) -> ResidueDeletionGate.Outcome {
        // 防夹带（复审 P2-2）：**clean 时刻**按当前根重推合法路径集——拼装 `AttachmentItem`
        // 塞进任意主目录路径的调用方在这里被拦下，不靠格子自带 provenance 的自觉。
        // 网关护栏照样兜底（domain nil 走主目录判据），这一层是把"没去删"如实带回来。
        let legitRoots = (rootsOverride ?? defaultRoots).map { FileSystem.normalizePath($0.path) }
        var candidates: [ResidueDeletionGate.Candidate] = []
        var smuggled: [ResidueDeletionGate.Rejection] = []
        for item in items {
            let norm = FileSystem.normalizePath(item.path)
            let inside = legitRoots.contains { norm == $0 || norm.hasPrefix($0 + "/") }
            if inside {
                candidates.append(ResidueDeletionGate.Candidate(item.name, path: item.path, domain: nil))
            } else {
                smuggled.append(.make(name: item.name, path: item.path, reason: .outsideDomain,
                                      message: "该路径不在本轮扫描的邮件附件根内，拒绝清理"))
            }
        }
        // journal 的默认值是 `.module(categoryName:)`：不传参走的就是它（网关便捷重载的
        // 裸默认是通用「治理清理」，会把模块名抹掉）；自检不显式传 journal——
        // 「默认值即安全策略」的参数，断言一律依赖默认值，否则测的是自己喂的实参。
        let result = ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal)
        return ResidueDeletionGate.Outcome(rejected: smuggled).merging(result)
    }
}
