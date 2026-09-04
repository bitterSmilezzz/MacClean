import Foundation
import AppKit

// MARK: - 风险项模型

/// 风险严重度
enum RiskSeverity: String, Codable, Equatable {
    case high     // 高风险：敏感数据可能泄露/被利用
    case medium   // 中风险：暴露面扩大/配置不当
    case low      // 低风险：建议优化

    var label: String {
        switch self {
        case .high: return "高风险"
        case .medium: return "中风险"
        case .low: return "低风险"
        }
    }

    var order: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

/// 风险类别
enum RiskCategory: String, Codable, Equatable {
    case sensitiveData   // 敏感数据
    case networkExposure // 网络暴露
    case systemSecurity  // 系统安全
    case startupItems    // 启动项与可疑程序

    var label: String {
        switch self {
        case .sensitiveData: return "敏感数据"
        case .networkExposure: return "网络暴露"
        case .systemSecurity: return "系统安全"
        case .startupItems: return "启动项与可疑程序"
        }
    }
}

/// 单条风险检查结果（只读检测，不删除任何文件）
struct RiskItem: Identifiable, Equatable {
    let id = UUID()
    let title: String          // 风险标题
    let detail: String         // 检测详情（只描述，不含敏感内容明文）
    let severity: RiskSeverity
    let category: RiskCategory
    let suggestion: String     // 修复建议
    var path: String? = nil    // 相关路径（可选）
}

// MARK: - 风险扫描器（电脑风险提醒）

/// 电脑风险检查：敏感数据泄露 / 网络暴露 / 系统安全 / 启动项
/// 只读检测，绝不删除文件；检测到敏感内容只提示存在，不输出明文。
enum RiskScanner {

    /// 全部检查项名称（诊断输出用）
    static let checkNames: [(RiskCategory, String)] = [
        (.sensitiveData, "SSH 私钥权限"),
        (.sensitiveData, "明文密钥环境变量"),
        (.sensitiveData, "敏感命名文件暴露"),
        (.sensitiveData, "共享目录权限"),
        (.networkExposure, "防火墙状态"),
        (.networkExposure, "远程登录/文件共享"),
        (.systemSecurity, "FileVault 磁盘加密"),
        (.systemSecurity, "自动登录"),
        (.startupItems, "可疑启动项"),
    ]

    /// 执行全部风险检查
    /// - Parameters:
    ///   - home: 用户主目录（测试可注入临时目录）
    ///   - progress: 逐项进度回调（检查名）
    static func scan(home: String = NSHomeDirectory(),
                     progress: @escaping (String) -> Void = { _ in }) -> [RiskItem] {
        var items: [RiskItem] = []

        // 1) SSH 私钥权限
        progress("检查 SSH 私钥权限…")
        if let sshItem = checkSSHKeys(home: home) { items.append(sshItem) }

        // 2) 明文密钥环境变量
        progress("检查明文密钥环境变量…")
        if let envItem = checkEnvSecrets(home: home) { items.append(envItem) }

        // 3) 敏感命名文件暴露
        progress("检查敏感命名文件…")
        items.append(contentsOf: checkSensitiveFiles(home: home))

        // 4) 共享目录权限
        progress("检查共享目录权限…")
        if let sharedItem = checkSharedDirs(home: home) { items.append(sharedItem) }

        // 5) 防火墙状态
        progress("检查防火墙状态…")
        if let fwItem = checkFirewall() { items.append(fwItem) }

        // 6) 远程登录/文件共享
        progress("检查远程登录与文件共享…")
        items.append(contentsOf: checkRemoteServices())

        // 7) FileVault
        progress("检查磁盘加密…")
        if let fvItem = checkFileVault() { items.append(fvItem) }

        // 8) 自动登录
        progress("检查自动登录…")
        if let autoItem = checkAutoLogin() { items.append(autoItem) }

        // 9) 可疑启动项
        progress("检查可疑启动项…")
        items.append(contentsOf: checkStartupItems(home: home))

        return items.sorted {
            if $0.severity.order != $1.severity.order { return $0.severity.order < $1.severity.order }
            return $0.category.rawValue < $1.category.rawValue
        }
    }

    // MARK: - 1. SSH 私钥权限

    static func checkSSHKeys(home: String) -> RiskItem? {
        let sshDir = (home as NSString).appendingPathComponent(".ssh")
        guard FileManager.default.fileExists(atPath: sshDir) else { return nil }
        let perms = posixPermissions(sshDir)
        // 私钥文件存在且权限过宽（group/other 可读）
        let privateKeys = FileSystem.children(of: sshDir, keepHidden: true).filter {
            let name = ($0 as NSString).lastPathComponent
            return name == "id_rsa" || name == "id_ed25519" || name == "id_dsa" || name == "id_ecdsa"
        }
        let weakKey = privateKeys.first { p in
            let pms = posixPermissions(p)
            return pms != nil && pms! & 0o077 != 0   // group/other 有权限
        }
        if let weakKey {
            return RiskItem(
                title: "SSH 私钥权限过宽",
                detail: "私钥文件 \((weakKey as NSString).lastPathComponent) 的权限为 \(formatPerms(weakKey))，其他用户可读取，存在私钥泄露风险。",
                severity: .high, category: .sensitiveData,
                suggestion: "执行 chmod 600 \(weakKey) 收紧权限。",
                path: weakKey)
        }
        if let perms, perms & 0o077 != 0 {
            return RiskItem(
                title: "SSH 目录权限过宽",
                detail: "~/.ssh 目录权限为 \(formatPerms(sshDir))，建议仅本人可读写。",
                severity: .medium, category: .sensitiveData,
                suggestion: "执行 chmod 700 \(sshDir)。",
                path: sshDir)
        }
        return nil
    }

