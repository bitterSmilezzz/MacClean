import Foundation

// MARK: - 应用自身状态的落点（v1.72.0）
//
// 历史记录与撤销快照此前在 `History.swift` 与 `UndoSnapshot.swift` 里各拼一遍
// `~/Library/Application Support/MacClean`。两处逻辑相同却各自实现，导致
// "把自检写盘操作隔离出去"这件事没有统一开关——自检跑一次就会往用户真实的
// `history.json` / `undo_sessions.json` 里插条目，多进程并发跑还会互相覆盖。
//
// `MACCLEAN_STATE_DIR` 就是这个开关：设置后所有应用自身状态都落到该目录，
// 自检与 CI 可以整轮跑完而不碰用户真实数据。

enum MacCleanState {
    /// 状态目录。设置了 `MACCLEAN_STATE_DIR` 时用之，否则用 Application Support。
    static var stateDirectory: URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["MACCLEAN_STATE_DIR"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath,
                          isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacClean", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 是否处于隔离状态（自检/CI）
    static var isIsolated: Bool {
        ProcessInfo.processInfo.environment["MACCLEAN_STATE_DIR"].map { !$0.isEmpty } ?? false
    }
}
