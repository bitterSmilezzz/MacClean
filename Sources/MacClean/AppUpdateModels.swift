import Foundation

// MARK: - App 更新检查：数据模型与版本比较 (v1.73.14)
//
// 对齐 Pearcleaner / CleanMyMac X 的 Updater 模块，但收敛到本仓的隐私立场：
// 只**列示与跳转**，不下载、不代装。来源判别只读两样东西——
// Info.plist 里 App 自己声明的 Sparkle `SUFeedURL`，和 App Store 收据的存在性；
// 不执行 bundle 内任何代码。
//
// 隐私边界（与 AppUpdateScanner 的 doc comment 同源，改一处必须同步另一处）：
// - 网络请求只发往 App 自己在 Info.plist 里声明的更新域名；
// - 请求内容不含本机文件路径、机器名、硬件信息等任何本机信息；
// - 清单本身（谁装了什么）不出本机。

/// 一个已安装应用的更新检查条目
struct AppUpdateEntry: Identifiable, Equatable {
    /// `.app` 绝对路径（本机展示用；**绝不**进入任何网络请求）
    let path: String
    /// 显示名（CFBundleDisplayName / CFBundleName / 目录名，取先到者）
    let name: String
    /// 小写 bundle id；读不到 Info.plist 时为空串
    let bundleID: String
    /// CFBundleShortVersionString（用户可见版本，如 "1.2.3"）
    let shortVersion: String
    /// CFBundleVersion（build 号，如 "917"）
    let buildVersion: String
    /// 更新来源
    let source: Source
    /// 本次检查结果（扫描后未检查时为 `.notChecked`）
    var result: CheckResult = .notChecked

    var id: String { path }

    /// 更新来源判别依据（只读 Info.plist 与收据存在性）
    enum Source: Equatable {
        /// Info.plist 里有 `SUFeedURL`（Sparkle 更新源地址）
        case sparkle(appcastURL: String)
        /// 存在 `Contents/_MASReceipt/receipt`（Mac App Store 安装）
        case appStore
        /// 两者皆无（或不构成有效声明）
        case none
    }

    enum CheckResult: Equatable {
        /// 远端版本不高于本地
        case upToDate
        /// 有更新；关联值是远端展示版本（shortVersion，缺省时用 build 号）
        case available(latestVersion: String)
        /// 检查未得出结论。**如实区分**：网络不可达 / 更新源解析失败 / 版本号缺失
        /// 都各带原因文案。不许把"查不了"渲染成"已是最新"。
        case unreachable(reason: String)
        /// 扫描后尚未检查
        case notChecked
    }

    /// 展示版本："1.2.3 (917)"；两者都缺时为 "未知"
    var displayVersion: String {
        switch (shortVersion.isEmpty, buildVersion.isEmpty) {
        case (false, false): return "\(shortVersion) (\(buildVersion))"
        case (false, true): return shortVersion
        case (true, false): return "build \(buildVersion)"
        case (true, true): return "未知"
        }
    }
}

/// 一次扫描（+ 可选的检查）的整体结果
struct AppUpdateSummary: Equatable {
    let entries: [AppUpdateEntry]
    /// G16：清单是否足以支撑结论（取自 `AppInventory.Snapshot.isComplete`）
    let inventoryComplete: Bool
    /// 读取失败的清单根目录（`inventoryComplete == false` 时供横幅点名）
    let unreadableRoots: [String]

    init(entries: [AppUpdateEntry], inventoryComplete: Bool, unreadableRoots: [String]) {
        self.entries = entries
        self.inventoryComplete = inventoryComplete
        self.unreadableRoots = unreadableRoots
    }

    // MARK: 分组（视图按此分组渲染；顺序即展示顺序）

    /// 有可用更新
    var updatable: [AppUpdateEntry] {
        entries.filter { entry in
            if case .available = entry.result { return true }
            return false
        }
    }

    /// 已是最新
    var upToDate: [AppUpdateEntry] { entries.filter { $0.result == .upToDate } }

    /// 检查未得出结论（网络不可达 / 更新源解析失败 / 版本号缺失）
    var unreachable: [AppUpdateEntry] {
        entries.filter { entry in
            if case .unreachable = entry.result { return true }
            return false
        }
    }

    /// App Store 来源（更新走 App Store 自己的「更新」页，本模块不代查）
    var appStore: [AppUpdateEntry] { entries.filter { $0.source == .appStore } }

    /// 无更新机制（Info.plist 无 SUFeedURL、也无 App Store 收据）
    var noUpdater: [AppUpdateEntry] { entries.filter { $0.source == .none } }

    // MARK: G16 降级

