import Foundation
import Combine

/// 目录节点勾选三态
enum DirectoryCheckState: Equatable {
    case all     // 全部勾选
    case none    // 全部未勾选
    case mixed   // 部分勾选
}

/// 目录树节点（支持递归包含、自底向上容量汇总与三态勾选）
struct DirectoryTreeNode: Identifiable, Equatable {
    let id: UUID
    let path: String              // 完整目录路径（如 /Users/xxx/Downloads/Videos）
    let displayName: String       // 展示名称（如 Videos 或 ~/Downloads）
    var totalBytes: Int64         // 当前目录及所有子目录下匹配文件的总大小
    var fileCount: Int            // 当前目录及所有子目录下匹配文件的总数量
    var checkState: DirectoryCheckState // 三态勾选
    var isExpanded: Bool          // 节点是否展开
    var children: [DirectoryTreeNode] // 子目录节点（按体积从大到小排序）

    init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        totalBytes: Int64 = 0,
        fileCount: Int = 0,
        checkState: DirectoryCheckState = .none,
        isExpanded: Bool = false,
        children: [DirectoryTreeNode] = []
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.totalBytes = totalBytes
        self.fileCount = fileCount
        self.checkState = checkState
        self.isExpanded = isExpanded
        self.children = children
    }
}

/// 目录树构建引擎（将平铺文件集合解析为多层级目录树并计算汇总指标）
enum DirectoryTreeBuilder {

    /// 待聚合的文件条目
    struct FileEntry {
        let path: String
        let size: Int64
        let isSelected: Bool
    }

    /// 内部建树中间结构
    private class MutableNode {
        let path: String
        let name: String
        var directBytes: Int64 = 0
        var directFiles: Int = 0
        var selectedCount: Int = 0
        var unselectedCount: Int = 0
        var subdirectories: [String: MutableNode] = [:]

        init(path: String, name: String) {
            self.path = path
            self.name = name
        }

        func toImmutable(defaultExpandedLevel: Int, currentDepth: Int = 0) -> DirectoryTreeNode {
            var totalBytes = directBytes
            var fileCount = directFiles
            var totalSelected = selectedCount
            var totalUnselected = unselectedCount

            var childNodes: [DirectoryTreeNode] = []
            for (_, child) in subdirectories {
                let immutableChild = child.toImmutable(defaultExpandedLevel: defaultExpandedLevel, currentDepth: currentDepth + 1)
                totalBytes += immutableChild.totalBytes
                fileCount += immutableChild.fileCount
                childNodes.append(immutableChild)
                // 累计子项的选择统计
                switch immutableChild.checkState {
                case .all:
                    totalSelected += immutableChild.fileCount
                case .none:
                    totalUnselected += immutableChild.fileCount
                case .mixed:
                    totalSelected += 1
                    totalUnselected += 1
                }
            }

            // 按占用空间从大到小排序子目录
            childNodes.sort { $0.totalBytes > $1.totalBytes }

            let checkState: DirectoryCheckState
            if fileCount == 0 || (totalSelected == 0 && totalUnselected == 0) {
                checkState = .none
            } else if totalSelected > 0 && totalUnselected == 0 {
                checkState = .all
            } else if totalSelected == 0 && totalUnselected > 0 {
                checkState = .none
            } else {
                checkState = .mixed
            }

            let isExpanded = currentDepth < defaultExpandedLevel

            return DirectoryTreeNode(
                path: path,
                displayName: name,
                totalBytes: totalBytes,
                fileCount: fileCount,
                checkState: checkState,
                isExpanded: isExpanded,
                children: childNodes
            )
        }
    }

    /// 将任意文件列表解析为层级目录树
    static func buildTree(
        from entries: [FileEntry],
        defaultExpandedLevel: Int = 1
    ) -> [DirectoryTreeNode] {
        guard !entries.isEmpty else { return [] }

        let homeDir = CleanPaths.expand("~")
        var mutableRoots: [String: MutableNode] = [:]

        for entry in entries {
            let dirPath = (entry.path as NSString).deletingLastPathComponent
            guard !dirPath.isEmpty && dirPath != "/" else { continue }

            // 拆解路径组件
            let (rootKey, relativeComponents) = extractRootAndRelative(dirPath: dirPath, homeDir: homeDir)

            let rootNode = mutableRoots[rootKey] ?? {
                let displayName = rootKey == homeDir ? "~" : (rootKey.hasPrefix(homeDir) ? rootKey.replacingOccurrences(of: homeDir, with: "~") : rootKey)
                let node = MutableNode(path: rootKey, name: displayName)
                mutableRoots[rootKey] = node
                return node
            }()

            var current = rootNode
            var currentAccumPath = rootKey

            for comp in relativeComponents {
                currentAccumPath = (currentAccumPath as NSString).appendingPathComponent(comp)
                let next = current.subdirectories[comp] ?? {
                    let n = MutableNode(path: currentAccumPath, name: comp)
                    current.subdirectories[comp] = n
                    return n
                }()
                current = next
            }

            // 记录该目录下的直接文件指标
            current.directBytes += entry.size
            current.directFiles += 1
            if entry.isSelected {
                current.selectedCount += 1
            } else {
                current.unselectedCount += 1
            }
        }

        var result = mutableRoots.values.map {
            $0.toImmutable(defaultExpandedLevel: defaultExpandedLevel, currentDepth: 0)
        }
        result.sort { $0.totalBytes > $1.totalBytes }
        return result
    }

