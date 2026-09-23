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

    /// 清理一批勾选的构建产物。
    ///
    /// 旧实现在这里绕开网关自己动删除调用：删完既不写历史也不留撤销快照（DerivedData
    /// 动辄几十 GB，用户清完整个人没有回退路径），废纸篓落点也传了 `nil` 丢掉；
    /// 护栏是三条自写的字符串检查，其中主目录那条只比了前缀、没带路径分隔符，
    /// `/Users/testa/...` 会被当成"在自家目录内"。
    /// 现在统一交给 `ResidueDeletionGate`：软链解析后的真实位置判定、G8/G6/用户白名单、
    /// 删除前实测体积、逐项拒绝原因与可撤销记录一次到位。
    func cleanOutcome(_ artifacts: [DevProjectArtifact], permanently: Bool = false,
                      journal: ResidueDeletionGate.Journal = .module(categoryName: "开发工程产物"))
        -> ResidueDeletionGate.Outcome {
        // DerivedData 根解析一次：旧版用 `path.contains("/DerivedData/")` 判，
        // 任何工程里一个叫 DerivedData 的目录都能蒙过放行；这里只认 Xcode 那个真身。
        let derivedDataRoot = FileSystem.normalizePath(
            FileSystem.realPath(CleanPaths.expand(CleanPaths.derivedData)))

        return ResidueDeletionGate.execute(
            artifacts.map { ResidueDeletionGate.Candidate($0.name, path: $0.path) },
            toTrash: !permanently,
            journal: journal,
            policy: { candidate in
                // ① 只认登记的产物目录名，或确实位于 Xcode DerivedData **之下**
                //    （不含等号：域根本身永不授权删，与偏好碎片模块同口径）
                let dirName = (candidate.path as NSString).lastPathComponent
                let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))
                let underDerivedData = real.hasPrefix(derivedDataRoot + "/")
                guard DevArtifactKind.allowedDirNames.contains(dirName) || underDerivedData else {
                    return .make(candidate, reason: .notDeletable,
                                 message: "「\(dirName)」不是登记的构建产物目录，可能含源码，未删除")
                }
                // ② 产物必须是目录：同名的源码文件（`dist`、`build`）一律不删
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: real, isDirectory: &isDir), isDir.boolValue else {
                    return .make(candidate, reason: .notDeletable, message: "不是产物目录本体，未删除")
                }
                return nil
            })
    }

    /// 按网关实测删除结果同步内存列表。**必须在主线程调用**——旧实现把它包在
    /// `DispatchQueue.main.async` 里、却同时在后台遍历 `projects`，两处线程交错。
    func pruneCleanedArtifacts(_ cleanedRealPaths: [String]) {
        let cleaned = Set(cleanedRealPaths)
        for idx in projects.indices {
            projects[idx].artifacts.removeAll { cleaned.contains(FileSystem.normalizePath(FileSystem.realPath($0.path))) }
        }
        projects.removeAll { $0.artifacts.isEmpty }
    }
}
