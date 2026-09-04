import Foundation
import AppKit

// MARK: - 已安装 App（供卸载器）

struct InstalledApp: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let bundleID: String?
    let size: Int64

    var isSystemApp: Bool { bundleID?.hasPrefix("com.apple.") == true }
    /// MED-2（终检）：实时查询运行态，不依赖进程启动时的静态快照
    var isRunning: Bool {
        guard let bundleID else { return false }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

// MARK: - 关联文件（App 卸载器扫描结果）

struct RelatedFile: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let kind: String   // 所属类别：Application Support / Preferences / Caches / Containers / Logs ...
    var isSelected: Bool = false
}

// MARK: - 卸载器状态

final class UninstallerState: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var selectedApp: InstalledApp?
    @Published var related: [RelatedFile] = []
    @Published var isScanning = false
    @Published var lastSummary: String?
    @Published var isUninstalling = false

    func loadApps() {
        // 三巡：置 isScanning 避免首次进入闪现"未发现可卸载 App"空态
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apps = UninstallerScanner.scanApps()
            DispatchQueue.main.async {
                self?.apps = apps
                self?.isScanning = false
            }
        }
    }

    func select(_ app: InstalledApp?) {
        selectedApp = app
        related = []
        lastSummary = nil
        guard let app, !app.isRunning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = UninstallerScanner.relatedFiles(for: app)
            DispatchQueue.main.async {
                self?.related = files
                self?.isScanning = false
            }
        }
    }

    var selectedFiles: [RelatedFile] { related.filter { $0.isSelected } }
    var selectedCount: Int { selectedFiles.count }
    var selectedSize: Int64 { selectedFiles.reduce(0) { $0 + $1.size } }
    var allSelected: Bool { !related.isEmpty && related.allSatisfy { $0.isSelected } }

    func toggle(_ fileID: UUID, _ on: Bool) {
        guard let idx = related.firstIndex(where: { $0.id == fileID }) else { return }
        var new = related
        new[idx].isSelected = on
        related = new   // 整体赋值触发 @Published
    }

    func setAllSelected(_ on: Bool) {
        related = related.map { var f = $0; f.isSelected = on; return f }
    }

    /// 卸载勾选的关联文件（默认移入废纸篓；已在废纸篓语义的项强制删除由 Cleaner 处理）
    func uninstallSelected(permanently: Bool) -> Bool {
        let files = selectedFiles
        guard !files.isEmpty, !isUninstalling else { return false }
        isUninstalling = true
        let items = files.map {
            CleanItem(name: $0.name, path: $0.path, size: $0.size, risk: .review,
                      category: .appResidue, note: "\($0.kind) · App 卸载残留")
        }
        // L5（数据层审查）：避免主线程同步执行大目录 trashItem 阻塞 UI——后台执行 + 主线程回写
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Cleaner.clean(items, permanently: permanently) { _ in }
            DispatchQueue.main.async {
                guard let self else { return }
                let failed = result.failedPaths
                let done = Set(files.map(\.id))
                // #1（二轮）：filter 保留快照外新勾选项（卸载期间用户勾选的新文件不被误移）
                self.related = self.related.map { f in
                    guard f.isSelected, done.contains(f.id) else { return f }
                    if failed.contains(f.path) {
                        var copy = f
                        copy.isSelected = false
                        return copy
                    }
                    return f
                }.filter { !$0.isSelected || !done.contains($0.id) }
                self.isUninstalling = false
                var parts = ["已卸载 \(result.succeeded) 项，释放 \(result.releasedBytes.byteStringCN)"]
                if !result.failures.isEmpty { parts.append("\(result.failures.count) 项失败") }
                self.lastSummary = parts.joined(separator: "，")
            }
        }
        return true
    }
}

// MARK: - 卸载器扫描（借鉴 PureMac 匹配思路的简化实现）

enum UninstallerScanner {

