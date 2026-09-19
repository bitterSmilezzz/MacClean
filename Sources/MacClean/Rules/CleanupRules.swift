import Foundation

/// 清理规则源头（与 `docs/CLEANUP-RULES.md` 严格同步维护）
///
/// 设计约定：
/// - 本文件是规则的**唯一事实来源**：每条规则的编号、分类、风险级与清理方式都登记在此，
///   `Scanner` 的新增规则直接引用本文件常量，避免路径与风险级散落在扫描逻辑各处；
/// - `CleanupRules.all.count` 与文档声明的条数由 `Selftest` 校验，防止文档与代码再次脱节
///   （v1.0 曾出现文档引用不存在的 `Rules/CleanupRules.swift`、`Models` 声称 `B1–B4`
///   而实际只有 B1–B3 的脱节问题）；
/// - 变更流程：改规则 = 改本文件 + 改 `Scanner` 实现 + 改 `docs/CLEANUP-RULES.md`，三处必须同步。
///
/// 版本：v1.1（2026-09-12）
enum CleanupRules {

    // MARK: - 规则模型

    /// 清理方式（对应文档表格「清理方式」列）
    enum CleanupMethod: String {
        /// 移入废纸篓（可恢复）——默认方式，遵守 G3
        case trash
        /// 彻底删除（仅用于：已在废纸篓内的项、纯缓存）
        case delete
    }

    /// 单条规则定义
    struct Rule {
        /// 规则编号，如 "C1" / "L6" / "D13"
        let id: String
        /// 所属清理分类
        let category: CleanCategory
        /// 项目本质：删了会发生什么（决定处置结论）
        let nature: ItemNature
        /// 删除后果的一句话描述——直接展示给用户，解释"为什么是这个结论"
        let consequence: String
        /// 一行描述，与文档表格「路径模式」列对应
        let summary: String
        /// 清理方式
        let cleanup: CleanupMethod
        /// 是否为 v1.1 新增规则
        let isNew: Bool

        init(id: String, category: CleanCategory, nature: ItemNature,
             consequence: String, summary: String,
             cleanup: CleanupMethod = .trash, isNew: Bool = false) {
            self.id = id
            self.category = category
            self.nature = nature
            self.consequence = consequence
            self.summary = summary
            self.cleanup = cleanup
            self.isNew = isNew
        }
    }

    // MARK: - 全部规则登记（v1.1：6 大类 41 条）

