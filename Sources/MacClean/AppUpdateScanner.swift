import Foundation
import AppKit
import Combine

// MARK: - App 更新检查（Updater，v1.73.14）
//
// 对齐 Pearcleaner / CleanMyMac X 的 Updater 缺口，但按本仓的隐私立场收敛：
//
// **默认关闭**。总开关存 UserDefaults（键 `appUpdateCheckEnabled`，缺省 false）。
// 关闭态下 `checkUpdates` 一次网络请求都不发、一次 feed 都不解析——开关裁决
// 就写在 `checkUpdates` 的第一行，UI 层拦不算数。
//
// **隐私边界**（与 AppUpdateModels 的 doc comment 同源，改一处必须同步另一处）：
// - 网络请求只发往 App 自己在 Info.plist `SUFeedURL` 里声明的更新域名；
// - 请求是裸 GET appcast URL：不带本机文件路径、机器名、硬件信息、清单摘要等
//   任何本机信息，URL 与 Info.plist 里声明的值逐字符一致（自检钉这条）；
// - User-Agent 是固定产品名，不带路径；
// - 清单本身（谁装了什么）不出本机——扫描只读 `AppInventory.current()`、
//   各 `.app` 的 `Contents/Info.plist` 与 `Contents/_MASReceipt/receipt` 的存在性，
//   **不执行 bundle 内任何代码**。
//
// **只列示与跳转**：`openUpdatePage` 打开 App 自己声明的 appcast 地址或 App Store，
// 不下载、不代装（代装要动用户的授权链，超出清理工具的本分，见 mainstream-parity §3）。

/// 网络与解析失败的可陈述原因。`localizedDescription` 拼不出来的人话都放在这里，
/// 由调用方如实渲染进「检查失败」分组。
enum AppUpdateError: Error {
    case badURL(String)
    case timeout
    case httpStatus(Int)
    case emptyBody

    var reason: String {
        switch self {
        case .badURL(let raw): return "更新源地址无效（\(raw)）"
        case .timeout: return "请求超时（10 秒）"
        case .httpStatus(let code): return "更新源返回 HTTP \(code)"
        case .emptyBody: return "更新源返回空内容"
        }
    }
}

final class AppUpdateScanner: ObservableObject {

    // MARK: 总开关（默认关）

    /// UserDefaults 键名。**缺省 false**：`UserDefaults.bool` 对不存在的键返回 false，
    /// 即"没设置过 = 关闭"。
    static let enabledDefaultsKey = "appUpdateCheckEnabled"

    private let defaults: UserDefaults

