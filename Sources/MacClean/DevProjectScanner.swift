import Foundation
import Combine
import SwiftUI

/// 开发工程构建产物深度排查与治理引擎
public final class DevProjectScanner: ObservableObject {
    public static let shared = DevProjectScanner()

    @Published public var projects: [DevProject] = []
    @Published public var isScanning: Bool = false
    @Published public var lastScanDate: Date? = nil

    private init() {}

    /// 常见工程根目录候选列表
    public static let defaultWorkspaceRoots: [String] = [
        "~/workspace",
        "~/Projects",
        "~/Developer",
        "~/Documents/GitHub",
        "~/Documents/Projects",
        "~/Code",
        "~/dev",
        "~/src",
        "~/github"
    ]

    // MARK: - 主扫描入口

    /// 扫描全量开发工程与构建产物
    @discardableResult
    public func scan(roots: [String]? = nil) -> [DevProject] {
        isScanning = true
        defer {
            isScanning = false
            lastScanDate = Date()
        }

        var projectMap: [String: DevProject] = [:] // path -> DevProject

        // 1. 扫描 Xcode DerivedData 并反查工程路径
        let derivedDataProjects = scanDerivedData()
        for p in derivedDataProjects {
            projectMap[p.path] = p
        }

        // 2. 扫描工作区代码目录下的多语言工程产物
        let targetRoots = roots ?? Self.defaultWorkspaceRoots
        let workspaceProjects = scanWorkspaceRoots(targetRoots)

        // 3. 聚合合并（若相同工程既有 DerivedData 又有本地 target/.build，合并至同一卡片）
        for wp in workspaceProjects {
            let normalizedPath = (wp.path as NSString).standardizingPath
            if var existing = projectMap[normalizedPath] {
                // 合并技术栈
                for t in wp.types where !existing.types.contains(t) {
                    existing.types.append(t)
                }
                // 合并修改时间
                if let newDate = wp.lastModified {
                    if let oldDate = existing.lastModified {
                        existing.lastModified = max(oldDate, newDate)
                    } else {
                        existing.lastModified = newDate
                    }
                }
                // 合并产物
                for art in wp.artifacts {
                    if !existing.artifacts.contains(where: { $0.path == art.path }) {
                        existing.artifacts.append(art)
                    }
                }
                existing.isOrphan = false
                projectMap[normalizedPath] = existing
            } else {
                projectMap[normalizedPath] = wp
            }
        }

        // 4. 过滤空产物工程，按占用体积从大到小排序
        let result = projectMap.values
            .filter { $0.totalArtifactSize > 0 }
            .sorted { a, b in
                if a.isOrphan != b.isOrphan {
                    return a.isOrphan // 孤儿产物排前面
                }
                return a.totalArtifactSize > b.totalArtifactSize
            }

        DispatchQueue.main.async {
            self.projects = result
        }
        return result
    }

    // MARK: - DerivedData 逆向工程匹配

    /// 扫描 DerivedData 子目录并读取 info.plist 反查源工程
    public func scanDerivedData() -> [DevProject] {
        var list: [DevProject] = []
        let ddPath = CleanPaths.expand(CleanPaths.derivedData)
        guard FileSystem.isDir(ddPath) else { return [] }

        let subdirs = FileSystem.subdirs(of: ddPath)
        for dir in subdirs {
            guard FileSystem.isSafeToClean(dir) else { continue }
            let size = FileSystem.size(at: dir)
            guard size > 0 else { continue }

            let dirName = (dir as NSString).lastPathComponent
            let infoPlistPath = (dir as NSString).appendingPathComponent("info.plist")

            var workspacePath: String?
            var lastAccessed: Date?

            if let dict = NSDictionary(contentsOfFile: infoPlistPath) {
                workspacePath = dict["WorkspacePath"] as? String
                lastAccessed = dict["LastAccessedDate"] as? Date
            }

            let artifact = DevProjectArtifact(
                name: "Xcode DerivedData",
                path: dir,
                size: size,
                kind: .derivedData,
                isSelected: true
            )

            if let ws = workspacePath, !ws.isEmpty {
                let wsClean = CleanPaths.expand(ws)
                let exists = FileManager.default.fileExists(atPath: wsClean)
                let projName = deriveProjectName(from: wsClean)
                let mdate = lastAccessed ?? FileSystem.modificationDate(wsClean) ?? FileSystem.modificationDate(dir)

                let project = DevProject(
                    id: wsClean,
                    name: projName,
                    path: wsClean,
                    types: [.xcode],
                    lastModified: mdate,
                    isOrphan: !exists,
                    artifacts: [artifact]
                )
                list.append(project)
            } else {
                // 没有 info.plist，基于目录名提取工程名前缀 (如 MacClean-abcdef...)
                let prefix = dirName.components(separatedBy: "-").first ?? dirName
                let mdate = lastAccessed ?? FileSystem.modificationDate(dir)

                let project = DevProject(
                    id: dir,
                    name: prefix,
                    path: dir,
                    types: [.xcode],
                    lastModified: mdate,
                    isOrphan: false,
                    artifacts: [artifact]
                )
                list.append(project)
            }
        }
        return list
    }

