import SwiftUI
import Foundation

// MARK: - 启动项存储位置

public enum StartupItemLocation: String, CaseIterable, Identifiable {
    case userAgent = "用户自启代理 (LaunchAgents)"
    case globalAgent = "系统自启代理 (/Library/LaunchAgents)"
    case globalDaemon = "系统全局守护 (/Library/LaunchDaemons)"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .userAgent: return "用户代理"
        case .globalAgent: return "全局代理"
        case .globalDaemon: return "系统守护"
        }
    }

    public var icon: String {
        switch self {
        case .userAgent: return "person.crop.circle"
        case .globalAgent: return "globe"
        case .globalDaemon: return "gearshape.2"
        }
    }

    public var requiresAdmin: Bool {
        switch self {
        case .userAgent: return false
        case .globalAgent, .globalDaemon: return true
        }
    }
}

// MARK: - 启动项运行与健康状态

public enum StartupItemStatus: String, CaseIterable, Identifiable {
    case valid = "正常激活"
    case disabled = "已停用"
    case missingExecutable = "幽灵残留 (程序缺失)"
    case orphanedApp = "宿主应用已卸载"
    case systemProtected = "系统受保护"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .valid: return "checkmark.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .missingExecutable: return "exclamationmark.triangle.fill"
        case .orphanedApp: return "trash.circle.fill"
        case .systemProtected: return "shield.fill"
        }
    }

    public var color: Color {
        switch self {
        case .valid: return Signal.positive
        case .disabled: return Ink.tertiary
        case .missingExecutable, .orphanedApp: return Signal.caution
        case .systemProtected: return Accent.tint
        }
    }

    public var isDangling: Bool {
        self == .missingExecutable || self == .orphanedApp
    }
}

// MARK: - 启动项数据模型

public struct StartupItem: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public var path: String
    public let label: String
    public let location: StartupItemLocation
    public let programPath: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public var isDisabled: Bool
    public var status: StartupItemStatus
    public let vendor: String
    public let fileSize: Int64

    public init(
        id: String? = nil,
        name: String,
        path: String,
        label: String,
        location: StartupItemLocation,
        programPath: String?,
        arguments: [String] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        isDisabled: Bool = false,
        status: StartupItemStatus = .valid,
        vendor: String = "未知开发者",
        fileSize: Int64 = 0
    ) {
        self.id = id ?? path
        self.name = name
        self.path = path
        self.label = label
        self.location = location
        self.programPath = programPath
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.isDisabled = isDisabled
        self.status = status
        self.vendor = vendor
        self.fileSize = fileSize
    }
}

// MARK: - 启动项巡检与管理引擎

public final class StartupItemManager {
    public static let shared = StartupItemManager()

    // 测试注入隔离目录
    public var overrideHomeDirectory: String?
    public var overrideGlobalAgentsDir: String?
    public var overrideGlobalDaemonsDir: String?

    public init() {}

    private var homeDir: String {
        overrideHomeDirectory ?? NSHomeDirectory()
    }

    private var userAgentsDir: String {
        "\(homeDir)/Library/LaunchAgents"
    }

    private var globalAgentsDir: String {
        overrideGlobalAgentsDir ?? "/Library/LaunchAgents"
    }

    private var globalDaemonsDir: String {
        overrideGlobalDaemonsDir ?? "/Library/LaunchDaemons"
    }

    /// 全面扫描所有位置的自启与守护项
    public func scanAll() -> [StartupItem] {
        var results: [StartupItem] = []

        results += scanDirectory(path: userAgentsDir, location: .userAgent)
        results += scanDirectory(path: globalAgentsDir, location: .globalAgent)
        results += scanDirectory(path: globalDaemonsDir, location: .globalDaemon)

        return results.sorted { lhs, rhs in
            if lhs.status.isDangling != rhs.status.isDangling {
                return lhs.status.isDangling && !rhs.status.isDangling
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func scanDirectory(path: String, location: StartupItemLocation) -> [StartupItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: path) else { return [] }

        var items: [StartupItem] = []
        for file in files {
            // 支持 .plist 与 .disabled
            let isPlist = file.hasSuffix(".plist")
            let isDisabledFile = file.hasSuffix(".disabled")
            guard isPlist || isDisabledFile else { continue }

            let fullPath = (path as NSString).appendingPathComponent(file)
            if let item = parseStartupItem(path: fullPath, filename: file, location: location) {
                items.append(item)
            }
        }
        return items
    }

    /// 解析单个 Plist 文件
    public func parseStartupItem(path: String, filename: String, location: StartupItemLocation) -> StartupItem? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }

        let label = (plist["Label"] as? String) ?? filename
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? false
        let plistDisabled = (plist["Disabled"] as? Bool) ?? false
        let isFileDisabled = filename.hasSuffix(".disabled")
        let isDisabled = plistDisabled || isFileDisabled

        // 提取可执行文件路径
        var programPath: String?
        var arguments: [String] = []

        if let prog = plist["Program"] as? String {
            programPath = prog
        }
        if let args = plist["ProgramArguments"] as? [String] {
            arguments = args
            if programPath == nil, let first = args.first {
                programPath = first
            }
        }

        // 文件大小
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // 状态判定
        let status = evaluateStatus(
            path: path,
            filename: filename,
            label: label,
            programPath: programPath,
            isDisabled: isDisabled
        )

        let vendor = resolveVendor(label: label, programPath: programPath)

        return StartupItem(
            name: filename,
            path: path,
            label: label,
            location: location,
            programPath: programPath,
            arguments: arguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            isDisabled: isDisabled,
            status: status,
            vendor: vendor,
            fileSize: size
        )
    }

