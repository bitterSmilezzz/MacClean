import Foundation
import AppKit

/// 固化路径规则（与 docs/CLEANUP-RULES.md 一一对应，v1.0）
enum CleanPaths {
    // MARK: G6 硬排除白名单
    static let hardExclude: [String] = [
        "~/Library/Mail",
        "~/Library/Keychains",
        "~/Library/Accounts",
        "~/Library/Messages",
        "~/Library/Safari/Bookmarks.plist",
        "~/Library/Safari/History.db",
        "~/.ssh",
        "~/.gnupg",
    ]

    // MARK: 1. 用户缓存 C1–C6
    static let userCaches = "~/Library/Caches"
    static let xcodeCache = "~/Library/Caches/com.apple.dt.Xcode"
    static let pipCache = "~/Library/Caches/pip"
    static let pipCacheAlt = "~/.cache/pip"
    static let homebrewCache = "~/Library/Caches/Homebrew"
    static let browserCacheDirs = [
        "~/Library/Caches/com.apple.Safari",
        "~/Library/Caches/com.google.Chrome",
        "~/Library/Caches/com.microsoft.Edge",
        "~/Library/Caches/com.brave.Browser",
        "~/Library/Caches/com.operasoftware.Opera",
        "~/Library/Caches/com.vivaldi.Vivaldi",
    ]
    static let containersCaches = "~/Library/Containers"

    // MARK: 2. 日志与临时文件 L1–L4
    static let logs = "~/Library/Logs"
    static let diagnosticReports = "~/Library/Logs/DiagnosticReports"
    static let tmp = "/private/tmp"
    static let varTmp = "/private/var/tmp"
    static let temporaryItems = "~/Library/TemporaryItems"

    // MARK: 3. 开发残留 D1–D11
    static let derivedData = "~/Library/Developer/Xcode/DerivedData"
    static let archives = "~/Library/Developer/Xcode/Archives"
    static let simulatorCaches = "~/Library/Developer/CoreSimulator/Caches"
    static let simulatorDevices = "~/Library/Developer/CoreSimulator/Devices"
    static let npmCache = "~/.npm/_cacache"
    static let yarnCache = "~/.yarn/cache"
    static let pnpmStore = "~/.pnpm-store"
    static let gradleCaches = "~/.gradle/caches"
    static let m2Repository = "~/.m2/repository"
    static let cargoRegistry = "~/.cargo/registry"
    static let swiftpmCache = "~/Library/Caches/org.swift.swiftpm"
    static let codeRoots = ["~/workspace", "~/projects", "~/dev", "~/code"]

    // MARK: 4. App 残留 A1–A4
    static let appSupport = "~/Library/Application Support"
    static let preferences = "~/Library/Preferences"
    static let launchAgents = "~/Library/LaunchAgents"
    static let appDirs = ["/Applications", "~/Applications", "/System/Applications",
                          "/Library/Input Methods", "~/Library/Input Methods"]

    // MARK: 5. 大文件与垃圾箱 T1–T4
    static let trash = "~/.Trash"
    static let downloads = "~/Downloads"
    static let bigFileRoots = ["~/Downloads", "~/Documents", "~/Desktop", "~/Movies"]

    // MARK: 6. 浏览器与系统数据 B1–B3
    static let safariLocalStorage = "~/Library/Safari/LocalStorage"
    static let safariWebsiteData = "~/Library/Safari/WebsiteData"
    static let safariContainerCaches = "~/Library/Containers/com.apple.Safari/Data/Library/Caches"
    static let chromiumCaches = [
        ("Google Chrome", "~/Library/Application Support/Google/Chrome"),
        ("Microsoft Edge", "~/Library/Application Support/Microsoft Edge"),
        ("Brave Browser", "~/Library/Application Support/BraveSoftware/Brave-Browser"),
        ("Opera", "~/Library/Application Support/com.operasoftware.Opera"),
        ("Vivaldi", "~/Library/Application Support/Vivaldi"),
    ]

    // MARK: 运行中应用排除（G5）
    static let runningBundleIDs: Set<String> = {
        let apps = NSWorkspace.shared.runningApplications
        return Set(apps.compactMap { $0.bundleIdentifier })
    }()

    /// 展开 ~ 前缀
    static func expand(_ p: String) -> String {
        p.replacingOccurrences(of: "~", with: NSHomeDirectory())
    }
}
