import Foundation

// MARK: - 语言包项

public struct LanguagePackItem: Identifiable, Equatable, Hashable {
    public let id: String              // .lproj 目录绝对路径
    public let code: String            // 语言代号，如 "zh-Hans", "fr", "Base"
    public let displayName: String     // 本地化友好名称，如 "法语 (French)"
    public let path: String            // 路径
    public let size: Int64             // 目录占用字节数
    /// v1.74.0：`true` 的**唯一**含义是"本工具判定不可删"。
    /// 除母语/系统语言/Base 之外，运行中的 App、`com.apple.` 系统应用、
    /// 以及证据不足的情况一律置 true——这样所有既有调用方
    /// （`Uninstaller.toggleLocalizationPack` 等都只碰 `!isProtected`）自动获得保护。
    public let isProtected: Bool
    /// 为什么不可删（`isProtected == true` 时给用户的中文原因；nil = 可勾选）
    public let protectionReason: String?
    public var isSelected: Bool        // 是否勾选清理（扫描结果**恒为 false**）

    public init(
        id: String,
        code: String,
        displayName: String,
        path: String,
        size: Int64,
        isProtected: Bool,
        isSelected: Bool = false,
        protectionReason: String? = nil
    ) {
        self.id = id
        self.code = code
        self.displayName = displayName
        self.path = path
        self.size = size
        self.isProtected = isProtected
        self.isSelected = isSelected
        self.protectionReason = protectionReason
    }

    /// 即使允许删除也必须展示的代价说明：删包内资源会破坏 CodeResources 签名密封。
    public var deletionRisk: String { LocalizationHelper.signatureRiskText }

    /// 该条目走的治理域：`/Applications` 下用包内资源域（深度 4，永删不到 .app 本体）；
    /// `~/Applications` 与自检 fixture 落在主目录/临时目录内，交主目录护栏。
    /// 解析口径由注册表的统一实现提供（含运行时登记的动态域）。
    /// internal：`GovernanceDomain` 是内部类型，不能出现在 public 属性上。
    var governanceDomain: GovernanceDomain? {
        GovernanceDomain.domain(forPath: path)
    }
}

// MARK: - 应用本地化 Bundle 结构

public struct AppLocalizationBundle: Identifiable, Equatable {
    public let id: String              // App 路径
    public let appName: String         // 应用名称，如 "Microsoft Word"
    public let bundleID: String?       // Bundle Identifier
    public let appPath: String         // .app 绝对路径
    public let appTotalSize: Int64     // 应用包整体大小
    public var languagePacks: [LanguagePackItem] // 包含的语言包列表
    /// v1.74.0：扫描时该 App 正在运行（NSWorkspace 实测）。运行中一律不列可删项。
    public let isRunningApp: Bool
    /// `com.apple.` 等 Apple 官方 bundle id：删包内资源会破坏系统组件签名。
    public let isAppleSystemApp: Bool
    /// 非 nil = 判定依据不足（语言列表读不到 / 已安装清单不完整 / 资源目录读不到），
    /// 整个 App 降级为"仅定位与建议"，一个语言包都不列成可删。
    public let evidenceNote: String?

    public init(
        id: String,
        appName: String,
        bundleID: String?,
        appPath: String,
        appTotalSize: Int64,
        languagePacks: [LanguagePackItem],
        isRunningApp: Bool = false,
        isAppleSystemApp: Bool = false,
        evidenceNote: String? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.appPath = appPath
        self.appTotalSize = appTotalSize
        self.languagePacks = languagePacks
        self.isRunningApp = isRunningApp
        self.isAppleSystemApp = isAppleSystemApp
        self.evidenceNote = evidenceNote
    }

    /// 该 App 是否被整株阻断（不给任何"可删"名额）
    public var isDeletionBlocked: Bool { isRunningApp || isAppleSystemApp || evidenceNote != nil }

    /// 阻断原因（展示用）；nil = 无阻断
    public var blockReason: String? {
        if let evidenceNote { return evidenceNote }
        if isRunningApp { return "应用正在运行：删除包内资源会让其立即异常" }
        if isAppleSystemApp { return "Apple 官方组件（com.apple.*），不提供清理" }
        return nil
    }

    /// 所有已选中且未受保护的语言包释放潜力
    public var reclaimableSize: Int64 {
        languagePacks
            .filter { !$0.isProtected && $0.isSelected }
            .reduce(0) { $0 + $1.size }
    }

