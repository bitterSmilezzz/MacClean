import Foundation

// MARK: - 浏览器隐私痕迹（v1.73.15）：(浏览器族 × 数据类) 开关矩阵的模型层
//
// 对标 BleachBit 的清理单元粒度：不是"浏览器目录"一整块，而是 **(app, 数据类) 选项**，
// 危险项带固定警示（firefox.xml："This option will delete your saved passwords."）。
// 判据来源：docs/research/cleanup-rules-industry.md §2（chromium.xml 把 cache/cookies/
// crash_reports/form_history/history 拆成独立开关）。
//
// 与 B 系列（CleanupRules B1–B5）的关系：B 系列是分类清理页的规则，本模块是工具页上
// 独立的 (浏览器 × 数据类) 粒度治理，两者并存、互不替代。
//
// 判据红线（RELEASE-CHECKLIST §1）：
// · **体积与年龄是呈现信息，不构成默认勾选理由**——所有格子 `isSelected` 默认全不选，
//   默认勾选是安全策略，不许由"忘了传实参"这种编译期过得去的形状展开；
// · savedLogins 与 sessionRestore 是 danger 格：不进「全选」，删除必须经独立确认；
// · 读不到 ≠ 空（G9）：三态呈现（读得到 / 读不到 / 本轮没试），本轮没试 ≠ 读不到；
// · 判龄只用 mtime（`directoryStats.newestModification`），绝不用 atime；
// · 路径是 `~` 前缀的固定常量，展开后交给网关；**没有** hasPrefix("/System") 式
//   字符串护栏（G18），系统位置判定一律走 `FileSystem.isSystemProtected` 一族。

/// 浏览器族。Chromium 系按已安装探测（AppInventory 为唯一清单源，G16）；
/// Safari 是 macOS 自带组件，始终在列。
enum BrowserFamily: String, CaseIterable, Identifiable, Equatable {
    case chrome, edge, brave, arc, firefox, safari

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .arc: return "Arc"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    var iconName: String {
        self == .safari ? "safari" : "globe"
    }

    /// AppInventory 探测用的 bundle id（正式版通道；Beta/Dev/Canary 的数据根不同，本轮不纳入矩阵）。
    /// `AppInventory.Snapshot.contains(bundleID:)` 自做小写比对，这里给规范写法即可。
    var bundleIDs: [String] {
        switch self {
        case .chrome: return ["com.google.Chrome"]
        case .edge: return ["com.microsoft.edgemac"]
        case .brave: return ["com.brave.Browser"]
        case .arc: return ["company.thebrowser.Browser"]
        case .firefox: return ["org.mozilla.firefox"]
        case .safari: return ["com.apple.Safari"]
        }
    }

    /// 用户数据根（`~` 前缀的固定路径常量，使用处经 `CleanPaths.expand` 展开）。
    /// Safari 无此结构：它的数据散落在若干固定位置，没有"用户数据根"可枚举。
    var userDataRootRaw: String? {
        switch self {
        case .chrome: return "~/Library/Application Support/Google/Chrome"
        case .edge: return "~/Library/Application Support/Microsoft Edge"
        case .brave: return "~/Library/Application Support/BraveSoftware/Brave-Browser"
        case .arc: return "~/Library/Application Support/Arc/User Data"
        case .firefox: return "~/Library/Application Support/Firefox"
        case .safari: return nil
        }
    }

    /// profile 目录所在的子目录。Firefox 的 profile 在数据根下还要进一层 `Profiles`；
    /// Chromium 系的 profile 直接是数据根的第一层子目录（返回 nil 表示就地枚举）。
    var profilesSubdirRaw: String? {
        self == .firefox ? "~/Library/Application Support/Firefox/Profiles" : nil
    }

    /// 独立缓存根。Firefox 的 cache2 与数据根分离（`~/Library/Caches/Firefox`）；
    /// Chromium 的缓存在各 profile 内部；Safari 的缓存位置是固定路径（homeFixed 锚点）。
    var cacheRootRaw: String? {
        self == .firefox ? "~/Library/Caches/Firefox" : nil
    }

    /// profile 目录名判别。
    /// Chromium 只认 `Default` 与 `Profile N`——`System Profile` / `Guest Profile` 是
    /// 浏览器内部与临时身份，不属于"用户的浏览痕迹"。
    /// Firefox 认 `*.default*`（`xxxx.default`、`xxxx.default-release`、`.dev-edition-default`）。
    func isProfileDirName(_ name: String) -> Bool {
        switch self {
        case .chrome, .edge, .brave, .arc:
            return name == "Default" || name.hasPrefix("Profile ")
        case .firefox:
            return name.contains(".default")
        case .safari:
            return false
        }
    }

