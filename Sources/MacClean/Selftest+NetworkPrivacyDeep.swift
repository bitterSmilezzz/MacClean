import Foundation
import Combine
import SwiftUI
import ViewInspector

// 自检套件：网络与系统安全隐私数据深度体检 (v1.52.0)
extension Selftest {
    static func suiteNetworkPrivacyDeep() {
        check("网络隐私解析：Wi-Fi 硬件端口解析鲁棒性 (parseWiFiInterface)") {
            let sampleOutput = """
            Hardware Port: Ethernet Adapter (en3)
            Device: en3
            Ethernet Address: da:d9:6b:79:f8:35

            Hardware Port: Wi-Fi
            Device: en0
            Ethernet Address: 68:5e:dd:79:02:25

            Hardware Port: Thunderbolt Bridge
            Device: bridge0
            """

            let iface = NetworkPrivacyInspector.parseWiFiInterface(from: sampleOutput)
            guard iface == "en0" else { return false }

            // 异常/未包含 Wi-Fi 时兜底 en0
            let fallback = NetworkPrivacyInspector.parseWiFiInterface(from: "Hardware Port: Bluetooth\nDevice: en9")
            guard fallback == "en0" else { return false }

            return true
        }

        check("网络隐私解析：首选无线网络列表文本过滤 (parsePreferredNetworks)") {
            let sampleList = """
            Preferred networks on en0:
            \tCMCC-606-5G
            \tZTE_886688
            \tHotel_Free_WiFi
            \tStarbucks_Guest

            """

            let ssids = NetworkPrivacyInspector.parsePreferredNetworks(from: sampleList)
            guard ssids == ["CMCC-606-5G", "ZTE_886688", "Hotel_Free_WiFi", "Starbucks_Guest"] else { return false }

            let emptyList = NetworkPrivacyInspector.parsePreferredNetworks(from: "Preferred networks on en0:\n")
            guard emptyList.isEmpty else { return false }

            return true
        }

        check("网络隐私解析：当前连接 Wi-Fi 状态判定 (parseCurrentWiFiNetwork)") {
            let connected = "Current Wi-Fi Network: MyHome_5G\n"
            guard NetworkPrivacyInspector.parseCurrentWiFiNetwork(from: connected) == "MyHome_5G" else { return false }

            let disconnected = "You are not associated with an AirPort network.\n"
            guard NetworkPrivacyInspector.parseCurrentWiFiNetwork(from: disconnected) == nil else { return false }

            guard NetworkPrivacyInspector.parseCurrentWiFiNetwork(from: "") == nil else { return false }
            return true
        }

        check("网络安全模型：WiFiSecurityKind 与风险判定不变量") {
            guard WiFiSecurityKind.openUnsecured.isDangerous == true else { return false }
            guard WiFiSecurityKind.wpaEncrypted.isDangerous == false else { return false }
            guard WiFiSecurityKind.unknown.isDangerous == false else { return false }

            let activeRecord = WiFiNetworkRecord(ssid: "Work_Office", securityKind: .wpaEncrypted, isCurrentActive: true)
            guard activeRecord.id == "Work_Office" && activeRecord.isCurrentActive == true else { return false }

            return true
        }

        check("网络风险联动：未加密 Wi-Fi 与过多历史网络检测 (RiskScanner)") {
            let safeRecords = [
                WiFiNetworkRecord(ssid: "Home", securityKind: .wpaEncrypted),
                WiFiNetworkRecord(ssid: "Office", securityKind: .wpaEncrypted)
            ]

            // 1. 全部加密安全时不报警
            guard RiskScanner.checkUnsecuredWiFi(records: safeRecords) == nil else { return false }

            // 2. 存在开放网络时报警
            let riskyRecords = [
                WiFiNetworkRecord(ssid: "Home", securityKind: .wpaEncrypted),
                WiFiNetworkRecord(ssid: "Airport_Free", securityKind: .openUnsecured),
                WiFiNetworkRecord(ssid: "Cafe_Open", securityKind: .openUnsecured)
            ]

            let unsecuredRisk = RiskScanner.checkUnsecuredWiFi(records: riskyRecords)
            guard let unsecuredRisk = unsecuredRisk, unsecuredRisk.severity == .medium else { return false }
            guard unsecuredRisk.detail.contains("Airport_Free") && unsecuredRisk.category == .networkExposure else { return false }

            // 3. 历史记录阈值检测
            guard RiskScanner.checkExcessiveWiFiHistory(records: safeRecords, threshold: 5) == nil else { return false }
            let excessive = (0..<16).map { WiFiNetworkRecord(ssid: "Net_\($0)", securityKind: .wpaEncrypted) }
            let historyRisk = RiskScanner.checkExcessiveWiFiHistory(records: excessive, threshold: 15)
            guard let historyRisk = historyRisk, historyRisk.severity == .low else { return false }

            return true
        }

        check("系统工具调用：命令与参数受控、失败如实上报（注入 runner，不真动系统 DNS）") {
            // 自检此前会**真的执行** `dscacheutil -flushcache`：每次自检都把用户的
            // DNS 缓存清空一次，而它断言的只是"退出码 0"。改为注入假 runner 之后，
            // 断言的是真正有风险的部分：调的是哪个可执行文件、参数对不对、
            // 非 0 退出码有没有被谎报成成功。
            let saved = SafeProcess.runner
            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "Hardware Port: Wi-Fi\nDevice: en0\n")
            }
            defer { SafeProcess.runner = saved }