    static let all: [Rule] = [
        // MARK: 1. 用户缓存 C1–C7
        Rule(id: "C1", category: .userCaches, nature: .losslessCache,
             consequence: "应用缓存文件，删除后应用会自动重建",
             summary: "~/Library/Caches/* 各子目录"),
        Rule(id: "C2", category: .userCaches, nature: .losslessCache,
             consequence: "Xcode 缓存，重新打开工程时自动重建",
             summary: "~/Library/Caches/com.apple.dt.Xcode（Xcode 未运行）"),
        Rule(id: "C3", category: .userCaches, nature: .losslessCache,
             consequence: "pip 下载缓存，下次安装依赖时重新下载",
             summary: "pip 缓存（~/Library/Caches/pip、~/.cache/pip）"),
        Rule(id: "C4", category: .userCaches, nature: .losslessCache,
             consequence: "Homebrew 下载缓存，下次安装时重新下载",
             summary: "~/Library/Caches/Homebrew"),
        Rule(id: "C5", category: .userCaches, nature: .losslessCache,
             consequence: "浏览器网页缓存，浏览时自动重建",
             summary: "浏览器缓存（Safari/Chrome/Edge/Brave/Opera/Vivaldi）"),
        Rule(id: "C6", category: .userCaches, nature: .losslessCache,
             consequence: "沙盒应用的缓存，应用会自动重建",
             summary: "沙盒容器缓存 ~/Library/Containers/*/Data/Library/Caches/*"),
        Rule(id: "C7", category: .userCaches, nature: .staleArtifact,
             consequence: "已安装应用的旧版本安装包，应用本体已安装完成",
             summary: "应用内旧安装包 ~/Library/Application Support/*/updates/*.{dmg,pkg,iso}",
             isNew: true),

        // MARK: 2. 日志与临时文件 L1–L6
        Rule(id: "L1", category: .logsAndTemp, nature: .losslessCache,
             consequence: "应用日志，删除后应用会重新创建",
             summary: "~/Library/Logs/* 顶层项"),
        Rule(id: "L2", category: .logsAndTemp, nature: .losslessCache,
             consequence: "崩溃与诊断报告，只用于事后排查",
             summary: "~/Library/Logs/DiagnosticReports/*"),
        Rule(id: "L3", category: .logsAndTemp, nature: .inferredUnused,
             consequence: "系统临时目录：通常可以丢弃，但可能有进程正在使用其中文件，请确认后再删",
             summary: "/private/tmp/*、/private/var/tmp/*（仅可写项）"),
        Rule(id: "L4", category: .logsAndTemp, nature: .losslessCache,
             consequence: "应用临时文件，应用会重新创建",
             summary: "~/Library/TemporaryItems/*"),
        Rule(id: "L5", category: .logsAndTemp, nature: .staleArtifact,
             consequence: "已轮转的历史日志，当前日志不受影响",
             summary: "旋转旧日志（*.log.N / *.N.log / *.gz，>30 天）"),
        Rule(id: "L6", category: .logsAndTemp, nature: .staleArtifact,
             consequence: "应用自动更新完成后的残留，更新已经结束",
             summary: "$TMPDIR/<bundle-id>.ShipIt.<suffix> 应用更新残留",
             isNew: true),

        // MARK: 3. 开发残留 D1–D15
        Rule(id: "D1", category: .devResidue, nature: .rebuildable,
             consequence: "Xcode 编译产物，下次构建会重新生成（首次构建明显变慢）",
             summary: "~/Library/Developer/Xcode/DerivedData/*"),
        Rule(id: "D2", category: .devResidue, nature: .userData,
             consequence: "Xcode 归档包，是发布记录的原始产物，删了不可恢复",
             summary: "~/Library/Developer/Xcode/Archives/*（>90 天）"),
        Rule(id: "D3", category: .devResidue, nature: .rebuildable,
             consequence: "模拟器运行时缓存，重新启动模拟器时重建",
             summary: "~/Library/Developer/CoreSimulator/Caches/*"),
        Rule(id: "D4", category: .devResidue, nature: .losslessCache,
             consequence: "npm 下载缓存，下次安装依赖时重新下载",
             summary: "~/.npm/_cacache"),
        Rule(id: "D5", category: .devResidue, nature: .losslessCache,
             consequence: "Yarn 下载缓存，下次安装依赖时重新下载",
             summary: "~/.yarn/cache"),
        Rule(id: "D6", category: .devResidue, nature: .losslessCache,
             consequence: "pnpm 内容寻址存储，下次安装依赖时重新下载",
             summary: "~/.pnpm-store"),
        Rule(id: "D7", category: .devResidue, nature: .losslessCache,
             consequence: "Gradle 依赖与构建缓存，下次构建时重新下载",
             summary: "~/.gradle/caches"),
        Rule(id: "D8", category: .devResidue, nature: .inferredUnused,
             consequence: "Maven 失效元数据；下次解析依赖时会重新生成，确认后再删",
             summary: "~/.m2/repository 失效元数据（*.lastUpdated / _remote.repositories）"),
        Rule(id: "D9", category: .devResidue, nature: .losslessCache,
             consequence: "Cargo 依赖源码缓存，下次构建时重新下载",
             summary: "~/.cargo/registry"),
        Rule(id: "D10", category: .devResidue, nature: .losslessCache,
             consequence: "Swift Package Manager 缓存，下次解析依赖时重新下载",
             summary: "~/Library/Caches/org.swift.swiftpm"),
        Rule(id: "D11", category: .devResidue, nature: .rebuildable,
             consequence: "Python 字节码缓存，下次导入时自动重新生成",
             summary: "__pycache__（限定 ~/workspace 等代码目录，深度 ≤5）"),
        Rule(id: "D12", category: .devResidue, nature: .inferredUnused,
             consequence: "Homebrew 旧版本目录：当前链接到的版本会保留，但部分配方依赖旧版本，删前请确认",
             summary: "/opt/homebrew/Cellar/<formula>/ 旧版本（保留当前 opt 链接版本）"),
        Rule(id: "D13", category: .devResidue, nature: .losslessCache,
             consequence: "Clang 模块缓存，编译时自动重建",
             summary: "$TMPDIR 同级 C/clang/ModuleCache（Clang 模块缓存）",
             isNew: true),
        Rule(id: "D14", category: .devResidue, nature: .losslessCache,
             consequence: "Node 编译缓存，下次运行时自动重建",
             summary: "$TMPDIR/node-compile-cache（Node 编译缓存）",
             isNew: true),
        Rule(id: "D15", category: .devResidue, nature: .inferredUnused,
             consequence: "依据命名推断为废弃副本；命名可能出自人工重命名，请确认后再删",
             summary: "全局 node_modules 下废弃版本副本（名字含 .old-/.retired-/.bak-/.disabled-）",
             isNew: true),
        Rule(id: "D16", category: .devResidue, nature: .losslessCache,
             consequence: "CocoaPods 依赖包与规格库缓存，下次执行 pod install 时按需重新下载",
             summary: "~/Library/Caches/CocoaPods/* 与 ~/.cocoapods/repos",
             isNew: true),
        Rule(id: "D17", category: .devResidue, nature: .losslessCache,
             consequence: "Docker 构建缓存与客户端运行日志，下次构建镜像时重新拉取或生成",
             summary: "~/.docker/buildx/cache/* 与 ~/Library/Containers/com.docker.docker/Data/log/*",
             isNew: true),
        Rule(id: "D18", category: .devResidue, nature: .losslessCache,
             consequence: "Cargo Git 源码仓库检出与索引，下次 cargo build 依赖时自动按需克隆",
             summary: "~/.cargo/git/checkouts/* 与 ~/.cargo/git/db/*",
             isNew: true),
        Rule(id: "D19", category: .devResidue, nature: .staleArtifact,
             consequence: "Gradle 历史守护进程日志与过时 Wrapper 发行包，不影响当前项目构建",
             summary: "~/.gradle/daemon/*/*.log 与 ~/.gradle/wrapper/dists/*",
             isNew: true),

        // MARK: 4. App 残留 A1–A3（原 A3「孤儿缓存」已删除，见下方说明）
        Rule(id: "A1", category: .appResidue, nature: .orphanedResidue,
             consequence: "已卸载应用的数据目录，应用已不在本机",
             summary: "~/Library/Application Support/<name>（App 已卸载）"),
        Rule(id: "A2", category: .appResidue, nature: .orphanedResidue,
             consequence: "已卸载应用的偏好设置，应用已不在本机",
             summary: "~/Library/Preferences/<bundle>.plist（App 已卸载，>180 天）"),
        // A3（`~/Library/Caches/<bundle>`，App 已卸载）已于 v1.2 删除 —— 它是一条**幽灵规则**：
        // 登记在册但 Scanner 从未实现，而且实现出来只会更糟：
        //   · C1 已经全量覆盖 `~/Library/Caches/*`，A3 的目标集合是它的真子集；
        //   · 同一目录被 C1（userCaches）与 A3（appResidue）各计一次字节，总可清理量虚增；
        //   · 已卸载应用的缓存**本质仍是缓存**，删除无损失，C1 的「可清理」结论本就是对的，
        //     硬套 orphanedResidue 反而把它降级成「需确认」，是过度保守而非更安全。
        // 结论：不是补实现，而是删规则。
        Rule(id: "A3", category: .appResidue, nature: .systemCritical,
             consequence: "开机启动项配置，删错会影响登录或后台服务，务必逐个确认",
             summary: "~/Library/LaunchAgents/*.plist（指向已卸载 App）"),

        // MARK: 5. 大文件与垃圾箱 T1–T5
        Rule(id: "T1", category: .largeFiles, nature: .userData,
             consequence: "废纸篓内容，清理即彻底删除、无法恢复",
             summary: "~/.Trash/*（清理 = 彻底删除）", cleanup: .delete),
        Rule(id: "T2", category: .largeFiles, nature: .userData,
             consequence: "下载目录里的文件，是你自己的东西",
             summary: "~/Downloads/*（>500MB 或 >180 天未访问）"),
        Rule(id: "T3", category: .largeFiles, nature: .userData,
             consequence: "大文件，删了不可恢复",
             summary: "大文件（>/1GB，深度 ≤2）"),
        Rule(id: "T4", category: .largeFiles, nature: .inferredUnused,
             consequence: "模拟器设备镜像（依据 90 天未使用推断）：删除后需重新创建并重装其中的 App",
             summary: "~/Library/Developer/CoreSimulator/Devices/*（>90 天未使用）"),
        Rule(id: "T5", category: .largeFiles, nature: .userData,
             consequence: "iPhone/iPad 本地备份，删了不可恢复",
             summary: "~/Library/Application Support/MobileSync/Backup/*（>180 天）"),

        // MARK: 6. 浏览器与系统数据 B1–B5
        Rule(id: "B1", category: .browserAndSystem, nature: .userData,
             consequence: "网站本地数据，删除后部分网站需要重新登录或丢失草稿",
             summary: "Safari LocalStorage / WebsiteData（Safari 未运行）"),
        Rule(id: "B2", category: .browserAndSystem, nature: .losslessCache,
             consequence: "浏览器网页缓存，浏览时自动重建",
             summary: "Chromium 系浏览器 Default/Cache、Default/Code Cache（浏览器未运行）"),
        Rule(id: "B3", category: .browserAndSystem, nature: .losslessCache,
             consequence: "Safari 容器缓存，浏览时自动重建",
             summary: "~/Library/Containers/com.apple.Safari 容器缓存"),
        // B4/B5：原本是一条"Chromium 内嵌组件缓存"，把 CRX 下载缓存与
        // WidevineCdm（DRM）/ WasmTtsEngine（语音合成）/ SODALanguagePacks（语言包）
        // 混在一起统标 safe。后三者是**按需下载的功能组件**，删掉是功能不可用而非
        // "缓存被重建"——这是实测中"标着安全其实删了会坏"的主要来源。现拆成两条。
        Rule(id: "B4", category: .browserAndSystem, nature: .losslessCache,
             consequence: "Chromium 组件下载缓存，需要时重新下载",
             summary: "Chromium 组件下载缓存 ~/Library/Application Support/*/component_crx_cache",
             isNew: true),
        Rule(id: "B5", category: .browserAndSystem, nature: .redownloadable,
             consequence: "按需下载的功能组件（DRM 播放 / 语音合成 / 语言包），删除后相关功能需重新下载才能使用",
             summary: "Chromium 功能组件 ~/Library/Application Support/*/{WidevineCdm, WasmTtsEngine, SODALanguagePacks}",
             isNew: true),
    ]