    /// 该族在矩阵里提供的行（数据类）。
    /// Safari 不提供 savedLogins（密码在钥匙串 / iCloud 钥匙串，G6 硬排除，工具不碰）
    /// 与 crashReports（没有浏览器专属的崩溃报告位置；`~/Library/Logs/DiagnosticReports`
    /// 是全体 App 共用的，整目录清理不属于本模块粒度）。
    var supportedKinds: [BrowserDataKind] {
        switch self {
        case .safari:
            return [.cookies, .history, .cache, .formHistory, .sessionRestore]
        default:
            return BrowserDataKind.allCases
        }
    }

    /// 一个数据类在该族下的路径条目。布局为本仓核对的 macOS 实际位置；
    /// 选项拆分对齐 BleachBit 的 chromium.xml / firefox.xml。
    func kindPaths(for kind: BrowserDataKind) -> [BrowserKindPath] {
        switch self {
        case .chrome, .edge, .brave, .arc:
            return chromiumKindPaths(kind)
        case .firefox:
            return firefoxKindPaths(kind)
        case .safari:
            return safariKindPaths(kind)
        }
    }

    private func chromiumKindPaths(_ kind: BrowserDataKind) -> [BrowserKindPath] {
        switch kind {
        case .cookies:
            // Chrome ≥ 96 把 Cookies 挪进了 Network/；旧版仍在 profile 根。两处都列。
            return [.init(anchor: .profile, relative: "Cookies"),
                    .init(anchor: .profile, relative: "Network/Cookies")]
        case .history:
            return [.init(anchor: .profile, relative: "History"),
                    .init(anchor: .profile, relative: "Archived History"),
                    .init(anchor: .profile, relative: "Top Sites"),
                    .init(anchor: .profile, relative: "Visited Links")]
        case .cache:
            return [.init(anchor: .profile, relative: "Cache"),
                    .init(anchor: .profile, relative: "Code Cache"),
                    .init(anchor: .profile, relative: "GPUCache"),
                    .init(anchor: .profile, relative: "Media Cache")]
        case .formHistory:
            // 自动填表条目存放在 Web Data（SQLite 的 autofill 表）
            return [.init(anchor: .profile, relative: "Web Data")]
        case .savedLogins:
            return [.init(anchor: .profile, relative: "Login Data")]
        case .sessionRestore:
            return [.init(anchor: .profile, relative: "Sessions"),
                    .init(anchor: .profile, relative: "Current Session"),
                    .init(anchor: .profile, relative: "Current Tabs"),
                    .init(anchor: .profile, relative: "Last Session"),
                    .init(anchor: .profile, relative: "Last Tabs")]
        case .crashReports:
            return [.init(anchor: .familyDataRoot, relative: "Crash Reports"),
                    .init(anchor: .familyDataRoot, relative: "Crashpad")]
        }
    }

    private func firefoxKindPaths(_ kind: BrowserDataKind) -> [BrowserKindPath] {
        switch kind {
        case .cookies:
            return [.init(anchor: .profile, relative: "cookies.sqlite")]
        case .history:
            return [.init(anchor: .profile, relative: "places.sqlite")]
        case .cache:
            // Firefox 的 cache2 在独立缓存根下的同名 profile 目录里
            return [.init(anchor: .profileCache, relative: "cache2"),
                    .init(anchor: .familyCacheRoot, relative: "startupCache")]
        case .formHistory:
            return [.init(anchor: .profile, relative: "formhistory.sqlite")]
        case .savedLogins:
            // logins.json（现行）与 signons.sqlite（旧版）。**key4.db 不在清理范围**：
            // 它是密码加密主钥匙，只删密码文件、留钥匙——误删钥匙会连累其他数据完整性。
            return [.init(anchor: .profile, relative: "logins.json"),
                    .init(anchor: .profile, relative: "signons.sqlite")]
        case .sessionRestore:
            return [.init(anchor: .profile, relative: "sessionstore-backups"),
                    .init(anchor: .profile, relative: "sessionstore.jsonlz4")]
        case .crashReports:
            return [.init(anchor: .familyDataRoot, relative: "Crash Reports"),
                    .init(anchor: .familyDataRoot, relative: "minidumps")]
        }
    }

