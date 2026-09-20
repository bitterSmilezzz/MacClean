import Foundation
import SwiftUI
import AppKit

// MARK: - 插件与系统扩展类型

enum PluginExtensionKind: String, Codable, CaseIterable, Identifiable {
    case quickLook = "QuickLook 快速查看"
    case spotlight = "Spotlight 导入器"
    case services = "服务菜单扩展"
    case contextualMenu = "上下文菜单插件"
    case internetPlugin = "网页浏览器插件"
    case screenSaver = "屏幕保护程序"
    case inputMethod = "输入法扩展"
    case colorPicker = "调色板组件"
    case other = "其他系统扩展"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .quickLook: return "QuickLook"
        case .spotlight: return "Spotlight"
        case .services: return "服务菜单"
        case .contextualMenu: return "右键菜单"
        case .internetPlugin: return "网页插件"
        case .screenSaver: return "屏保"
        case .inputMethod: return "输入法"
        case .colorPicker: return "调色板"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .quickLook: return "eye.circle"
        case .spotlight: return "magnifyingglass.circle"
        case .services: return "gearshape.2"
        case .contextualMenu: return "contextualmenu.and.cursor"
        case .internetPlugin: return "safari"
        case .screenSaver: return "display"
        case .inputMethod: return "keyboard"
        case .colorPicker: return "paintpalette"
        case .other: return "puzzlepiece.extension"
        }
    }
}

// MARK: - 插件健康状态

enum PluginExtensionStatus: String, Codable, CaseIterable, Identifiable {
    case orphan = "宿主已卸载"
    case broken = "扩展已损坏"
    case installed = "宿主正常在用"
    case system = "系统官方组件"

    var id: String { rawValue }

    var badgeColor: Color {
        switch self {
        case .orphan: return .red
        case .broken: return .orange
        case .installed: return .secondary
        case .system: return .blue
        }
    }

    var icon: String {
        switch self {
        case .orphan: return "xmark.bin"
        case .broken: return "exclamationmark.triangle"
        case .installed: return "checkmark.shield"
        case .system: return "apple.logo"
        }
    }
}

// MARK: - 插件与系统扩展模型

struct PluginExtensionItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let size: Int64
    let bundleID: String?
    let version: String?
    let kind: PluginExtensionKind
    let status: PluginExtensionStatus
    let hostAppName: String?
    let isUserDomain: Bool
    var isSelected: Bool

    var isSafeToClean: Bool {
        status == .orphan || status == .broken
    }

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        size: Int64,
        bundleID: String?,
        version: String?,
        kind: PluginExtensionKind,
        status: PluginExtensionStatus,
        hostAppName: String?,
        isUserDomain: Bool,
        isSelected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.bundleID = bundleID
        self.version = version
        self.kind = kind
        self.status = status
        self.hostAppName = hostAppName
        self.isUserDomain = isUserDomain
        self.isSelected = isSelected
    }
}

// MARK: - 插件与扩展治理检测引擎

final class PluginExtensionInspector {
    static let shared = PluginExtensionInspector()

    private init() {}

    // MARK: - 扫描目录定义

    struct TargetDirectory {
        let path: String
        let kind: PluginExtensionKind
        let isUserDomain: Bool

        init(path: String, kind: PluginExtensionKind, isUserDomain: Bool) {
            self.path = path
            self.kind = kind
            self.isUserDomain = isUserDomain
        }
    }

    /// 获取默认系统与用户级扫描目录
    static func defaultDirectories() -> [TargetDirectory] {
        var dirs: [TargetDirectory] = []

        // 用户层目录 (~/Library/...)
        let userLib = ("~/Library" as NSString).expandingTildeInPath
        dirs.append(TargetDirectory(path: "\(userLib)/QuickLook", kind: .quickLook, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Spotlight", kind: .spotlight, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Services", kind: .services, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Contextual Menu Items", kind: .contextualMenu, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Internet Plug-Ins", kind: .internetPlugin, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Screen Savers", kind: .screenSaver, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/Input Methods", kind: .inputMethod, isUserDomain: true))
        dirs.append(TargetDirectory(path: "\(userLib)/ColorPickers", kind: .colorPicker, isUserDomain: true))

        // 全局系统目录 (/Library/...)
        dirs.append(TargetDirectory(path: "/Library/QuickLook", kind: .quickLook, isUserDomain: false))
        dirs.append(TargetDirectory(path: "/Library/Spotlight", kind: .spotlight, isUserDomain: false))
        dirs.append(TargetDirectory(path: "/Library/Contextual Menu Items", kind: .contextualMenu, isUserDomain: false))
        dirs.append(TargetDirectory(path: "/Library/Internet Plug-Ins", kind: .internetPlugin, isUserDomain: false))
        dirs.append(TargetDirectory(path: "/Library/Screen Savers", kind: .screenSaver, isUserDomain: false))
        dirs.append(TargetDirectory(path: "/Library/Input Methods", kind: .inputMethod, isUserDomain: false))
        dirs.append(TargetDirectory(path: "/Library/ColorPickers", kind: .colorPicker, isUserDomain: false))

        return dirs
    }