    /// 被"更具体的规则"单独认领的 `~/Library/Caches` 子路径。
    ///
    /// **C1 兜底扫描必须跳过这些目录**，理由有两条：
    ///  · 正确性：同一目录被两条规则同时列入会各计一次字节。C1 属于 userCaches，
    ///    D10（swiftpmCache）属于 devResidue，两边 seen 各自独立，谁都拦不住对方——
    ///    实测 `~/Library/Caches/org.swift.swiftpm` 就被重复计算，「总计可清理」虚增。
    ///  · 可解释性：界面上显示"规则 C1"还是"C4"直接影响用户判断该不该删。
    ///
    /// 新增"针对 ~/Library/Caches 下具体子目录"的规则时，**必须同步登记到这里**。
    static let userCachesClaimedBySpecificRules: [String] = [
        CleanPaths.xcodeCache,      // C2
        CleanPaths.pipCache,        // C3
        CleanPaths.homebrewCache,   // C4
        CleanPaths.swiftpmCache,    // D10（跨分类，最需要让位的一条）
        CleanPaths.cocoapodsCache,  // D16（跨分类，CocoaPods 缓存让位）
    ] + CleanPaths.browserCacheDirs  // C5

    // MARK: - 查询接口

    static func rule(_ id: String) -> Rule? { all.first { $0.id == id } }

