import Foundation
import SwiftUI

// MARK: - Wi-Fi 安全类型

public enum WiFiSecurityKind: String, Codable, CaseIterable, Identifiable {
    case wpaEncrypted = "加密保护 (WPA/WPA2/WPA3)"
    case openUnsecured = "开放未加密 (高风险)"
    case unknown = "未知安全类型"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .wpaEncrypted: return "加密保护"
        case .openUnsecured: return "开放未加密"
        case .unknown: return "未知协议"
        }
    }

    public var icon: String {
        switch self {
        case .wpaEncrypted: return "lock.fill"
        case .openUnsecured: return "lock.slash.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    public var color: Color {
        switch self {
        case .wpaEncrypted: return Signal.positive
        case .openUnsecured: return Signal.critical
        case .unknown: return Ink.tertiary
        }
    }

    public var isDangerous: Bool {
        self == .openUnsecured
    }
}

// MARK: - Wi-Fi 网络记录

public struct WiFiNetworkRecord: Identifiable, Equatable, Hashable {
    public var id: String { ssid }
    public let ssid: String
    public var securityKind: WiFiSecurityKind
    public var interface: String
    public var isCurrentActive: Bool

    public init(
        ssid: String,
        securityKind: WiFiSecurityKind,
        interface: String = "en0",
        isCurrentActive: Bool = false
    ) {
        self.ssid = ssid
        self.securityKind = securityKind
        self.interface = interface
        self.isCurrentActive = isCurrentActive
    }
}

// MARK: - DNS 缓存状态

public struct DNSCacheStatus: Equatable {
    public var lastFlushedDate: Date?
    public var message: String
    public var isSuccess: Bool

    public init(lastFlushedDate: Date? = nil, message: String = "", isSuccess: Bool = true) {
        self.lastFlushedDate = lastFlushedDate
        self.message = message
        self.isSuccess = isSuccess
    }
}

// MARK: - 网络与隐私治理检查器

public final class NetworkPrivacyInspector {
    public static let shared = NetworkPrivacyInspector()

    private init() {}

    // MARK: - 静态解析函数（便于脱机与高频单元自检）

    /// 从 `networksetup -listallhardwareports` 提取首选 Wi-Fi 网络接口（如 en0）
    public static func parseWiFiInterface(from output: String) -> String {
        let blocks = output.components(separatedBy: "Hardware Port: ")
        for block in blocks {
            if block.hasPrefix("Wi-Fi") || block.hasPrefix("AirPort") {
                if let range = block.range(of: "Device: ") {
                    let sub = block[range.upperBound...]
                    let dev = sub.components(separatedBy: .whitespacesAndNewlines).first ?? "en0"
                    if !dev.isEmpty {
                        return dev
                    }
                }
            }
        }
        return "en0"
    }