    /// 提取逻辑根目录与相对层级
    private static func extractRootAndRelative(dirPath: String, homeDir: String) -> (root: String, relatives: [String]) {
        // 如果是用户主目录下的标准子目录（如 ~/Downloads, ~/Pictures, ~/Documents, ~/Desktop 等），以该标准目录为顶层
        let standardNames = ["Downloads", "Pictures", "Documents", "Desktop", "Movies", "Music", "Library"]
        for std in standardNames {
            let prefix = (homeDir as NSString).appendingPathComponent(std)
            if dirPath == prefix {
                return (prefix, [])
            } else if dirPath.hasPrefix(prefix + "/") {
                let relative = String(dirPath.dropFirst(prefix.count + 1))
                let comps = relative.split(separator: "/").map(String.init)
                return (prefix, comps)
            }
        }

        if dirPath.hasPrefix(homeDir + "/") {
            let relative = String(dirPath.dropFirst(homeDir.count + 1))
            let comps = relative.split(separator: "/").map(String.init)
            if let first = comps.first {
                let root = (homeDir as NSString).appendingPathComponent(first)
                return (root, Array(comps.dropFirst()))
            }
            return (homeDir, comps)
        }

        // 外部路径（如 /Applications, /tmp, /Volumes/xxx）
        let comps = dirPath.split(separator: "/").map(String.init)
        if comps.count >= 2 {
            let root = "/" + comps[0] + "/" + comps[1]
            return (root, Array(comps.dropFirst(2)))
        } else if comps.count == 1 {
            return ("/" + comps[0], [])
        }
        return (dirPath, [])
    }
}

/// 扫描目录范围与排除项管理器（持久化管理自定义根目录与子目录排除名单）
final class DirectoryScopeManager: ObservableObject {
    static let shared = DirectoryScopeManager()

    private let customRootsKey = "MacClean_CustomSearchRoots"
    private let excludedPathsKey = "MacClean_ExcludedSearchPaths"

    /// 预设默认扫描目录
    static let defaultSearchRoots: [String] = [
        "~/Downloads",
        "~/Pictures",
        "~/Documents",
        "~/Desktop"
    ]

    /// 当前激活的扫描根目录集合
    @Published var searchRoots: [String] {
        didSet { saveConfig() }
    }

    /// 当前被排除的子路径集合
    @Published var excludedPaths: Set<String> {
        didSet { saveConfig() }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let savedRoots = defaults.stringArray(forKey: customRootsKey), !savedRoots.isEmpty {
            self.searchRoots = savedRoots
        } else {
            self.searchRoots = DirectoryScopeManager.defaultSearchRoots
        }

        if let savedExcluded = defaults.stringArray(forKey: excludedPathsKey) {
            self.excludedPaths = Set(savedExcluded)
        } else {
            self.excludedPaths = []
        }
    }

    /// 展开为绝对路径的根目录列表
    var expandedRoots: [String] {
        searchRoots.map { CleanPaths.expand($0) }
    }

    /// 判断指定文件或文件夹是否在排除名单中（或在其任一已排除父目录下）
    func isPathExcluded(_ path: String) -> Bool {
        guard !excludedPaths.isEmpty else { return false }
        let expanded = CleanPaths.expand(path)
        for excluded in excludedPaths {
            let expExcluded = CleanPaths.expand(excluded)
            if expanded == expExcluded || expanded.hasPrefix(expExcluded + "/") {
                return true
            }
        }
        return false
    }

    /// 添加自定义根目录
    func addRootPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let display = trimmed.hasPrefix(CleanPaths.expand("~")) ? trimmed.replacingOccurrences(of: CleanPaths.expand("~"), with: "~") : trimmed
        if !searchRoots.contains(display) {
            searchRoots.append(display)
        }
    }

    /// 移除根目录
    func removeRootPath(_ path: String) {
        searchRoots.removeAll { $0 == path || CleanPaths.expand($0) == CleanPaths.expand(path) }
    }

    /// 切换某个子路径的排除状态
    func togglePathExcluded(_ path: String) {
        let cleanPath = CleanPaths.expand(path)
        if excludedPaths.contains(cleanPath) {
            excludedPaths.remove(cleanPath)
        } else {
            excludedPaths.insert(cleanPath)
        }
    }

    /// 显式设置排除状态
    func setPathExcluded(_ path: String, excluded: Bool) {
        let cleanPath = CleanPaths.expand(path)
        if excluded {
            excludedPaths.insert(cleanPath)
        } else {
            excludedPaths.remove(cleanPath)
        }
    }

    /// 重置为出厂预设
    func resetToDefaults() {
        searchRoots = DirectoryScopeManager.defaultSearchRoots
        excludedPaths = []
    }

    private func saveConfig() {
        UserDefaults.standard.set(searchRoots, forKey: customRootsKey)
        UserDefaults.standard.set(Array(excludedPaths), forKey: excludedPathsKey)
    }
}