    static func rules(in category: CleanCategory) -> [Rule] {
        all.filter { $0.category == category }
    }

    /// 规则总条数（Selftest 校验文档一致性用）
    static var count: Int { all.count }

    /// 本版新增规则条数
    static var newCount: Int { all.filter(\.isNew).count }

    /// 版本号（与文档头部一致）
    static let version = "v1.1"

    // MARK: - v1.1 新增规则所需的路径常量与匹配模式

    /// L6：应用自动更新残留（Squirrel/ShipIt）的稳定命名片段。
    /// 完整命名约定：`<bundle-id>.ShipIt.<随机字母数字后缀>`
    static let shipItMarker = ".ShipIt."

    /// C7：应用内旧安装包所在子目录名
    static let appInstallerSubdir = "updates"
    /// C7：安装包扩展名
    static let installerExtensions: Set<String> = ["dmg", "pkg", "iso"]

    /// D13：Clang 模块缓存（位于 $TMPDIR 同级 C 目录下）
    static let clangCacheRelativePath = "C/clang/ModuleCache"

    /// D14：Node 编译缓存目录名
    static let nodeCompileCacheName = "node-compile-cache"

    /// B4：Chromium 组件**下载缓存**（真正的缓存，重建无代价）
    static let chromiumDownloadCaches: Set<String> = [
        "component_crx_cache",
    ]

