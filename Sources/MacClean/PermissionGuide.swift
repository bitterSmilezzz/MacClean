import AppKit

/// 「读不到」要说清楚，还要给得出下一步。
///
/// 规则 v2 步骤 6（owner 决策 D-2「申请完全磁盘访问权限，分权限口径」）。
/// 在此之前扫描链路已经能产出 `ScanIssue`，但补救建议是一句写死的
/// "在系统设置里勾选 MacClean"——问题是这句话在两种情况下**含义相反**：
/// ① 还没授权 FDA：照做就能解决；
/// ② 已经授权 FDA 仍读不到：那是别的 App 的沙盒或需要 root，照做只会反复授权反复失败。
/// 把两种情况写成同一句话，用户得到的不是指引而是误导，所以措辞必须按权限口径分开。
enum PermissionGuide {

    /// 系统设置 → 隐私与安全性 → 完全磁盘访问权限
    static let settingsURLString =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// 自检用的探针覆盖。`nil` = 用真实探针。
    ///
    /// 与 `AIService.networkDisabled` 同一套路：让"缺权限"这条分支能被**真正走到**，
    /// 而不是只能靠人工去系统设置里拔掉授权来验。生产路径永远是 nil。
    static var fdaProbeOverride: Bool?

    static var hasFullDiskAccess: Bool {
        fdaProbeOverride ?? FileSystem.hasFullDiskAccess()
    }

    // MARK: - 扫描前的权限门

    /// 扫描前是否该先把用户拦下来要权限。
    enum ScanGate: Equatable {
        /// 不缺权限（或用户已经明确选择过"仍然扫描"），直接扫。
        case proceed
        /// 缺「完全磁盘访问权限」且本会话还没被告知过 → 先弹提示。
        case needsFullDiskAccess
    }

    /// **唯一**的权限门决策入口。
    ///
    /// 抽成纯函数（不碰真实探针、不碰 UI）的理由：这条判据要能被穷举，
    /// 而它最容易出的错是"把无人值守那一路也拦下来"——那会让定时扫描
    /// 弹出没人应答的模态框、把整轮扫描永久挂住（`AppState.scanAll` 的
    /// `unattended` 参数与 `AutoCleanService` 都是为这件事存在的）。
    ///
    /// - Parameters:
    ///   - unattended: 无人值守的一轮（`DiskMonitor` 定时触发 / 后台自愈）。**永不拦截。**
    ///   - hasFullDiskAccess: 当前是否已有 FDA。
    ///   - acknowledgedWithoutFDA: 用户在本会话里是否已经明确选过"仍然扫描"。
    ///     只在内存里，不落盘：下次启动该再问一次——权限是这次的事，
    ///     "上次我说了不算"不该成为永久静音。
    static func scanGate(unattended: Bool,
                         hasFullDiskAccess: Bool,
                         acknowledgedWithoutFDA: Bool) -> ScanGate {
        if unattended { return .proceed }
        if hasFullDiskAccess { return .proceed }
        if acknowledgedWithoutFDA { return .proceed }
        return .needsFullDiskAccess
    }

    /// 提示标题与正文。措辞与 `remedy` 保持同一口径：缺 FDA 是**能靠授权解决**的那一类。
    static let gateTitle = "MacClean 还没有「完全磁盘访问权限」"

    static var gateMessage: String {
        """
        没有这项授权时，扫描不会报错——它会**安静地少看到一批位置**，\
        而界面上看起来和"这里本来就没东西"一模一样。典型读不到的包括\
        浏览器数据、邮件与信息、其他 App 的沙盒容器、系统诊断报告。

        授权后回来点「扫描」即可；下面的「仍然扫描」会照常扫一遍，\
        扫完会如实列出哪些位置因权限没能读到。
        """
    }

    /// 打开系统设置的对应面板。返回 false 表示这个 macOS 版本没有该 URL scheme，
    /// 调用方要退回到"告诉你去哪儿"而不是静默失败。
    @discardableResult
    static func openSettings() -> Bool {
        guard let url = URL(string: settingsURLString) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// 家目录写成 `~`，并把过长的容器路径收成看得懂的那一段。
    /// 直接取 `lastPathComponent` 会得到 "Caches" 这种毫无信息量的词。
    static func label(_ path: String) -> String {
        let home = NSHomeDirectory()
        var rel = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        if rel.count > 58, let range = rel.range(of: "/Library/", options: .backwards) {
            rel = "~…" + rel[range.lowerBound...]
        }
        return rel
    }

    static func message(path: String) -> String {
        "\(label(path)) 读不到（权限不足）：其中的内容没有计入本次结果——这里是「没看到」，不是「没有东西」"
    }

    /// 补救建议。`needsFDA` 由调用方给出，自检要能两个分支都跑到。
    static func remedy(path: String, needsFDA: Bool) -> String {
        needsFDA
            ? "MacClean 还没有「完全磁盘访问权限」。在系统设置 → 隐私与安全性 → 完全磁盘访问权限里勾选 MacClean，回来点「重新扫描」才会看到 \(label(path))"
            : "已有完全磁盘访问权限仍读不到 \(label(path))：它属于其他 App 的沙盒或需要管理员权限，本工具不会代你提权"
    }
}