    // MARK: - 扫描与解析主流程

    /// 全量扫描扩展项
    func scan(
        directories: [TargetDirectory] = defaultDirectories(),
        installedApps: [InstalledApp]? = nil
    ) -> [PluginExtensionItem] {
        let fm = FileManager.default
        let apps = installedApps ?? UninstallerScanner.scanApps()
        var items: [PluginExtensionItem] = []

        for target in directories {
            guard fm.fileExists(atPath: target.path) else { continue }
            guard let contents = try? fm.contentsOfDirectory(atPath: target.path) else { continue }

            for filename in contents {
                // 跳过隐藏文件或 .DS_Store
                if filename.hasPrefix(".") { continue }

                let fullPath = (target.path as NSString).appendingPathComponent(filename)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

                // 计算体积
                let itemSize: Int64 = FileSystem.size(at: fullPath)

                // 解析 Bundle 元数据
                let parsed = parseBundleMetadata(path: fullPath, defaultName: filename, kind: target.kind)

                // 研判健康状态
                let (status, hostApp) = evaluateStatus(
                    bundleID: parsed.bundleID,
                    appName: parsed.name,
                    executableExists: parsed.executableExists,
                    fullPath: fullPath,
                    installedApps: apps
                )

                let item = PluginExtensionItem(
                    name: parsed.name,
                    path: fullPath,
                    size: itemSize,
                    bundleID: parsed.bundleID,
                    version: parsed.version,
                    kind: target.kind,
                    status: status,
                    hostAppName: hostApp,
                    isUserDomain: target.isUserDomain,
                    isSelected: false
                )
                items.append(item)
            }
        }

        // 排序：孤儿与损坏优先排前，其次按体积降序
        return items.sorted { a, b in
            if a.isSafeToClean != b.isSafeToClean {
                return a.isSafeToClean && !b.isSafeToClean
            }
            return a.size > b.size
        }
    }

    // MARK: - Bundle 元数据解析

    struct ParsedMetadata {
        let name: String
        let bundleID: String?
        let version: String?
        let executableExists: Bool
    }

    func parseBundleMetadata(path: String, defaultName: String, kind: PluginExtensionKind) -> ParsedMetadata {
        let fm = FileManager.default
        var plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        if !fm.fileExists(atPath: plistPath) {
            // 尝试根目录下的 Info.plist
            let altPlist = (path as NSString).appendingPathComponent("Info.plist")
            if fm.fileExists(atPath: altPlist) {
                plistPath = altPlist
            }
        }

        guard fm.fileExists(atPath: plistPath),
              let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
            // 非标准 Bundle 或无 Info.plist
            let cleanName = stripExtension(from: defaultName)
            return ParsedMetadata(name: cleanName, bundleID: nil, version: nil, executableExists: true)
        }

        let bundleID = dict["CFBundleIdentifier"] as? String
        let displayName = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? stripExtension(from: defaultName)

        let version = (dict["CFBundleShortVersionString"] as? String)
            ?? (dict["CFBundleVersion"] as? String)

        var execExists = true
        if let execName = dict["CFBundleExecutable"] as? String, !execName.isEmpty {
            let execPath1 = (path as NSString).appendingPathComponent("Contents/MacOS/\(execName)")
            let execPath2 = (path as NSString).appendingPathComponent(execName)
            if !fm.fileExists(atPath: execPath1) && !fm.fileExists(atPath: execPath2) {
                execExists = false
            }
        }