    /// 扫描已安装 App（排除系统 App；含 /Applications、~/Applications）
    static func scanApps() -> [InstalledApp] {
        var apps: [InstalledApp] = []
        for dir in ["/Applications", "~/Applications"] {
            let dirPath = CleanPaths.expand(dir)
            for child in FileSystem.children(of: dirPath) where child.hasSuffix(".app") {
                let name = (child as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                let plist = (child as NSString).appendingPathComponent("Contents/Info.plist")
                let bundleID = (NSDictionary(contentsOfFile: plist)?["CFBundleIdentifier"] as? String)
                let app = InstalledApp(name: name, path: child, bundleID: bundleID,
                                       size: FileSystem.size(at: child))
                if !app.isSystemApp { apps.append(app) }
            }
        }
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// 查找某 App 的全部关联文件（简化版 10 级匹配：bundle id + 名称）
    static func relatedFiles(for app: InstalledApp) -> [RelatedFile] {
        let home = NSHomeDirectory()
        let bundle = app.bundleID
        let normName = normalize(app.name)
        var results: [RelatedFile] = []
        var seen = Set<String>()

        func add(_ path: String, kind: String) {
            let expanded = CleanPaths.expand(path)
            guard FileManager.default.fileExists(atPath: expanded),
                  FileSystem.isSafeToClean(expanded),
                  !seen.contains(expanded) else { return }
            seen.insert(expanded)
            let size = FileSystem.size(at: expanded)
            if size > 0 {
                results.append(RelatedFile(
                    name: (expanded as NSString).lastPathComponent,
                    path: expanded, size: size, kind: kind))
            }
        }

        // 1) Preferences：bundle id 前缀（含 helper：com.xxx.app.helper.plist）
        if let bundle {
            for child in FileSystem.children(of: "\(home)/Library/Preferences", keepHidden: false)
            where child.hasSuffix(".plist") {
                let file = (child as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
                if file == bundle || file.hasPrefix(bundle + ".") {
                    add(child, kind: "Preferences")
                }
            }
        }

        // 2) Caches / Containers / HTTPStorages / WebKit / Saved Application State：bundle id
        if let bundle {
            for (root, kind) in [
                ("\(home)/Library/Caches", "Caches"),
                ("\(home)/Library/Containers", "Containers"),
                ("\(home)/Library/HTTPStorages", "HTTPStorages"),
                ("\(home)/Library/WebKit", "WebKit"),
                ("\(home)/Library/Saved Application State", "Saved State"),
            ] {
                for child in FileSystem.children(of: root) {
                    let name = (child as NSString).lastPathComponent
                    if name == bundle || name.hasPrefix(bundle + ".") {
                        add(child, kind: kind)
                    }
                }
            }
        }

        // 3) Application Support / Logs：名称匹配（N5：收紧防误删他 App 数据）
        // 只允许「目录名 == app 名」或「目录名包含完整 app 名」——
        // 不允许短 vendor 目录（Google/Microsoft）因"app 名包含它"被整体列入
        // LOW-5（终检）：Group Containers 中 iCloud 系统容器（group.com.apple.*）永远白名单跳过
        for (root, kind) in [
            ("\(home)/Library/Application Support", "Application Support"),
            ("\(home)/Library/Logs", "Logs"),
            ("\(home)/Library/Group Containers", "Group Containers"),
        ] {
            for child in FileSystem.children(of: root) {
                let dirName = (child as NSString).lastPathComponent
                if dirName.hasPrefix(".") { continue }
                // iCloud 系统组容器（Notes/Calendar 等）不与任何第三方 App 卸载关联
                if kind == "Group Containers", dirName.hasPrefix("group.com.apple.") { continue }
                let norm = normalize(dirName)
                guard norm.count >= 3 else { continue }
                // 等价：app 名 == 目录名；或目录名包含完整 app 名（含分隔符边界）
                if norm == normName {
                    add(child, kind: kind)
                } else if norm.count > normName.count, norm.contains(normName) {
                    add(child, kind: kind)
                }
            }
        }

        // 4) LaunchAgents：ProgramArguments 指向该 App
        for child in FileSystem.children(of: "\(home)/Library/LaunchAgents", keepHidden: false)
        where child.hasSuffix(".plist") {
            if let dict = NSDictionary(contentsOfFile: child),
               let args = dict["ProgramArguments"] as? [String],
               args.contains(where: { $0 == app.path || $0.hasPrefix(app.path + "/") }) {
                add(child, kind: "LaunchAgents")
            }
        }

        return results.sorted { $0.size > $1.size }
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "")
    }
}