    /// 总开关（视图通过 `setEnabled` 改；@Published 驱动 UI 刷新）
    @Published private(set) var isEnabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        defaults.set(value, forKey: Self.enabledDefaultsKey)
    }

    // MARK: 视图状态

    /// 最近一次扫描（+ 检查）的结果；nil = 尚未扫描
    @Published var summary: AppUpdateSummary?
    @Published var isWorking = false

    // MARK: 扫描（本地只读，零网络）

    /// 枚举已安装应用并判别更新来源。
    ///
    /// 清单**只**取自 `AppInventory.current()`（G16 唯一清单源，已含 `/Applications` 与
    /// `~/Applications`）；来源判别只读 Info.plist 与收据存在性。清单不可信时
    /// summary 里的 `degradationNotice` 非 nil，视图必须把降级横幅亮出来。
    func scanInstalledSources() -> AppUpdateSummary {
        let snapshot = AppInventory.current()
        var entries: [AppUpdateEntry] = []
        for path in snapshot.appPaths {
            // 系统自带应用（/System/...）由「软件更新」负责，不属于本模块口径。
            // 判据必须走 `FileSystem.isSystemProtected`（normalizePath + GuardPath 全表）
            // 而不是 `hasPrefix("/System")` 字符串护栏——G18 全仓 lint 立禁那族写法：
            // 字面护栏漏 SIP 清单里非 /System 前缀的位置、且与删除侧两套标准。
            guard !FileSystem.isSystemProtected(path) else { continue }
            entries.append(Self.makeEntry(appPath: path))
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return AppUpdateSummary(entries: entries,
                                inventoryComplete: snapshot.isComplete,
                                unreadableRoots: snapshot.unreadableRoots)
    }

    /// 读单个 `.app` 的来源。Info.plist 读不到时**如实列示**为"无更新机制、版本未知"，
    /// 不许静默跳过——跳过会把"读不到"渲染成"这里没有"。
    static func makeEntry(appPath: String) -> AppUpdateEntry {
        let fm = FileManager.default
        let dirName = (appPath as NSString).lastPathComponent
        let displayName = dirName.hasSuffix(".app") ? String(dirName.dropLast(4)) : dirName
        let contents = (appPath as NSString).appendingPathComponent("Contents")

        func entry(name: String, bundleID: String, short: String, build: String,
                   source: AppUpdateEntry.Source) -> AppUpdateEntry {
            AppUpdateEntry(path: appPath, name: name, bundleID: bundleID,
                           shortVersion: short, buildVersion: build, source: source)
        }

        guard let dict = NSDictionary(contentsOfFile: (contents as NSString)
            .appendingPathComponent("Info.plist")) as? [String: Any] else {
            return entry(name: displayName, bundleID: "", short: "", build: "", source: .none)
        }
        let name = (dict["CFBundleDisplayName"] as? String)
            ?? (dict["CFBundleName"] as? String)
            ?? displayName
        let bundleID = ((dict["CFBundleIdentifier"] as? String) ?? "").lowercased()
        let short = Self.plistString(dict["CFBundleShortVersionString"])
        let build = Self.plistString(dict["CFBundleVersion"])

        // 来源判别（Sparkle 声明优先；两者都有的极少数按 Sparkle 算，口径写死不摇摆）
        if let feed = dict["SUFeedURL"] as? String {
            let trimmed = feed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return entry(name: name, bundleID: bundleID, short: short, build: build,
                             source: .sparkle(appcastURL: trimmed))
            }
        }
        let hasReceipt = fm.fileExists(atPath: (contents as NSString)
            .appendingPathComponent("_MASReceipt/receipt"))
        if hasReceipt {
            return entry(name: name, bundleID: bundleID, short: short, build: build,
                         source: .appStore)
        }
        return entry(name: name, bundleID: bundleID, short: short, build: build, source: .none)
    }

    /// CFBundleShortVersionString 偶见数字型 plist 值；统一转字符串
    private static func plistString(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: 检查（开关裁决 + 注入缝）

    /// 对 sparkle 来源逐个 GET appcast 并与本地版本比较。
    ///
    /// - 总开关裁决在**这里**：关闭时原样返回，fetcher 一次都不会被调（自检钉这条）。
    /// - `fetcher` 是**注入缝**：nil = 真网络（URLSession，每请求 10s 超时）。
    ///   自检必须注入计数 fetcher，绝不发真网络。
    /// - 非 sparkle 来源（App Store / 无更新机制）不发任何请求，结果保持 notChecked。
    @discardableResult
    func checkUpdates(entries: [AppUpdateEntry],
                      fetcher: ((URL) throws -> Data)? = nil) -> [AppUpdateEntry] {
        guard isEnabled else { return entries }   // 默认关：零请求、零解析
        let doFetch = fetcher ?? Self.defaultFetcher
        return entries.map { entry in
            var updated = entry
            guard case .sparkle(let urlString) = entry.source else { return entry }
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                updated.result = .unreachable(reason: AppUpdateError.badURL(urlString).reason)
                return updated
            }
            do {
                let data = try doFetch(url)
                guard let item = AppcastParser.parse(data) else {
                    updated.result = .unreachable(reason: "更新源内容解析不出 appcast 条目")
                    return updated
                }
                updated.result = Self.decideResult(local: entry, remote: item)
            } catch let error as AppUpdateError {
                updated.result = .unreachable(reason: error.reason)
            } catch {
                updated.result = .unreachable(reason: "请求失败：\(error.localizedDescription)")
            }
            return updated
        }
    }

    /// 本地 vs 远端的结论。口径：
    /// - 主判据是**用户可见版本**（shortVersion）两边都有才比；分出胜负即定结论；
    /// - 用户可见版本相同 → build 号定胜负；任一侧没有 build 号按"同一版本"处理；
    /// - 一边只有 short 一边只有 build 这种**错位**，比不了 → 如实报 unreachable，
    ///   不许把"无法比较"渲染成"已是最新"。
    static func decideResult(local entry: AppUpdateEntry,
                             remote item: AppcastParser.Item) -> AppUpdateEntry.CheckResult {
        let remoteShort = nonEmpty(item.shortVersion)
        let remoteBuild = nonEmpty(item.buildVersion)
        let localShort = nonEmpty(entry.shortVersion)
        let localBuild = nonEmpty(entry.buildVersion)
        let remoteDisplay = remoteShort ?? remoteBuild ?? ""

        guard remoteShort != nil || remoteBuild != nil else {
            return .unreachable(reason: "更新源条目里没有版本号")
        }
        guard localShort != nil || localBuild != nil else {
            return .unreachable(reason: "本机应用未标注版本号，无法比较")
        }

        func byBuild(_ lBuild: String, _ rBuild: String) -> AppUpdateEntry.CheckResult {
            switch compareVersions(lBuild, rBuild) {
            case .orderedAscending: return .available(latestVersion: remoteDisplay)
            default: return .upToDate
            }
        }

        if let lShort = localShort, let rShort = remoteShort {
            switch compareVersions(lShort, rShort) {
            case .orderedAscending: return .available(latestVersion: remoteDisplay)
            case .orderedDescending: return .upToDate
            case .orderedSame:
                if let lBuild = localBuild, let rBuild = remoteBuild {
                    return byBuild(lBuild, rBuild)
                }
                // 同一用户可见版本；build 号缺一边，按同一版本处理（口径见 doc comment）
                return .upToDate
            }
        }
        if let lBuild = localBuild, let rBuild = remoteBuild {
            return byBuild(lBuild, rBuild)
        }
        let localDesc = localShort ?? localBuild ?? "(空)"
        let remoteDesc = remoteShort ?? remoteBuild ?? "(空)"
        return .unreachable(reason: "版本信息错位无法比较：本地 \(localDesc)，远端 \(remoteDesc)")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: 真网络 fetcher（仅当 fetcher 参数为 nil 时使用；自检必须注入）

    /// 每请求 10 秒超时
    static let requestTimeout: TimeInterval = 10
    /// 固定 UA：只有产品名。不带路径、版本、机器信息。
    static let userAgent = "MacClean-Updater"

    static let defaultFetcher: (URL) throws -> Data = { url in
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw AppUpdateError.badURL(url.absoluteString)
        }
        var request = URLRequest(url: url, timeoutInterval: AppUpdateScanner.requestTimeout)
        request.httpMethod = "GET"
        request.setValue(AppUpdateScanner.userAgent, forHTTPHeaderField: "User-Agent")
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var failure: Error?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { failure = error; return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failure = AppUpdateError.httpStatus(http.statusCode)
                return
            }
            payload = data
        }
        task.resume()
        // URLRequest 的 10s 超时会以错误回调；这里的等待上限再加 2s 只是兜底
        if semaphore.wait(timeout: .now() + AppUpdateScanner.requestTimeout + 2) == .timedOut {
            task.cancel()
            throw AppUpdateError.timeout
        }
        if let failure { throw failure }
        guard let payload, !payload.isEmpty else { throw AppUpdateError.emptyBody }
        return payload
    }

    // MARK: 只列示与跳转

    /// 打开更新页：sparkle → App 自己声明的 appcast 地址；appStore → App Store。
    /// **不下载、不安装**：绝不触碰 appcast 里 enclosure 的下载地址。
    static func openUpdatePage(_ entry: AppUpdateEntry) {
        switch entry.source {
        case .sparkle(let urlString):
            guard let url = URL(string: urlString) else { return }
            NSWorkspace.shared.open(url)
        case .appStore:
            if let url = URL(string: "macappstore://apps.apple.com") {
                NSWorkspace.shared.open(url)
            }
        case .none:
            break
        }
    }

    // MARK: 视图动作（后台执行 + 主线程发布）

    /// 「扫描更新源」：本地只读。AppInventory 有缓存，通常毫秒级，同步执行即可。
    func scanSources() {
        summary = scanInstalledSources()
    }

    /// 「检查更新」：网络动作放后台线程，结果回主线程发布。
    /// `fetcher` 透传给 `checkUpdates`——自检注入用，视图层永远传 nil。
    func runUpdateCheck(fetcher: ((URL) throws -> Data)? = nil) {
        guard let current = summary else { return }
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let checked = self?.checkUpdates(entries: current.entries, fetcher: fetcher)
                ?? current.entries
            DispatchQueue.main.async {
                guard let self else { return }
                self.summary = AppUpdateSummary(entries: checked,
                                                inventoryComplete: current.inventoryComplete,
                                                unreadableRoots: current.unreadableRoots)
                self.isWorking = false
            }
        }
    }
}

