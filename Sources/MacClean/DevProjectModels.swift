import Foundation
import SwiftUI

// MARK: - 工程技术栈类型

/// 开发工程的技术栈分类
public enum DevProjectType: String, CaseIterable, Codable, Identifiable {
    case xcode = "Xcode / Swift"
    case rust = "Rust Cargo"
    case swiftpm = "SwiftPM"
    case node = "Node.js / 前端"
    case gradle = "Gradle / Java"
    case python = "Python"
    case golang = "Go"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .xcode: return "hammer.fill"
        case .rust: return "gearshape.2.fill"
        case .swiftpm: return "swift"
        case .node: return "shippingbox.fill"
        case .gradle: return "cup.and.saucer.fill"
        case .python: return "ant.fill"
        case .golang: return "network"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .xcode: return Color.blue
        case .rust: return Color.orange
        case .swiftpm: return Color.red
        case .node: return Color.green
        case .gradle: return Color.purple
        case .python: return Color.yellow
        case .golang: return Color.cyan
        }
    }
}

// MARK: - 构建产物细分类别

/// 开发构建产物的具体种类
public enum DevArtifactKind: String, CaseIterable, Codable, Identifiable {
    case derivedData = "Xcode 派生产物"
    case rustTarget = "Cargo 编译目录 (target)"
    case swiftpmBuild = "SwiftPM 构建产物 (.build)"
    case nodeModules = "Node 依赖库 (node_modules)"
    case frontendCache = "前端框架缓存 (.next / .nuxt / .turbo)"
    case gradleBuild = "Gradle 构建产物 (build / .gradle)"
    case pythonVenv = "Python 虚拟环境 (.venv / venv)"
    case generalBuild = "通用构建输出 (dist / build)"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .derivedData: return "hammer"
        case .rustTarget: return "gearshape"
        case .swiftpmBuild: return "swift"
        case .nodeModules: return "cube"
        case .frontendCache: return "bolt.horizontal"
        case .gradleBuild: return "cup.and.saucer"
        case .pythonVenv: return "leaf"
        case .generalBuild: return "archivebox"
        }
    }

    /// 安全校验白名单名称：确保只删除纯产物目录，绝不误伤源码
    public static let allowedDirNames: Set<String> = [
        "target", ".build", "node_modules", ".next", ".nuxt", ".turbo",
        "build", ".gradle", ".venv", "venv", "dist", ".pytest_cache", ".mypy_cache"
    ]
}

// MARK: - 单项构建产物模型

/// 工程下属的某一个具体构建产物目录
public struct DevProjectArtifact: Identifiable, Equatable, Codable {
    public let id: String
    public let name: String
    public let path: String
    public var size: Int64
    public let kind: DevArtifactKind
    public var isSelected: Bool

    public init(id: String = UUID().uuidString,
                name: String,
                path: String,
                size: Int64,
                kind: DevArtifactKind,
                isSelected: Bool = true) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.kind = kind
        self.isSelected = isSelected
    }
}

// MARK: - 聚合开发工程模型

/// 按项目聚合的开发工程模型
public struct DevProject: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public var types: [DevProjectType]
    public var lastModified: Date?
    public var isOrphan: Bool
    public var artifacts: [DevProjectArtifact]

    public init(id: String = UUID().uuidString,
                name: String,
                path: String,
                types: [DevProjectType],
                lastModified: Date? = nil,
                isOrphan: Bool = false,
                artifacts: [DevProjectArtifact] = []) {
        self.id = id
        self.name = name
        self.path = path
        self.types = types
        self.lastModified = lastModified
        self.isOrphan = isOrphan
        self.artifacts = artifacts
    }

    /// 闲置天数
    public var daysInactive: Int {
        guard let lm = lastModified else { return 999 }
        let diff = Date().timeIntervalSince(lm)
        return max(0, Int(diff / 86400))
    }

    /// 活跃工程（7 天内有修改）—— 默认保护，不建议一键自动清理
    public var isActive: Bool {
        guard !isOrphan else { return false }
        return daysInactive <= 7
    }

    /// 陈旧工程（>30 天未修改）—— 强烈推荐释放构建缓存
    public var isStale: Bool {
        return isOrphan || daysInactive >= 30
    }

    /// 构建产物总占用大小
    public var totalArtifactSize: Int64 {
        artifacts.reduce(0) { $0 + $1.size }
    }

    /// 勾选项的体积与条数，**一趟**算完。
    /// 页脚、确认框、行内按钮都要读它，分成两个 `filter().reduce()` 就是每帧多趟全表扫描。
    public var selectedSummary: (bytes: Int64, count: Int) {
        artifacts.reduce(into: (Int64(0), 0)) { acc, art in
            guard art.isSelected else { return }
            acc.0 += art.size
            acc.1 += 1
        }
    }

    /// 选中的构建产物占用大小
    public var selectedArtifactSize: Int64 { selectedSummary.bytes }

    /// 是否全部选中
    public var isAllSelected: Bool {
        !artifacts.isEmpty && artifacts.allSatisfy(\.isSelected)
    }

    /// 是否部分选中
    public var isPartiallySelected: Bool {
        let count = selectedSummary.count
        return count > 0 && count < artifacts.count
    }

    /// 格式化闲置状态文案
    public var statusBadgeText: String {
        if isOrphan {
            return "👻 孤儿产物 (项目已删除)"
        } else if isActive {
            return "🔥 活跃工程 (\(daysInactive)天前活跃)"
        } else if daysInactive > 365 {
            return "❄️ 闲置 1 年以上"
        } else {
            return "🍂 闲置 \(daysInactive) 天"
        }
    }

    /// 状态徽标主色调
    public var statusBadgeColor: Color {
        if isOrphan {
            return Signal.critical
        } else if isActive {
            return Signal.positive
        } else if isStale {
            return Signal.caution
        } else {
            return Ink.secondary
        }
    }
}