    // MARK: - 工作区工程探测

    /// 遍历指定工作区根目录，深潜发现代码工程及产物
    public func scanWorkspaceRoots(_ roots: [String]) -> [DevProject] {
        var list: [DevProject] = []
        var visitedPaths = Set<String>()

        for root in roots {
            let expRoot = CleanPaths.expand(root)
            guard FileSystem.isDir(expRoot) else { continue }

            // 深度 ≤ 3 遍历寻找工程根目录
            exploreProjects(in: expRoot, currentDepth: 1, maxDepth: 3, visited: &visitedPaths, results: &list)
        }
        return list
    }

    private func exploreProjects(in directory: String,
                                 currentDepth: Int,
                                 maxDepth: Int,
                                 visited: inout Set<String>,
                                 results: inout [DevProject]) {
        guard currentDepth <= maxDepth else { return }
        guard !visited.contains(directory) else { return }
        visited.insert(directory)

        // 检查当前目录是否为工程根目录
        if let proj = inspectProject(at: directory) {
            results.append(proj)
            // 如果已经是工程根，不需要再向其内部子目录递归寻找子工程
            return
        }

        // 否则继续枚举子目录
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { return }

        for entry in entries {
            // 跳过隐藏目录、系统保护目录以及已知的产物目录
            if entry.hasPrefix(".") || entry == "Pods" || entry == "vendor" || entry == "Library" {
                continue
            }
            let subPath = (directory as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue {
                exploreProjects(in: subPath, currentDepth: currentDepth + 1, maxDepth: maxDepth, visited: &visited, results: &results)
            }
        }
    }

    /// 探测特定目录下是否存在工程特征文件与构建产物
    public func inspectProject(at directory: String) -> DevProject? {
        let fm = FileManager.default
        var types: [DevProjectType] = []
        var artifacts: [DevProjectArtifact] = []

        let cargoToml = (directory as NSString).appendingPathComponent("Cargo.toml")
        let packageSwift = (directory as NSString).appendingPathComponent("Package.swift")
        let packageJson = (directory as NSString).appendingPathComponent("package.json")
        let buildGradle = (directory as NSString).appendingPathComponent("build.gradle")
        let buildGradleKts = (directory as NSString).appendingPathComponent("build.gradle.kts")
        let pomXml = (directory as NSString).appendingPathComponent("pom.xml")
        let pyprojectToml = (directory as NSString).appendingPathComponent("pyproject.toml")
        let requirementsTxt = (directory as NSString).appendingPathComponent("requirements.txt")
        let goMod = (directory as NSString).appendingPathComponent("go.mod")

        // 1. Rust Cargo
        if fm.fileExists(atPath: cargoToml) {
            types.append(.rust)
            let targetDir = (directory as NSString).appendingPathComponent("target")
            if fm.fileExists(atPath: targetDir), FileSystem.isSafeToClean(targetDir) {
                let sz = FileSystem.size(at: targetDir)
                if sz > 0 {
                    artifacts.append(DevProjectArtifact(name: "target (Cargo 编译产物)", path: targetDir, size: sz, kind: .rustTarget))
                }
            }
        }

        // 2. SwiftPM
        if fm.fileExists(atPath: packageSwift) {
            types.append(.swiftpm)
            let buildDir = (directory as NSString).appendingPathComponent(".build")
            if fm.fileExists(atPath: buildDir), FileSystem.isSafeToClean(buildDir) {
                let sz = FileSystem.size(at: buildDir)
                if sz > 0 {
                    artifacts.append(DevProjectArtifact(name: ".build (SwiftPM 构建产物)", path: buildDir, size: sz, kind: .swiftpmBuild))
                }
            }
        }

        // 3. Node.js / 前端
        if fm.fileExists(atPath: packageJson) {
            types.append(.node)
            let nodeModules = (directory as NSString).appendingPathComponent("node_modules")
            if fm.fileExists(atPath: nodeModules), FileSystem.isSafeToClean(nodeModules) {
                let sz = FileSystem.size(at: nodeModules)
                if sz > 0 {
                    artifacts.append(DevProjectArtifact(name: "node_modules (依赖库)", path: nodeModules, size: sz, kind: .nodeModules))
                }
            }
            for cacheName in [".next", ".nuxt", ".turbo"] {
                let cacheDir = (directory as NSString).appendingPathComponent(cacheName)
                if fm.fileExists(atPath: cacheDir), FileSystem.isSafeToClean(cacheDir) {
                    let sz = FileSystem.size(at: cacheDir)
                    if sz > 0 {
                        artifacts.append(DevProjectArtifact(name: "\(cacheName) (构建缓存)", path: cacheDir, size: sz, kind: .frontendCache))
                    }
                }
            }
        }

        // 4. Gradle / Maven
        if fm.fileExists(atPath: buildGradle) || fm.fileExists(atPath: buildGradleKts) || fm.fileExists(atPath: pomXml) {
            types.append(.gradle)
            let gradleBuild = (directory as NSString).appendingPathComponent("build")
            if fm.fileExists(atPath: gradleBuild), FileSystem.isSafeToClean(gradleBuild) {
                let sz = FileSystem.size(at: gradleBuild)
                if sz > 0 {
                    artifacts.append(DevProjectArtifact(name: "build (Gradle 产物)", path: gradleBuild, size: sz, kind: .gradleBuild))
                }
            }
            let dotGradle = (directory as NSString).appendingPathComponent(".gradle")
            if fm.fileExists(atPath: dotGradle), FileSystem.isSafeToClean(dotGradle) {
                let sz = FileSystem.size(at: dotGradle)
                if sz > 0 {
                    artifacts.append(DevProjectArtifact(name: ".gradle (本地缓存)", path: dotGradle, size: sz, kind: .gradleBuild))
                }
            }
        }

        // 5. Python
        if fm.fileExists(atPath: pyprojectToml) || fm.fileExists(atPath: requirementsTxt) {
            types.append(.python)
            for venvName in [".venv", "venv"] {
                let venvDir = (directory as NSString).appendingPathComponent(venvName)
                if fm.fileExists(atPath: venvDir), FileSystem.isSafeToClean(venvDir) {
                    let sz = FileSystem.size(at: venvDir)
                    if sz > 0 {
                        artifacts.append(DevProjectArtifact(name: "\(venvName) (虚拟环境)", path: venvDir, size: sz, kind: .pythonVenv))
                    }
                }
            }
        }

        // 6. Go
        if fm.fileExists(atPath: goMod) {
            types.append(.golang)
        }

        // 如果没有匹配任何工程特征，且没有任何产物，返回 nil
        guard !types.isEmpty || !artifacts.isEmpty else { return nil }

        let projName = (directory as NSString).lastPathComponent
        let mdate = detectProjectActivityDate(at: directory)

        return DevProject(
            id: directory,
            name: projName,
            path: directory,
            types: types,
            lastModified: mdate,
            isOrphan: false,
            artifacts: artifacts
        )
    }

    /// 读取工程最近活动时间（优先读取 .git 状态，其次读取工程根目录或源码 mtime）
    public func detectProjectActivityDate(at directory: String) -> Date {
        let fm = FileManager.default
        let gitDir = (directory as NSString).appendingPathComponent(".git")

        if fm.fileExists(atPath: gitDir) {
            let head = (gitDir as NSString).appendingPathComponent("HEAD")
            let index = (gitDir as NSString).appendingPathComponent("index")
            let dHead = FileSystem.modificationDate(head)
            let dIndex = FileSystem.modificationDate(index)

            if let d1 = dHead, let d2 = dIndex {
                return max(d1, d2)
            } else if let d = dHead ?? dIndex {
                return d
            }
        }

        return FileSystem.modificationDate(directory) ?? Date()
    }

    private func deriveProjectName(from path: String) -> String {
        let last = (path as NSString).lastPathComponent
        if last.hasSuffix(".xcodeproj") || last.hasSuffix(".xcworkspace") {
            return (last as NSString).deletingPathExtension
        }
        return last
    }

    // MARK: - 安全清理

    /// 清理单个构建产物目录
    public func cleanArtifact(_ artifact: DevProjectArtifact, permanently: Bool = false) -> (success: Bool, freedBytes: Int64) {
        let path = artifact.path
        let dirName = (path as NSString).lastPathComponent

        // 安全防线 1：必须符合产物白名单或位于 DerivedData 目录下
        guard DevArtifactKind.allowedDirNames.contains(dirName) || path.contains("/DerivedData/") else {
            return (false, 0)
        }

        // 安全防线 2：绝对不可是根路径或用户 Home
        let home = NSHomeDirectory()
        guard path != home, path != "/", path.hasPrefix(home) || path.hasPrefix("/Users/") || path.hasPrefix("/tmp") || path.hasPrefix("/private/tmp") else {
            return (false, 0)
        }

        // 安全防线 3：通用安全护栏
        guard FileSystem.isSafeToClean(path) else {
            return (false, 0)
        }

        let size = FileSystem.size(at: path)
        var ok = false

        if permanently {
            do {
                try FileManager.default.removeItem(atPath: path)
                ok = true
            } catch {
                ok = false
            }
        } else {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                ok = true
            } catch {
                ok = false
            }
        }

        if ok {
            // 从内存列表中移除已清理产物
            DispatchQueue.main.async {
                for i in 0..<self.projects.count {
                    self.projects[i].artifacts.removeAll(where: { $0.path == path })
                }
                self.projects.removeAll(where: { $0.artifacts.isEmpty })
            }
            return (true, size)
        }
        return (false, 0)
    }

    /// 批量清理某个工程下的所有选中产物
    public func cleanProject(_ project: DevProject, permanently: Bool = false) -> (success: Bool, freedBytes: Int64) {
        var totalFreed: Int64 = 0
        var allOk = true

        let selected = project.artifacts.filter(\.isSelected)
        for art in selected {
            let res = cleanArtifact(art, permanently: permanently)
            if res.success {
                totalFreed += res.freedBytes
            } else {
                allOk = false
            }
        }
        return (allOk, totalFreed)
    }
}
