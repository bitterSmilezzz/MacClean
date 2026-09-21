import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：扫描完整度与测量缓存
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 2337–2394）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteScanDiagnostics() {
        // MARK: - 扫描完整度（"读不到" ≠ "很干净"）

        check("扫描诊断：权限不足的目录被判为「读不到」而不是「空」") {
            // 这是整个诊断层的前提。历史缺陷：扫描链路里没有任何一处区分这两者，
            // 缺「完全磁盘访问权限」时废纸篓稳定返回 0 项，界面上和"空"一模一样。
            let dir = "/private/tmp/macclean-permprobe-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: dir + "/inside.bin", contents: Data(repeating: 1, count: 1024))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
                try? FileManager.default.removeItem(atPath: dir)
            }
            // 内容存在但不可读
            // 先确认内容真的在那里（chmod 之后就再也看不到它了）
            let hadContent = FileManager.default.fileExists(atPath: dir + "/inside.bin")
                && !(FileSystem.children(of: dir).isEmpty)
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir)
            let nowUnreadable = FileSystem.isPermissionDenied(dir)
            // 关键对比：目录里确实有东西，但现在读不到、也列不出来 ——
            // 只看 `children` 的返回值会得到"0 项"，这正是"读不到"骗成"很干净"的机制。
            let looksEmpty = FileSystem.children(of: dir).isEmpty
            return hadContent && nowUnreadable && looksEmpty
        }

        check("测量缓存：清理后路径与其父目录都不会给出过期体积") {
            // 缓存的前提是"一次扫描会话内体积不变"，而清理恰好会打破这个前提。
            // 只失效被删路径本身是不够的：删掉 dir/a.bin 之后 dir 自己的体积也变了，
            // 若父目录还留着旧值，重新扫描就会报出已经释放掉的字节。
            let dir = "/private/tmp/macclean-measure-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let file = dir + "/a.bin"
            FileManager.default.createFile(atPath: file, contents: Data(repeating: 0, count: 200_000))
            defer { try? FileManager.default.removeItem(atPath: dir) }

            FileSystem.beginMeasurementSession()
            let before = FileSystem.size(at: dir)
            guard before > 0 else { return false }

            let item = CleanItem(name: "a.bin", path: file, size: 200_000,
                                 rule: "C1", category: .userCaches)
            _ = Cleaner.clean([item], permanently: true) { _ in }

            // 父目录必须反映"已经空了"，而不是缓存里的旧体积
            return FileSystem.size(at: dir) < before
        }

        check("测量缓存：新一轮扫描会话会清空上一轮的结果") {
            let dir = "/private/tmp/macclean-session-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            FileSystem.beginMeasurementSession()
            FileManager.default.createFile(atPath: dir + "/x.bin", contents: Data(repeating: 0, count: 50_000))
            let withFile = FileSystem.size(at: dir)
            try? FileManager.default.removeItem(atPath: dir + "/x.bin")
            FileSystem.beginMeasurementSession()   // 新会话
            return withFile > 0 && FileSystem.size(at: dir) == 0
        }

    }
}