        return ParsedMetadata(
            name: displayName,
            bundleID: bundleID,
            version: version,
            executableExists: execExists
        )
    }

    // MARK: - 状态研判

    func evaluateStatus(
        bundleID: String?,
        appName: String,
        executableExists: Bool,
        fullPath: String,
        installedApps: [InstalledApp]
    ) -> (PluginExtensionStatus, String?) {
        // 1. 如果可执行文件丢失或明确损坏
        if !executableExists {
            return (.broken, nil)
        }

        // 2. Apple 官方系统组件保护
        if let bundleID, bundleID.lowercased().hasPrefix("com.apple.") {
            return (.system, "macOS 系统内置")
        }

        // 3. 匹配在用 App (InstalledApp)
        if let bundleID, !bundleID.isEmpty {
            let lowerBundle = bundleID.lowercased()

            // 精确或前缀匹配已安装应用 Bundle ID
            for app in installedApps {
                if let appBundle = app.bundleID?.lowercased(), !appBundle.isEmpty {
                    if lowerBundle == appBundle || lowerBundle.hasPrefix(appBundle + ".") || appBundle.hasPrefix(lowerBundle + ".") {
                        return (.installed, app.name)
                    }
                }
            }

            // 词干逆向匹配 (如 com.sublimetext.3 -> sublime text)
            let stem = stemOfBundle(lowerBundle)
            for app in installedApps {
                let appNameNorm = normalizeName(app.name)
                if !stem.isEmpty && (appNameNorm.contains(stem) || stem.contains(appNameNorm)) {
                    return (.installed, app.name)
                }
            }
        }

        // 4. 按扩展名/插件文件名匹配在用 App
        let itemBase = normalizeName(stripExtension(from: (fullPath as NSString).lastPathComponent))
        for app in installedApps {
            let appNameNorm = normalizeName(app.name)
            if !itemBase.isEmpty && (appNameNorm == itemBase || appNameNorm.hasPrefix(itemBase) || itemBase.hasPrefix(appNameNorm)) {
                return (.installed, app.name)
            }
        }

        // 5. 若无法匹配任何在用 App，且具备 BundleID 或独立第三方特征，判定为孤儿
        let derivedHost = bundleID != nil ? PreferenceResidueInspector.deriveDisplayName(from: bundleID!) : appName
        return (.orphan, derivedHost)
    }

    // MARK: - 清理与安全执行

    struct CleanResult {
        let succeeded: Int
        let failed: Int
        let releasedBytes: Int64
        let hadQuickLook: Bool

        init(succeeded: Int, failed: Int, releasedBytes: Int64, hadQuickLook: Bool) {
            self.succeeded = succeeded
            self.failed = failed
            self.releasedBytes = releasedBytes
            self.hadQuickLook = hadQuickLook
        }
    }

    /// 清理所选扩展
    func clean(
        items: [PluginExtensionItem],
        permanently: Bool,
        onProgress: @escaping (String) -> Void = { _ in }
    ) -> CleanResult {
        var succeeded = 0
        var failed = 0
        var released: Int64 = 0
        var hadQuickLook = false

        let fm = FileManager.default

        for item in items {
            // 系统官方组件绝不清理
            guard item.status != .system else {
                failed += 1
                continue
            }

            let path = item.path
            guard fm.fileExists(atPath: path) else { continue }

            onProgress("正在清理 \(item.name)...")

            do {
                if permanently {
                    try fm.removeItem(atPath: path)
                } else {
                    var resultingURL: NSURL?
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
                }
                succeeded += 1
                released += item.size
                if item.kind == .quickLook {
                    hadQuickLook = true
                }
            } catch {
                failed += 1
            }
        }

        // 若清理了 QuickLook 插件，异步重置 QuickLook 守护进程缓存
        if hadQuickLook {
            resetQuickLookCache()
        }

        return CleanResult(
            succeeded: succeeded,
            failed: failed,
            releasedBytes: released,
            hadQuickLook: hadQuickLook
        )
    }

    /// 异步重置 QuickLook 缓存与服务
    func resetQuickLookCache() {
        DispatchQueue.global(qos: .utility).async {
            let p1 = Process()
            p1.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p1.arguments = ["-r"]
            try? p1.run()
            p1.waitUntilExit()

            let p2 = Process()
            p2.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
            p2.arguments = ["-r", "cache"]
            try? p2.run()
            p2.waitUntilExit()
        }
    }

    // MARK: - 辅助方法

    private func stripExtension(from string: String) -> String {
        return (string as NSString).deletingPathExtension
    }

    private func stemOfBundle(_ bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        if parts.count >= 2 {
            return String(parts[1]).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        }
        return ""
    }

    private func normalizeName(_ name: String) -> String {
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".app", with: "")
    }
}