    // MARK: - 2. 明文密钥环境变量

    static func checkEnvSecrets(home: String) -> RiskItem? {
        let files = [".zshrc", ".zprofile", ".bashrc", ".bash_profile", ".profile"]
        var hits: [(String, String)] = []   // (文件, 变量名)
        for f in files {
            let path = (home as NSString).appendingPathComponent(f)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("export ") || trimmed.hasPrefix("export\t") else { continue }
                let body = trimmed.replacingOccurrences(of: #"^export\s+"#, with: "", options: .regularExpression)
                guard let eq = body.firstIndex(of: "=") else { continue }
                let varName = String(body[..<eq])
                let value = String(body[body.index(after: eq)...])
                // 仅检测"疑似密钥"特征，不输出明文内容
                let looksSecret = value.hasPrefix("sk-") || value.hasPrefix("ghp_") || value.hasPrefix("AKIA")
                    || value.hasPrefix("AIza") || value.hasPrefix("xoxb-") || value.hasPrefix("eyJ")
                    || varName.lowercased().contains("token") || varName.lowercased().contains("secret")
                    || varName.lowercased().contains("password") || varName.lowercased().contains("api_key")
                if looksSecret, value.count >= 8 {
                    hits.append((f, varName))
                }
            }
        }
        guard !hits.isEmpty else { return nil }
        let names = hits.map { "\($0.0) 中的 \($0.1)" }.joined(separator: "、")
        return RiskItem(
            title: "检测到明文密钥环境变量",
            detail: "\(names) 疑似包含 API 密钥/令牌明文。任何能读取该文件的进程都可能获得这些凭据。",
            severity: .high, category: .sensitiveData,
            suggestion: "改用钥匙串或 .env 文件（仅本人可读，且不提交到版本库）。",
            path: hits.first.map { (home as NSString).appendingPathComponent($0.0) })
    }

    // MARK: - 3. 敏感命名文件暴露

    static func checkSensitiveFiles(home: String) -> [RiskItem] {
        var items: [RiskItem] = []
        let roots = ["Desktop", "Downloads", "Documents"]
        let pattern = #"(?i)(password|密码|secret|密钥|token|私钥|credential|\.pem$|\.key$|backup.*\.zip$)"#
        for root in roots {
            let dir = (home as NSString).appendingPathComponent(root)
            guard FileManager.default.fileExists(atPath: dir) else { continue }
            // 顶层 + 一级子目录（限深度 2，避免全盘扫描）
            let candidates = FileSystem.children(of: dir, keepHidden: false)
                + FileSystem.subdirs(of: dir).flatMap { FileSystem.children(of: $0, keepHidden: false) }
            let sensitive = candidates.filter {
                let name = ($0 as NSString).lastPathComponent
                return name.range(of: pattern, options: .regularExpression) != nil
            }
            for f in sensitive.prefix(5) {
                let size = FileSystem.size(at: f)
                guard size > 0 else { continue }
                items.append(RiskItem(
                    title: "发现疑似敏感文件",
                    detail: "文件 \((f as NSString).lastPathComponent)（\(size.byteStringCN)）位于 \(root)，文件名含敏感关键词，可能包含密码/密钥等数据。",
                    severity: .medium, category: .sensitiveData,
                    suggestion: "确认内容后移入加密磁盘映像（.dmg）或密码管理器，并从桌面/下载目录移走。",
                    path: f))
            }
        }
        return items
    }

    // MARK: - 4. 共享目录权限

    static func checkSharedDirs(home: String) -> RiskItem? {
        let publicDir = (home as NSString).appendingPathComponent("Public")
        guard FileManager.default.fileExists(atPath: publicDir) else { return nil }
        if let perms = posixPermissions(publicDir), perms & 0o002 != 0 {
            return RiskItem(
                title: "共享目录对所有人可写",
                detail: "~/Public 权限为 \(formatPerms(publicDir))，局域网内的其他用户可能写入文件。",
                severity: .medium, category: .sensitiveData,
                suggestion: "执行 chmod 755 \(publicDir)（仅读，不可写）。",
                path: publicDir)
        }
        return nil
    }

    // MARK: - 5. 防火墙状态

