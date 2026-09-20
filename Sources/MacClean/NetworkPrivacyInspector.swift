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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listallhardwareports"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return Self.parseWiFiInterface(from: output)
        } catch {
            return "en0"
        }
    }

    /// 获取当前正在连接中的 Wi-Fi SSID
    public func getCurrentWiFiNetwork(interface: String? = nil) -> String? {
        let iface = interface ?? detectDefaultWiFiInterface()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-getairportnetwork", iface]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return Self.parseCurrentWiFiNetwork(from: output)
        } catch {
            return nil
        }
    }

    /// 检查指定 SSID 在 Keychain 中是否存在 AirPort 密码记录（确定是否属于加密保护网络）
    public func checkSecurityKind(ssid: String) -> WiFiSecurityKind {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", "AirPort",
            "-a", ssid,
            "/Library/Keychains/System.keychain"
        ]

        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .wpaEncrypted
            } else {
                // 钥匙串中无该 SSID 密码，且存在于首选网络中 → 判定为开放无加密网络
                return .openUnsecured
            }
        } catch {
            return .unknown
        }
    }

    /// 全量列出已保存的首选 Wi-Fi 网络及其安全属性
    public func listPreferredNetworks(interface: String? = nil) -> [WiFiNetworkRecord] {
        let iface = interface ?? detectDefaultWiFiInterface()
        let currentSSID = getCurrentWiFiNetwork(interface: iface)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-listpreferredwirelessnetworks", iface]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let ssids = Self.parsePreferredNetworks(from: output)

            return ssids.map { ssid in
                let sec = checkSecurityKind(ssid: ssid)
                let isCurrent = (ssid == currentSSID)
                return WiFiNetworkRecord(
                    ssid: ssid,
                    securityKind: sec,
                    interface: iface,
                    isCurrentActive: isCurrent
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - 清理与治理动作

    /// 单项移除指定的首选无线网络记录
    public func removePreferredNetwork(ssid: String, interface: String? = nil) -> (success: Bool, message: String) {
        let iface = interface ?? detectDefaultWiFiInterface()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = ["-removepreferredwirelessnetwork", iface, ssid]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if process.terminationStatus == 0 {
                return (true, "已成功从已保存网络中移除 \"\(ssid)\"")
            } else {
                return (false, output.isEmpty ? "移除网络失败 (退出码: \(process.terminationStatus))" : output)
            }
        } catch {
            return (false, "执行 networksetup 异常: \(error.localizedDescription)")
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                return (true, "已成功清空系统本地 DNS 解析缓存")
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let err = String(data: data, encoding: .utf8) ?? ""
                return (false, "刷新 DNS 失败: \(err)")
            }
        } catch {
            return (false, "执行 dscacheutil 异常: \(error.localizedDescription)")
        }
    }
}
