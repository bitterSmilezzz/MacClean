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

    /// 本模块唯一可删的三类位置，与 `scanOrphanPreferences` 的扫描根同集合。
    /// 暴露出来是为了让"能扫到"与"能删掉"两处口径不可能各写一份。
    static func preferenceRoots(home: String = NSHomeDirectory()) -> [String] {
        ["Library/Preferences", "Library/Preferences/ByHost", "Library/SyncedPreferences"]
            .map { FileSystem.normalizePath(FileSystem.realPath(home + "/" + $0)) }
    }

    /// 清理指定的偏好设置碎片。
    ///
    /// 旧实现是全仓**唯一一处连基础护栏都没有**的删除：只 `fileExists` 就动手，
    /// 既不过 `isSafeToClean` 也不过网关 → G8 系统硬保护、G6 用户数据硬排除、
    /// 你在设置里加的白名单对这条路径**完全失效**；`freed` 累加的是扫描时缓存的
    /// `item.size`（读到 0 也照计成功）；删完不写历史与撤销快照。
    /// 而它的调用方是 App 卸载器——用户点"卸载"时顺带清掉的正是偏好文件本身。
    func cleanOutcome(items: [OrphanPreferenceItem], toTrash: Bool = true,
                      home: String = NSHomeDirectory(),
                      journal: ResidueDeletionGate.Journal = .module(categoryName: "偏好残留"))
        -> ResidueDeletionGate.Outcome {
        let roots = Self.preferenceRoots(home: home)
        return ResidueDeletionGate.execute(
            items.map { ResidueDeletionGate.Candidate($0.fileName, path: $0.path) },
            toTrash: toTrash,
            journal: journal,
            policy: { candidate in
                // 本模块只清 plist 碎片：目录、其它扩展名一律不碰
                guard (candidate.path as NSString).pathExtension.lowercased() == "plist" else {
                    return .make(candidate, reason: .notDeletable,
                                 message: "不是 .plist 偏好文件，本模块不清理")
                }
                let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue else {
                    return .make(candidate, reason: .notDeletable, message: "不是偏好文件本体（目录不递归删），未删除")
                }
                guard roots.contains(where: { real.hasPrefix($0 + "/") }) else {
                    return .make(candidate, reason: .outsideDomain,
                                 message: "解析后的真实位置不在已登记的三类偏好根内，未删除")
                }
                return nil
            })
    }

    func cleanPreferences(
        items: [OrphanPreferenceItem],
        toTrash: Bool = true,
        home: String = NSHomeDirectory(),
        journal: ResidueDeletionGate.Journal = .module(categoryName: "偏好残留")
    ) -> (successCount: Int, failCount: Int, freedBytes: Int64) {
        let outcome = cleanOutcome(items: items, toTrash: toTrash, home: home, journal: journal)
        // `failCount` 现在含"被护栏拦下"的项：只报成功数会让用户以为剩下的也处理了
        return (outcome.cleanedCount, outcome.errorCount, outcome.freedBytes)
    }
}