    /// 从 `networksetup -listpreferredwirelessnetworks <interface>` 输出解析全部 SSID
    public static func parsePreferredNetworks(from output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        var results: [String] = []
        var isHeaderPassed = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.contains("Preferred networks on") {
                isHeaderPassed = true
                continue
            }
            if isHeaderPassed {
                results.append(trimmed)
            }
        }
        return results
    }

    /// 从 `networksetup -getairportnetwork <interface>` 解析当前连接的网络 SSID
    public static func parseCurrentWiFiNetwork(from output: String) -> String? {
        if output.contains("Current Wi-Fi Network:") {
            let parts = output.components(separatedBy: "Current Wi-Fi Network:")
            if parts.count > 1 {
                let ssid = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return ssid.isEmpty ? nil : ssid
            }
        }
        return nil
    }

    // MARK: - 动态检测与系统交互

    /// 自动探测系统的默认 Wi-Fi 硬件接口
    public func detectDefaultWiFiInterface() -> String {
        guard let output = SafeProcess.output(Self.networkSetupPath, ["-listallhardwareports"]) else {
            return "en0"
        }
        return Self.parseWiFiInterface(from: output)
    }

    /// 获取当前正在连接中的 Wi-Fi SSID
    public func getCurrentWiFiNetwork(interface: String? = nil) -> String? {
        let iface = interface ?? detectDefaultWiFiInterface()
        guard let output = SafeProcess.output(Self.networkSetupPath, ["-getairportnetwork", iface]) else {
            return nil
        }
        return Self.parseCurrentWiFiNetwork(from: output)
    }

    /// `networksetup` 路径可覆盖：自检据此断言"到底调了哪个命令、带了哪些参数"。
    static var networkSetupPath = "/usr/sbin/networksetup"
    static var securityPath = "/usr/bin/security"
    static var dscacheutilPath = "/usr/bin/dscacheutil"

    /// 检查指定 SSID 在 Keychain 中是否存在 AirPort 密码记录（确定是否属于加密保护网络）
    public func checkSecurityKind(ssid: String) -> WiFiSecurityKind {
        let result = SafeProcess.run(Self.securityPath, [
            "find-generic-password",
            "-s", "AirPort",
            "-a", ssid,
            "/Library/Keychains/System.keychain"
        ], timeout: 6)
        guard let result else { return .unknown }
        if result.exitCode == 0 { return .wpaEncrypted }
        // `security` 的 45 是"条目不存在"，44 是"用户拒绝访问"，其它是执行失败。
        // 此前这里把**任何非 0** 都当成"没有密码 → 开放网络"：一次钥匙串授权被拒，
        // 整片已保存网络就会被标成危险，并出现在"一键清理"的候选里。
        // 只有确证的 45 才能判开放无加密，其余一律 unknown。
        return result.exitCode == 45 ? .openUnsecured : .unknown
    }

    /// 全量列出已保存的首选 Wi-Fi 网络及其安全属性
    public func listPreferredNetworks(interface: String? = nil) -> [WiFiNetworkRecord] {
        let iface = interface ?? detectDefaultWiFiInterface()
        let currentSSID = getCurrentWiFiNetwork(interface: iface)

        guard let output = SafeProcess.output(Self.networkSetupPath,
                                             ["-listpreferredwirelessnetworks", iface]) else {
            return []
        }
        let ssids = Self.parsePreferredNetworks(from: output)
        return ssids.map { ssid in
            WiFiNetworkRecord(
                ssid: ssid,
                securityKind: checkSecurityKind(ssid: ssid),
                interface: iface,
                isCurrentActive: ssid == currentSSID
            )
        }
    }

    // MARK: - 清理与治理动作

    /// 单项移除指定的首选无线网络记录
    public func removePreferredNetwork(ssid: String, interface: String? = nil) -> (success: Bool, message: String) {
        let iface = interface ?? detectDefaultWiFiInterface()
        guard let result = SafeProcess.run(Self.networkSetupPath,
                                          ["-removepreferredwirelessnetwork", iface, ssid],
                                          timeout: 15) else {
            return (false, "无法启动 networksetup")
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded {
            return (true, "已成功从已保存网络中移除 \"\(ssid)\"")
        }
        if result.timedOut { return (false, "移除超时，networksetup 未响应") }
        return (false, output.isEmpty ? "移除网络失败 (退出码: \(result.exitCode))" : output)
    }

    /// 批量清除所有开放未加密高危公共网络（强制跳过当前正连接中的网络）
    public func removeUnsecuredNetworks(interface: String? = nil) -> (removedCount: Int, failedCount: Int) {
        let all = listPreferredNetworks(interface: interface)
        // 开放未加密 且 不是当前正在使用的网络
        let dangerous = all.filter { $0.securityKind.isDangerous && !$0.isCurrentActive }
        var successCount = 0
        var failCount = 0

        for item in dangerous {
            let res = removePreferredNetwork(ssid: item.ssid, interface: item.interface)
            if res.success {
                successCount += 1
            } else {
                failCount += 1
            }
        }
        return (successCount, failCount)
    }

    /// 批量清空全部历史 Wi-Fi 网络（默认保留当前连接的网络）
    public func removeAllHistoricalNetworks(exceptCurrent: Bool = true, interface: String? = nil) -> (removedCount: Int, failedCount: Int) {
        let all = listPreferredNetworks(interface: interface)
        let targets = all.filter { !(exceptCurrent && $0.isCurrentActive) }

        var successCount = 0
        var failCount = 0

        for item in targets {
            let res = removePreferredNetwork(ssid: item.ssid, interface: item.interface)
            if res.success {
                successCount += 1
            } else {
                failCount += 1
            }
        }
        return (successCount, failCount)
    }

    /// 刷新并释放系统 DNS 解析缓存 (dscacheutil -flushcache)
    public func flushDNSCache() -> (success: Bool, message: String) {
        guard let result = SafeProcess.run(Self.dscacheutilPath, ["-flushcache"], timeout: 10) else {
            return (false, "无法启动 dscacheutil")
        }
        if result.succeeded { return (true, "已成功清空系统本地 DNS 解析缓存") }
        if result.timedOut { return (false, "DNS 缓存刷新超时") }
        let err = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, err.isEmpty ? "刷新 DNS 失败 (退出码: \(result.exitCode))" : "刷新 DNS 失败: \(err)")
    }
}
