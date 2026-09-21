import Foundation
import Darwin

// MARK: - 受控子进程执行器（v1.72.0）
//
// 治理模块会调用 `qlmanage` / `mdutil` / `atsutil` / `launchctl` / `killall` 等外部命令
// 让系统立即生效。此前 11 个模块各写一份 `Process`，其中多数带着两个真实故障：
//
// ① **管道死锁**：先 `waitUntilExit()` 再 `readDataToEndOfFile()`。macOS 管道缓冲仅约
//    64 KB，子进程写满即阻塞在 `write`，父进程阻塞在 `wait`，谁也不前进。
//    `launchctl list` 在装了 CI runner 的机器上轻易超过 64 KB。
// ② **无超时**：子进程挂死时整轮扫描一起挂死，UI 表现为"永远在转圈"。
// ③ **未启动就 wait**：`try? p.run()` 失败后仍调 `waitUntilExit()`，
//    在从未启动的 Process 上调用会直接抛异常崩溃（`QuickLookThumbnailPurger`、
//    `LoginItemCleaner` 均是这个形状）。
//
// 本文件把 `RiskScanner.runCommand` 已验证正确的实现提为公共入口，并留出
// `runner` 注入点——自检从此可以断言"调的是哪个命令、带哪些参数"，
// 而不必真的去动系统状态。

enum SafeProcess {

    struct Result: Equatable {
        let exitCode: Int32
        let output: String
        var timedOut: Bool = false

        var succeeded: Bool { exitCode == 0 && !timedOut }
    }

    /// 自检注入点：非 nil 时完全不启真实进程，返回该闭包的结果。
    /// 生产路径永远为 nil。
    static var runner: ((String, [String], TimeInterval) -> Result?)?

    /// 可被拦截的命令记录，供自检断言"调的是哪个可执行文件、带哪些参数"。
    ///
    /// **只在自检/CI（`MACCLEAN_STATE_DIR` 已设）下累积**：生产路径里 GUI 会反复调
    /// `mdutil`/`launchctl`/`qlmanage`，`--autoclean` 更是常驻进程，无条件 append 会变成
    /// 只增不减的数组，而且里面存着用户的完整路径。测试上下文才需要这份痕迹。
    private(set) static var invokedCommands: [(path: String, args: [String])] = []
    static func resetInvokedCommands() { invokedCommands.removeAll() }

    private static var isRecording: Bool { MacCleanState.isIsolated }

    /// 运行命令并捕获 stdout+stderr。永不抛异常、永不无限等待。
    static func run(_ launchPath: String, _ arguments: [String] = [],
                    timeout: TimeInterval = 10) -> Result? {
        if isRecording { invokedCommands.append((launchPath, arguments)) }
        if let injected = runner { return injected(launchPath, arguments, timeout) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        // 读端先挂上后台开始排空，再启动进程（见 ① 管道死锁）
        var captured = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            captured = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }

        do {
            try p.run()
        } catch {
            // 启动失败：关掉写端让读端自然收尾，**绝不 wait 一个没起来的进程**
            pipe.fileHandleForWriting.closeFile()
            _ = readDone.wait(timeout: .now() + 1)
            return Result(exitCode: -1, output: error.localizedDescription)
        }
        pipe.fileHandleForWriting.closeFile()

        // 超时兜底：TERM → KILL
        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning {
            timedOut = true
            p.terminate()
            usleep(200_000)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        _ = readDone.wait(timeout: .now() + 2)

        return Result(exitCode: p.terminationStatus,
                      output: String(data: captured, encoding: .utf8) ?? "",
                      timedOut: timedOut)
    }

    /// 只要文本输出（旧调用方的形状）。
    static func output(_ launchPath: String, _ arguments: [String] = [],
                       timeout: TimeInterval = 10) -> String? {
        run(launchPath, arguments, timeout: timeout)?.output
    }

    /// 命令是否真实存在且可执行。
    ///
    /// 用于在**调用之前**就知道"这台机器上没有这个工具"，
    /// 而不是等 `run()` 失败后把"未执行"谎报成"已重置缓存"。
    static func isAvailable(_ launchPath: String) -> Bool {
        guard isExecutableFile(launchPath) else { return false }
        return true
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var st = stat()
        guard stat(path, &st) == 0 else { return false }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return false }
        return access(path, X_OK) == 0
    }
}
