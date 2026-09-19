import Foundation

/// LaunchAgent 调度触发频率
enum LaunchAgentFrequency: String, Codable, CaseIterable, Identifiable {
    case daily = "每天定点 (默认 03:00)"
    case every12Hours = "每 12 小时"
    case every24Hours = "每 24 小时"
    case login = "每次开机登录时"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .daily: return "每天定点"
        case .every12Hours: return "每 12 小时"
        case .every24Hours: return "每 24 小时"
        case .login: return "开机登录时"
        }
    }
}

/// 系统级定时自动维护 LaunchAgent 调度管理器
///
/// 负责生成、安装、卸载及同步 `~/Library/LaunchAgents/com.macclean.scheduler.plist`。
/// 即使主程序完全退出，macOS launchd 也能在指定时间唤醒 `--autoclean` 命令行执行静默维护。
final class LaunchAgentManager {
    static let shared = LaunchAgentManager()

    static let label = "com.macclean.scheduler"
    static let plistFileName = "\(label).plist"

    // MARK: - 测试注入路径支持（隔离自检，防止污染宿主真实环境）
    var overrideLaunchAgentsDirectory: URL?
    var overrideLogsDirectory: URL?
    var overrideExecutablePath: String?
    /// 测试环境允许禁用真实 launchctl 进程调用
    var skipLaunchctlExecutionForTesting: Bool = false

    /// LaunchAgents 存储目录（通常为 ~/Library/LaunchAgents）
    var launchAgentsDirectory: URL {
        if let override = overrideLaunchAgentsDirectory { return override }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// 日志存储目录（通常为 ~/Library/Logs/MacClean）
    var logsDirectory: URL {
        if let override = overrideLogsDirectory { return override }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return home.appendingPathComponent("Library/Logs/MacClean", isDirectory: true)
    }

    /// 目标 Plist 完整文件路径
    var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent(Self.plistFileName)
    }

    /// 标准标准输出日志路径
    var standardOutLogPath: String {
        logsDirectory.appendingPathComponent("scheduler.log").path
    }

    /// 标准标准错误日志路径
    var standardErrorLogPath: String {
        logsDirectory.appendingPathComponent("scheduler.err").path
    }

    /// 寻找用于后台执行的 MacClean 可执行二进制文件绝对路径
    var executablePath: String {
        if let override = overrideExecutablePath { return override }
        // 1. 若安装于标准应用目录，优先使用 /Applications/MacClean.app
        let standardAppBinary = "/Applications/MacClean.app/Contents/MacOS/MacClean"
        if FileManager.default.isExecutableFile(atPath: standardAppBinary) {
            return standardAppBinary
        }
        // 2. 否则使用当前运行进程的二进制路径
        if let currentPath = Bundle.main.executablePath, FileManager.default.isExecutableFile(atPath: currentPath) {
            return currentPath
        }
        return standardAppBinary
    }

    // MARK: - Plist 生成器

    /// 根据调度类型与时分参数生成符合 Apple launchd 规范的 XML 属性列表
    func generatePlistContent(
        frequency: LaunchAgentFrequency,
        dailyHour: Int = 3,
        dailyMinute: Int = 0,
        executablePath: String? = nil
    ) -> String {
        let exec = executablePath ?? self.executablePath
        let clampedHour = max(0, min(23, dailyHour))
        let clampedMinute = max(0, min(59, dailyMinute))

        var scheduleXML = ""
        switch frequency {
        case .daily:
            scheduleXML = """
                <key>StartCalendarInterval</key>
                <dict>
                    <key>Hour</key>
                    <integer>\(clampedHour)</integer>
                    <key>Minute</key>
                    <integer>\(clampedMinute)</integer>
                </dict>
            """
        case .every12Hours:
            scheduleXML = """
                <key>StartInterval</key>
                <integer>43200</integer>
            """
        case .every24Hours:
            scheduleXML = """
                <key>StartInterval</key>
                <integer>86400</integer>
            """
        case .login:
            scheduleXML = """
                <key>RunAtLoad</key>
                <true/>
            """
        }

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Self.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(exec)</string>
                <string>--autoclean</string>
            </array>
        \(scheduleXML)
            <key>ProcessType</key>
            <string>Background</string>
            <key>LowPriorityIO</key>
            <true/>
            <key>Nice</key>
            <integer>10</integer>
            <key>StandardOutPath</key>
            <string>\(standardOutLogPath)</string>
            <key>StandardErrorPath</key>
            <string>\(standardErrorLogPath)</string>
        </dict>
        </plist>
        """
    }

    // MARK: - 安装与卸载

    /// 安装或更新 LaunchAgent 调度服务
    @discardableResult
    func install(
        frequency: LaunchAgentFrequency,
        dailyHour: Int = 3,
        dailyMinute: Int = 0,
        executablePath: String? = nil
    ) -> Bool {
        let fm = FileManager.default

        // 1. 确保 LaunchAgents 与 Logs 目录存在
        try? fm.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        // 2. 生成并写入 Plist 文件
        let content = generatePlistContent(
            frequency: frequency,
            dailyHour: dailyHour,
            dailyMinute: dailyMinute,
            executablePath: executablePath
        )

        do {
            try content.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            print("[LaunchAgentManager] 写入 Plist 失败: \(error.localizedDescription)")
            return false
        }

        // 3. 测试环境跳过系统 launchctl 操作
        if skipLaunchctlExecutionForTesting {
            return true
        }

        // 4. 执行 launchctl 重载
        let path = plistURL.path
        _ = runLaunchctl(["unload", path])
        let loadResult = runLaunchctl(["load", "-w", path])
        return loadResult.exitCode == 0
    }

    /// 卸载并清除 LaunchAgent 调度服务
    @discardableResult
    func uninstall() -> Bool {
        let fm = FileManager.default
        let path = plistURL.path

        if !skipLaunchctlExecutionForTesting && fm.fileExists(atPath: path) {
            _ = runLaunchctl(["unload", "-w", path])
        }

        if fm.fileExists(atPath: path) {
            do {
                try fm.removeItem(at: plistURL)
            } catch {
                print("[LaunchAgentManager] 删除 Plist 失败: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// 检查 Plist 文件是否已安装存在
    func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 检查服务是否已在 launchd 中加载运行
    func isLoaded() -> Bool {
        guard !skipLaunchctlExecutionForTesting else {
            return isInstalled()
        }
        let res = runLaunchctl(["list", Self.label])
        return res.exitCode == 0
    }

    /// 根据 DiskMonitorConfig 状态同步 LaunchAgent
    func syncWithConfig(_ config: DiskMonitorConfig) {
        if config.launchAgentEnabled {
            install(
                frequency: config.launchAgentFrequency,
                dailyHour: config.launchAgentDailyHour,
                dailyMinute: config.launchAgentDailyMinute
            )
        } else {
            if isInstalled() {
                uninstall()
            }
        }
    }

    // MARK: - 子进程执行

    private struct ProcessOutcome {
        let exitCode: Int32
        let output: String
    }

    @discardableResult
    private func runLaunchctl(_ args: [String]) -> ProcessOutcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args

        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return ProcessOutcome(exitCode: p.terminationStatus, output: out)
        } catch {
            return ProcessOutcome(exitCode: -1, output: error.localizedDescription)
        }
    }
}