    /// 所有非受保护语言包的最大可释放大小（全选潜力）
    public var totalReclaimablePotential: Int64 {
        languagePacks
            .filter { !$0.isProtected }
            .reduce(0) { $0 + $1.size }
    }

    /// 可清理的语言包数量
    public var removablePackCount: Int {
        languagePacks.filter { !$0.isProtected }.count
    }

    /// 已勾选的语言包数量
    public var selectedPackCount: Int {
        languagePacks.filter { !$0.isProtected && $0.isSelected }.count
    }

    /// 受保护的语言包数量
    public var protectedPackCount: Int {
        languagePacks.filter { $0.isProtected }.count
    }

    /// 总语言包数量
    public var totalPackCount: Int {
        languagePacks.count
    }

    /// 卡片顶部的风险声明：本模块的既有文案暗示"删了没事"，事实并非如此，
    /// 因此把真实代价写进模型，供任何渲染它的视图复用。
    public static let moduleRiskText = LocalizationHelper.signatureRiskText
}

// MARK: - 语言代码映射与保护策略辅助器

public enum LocalizationHelper {
    /// 兜底保护的语言代号（基础资源 + 中英），任何机器上都坚决保护。
    public static let protectedLanguageCodes: Set<String> = [
        "base",
        "zh", "zh-hans", "zh-hant", "zh-cn", "zh-tw", "zh-hk", "zh_cn", "zh_tw", "zh_hk",
        "en", "en-us", "en-gb", "en-au", "en-ca", "en-in", "en_us", "en_gb"
    ]

    /// Apple 官方组件的 bundle id 前缀：这些 App 包内资源不提供清理。
    public static let appleBundlePrefixes: [String] = ["com.apple.", "apple.", "system."]

    /// 删包内资源的确切代价，卡片对**每一项**都要显式说出来。
    public static let signatureRiskText =
        "删除会破坏该 App 的 CodeResources 签名密封：加固运行、Gatekeeper 复核或自动更新"
        + "可能报「应用已损坏，无法打开」，且只能靠重装或重新签名恢复。MacClean 不提供修复手段。"

    /// 语言列表注入点（自检用）：非 nil 时用它代替真机的 `AppleLanguages` /
    /// `NSLocale.preferredLanguages`，使"母语必受保护"这条断言不随机器语言设置翻转。
    public static var preferredLanguagesOverride: [String]?

    /// 本机用户母语 / 系统语言 / `AppleLanguages` 首项，按优先级排好的归一化语言代号。
    /// 读不到任何一项时返回空数组——调用方据此把结果降级为"证据不足"，而不是当作"没有母语"。
    public static func preferredLanguageCodes() -> [String] {
        if let override = preferredLanguagesOverride {
            return override.compactMap { normalizeLanguage($0) }
        }
        var raw: [String] = []
        if let list = UserDefaults.standard.stringArray(forKey: "AppleLanguages"), !list.isEmpty {
            raw.append(contentsOf: list)
        }
        raw.append(contentsOf: Locale.preferredLanguages)
        raw.append(Locale.current.identifier)
        raw.append(Locale.current.language.languageCode?.identifier ?? "")
        var seen = Set<String>()
        var out: [String] = []
        for entry in raw {
            guard let n = normalizeLanguage(entry), !seen.contains(n) else { continue }
            seen.insert(n)
            out.append(n)
        }
        return out
    }