    static func checkFirewall() -> RiskItem? {
        let out = runCommand("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
        guard let out else { return nil }
        if out.contains("disabled") {
            return RiskItem(
                title: "防火墙未开启",
                detail: "macOS 应用防火墙当前为关闭状态，入站连接不被拦截。",
                severity: .medium, category: .networkExposure,
                suggestion: "系统设置 → 网络 → 防火墙 → 打开防火墙。")
        }
        return nil
    }

    // MARK: - 6. 远程登录 / 文件共享

    static func checkRemoteServices() -> [RiskItem] {
        var items: [RiskItem] = []
        // 远程登录（SSH）
        if let list = try? Process().launchAndCapture("/bin/launchctl", ["list"]),
           list.contains("com.openssh.sshd") {
            items.append(RiskItem(
                title: "远程登录（SSH）已开启",
                detail: "检测到 sshd 正在运行，若使用弱密码可能被远程暴力破解。",
                severity: .medium, category: .networkExposure,
                suggestion: "不使用远程登录时：系统设置 → 通用 → 共享 → 关闭「远程登录」。"))
        }
        // 文件共享 / 屏幕共享
        let sharing = ["com.apple.smbd": "文件共享", "com.apple.ARDAgent": "屏幕共享", "com.apple.screensharing": "屏幕共享"]
        for (service, label) in sharing {
            if let list = try? Process().launchAndCapture("/bin/launchctl", ["list"]),
               list.contains(service) {
                items.append(RiskItem(
                    title: "\(label)已开启",
                    detail: "检测到 \(label)（\(service)）正在运行，局域网设备可访问本机。",
                    severity: .low, category: .networkExposure,
                    suggestion: "不需要时：系统设置 → 通用 → 共享 → 关闭对应共享。"))
            }
        }
        return items
    }

    // MARK: - 7. FileVault

    static func checkFileVault() -> RiskItem? {
        let out = runCommand("/usr/bin/fdesetup", ["status"])
        guard let out else { return nil }
        if out.lowercased().contains("off") {
            return RiskItem(
                title: "磁盘加密（FileVault）未开启",
                detail: "磁盘未加密，设备丢失或被物理接触时敏感数据可能被直接读取。",
                severity: .medium, category: .systemSecurity,
                suggestion: "系统设置 → 隐私与安全性 → FileVault → 打开，并妥善保管恢复密钥。")
        }
        return nil
    }

    // MARK: - 8. 自动登录

    static func checkAutoLogin() -> RiskItem? {
        let out = runCommand("/usr/bin/defaults", ["read", "/Library/Preferences/com.apple.loginwindow", "autoLoginUser"])
        if let out, !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !out.contains("does not exist") {
            return RiskItem(
                title: "开启了自动登录",
                detail: "系统登录不需要密码，设备丢失后他人可直接进入桌面访问所有数据。",
                severity: .high, category: .systemSecurity,
                suggestion: "系统设置 → 用户与群组 → 关闭「自动登录」。")
        }
        return nil
    }

    // MARK: - 9. 可疑启动项

    static func checkStartupItems(home: String) -> [RiskItem] {
        var items: [RiskItem] = []
        let dirs = ["~/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for dir in dirs {
            let full = dir.replacingOccurrences(of: "~", with: home)
            guard FileManager.default.fileExists(atPath: full) else { continue }
            for child in FileSystem.children(of: full, keepHidden: false) where child.hasSuffix(".plist") {
                guard let dict = NSDictionary(contentsOfFile: child),
                      let args = dict["ProgramArguments"] as? [String],
                      let exe = args.first else { continue }
                // 指向 /tmp、共享目录、或已不存在的程序 → 可疑
                let suspicious = exe.contains("/tmp/") || exe.contains("/Users/Shared/")
                    || exe.contains("/private/var/tmp/")
                // 仅绝对路径才做存在性检查（相对路径如 sh 走 PATH，视为正常）
                let missing = exe.hasPrefix("/") && !FileManager.default.fileExists(atPath: exe)
                if suspicious || missing {
                    items.append(RiskItem(
                        title: "发现可疑启动项",
                        detail: "\(((child as NSString).lastPathComponent)) 指向 \(exe)（\(missing ? "程序不存在" : "位于临时/共享目录")）。",
                        severity: .medium, category: .startupItems,
                        suggestion: "核实该启动项来源；如不认识，在 系统设置 → 通用 → 登录项 中移除，或删除该 plist。",
                        path: child))
                }
            }
        }
        return items
    }

    // MARK: - 工具

    /// 路径 POSIX 权限（八进制数字）
    static func posixPermissions(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    static func formatPerms(_ path: String) -> String {
        guard let p = posixPermissions(path) else { return "未知" }
        return String(format: "%04o", p)
    }

    /// 运行命令并捕获 stdout（只读）
    static func runCommand(_ launchPath: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - Process 辅助（launchctl list 捕获）

extension Process {
    /// 运行并返回 stdout（供风险扫描只读检测使用）
    func launchAndCapture(_ launchPath: String, _ args: [String]) throws -> String {
        executableURL = URL(fileURLWithPath: launchPath)
        arguments = args
        let pipe = Pipe()
        standardOutput = pipe
        standardError = pipe
        try run()
        waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
