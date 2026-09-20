import Foundation

// MARK: - 语言包项

public struct LanguagePackItem: Identifiable, Equatable, Hashable {
    public let id: String              // .lproj 目录绝对路径
    public let code: String            // 语言代号，如 "zh-Hans", "fr", "Base"
    public let displayName: String     // 本地化友好名称，如 "法语 (French)"
    public let path: String            // 路径
    public let size: Int64             // 目录占用字节数
    public let isProtected: Bool       // 是否为保护语言（中文/英文/Base），受保护项不可被勾选清理
    public var isSelected: Bool        // 是否勾选清理

    public init(
        id: String,
        code: String,
        displayName: String,
        path: String,
        size: Int64,
        isProtected: Bool,
        isSelected: Bool = false
    ) {
        self.id = id
        self.code = code
        self.displayName = displayName
        self.path = path
        self.size = size
        self.isProtected = isProtected
        self.isSelected = isSelected
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

    public init(
        id: String,
        appName: String,
        bundleID: String?,
        appPath: String,
        appTotalSize: Int64,
        languagePacks: [LanguagePackItem]
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.appPath = appPath
        self.appTotalSize = appTotalSize
        self.languagePacks = languagePacks
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
}

// MARK: - 语言代码映射与保护策略辅助器

public enum LocalizationHelper {
    /// 默认保护的语言代号前缀或精确代码（中文、英文以及基础资源 Base 坚决保护）
    public static let protectedLanguageCodes: Set<String> = [
        "base",
        "zh", "zh-hans", "zh-hant", "zh-cn", "zh-tw", "zh-hk", "zh_cn", "zh_tw", "zh_hk",
        "en", "en-us", "en-gb", "en-au", "en-ca", "en-in", "en_us", "en_gb"
    ]

    /// 判断指定语言代码是否属于受保护语言
    public static func isProtected(code: String) -> Bool {
        let normalized = code.lowercased()
            .replacingOccurrences(of: ".lproj", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if protectedLanguageCodes.contains(normalized) {
            return true
        }

        // 前缀判定（如 zh-Hans-CN, en-001 等）
        if normalized.hasPrefix("zh") || normalized.hasPrefix("en") || normalized == "base" {
            return true
        }

        return false
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