    /// 语言代号归一化：去掉 `.lproj`、下划线转连字符、小写。无法归一化时返回 nil。
    static func normalizeLanguage(_ code: String) -> String? {
        let n = code.lowercased()
            .replacingOccurrences(of: ".lproj", with: "")
            .replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    /// 主语言子标签（`zh-hans-cn` → `zh`）
    static func primarySubtag(_ normalized: String) -> String {
        String(normalized.split(separator: "-").first ?? "")
    }

    /// 判断指定语言代码是否属于受保护语言。
    ///
    /// v1.74.0：除兜底清单外，**用户母语 / 系统语言 / AppleLanguages 里的任一项**
    /// 及其同主语言变体一律保护（宁可少删，不可删掉用户看得懂的那份）。
    /// - Parameter userLanguages: nil = 取 `preferredLanguageCodes()`；自检传固定值。
    public static func isProtected(code: String, userLanguages: [String]? = nil) -> Bool {
        guard let normalized = normalizeLanguage(code) else { return true }   // 读不懂的名字按保护处理
        if protectedLanguageCodes.contains(normalized) { return true }

        // 前缀判定（如 zh-Hans-CN、en-001、zh_cn 等变体）
        if normalized.hasPrefix("zh") || normalized.hasPrefix("en") || normalized == "base" {
            return true
        }

        let languages = userLanguages ?? preferredLanguageCodes()
        for userRaw in languages {
            guard let user = normalizeLanguage(userRaw) else { continue }
            if normalized == user { return true }
            // 互为前缀（用户 `zh-hans-cn` ↔ 资源 `zh-hans`；资源 `ja-jp` ↔ 用户 `ja`）
            if normalized.hasPrefix(user + "-") || user.hasPrefix(normalized + "-") { return true }
            // 同主语言：宁可把该语言的所有地区变体都留下
            if primarySubtag(normalized) == primarySubtag(user) { return true }
        }
        return false
    }

    /// bundle id 是否属于 Apple 官方组件
    public static func isAppleSystemBundleID(_ bundleID: String?) -> Bool {
        guard let bid = bundleID?.lowercased().trimmingCharacters(in: .whitespaces) else { return true }
        guard !bid.isEmpty else { return true }        // 读不到 bundle id → 按系统组件保护
        return appleBundlePrefixes.contains { bid.hasPrefix($0) }
    }

    /// 提取 .lproj 目录对应的标准语言代码
    public static func extractLanguageCode(from folderName: String) -> String {
        var name = folderName
        if name.hasSuffix(".lproj") {
            name = String(name.dropLast(".lproj".count))
        }
        return name
    }

    /// 友好名称字典
    private static let knownLanguageNames: [String: String] = [
        "base": "基础界面 (Base Resources)",
        "zh-hans": "简体中文 (Simplified Chinese)",
        "zh-hant": "繁体中文 (Traditional Chinese)",
        "zh_cn": "简体中文 (中国大陆)",
        "zh_tw": "繁体中文 (中国台湾)",
        "zh_hk": "繁体中文 (中国香港)",
        "zh": "中文 (Chinese)",
        "en": "英语 (English)",
        "en-us": "英语 (美国)",
        "en-gb": "英语 (英国)",
        "ja": "日语 (Japanese)",
        "ko": "韩语 (Korean)",
        "fr": "法语 (French)",
        "fr-ca": "法语 (加拿大)",
        "de": "德语 (German)",
        "es": "西班牙语 (Spanish)",
        "es-419": "西班牙语 (拉丁美洲)",
        "it": "意大利语 (Italian)",
        "pt": "葡萄牙语 (Portuguese)",
        "pt-br": "葡萄牙语 (巴西)",
        "pt-pt": "葡萄牙语 (葡萄牙)",
        "ru": "俄语 (Russian)",
        "ar": "阿拉伯语 (Arabic)",
        "nl": "荷兰语 (Dutch)",
        "pl": "波兰语 (Polish)",
        "tr": "土耳其语 (Turkish)",
        "th": "泰语 (Thai)",
        "vi": "越南语 (Vietnamese)",
        "id": "印尼语 (Indonesian)",
        "ms": "马来语 (Malay)",
        "sv": "瑞典语 (Swedish)",
        "da": "丹麦语 (Danish)",
        "fi": "芬兰语 (Finnish)",
        "nb": "挪威语 (Bokmål)",
        "nn": "挪威语 (Nynorsk)",
        "no": "挪威语 (Norwegian)",
        "cs": "捷克语 (Czech)",
        "hu": "匈牙利语 (Hungarian)",
        "el": "希腊语 (Greek)",
        "he": "希伯来语 (Hebrew)",
        "ro": "罗马尼亚语 (Romanian)",
        "sk": "斯洛伐克语 (Slovak)",
        "uk": "乌克兰语 (Ukrainian)",
        "hr": "克罗地亚语 (Croatian)",
        "ca": "加泰罗尼亚语 (Catalan)",
        "hi": "印地语 (Hindi)"
    ]

    /// 获取语言代号对应的可读中文与国际化名称
    public static func displayName(for code: String) -> String {
        let clean = extractLanguageCode(from: code)
        let normalized = clean.lowercased().replacingOccurrences(of: "_", with: "-")

        if let mapped = knownLanguageNames[normalized] {
            return mapped
        }

        // 尝试 Locale 原生解析
        let locale = Locale(identifier: "zh_CN")
        if let localized = locale.localizedString(forIdentifier: clean) {
            return "\(localized) (\(clean))"
        }

        return "\(clean) 语言资源"
    }
}