            let iface = NetworkPrivacyInspector.shared.detectDefaultWiFiInterface()
            guard iface == "en0" else { return false }
            guard seen.last?.1 == ["-listallhardwareports"] else { return false }

            let flushRes = NetworkPrivacyInspector.shared.flushDNSCache()
            guard flushRes.success else { return false }
            guard seen.last?.0 == NetworkPrivacyInspector.dscacheutilPath,
                  seen.last?.1 == ["-flushcache"] else { return false }

            // 非 0 退出码必须转成失败，不能被当成"已刷新"
            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "operation not permitted")
            }
            let failRes = NetworkPrivacyInspector.shared.flushDNSCache()
            guard !failRes.success, failRes.message.contains("operation not permitted") else { return false }

            // 钥匙串授权被拒（44）绝不能读成"这是个开放网络"
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 44, output: "") }
            guard NetworkPrivacyInspector.shared.checkSecurityKind(ssid: "Corp") == .unknown else { return false }
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 45, output: "") }
            guard NetworkPrivacyInspector.shared.checkSecurityKind(ssid: "Cafe") == .openUnsecured else { return false }
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            guard NetworkPrivacyInspector.shared.checkSecurityKind(ssid: "Home") == .wpaEncrypted else { return false }
            return true
        }

        check("网络隐私视图渲染：NetworkPrivacyView 与 RiskView 标签切换 ViewInspector 检验") {
            let privacyView = NetworkPrivacyView()
            guard let inspectedPrivacy = try? privacyView.inspect() else { return false }

            // 校验根容器、DNS 按钮与清理历史按钮
            guard (try? inspectedPrivacy.find(viewWithAccessibilityIdentifier: "networkPrivacyContainer")) != nil else {
                return false
            }
            guard (try? inspectedPrivacy.find(viewWithAccessibilityIdentifier: "flushDNSButton")) != nil else {
                return false
            }
            guard (try? inspectedPrivacy.find(viewWithAccessibilityIdentifier: "cleanHistoricalWiFiButton")) != nil else {
                return false
            }

            // 检验 RiskView 中的分段选择器
            let app = AppState()
            let riskView = RiskView().environmentObject(app)
            guard let inspectedRisk = try? riskView.inspect() else { return false }
            guard (try? inspectedRisk.find(viewWithAccessibilityIdentifier: "riskTabPicker")) != nil else {
                return false
            }

            return true
        }
    }
}