    /// B5：Chromium **按需下载的功能组件**。
    ///
    /// 这些不是缓存：删掉之后对应功能（Widevine DRM 播放、端上语音合成、语言包）
    /// 会直接不可用，要等应用重新下载完才恢复。实测中它们曾被混进 B4 统标为 safe，
    /// 是"标着安全其实删了会坏"的主要来源。
    static let chromiumFunctionalComponents: Set<String> = [
        "SODALanguagePacks",
        "WasmTtsEngine",
        "WidevineCdm",
    ]

    /// D15：废弃版本副本的命名标记（小写比对）
    ///
    /// 覆盖两种真实命名形态（实测自本机 `@deepseek-ai` 目录）：
    /// - `dsh.old-0.1.2-alpha.3`            点分隔 + 版本号
    /// - `dsh.global-retired-20260906`      连字符 + 日期
    ///
    /// **标记后必须紧跟数字**（版本号/日期），否则不判定为废弃副本 ——
    /// 该约束用于排除 `bold-italic`、`is-old-school` 这类含标记词但语义无关的包名。
    static let retiredMarkers: [String] = [
        ".old-", "-old-",
        ".retired-", "-retired-",
        ".bak-", "-bak-",
        ".disabled-", "-disabled-",
    ]

    /// 判断包目录名是否形如"废弃版本副本"。
    /// 供 `FileSystem.isRetiredGlobalPackage` 与 D15 扫描共用，确保判定口径一致。
    static func isRetiredPackageName(_ name: String) -> Bool {
        let lower = name.lowercased()
        for marker in retiredMarkers {
            guard let r = lower.range(of: marker) else { continue }
            let after = lower[r.upperBound...]
            // 标记后紧跟数字才认定为版本/日期形态（排除 bold-italic 等无关词）
            if let first = after.first, first.isNumber { return true }
        }
        return false
    }

    /// D15：全局 node_modules 扫描根
    static let globalNodeModulesRoots: [String] = [
        "/opt/homebrew/lib/node_modules",   // Apple Silicon Homebrew
        "/usr/local/lib/node_modules",       // Intel Homebrew
    ]
}