    /// 清单不可信时**必须**降级明示：不许把"清单不完整"渲染成"这台机器全部最新"。
    /// 文案从实际的 `unreadableRoots` 集合取材，不做无条件宣称。
    var degradationNotice: String? {
        guard !inventoryComplete else { return nil }
        if unreadableRoots.isEmpty {
            // isComplete 为假但没记下失败根：说明是"一个应用都没枚举到"这一支
            return "已安装应用清单不完整（没有枚举到任何应用），结果可能漏项"
        }
        let names = unreadableRoots.joined(separator: "、")
        return "已安装应用清单不完整（\(unreadableRoots.count) 个应用目录读取失败：\(names)），结果可能漏项"
    }
}

// MARK: - 版本比较（纯函数）

/// 比较两个版本号，返回 `a` 相对 `b` 的次序。
///
/// 规则（每条都有自检断言钉着，见 `Selftest+Foundation` 的「compareVersions」组）：
/// 1. 允许 `v`/`V` 前缀、首尾空白；主版本与括号 build 后缀分离（`1.2.3 (917)`）。
/// 2. 主版本按 `.` 分段，**逐段数值比较**——`1.2.10 > 1.2.9`（字符串比较会判反）。
/// 3. 段内允许非数字尾缀（`3b2`、`beta`）：先比数字前缀；数字相同则
///    **无尾缀（正式版）> 有尾缀（预发布）**；两侧都有尾缀时按字母序（大小写不敏感）。
/// 4. 段数不齐时缺段按 `0` 补齐——`1.2 == 1.2.0`，`1.2 < 1.2.1`。
/// 5. 主版本分出胜负后括号 build 才参与：`1.2.3 (918) > 1.2.3 (917) > 1.2.3`；
///    缺 build 按 `0` 处理。
func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let a = VersionCompare.parsedVersion(lhs)
    let b = VersionCompare.parsedVersion(rhs)

    // 主版本逐段比较
    let main = VersionCompare.compareSegments(a.segments, b.segments)
    if main != .orderedSame { return main }

    // 主版本相同才比括号 build
    return VersionCompare.compareSegments(a.buildSegments, b.buildSegments)
}

/// `compareVersions` 的实现细节。独立命名空间，方便自检做变异验证时一眼定位。
enum VersionCompare {
    struct ParsedVersion: Equatable {
        var segments: [Segment] = []
        var buildSegments: [Segment] = []
    }

    /// 一段 = 数字前缀 + 非数字尾缀
    struct Segment: Equatable {
        var number: Int
        var suffix: String   // 已小写
    }

    static func compareSegments(_ a: [Segment], _ b: [Segment]) -> ComparisonResult {
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : Segment(number: 0, suffix: "")
            let y = i < b.count ? b[i] : Segment(number: 0, suffix: "")
            if x.number != y.number {
                return x.number < y.number ? .orderedAscending : .orderedDescending
            }
            // 数字相同：正式版（无尾缀）> 预发布（有尾缀）
            switch (x.suffix.isEmpty, y.suffix.isEmpty) {
            case (true, true): continue
            case (true, false): return .orderedDescending
            case (false, true): return .orderedAscending
            case (false, false):
                if x.suffix != y.suffix {
                    return x.suffix < y.suffix ? .orderedAscending : .orderedDescending
                }
            }
        }
        return .orderedSame
    }

    /// 解析 "v 1.2.3b2 (917)" 形状的版本串；无法解析的部分按 0 处理（不抛错——
    /// 版本号是展示性输入，解析器不该因为开发者手滑就把整次检查变成异常）。
    static func parsedVersion(_ raw: String) -> ParsedVersion {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v"), s.dropFirst().first?.isNumber == true {
            s = String(s.dropFirst())
        }

        // 括号 build 后缀："1.2.3 (917)"
        var main = s
        var build = ""
        if let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            main = String(s[s.startIndex..<open]).trimmingCharacters(in: .whitespaces)
            build = String(s[s.index(after: open)..<close])
        }
        // 也接受 "1.2.3+917" 的 build 写法
        else if let plus = s.firstIndex(of: "+") {
            main = String(s[s.startIndex..<plus])
            build = String(s[s.index(after: plus)...])
        }

        return ParsedVersion(segments: parseSegments(main),
                             buildSegments: build.isEmpty ? [] : parseSegments(build))
    }

    private static func parseSegments(_ text: String) -> [Segment] {
        text.split(separator: ".", omittingEmptySubsequences: true).map { raw in
            let seg = raw.trimmingCharacters(in: .whitespaces)
            let digits = seg.prefix { $0.isNumber }
            let number = Int(digits) ?? 0
            let suffix = String(seg.dropFirst(digits.count)).lowercased()
            return Segment(number: number, suffix: suffix)
        }
    }
}