    private func safariKindPaths(_ kind: BrowserDataKind) -> [BrowserKindPath] {
        switch kind {
        case .cookies:
            return [.init(anchor: .homeFixed, relative: "~/Library/Cookies/Cookies.binarycookies"),
                    .init(anchor: .homeFixed,
                          relative: "~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies")]
        case .history:
            // `~/Library/Safari/History.db` 在 G6 硬排除清单里（用户数据）。这一行照常
            // 呈现体积，删除会被网关以「用户数据硬排除」拒绝并原样展示——这是刻意的：
            // 工具不替用户决定抹掉浏览历史数据库，决定权在删除网关。
            return [.init(anchor: .homeFixed, relative: "~/Library/Safari/History.db")]
        case .cache:
            return [.init(anchor: .homeFixed, relative: "~/Library/Caches/com.apple.Safari"),
                    .init(anchor: .homeFixed,
                          relative: "~/Library/Containers/com.apple.Safari/Data/Library/Caches")]
        case .formHistory:
            return [.init(anchor: .homeFixed, relative: "~/Library/Form Values"),
                    .init(anchor: .homeFixed, relative: "~/Library/Safari/AutoFillCorrections.db")]
        case .sessionRestore:
            return [.init(anchor: .homeFixed, relative: "~/Library/Safari/LastSession.plist"),
                    .init(anchor: .homeFixed,
                          relative: "~/Library/Saved Application State/com.apple.Safari.savedState")]
        case .savedLogins, .crashReports:
            return []   // Safari 不提供这两行（见 supportedKinds 的注释）
        }
    }
}

/// 一个数据类。固定元数据（名称 / danger / 警示文案 / 说明），与具体族无关。
enum BrowserDataKind: String, CaseIterable, Identifiable, Equatable {
    case cookies, history, cache, formHistory, savedLogins, sessionRestore, crashReports

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cookies: return "Cookies 与网站登录态"
        case .history: return "浏览历史"
        case .cache: return "网页缓存"
        case .formHistory: return "自动填表记录"
        case .savedLogins: return "已保存的登录信息"
        case .sessionRestore: return "会话恢复数据"
        case .crashReports: return "崩溃报告"
        }
    }

    var iconName: String {
        switch self {
        case .cookies: return "cookie"
        case .history: return "clock.arrow.circlepath"
        case .cache: return "arrow.down.circle"
        case .formHistory: return "rect.and.pencil.and.ellipsis"
        case .savedLogins: return "key"
        case .sessionRestore: return "arrow.uturn.backward.circle"
        case .crashReports: return "exclamationmark.bubble"
        }
    }

    /// danger 格：**永远** danger（与族无关）。不进「全选」，删除必须经独立确认
    /// （`BrowserPrivacyScanner.clean` 的 `confirmedDanger`）。
    /// savedLogins 与 sessionRestore 同档——前者丢登录态，后者丢会话恢复。
    var danger: Bool {
        self == .savedLogins || self == .sessionRestore
    }

    /// 固定警示文案（BleachBit `<warning>` 范式）。**不变量：非 nil ⇔ danger**（自检锁定）。
    var warning: String? {
        switch self {
        case .savedLogins:
            return "删除后已保存的登录状态全部丢失"
        case .sessionRestore:
            return "删除后所有窗口与标签页的恢复状态丢失，下次打开不再是上次的会话"
        default:
            return nil
        }
    }

    /// 这是什么（呈现信息，不构成勾选理由）。
    var note: String {
        switch self {
        case .cookies: return "网站写入的 Cookie 与本地登录凭据，删除后需要重新登录各网站"
        case .history: return "浏览过的网址记录（含归档历史与常用站点）"
        case .cache: return "网页图片与脚本的本地缓存，删除后浏览时自动重建"
        case .formHistory: return "网页表单的自动填写记录（姓名、地址、搜索词等）"
        case .savedLogins: return "浏览器保存的用户名与密码"
        case .sessionRestore: return "浏览器退出或崩溃时的窗口与标签页快照，用于恢复上次会话"
        case .crashReports: return "浏览器收集的崩溃转储与报告，可用于向开发者反馈问题"
        }
    }
}

/// 一条 (族, 数据类) 的候选路径条目：锚点 + 相对段。
struct BrowserKindPath: Equatable {
    enum Anchor: Equatable {
        /// 相对每个 profile 目录
        case profile
        /// 相对族用户数据根
        case familyDataRoot
        /// 相对族缓存根
        case familyCacheRoot
        /// 相对族缓存根下的**同名** profile 目录（Firefox 的 cache2）
        case profileCache
        /// 主目录下的固定位置（`relative` 是 `~` 前缀常量；Safari 用）
        case homeFixed
    }

    let anchor: Anchor
    let relative: String
}

