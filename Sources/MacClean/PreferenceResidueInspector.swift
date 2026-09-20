import Foundation
import SwiftUI
import AppKit

// MARK: - 偏好碎片存储位置

public enum PreferenceLocationKind: String, Codable, CaseIterable, Identifiable {
    case standard = "标准偏好 (~/Library/Preferences)"
    case byHost = "硬件绑定偏好 (ByHost)"
    case synced = "同步偏好 (SyncedPreferences)"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .standard: return "标准偏好"
        case .byHost: return "ByHost"
        case .synced: return "同步偏好"
        }
    }

    public var icon: String {
        switch self {
        case .standard: return "gearshape"
        case .byHost: return "cpu"
        case .synced: return "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - 孤儿偏好碎片模型

public struct OrphanPreferenceItem: Identifiable, Equatable, Hashable {
    public let id: UUID
    public let appName: String
    public let bundleID: String
    public let fileName: String
    public let path: String
    public let size: Int64
    public let lastModified: Date?
    public let ageDays: Int
    public let location: PreferenceLocationKind
    public var isSelected: Bool

    public init(
        id: UUID = UUID(),
        appName: String,
        bundleID: String,
        fileName: String,
        path: String,
        size: Int64,
        lastModified: Date?,
        ageDays: Int,
        location: PreferenceLocationKind,
        isSelected: Bool = false
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.fileName = fileName
        self.path = path
        self.size = size
        self.lastModified = lastModified
        self.ageDays = ageDays
        self.location = location
        self.isSelected = isSelected
    }
}

// MARK: - 已卸载应用偏好碎片逆向匹配引擎

final class PreferenceResidueInspector {
    static let shared = PreferenceResidueInspector()

    private init() {}

    // MARK: - 字符串与正则表达式工具

    private static let uuidRegex = try? NSRegularExpression(
        pattern: "\\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
        options: []
    )

    /// 从 plist 文件名中提取净空 Bundle 标识（剥离 .plist 后缀与 ByHost 硬件 UUID）
    static func extractBundleID(from filename: String) -> String {
        var base = filename
        if base.hasSuffix(".plist") {
            base = String(base.dropLast(6))
        }

        if let regex = uuidRegex {
            let range = NSRange(location: 0, length: base.utf16.count)
            base = regex.stringByReplacingMatches(in: base, options: [], range: range, withTemplate: "")
        }
        return base
    }

    /// 根据 Bundle 标识智能推导人类易读的应用名
    static func deriveDisplayName(from bundleID: String) -> String {
        let lower = bundleID.lowercased()

        // 知名常用应用映射
        let knownMappings: [String: String] = [
            "com.tencent.xinwechat": "微信 (WeChat)",
            "com.tencent.qq": "QQ",
            "com.google.chrome": "Google Chrome",
            "com.google.keystone": "Google Update (Keystone)",
            "com.microsoft.vscode": "Visual Studio Code",
            "com.spotify.client": "Spotify",
            "com.netease.163music": "网易云音乐",
            "org.videolan.vlc": "VLC media player",
            "com.sublimetext.3": "Sublime Text 3",
            "com.sublimetext.4": "Sublime Text 4",
            "com.github.githubclient": "GitHub Desktop",
            "com.postmanlabs.mac": "Postman",
            "com.figma.desktop": "Figma",
            "com.notion.id": "Notion",
            "ai.opencode.desktop": "OpenCode",
            "cn.coze.desktop": "扣子 (Coze)",
            "cn.trae.app": "Trae",
            "cn.trae.solo.app": "Trae Solo"
        ]

        if let mapped = knownMappings[lower] {
            return mapped
        }

        // 包含 ShipIt 自动更新器标识
        if lower.contains("shipit") {
            let stripped = bundleID.replacingOccurrences(of: ".ShipIt", with: "", options: .caseInsensitive)
            let baseName = deriveDisplayName(from: stripped)
            return "\(baseName) (更新组件)"
        }

        return OrphanScanner.deriveDisplayName(bundleID)
    }

    // MARK: - 扫描与逆向匹配

    /// 全面扫描已卸载应用的偏好设置碎片
    /// - Parameters:
    ///   - home: 用户主目录
    ///   - db: 已安装应用数据库（若不传则现场构建）
    ///   - minAgeDays: 最小闲置天数（默认 7 天，避免刚生成的新偏好误判）
    func scanOrphanPreferences(
        home: String = NSHomeDirectory(),
        db: OrphanScanner.InstalledDatabase? = nil,
        minAgeDays: Int = 7
    ) -> [OrphanPreferenceItem] {
        let database = db ?? OrphanScanner.InstalledDatabase.build()
        var results: [OrphanPreferenceItem] = []
        let now = Date()
        let cutoff = now.addingTimeInterval(-Double(minAgeDays) * 86400)

        // 1. 标准偏好 ~/Library/Preferences
        let standardDir = "\(home)/Library/Preferences"
        scanDirectory(dir: standardDir, location: .standard, db: database, cutoff: cutoff, now: now, minAgeDays: minAgeDays, into: &results)

        // 2. ByHost 偏好 ~/Library/Preferences/ByHost
        let byHostDir = "\(home)/Library/Preferences/ByHost"
        scanDirectory(dir: byHostDir, location: .byHost, db: database, cutoff: cutoff, now: now, minAgeDays: minAgeDays, into: &results)

        // 3. SyncedPreferences ~/Library/SyncedPreferences
        let syncedDir = "\(home)/Library/SyncedPreferences"
        scanDirectory(dir: syncedDir, location: .synced, db: database, cutoff: cutoff, now: now, minAgeDays: minAgeDays, into: &results)

        return results.sorted {
            if $0.ageDays != $1.ageDays {
                return $0.ageDays > $1.ageDays // 闲置最久的优先展示
            }
            return $0.size > $1.size
        }
    }

    private func scanDirectory(
        dir: String,
        location: PreferenceLocationKind,
        db: OrphanScanner.InstalledDatabase,
        cutoff: Date,
        now: Date,
        minAgeDays: Int,
        into results: inout [OrphanPreferenceItem]
    ) {
        guard FileManager.default.fileExists(atPath: dir) else { return }

        for child in FileSystem.children(of: dir, keepHidden: false) where child.hasSuffix(".plist") {
            let fileName = (child as NSString).lastPathComponent
            let bundleID = Self.extractBundleID(from: fileName)

            // 系统与在用应用保护
            guard !OrphanScanner.isInstalledOrProtected(identifier: bundleID, db: db) else { continue }
            guard FileSystem.isSafeToClean(child) else { continue }

            let mdate = FileSystem.modificationDate(child)
            if let mdate = mdate, mdate >= cutoff {
                // 尚在缓冲期内，跳过
                continue
            }

            let size = FileSystem.size(at: child)
            guard size > 0 else { continue }

            let days: Int
            if let mdate = mdate {
                days = max(0, Calendar.current.dateComponents([.day], from: mdate, to: now).day ?? 0)
            } else {
                days = minAgeDays
            }

            let appName = Self.deriveDisplayName(from: bundleID)
            let item = OrphanPreferenceItem(
                appName: appName,
                bundleID: bundleID,
                fileName: fileName,
                path: child,
                size: size,
                lastModified: mdate,
                ageDays: days,
                location: location
            )
            results.append(item)
        }
    }

    // MARK: - 清理与释放

    /// 清理指定的偏好设置碎片
    func cleanPreferences(
        items: [OrphanPreferenceItem],
        toTrash: Bool = true
    ) -> (successCount: Int, failCount: Int, freedBytes: Int64) {
        var success = 0
        var fail = 0
        var freed: Int64 = 0

        for item in items {
            guard FileManager.default.fileExists(atPath: item.path) else { continue }
            let fileSize = item.size

            if toTrash {
                do {
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &resultingURL)
                    success += 1
                    freed += fileSize
                } catch {
                    fail += 1
                }
            } else {
                do {
                    try FileManager.default.removeItem(atPath: item.path)
                    success += 1
                    freed += fileSize
                } catch {
                    fail += 1
                }
            }
        }

        return (success, fail, freed)
    }
}
