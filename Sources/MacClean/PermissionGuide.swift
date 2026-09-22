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

    static var hasFullDiskAccess: Bool { FileSystem.hasFullDiskAccess() }

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