/// 一格内一条路径的探测事实。`state` 与 `stats` 把"读得到 / 读不到 / 没试 / 不存在"四态分开。
struct BrowserCellPath: Equatable {
    enum PathState: Equatable {
        /// 路径不存在——不是"读不到"，也不是 0 字节
        case absent
        /// 存在且统计读全（stats 非 nil）
        case measured
        /// 存在但读不到（TCC / 权限，或遍历被掐断——此时 stats 若有值也只是下限）
        case unreadable
        /// 本轮没去读（在途额度满等）——「没试」≠「读不到」
        case deferred
    }

    /// 展开并归一化后的绝对路径
    let path: String
    /// 出处（防夹带）：这条路径是从哪个根 + 哪个相对段重建出来的。
    /// clean() 据此拒绝任何不是本模块固定路径表登记过的位置。
    let ownerRoot: String
    let relative: String
    let state: PathState
    let stats: FileSystem.DirectoryStats?
    /// G6/G8 注记——**读共享判据**（`FileSystem.isSystemProtectedNormalized` /
    /// `isHardExcludedNormalized`），不复制清单（G19：扫描侧与删除侧同一份判据）。
    let protection: String?
}

/// 聚合一格内全部路径后的呈现状态。
enum BrowserCellStatus: Equatable {
    /// 存在的路径全部读通，size 可信
    case readable
    /// 有存在的路径读不到（TCC/权限）或遍历被掐断——size 是下限（G9：读不到 ≠ 空）
    case unreadable
    /// 本轮没去读（在途额度满等）——「没试」≠「读不到」
    case deferred
    /// 全部路径不存在
    case absent

    var label: String {
        switch self {
        case .readable: return "可读"
        case .unreadable: return "读不到"
        case .deferred: return "本轮未读取"
        case .absent: return "无数据"
        }
    }
}

/// 矩阵的一格：(浏览器族 × 数据类)。
struct BrowserPrivacyCell: Identifiable, Equatable {
    let family: BrowserFamily
    let kind: BrowserDataKind
    var paths: [BrowserCellPath]
    var status: BrowserCellStatus
    /// 可读路径的体积之和（读不到的路径不计——它不是 0，是未知）
    var size: Int64
    /// 树内最新写入时间（mtime；判龄判据，绝不用 atime）
    var newestModification: Date?
    /// **默认全不选**（v1.73.15 红线）：体积与年龄是呈现信息，不构成勾选理由。
    /// 默认勾选是安全策略，该默认值必须是 false。
    var isSelected: Bool = false

    var id: String { "\(family.rawValue).\(kind.rawValue)" }

    /// 行内勾选框的开放判据：只有"读得到且体积可信"的格子可勾。
    /// 「全选」与它只差一条**明说的**规则：danger 格不进全选（见 includedInSelectAll）。
    var isCleanable: Bool { status == .readable }

    /// 「全选可清理项」的范围：可清理 **且非 danger**。
    var includedInSelectAll: Bool { isCleanable && !kind.danger }

    var existingPathCount: Int { paths.filter { $0.state != .absent }.count }
}

/// 一轮扫描的汇总。
struct BrowserPrivacySummary: Equatable {
    struct FamilyBlock: Equatable, Identifiable {
        let family: BrowserFamily
        /// 发现的 profile（绝对路径；Safari 为空——它没有 profile 结构）
        let profiles: [String]
        var cells: [BrowserPrivacyCell]

        var id: BrowserFamily { family }
    }

    /// 在列的族（显示顺序 = BrowserFamily.allCases 顺序）
    var blocks: [FamilyBlock] = []
    /// 已安装（按 AppInventory）但还没有产生用户数据的族——如实注明，不渲染成 0 体积
    var installedWithoutData: [BrowserFamily] = []
    /// 证据缺口（G16 清单降级等）。非空即 isResultComplete == false。
    var issues: [String] = []

    var isResultComplete: Bool { issues.isEmpty }
    var allCells: [BrowserPrivacyCell] { blocks.flatMap(\.cells) }
    var scannedFamilies: [BrowserFamily] { blocks.map(\.family) }
}

extension Array where Element == BrowserPrivacyCell {
    /// 「全选可清理项」的**唯一**判据：只选非 danger 且可读的格子。
    /// 判据本体在 `BrowserPrivacyCell.includedInSelectAll`——这里只做映射，
    /// 不再复制第二份条件式（复审 P3-1：平行表述会在生产改判据时让测试测旧的）。
    func selectAllCleanableTargets() -> [String] {
        filter { $0.includedInSelectAll }.map(\.id)
    }
}