// MARK: - Sparkle appcast 解析

/// 解析 Sparkle appcast（RSS 2.0 + sparkle 命名空间）。
///
/// 取 channel 里的**第一个** `<item>`——Sparkle 约定条目按发布时间倒序排，
/// 第一条就是最新版本。第一条没有版本号就如实报"没有版本号"，
/// **不**往下翻旧条目找版本（那会把旧版本当成新版本，制造假"有更新"）。
/// 解析失败（非 XML / 没有 item）返回 nil。
enum AppcastParser {

    struct Item: Equatable {
        /// `<sparkle:shortVersionString>`（元素或 enclosure 属性）
        var shortVersion: String?
        /// `<sparkle:version>`（元素或 enclosure 属性）
        var buildVersion: String?
        /// `<enclosure url=…>`。只用于展示与排障，本模块**从不**打开它。
        var downloadURL: String?
    }

    static func parse(_ data: Data) -> Item? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse(), !delegate.items.isEmpty else { return nil }
        return delegate.items.first
    }

    /// sparkle 命名空间的本地名。优先按 URI（andymatuschak.org）确认；
    /// 有些 feed 声明不完整，退回按 `sparkle:` 前缀识别。
    fileprivate static func sparkleLocalName(_ name: String, uri: String?) -> String? {
        if (uri ?? "").lowercased().contains("andymatuschak") {
            return name.contains(":")
                ? name.split(separator: ":", maxSplits: 1).last.map(String.init)
                : name
        }
        if name.lowercased().hasPrefix("sparkle:") {
            return String(name.dropFirst("sparkle:".count))
        }
        return nil
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [Item] = []
        private var current: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            text = ""
            if elementName == "item" || elementName.hasSuffix(":item") {
                current = Item()
                return
            }
            if elementName == "enclosure" || elementName.hasSuffix(":enclosure") {
                current?.downloadURL = attributeDict["url"]
                // Sparkle 1.x 的常见写法：版本直接挂在 enclosure 属性上
                for (key, value) in attributeDict {
                    guard key.lowercased().hasPrefix("sparkle:") else { continue }
                    let local = String(key.dropFirst("sparkle:".count)).lowercased()
                    if local == "version" { current?.buildVersion = value }
                    if local == "shortversionstring" { current?.shortVersion = value }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch AppcastParser.sparkleLocalName(elementName, uri: namespaceURI) {
            case "shortVersionString": current?.shortVersion = trimmed
            case "version": current?.buildVersion = trimmed
            default: break
            }
            text = ""
            if elementName == "item" || elementName.hasSuffix(":item") {
                if let item = current { items.append(item) }
                current = nil
            }
        }
    }
}