    /// 状态诊断核心逻辑
    public func evaluateStatus(
        path: String,
        filename: String,
        label: String,
        programPath: String?,
        isDisabled: Bool
    ) -> StartupItemStatus {
        if label.hasPrefix("com.apple.") || path.contains("/System/") {
            return .systemProtected
        }

        guard let rawProg = programPath, !rawProg.trimmingCharacters(in: .whitespaces).isEmpty else {
            return isDisabled ? .disabled : .missingExecutable
        }

        let resolvedProg = (rawProg as NSString).expandingTildeInPath
        let fm = FileManager.default

        // 如果可执行文件位于 .app 包内
        if resolvedProg.contains(".app/") {
            let parts = resolvedProg.components(separatedBy: ".app/")
            if let appPart = parts.first {
                let appBundlePath = appPart + ".app"
                if !fm.fileExists(atPath: appBundlePath) {
                    return .orphanedApp
                }
            }
        }

        if !fm.fileExists(atPath: resolvedProg) {
            return .missingExecutable
        }

        if isDisabled {
            return .disabled
        }

        return .valid
    }

    /// 厂商识别
    public func resolveVendor(label: String, programPath: String?) -> String {
        let text = "\(label) \(programPath ?? "")".lowercased()
        if text.contains("apple") { return "Apple 原生/系统" }
        if text.contains("google") { return "Google" }
        if text.contains("microsoft") { return "Microsoft" }
        if text.contains("docker") { return "Docker" }
        if text.contains("jetbrains") { return "JetBrains" }
        if text.contains("adobe") { return "Adobe" }
        if text.contains("dropbox") { return "Dropbox" }
        if text.contains("homebrew") || text.contains("/opt/homebrew") || text.contains("/usr/local") {
            return "Homebrew / 开源服务"
        }
        if text.contains("macclean") { return "MacClean 调度服务" }
        return "第三方软件"
    }

    // MARK: - 操作控制（安全停用 / 启用 / 移入废纸篓）

    /// 切换停用/启用状态（通过重命名 .disabled 后缀）
    public func toggleDisabled(item: StartupItem) throws -> StartupItem {
        let fm = FileManager.default
        let oldPath = item.path
        let newPath: String

        if item.path.hasSuffix(".disabled") {
            // 启用：移除 .disabled
            newPath = String(item.path.dropLast(".disabled".count))
        } else {
            // 禁用：增加 .disabled
            newPath = item.path + ".disabled"
        }

        try fm.moveItem(atPath: oldPath, toPath: newPath)

        var updated = item
        updated.path = newPath
        updated.isDisabled = !item.isDisabled
        if updated.isDisabled {
            updated.status = .disabled
        } else {
            updated.status = evaluateStatus(
                path: newPath,
                filename: (newPath as NSString).lastPathComponent,
                label: item.label,
                programPath: item.programPath,
                isDisabled: false
            )
        }
        return updated
    }

    /// 安全移入废纸篓
    public func moveToTrash(item: StartupItem) throws {
        let fileURL = URL(fileURLWithPath: item.path)
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
    }

    /// 一键批量安全清理所有幽灵残留项
    public func cleanAllDangling(items: [StartupItem]) -> (removedCount: Int, freedBytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for item in items where item.status.isDangling {
            do {
                try moveToTrash(item: item)
                count += 1
                bytes += item.fileSize
            } catch {
                print("移入废纸篓失败: \(item.path), error: \(error)")
            }
        }
        return (count, bytes)
    }
}
