import SwiftUI

/// 网络与系统安全隐私数据深度治理视图 (v1.52.0)
public struct NetworkPrivacyView: View {
    @State private var networks: [WiFiNetworkRecord] = []
    @State private var dnsStatus: DNSCacheStatus?
    @State private var currentInterface: String = "en0"
    @State private var isLoading: Bool = false
    @State private var isFlushingDNS: Bool = false
    @State private var isCleaningUnsecured: Bool = false
    @State private var feedbackBanner: String?
    @State private var searchQuery: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: Space.sm) {
            // 反馈横幅
            if let banner = feedbackBanner {
                HStack(spacing: Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Signal.positive)
                    Text(banner)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                    Spacer()
                    Button {
                        withAnimation(Motion.micro) { feedbackBanner = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Ink.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .background(Surface.raised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Surface.hairline, lineWidth: 0.5))
                .motionSafeTransition(.opacity.combined(with: .move(edge: .top)))
            }

            // 1. DNS 缓存治理微卡
            dnsCacheGroup

            // 2. Wi-Fi 访问历史与未加密开放网络排查卡片
            wifiHistoryGroup
        }
        .accessibilityIdentifier("networkPrivacyContainer")
        .onAppear {
            refreshData()
        }
    }

    // MARK: - 1. DNS 缓存治理卡片

    private var dnsCacheGroup: some View {
        GroupBox(title: "DNS 本地解析缓存") {
            GroupedRow(isLast: true) {
                HStack(spacing: Space.sm) {
                    IconSlot(systemName: "network.badge.shield.half.filled", size: 16, color: Accent.tint)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统域名解析缓存")
                            .font(Typo.row)
                            .foregroundStyle(Ink.primary)
                        Text("清空本机临时域名 IP 缓存，消除访问踪迹并刷新陈旧污染解析")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.tertiary)
                    }

                    Spacer(minLength: Space.xs)

                    Button {
                        flushDNS()
                    } label: {
                        if isFlushingDNS {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("清空 DNS 缓存", systemImage: "arrow.clockwise")
                                .font(Typo.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isFlushingDNS)
                    .accessibilityIdentifier("flushDNSButton")
                }
            }
        }
    }

    // MARK: - 2. Wi-Fi 访问历史与安全治理卡片

    private var wifiHistoryGroup: some View {
        let dangerousCount = networks.filter { $0.securityKind.isDangerous }.count
        let filtered = filteredNetworks

        return GroupBox(title: "无线网络历史足迹与安全 (\(networks.count))") {
            VStack(spacing: 0) {
                // 操作工具条
                GroupedRow {
                    HStack(spacing: Space.xs) {
                        Image(systemName: "wifi")
                            .font(.system(size: 12))
                            .foregroundStyle(Ink.secondary)
                        Text("接口: \(currentInterface)")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.secondary)

                        if dangerousCount > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Signal.caution)
                                Text("发现 \(dangerousCount) 个开放无密码网络")
                                    .font(Typo.micro)
                                    .foregroundStyle(Signal.caution)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Signal.caution.opacity(0.12))
                            .clipShape(Capsule())
                        }

                        Spacer(minLength: Space.xs)

                        // 一键清理所有未加密开放网络
                        if dangerousCount > 0 {
                            Button {
                                cleanUnsecured()
                            } label: {
                                if isCleaningUnsecured {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Label("清除开放网络 (\(dangerousCount))", systemImage: "trash")
                                        .font(Typo.micro)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .tint(Signal.critical)
                            .disabled(isCleaningUnsecured)
                            .accessibilityIdentifier("cleanUnsecuredWiFiButton")
                        }

                        // 一键清除全部历史网络（保留当前）
                        Button {
                            cleanAllHistory()
                        } label: {
                            Text("清理历史记录")
                                .font(Typo.micro)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(networks.filter { !$0.isCurrentActive }.isEmpty)
                        .accessibilityIdentifier("cleanHistoricalWiFiButton")

                        Button {
                            refreshData()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("刷新无线网络列表")
                    }
                }

                // 搜索过滤条
                if networks.count > 5 {
                    GroupedRow {
                        HStack(spacing: Space.xs) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(Ink.tertiary)
                            TextField("搜索已记忆的 Wi-Fi 名称…", text: $searchQuery)
                                .textFieldStyle(.plain)
                                .font(Typo.micro)
                            if !searchQuery.isEmpty {
                                Button {
                                    searchQuery = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Ink.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if isLoading {
                    GroupedRow(isLast: true) {
                        HStack {
                            Spacer()
                            ProgressView("正在探查无线网络安全属性…")
                                .controlSize(.small)
                                .font(Typo.micro)
                            Spacer()
                        }
                        .padding(.vertical, Space.sm)
                    }
                } else if filtered.isEmpty {
                    GroupedRow(isLast: true) {
                        HStack {
                            Spacer()
                            Text(networks.isEmpty ? "未检测到已记忆的 Wi-Fi 网络" : "无匹配搜索的网络记录")
                                .font(Typo.micro)
                                .foregroundStyle(Ink.tertiary)
                            Spacer()
                        }
                        .padding(.vertical, Space.sm)
                    }
                } else {
                    ForEach(filtered.indices, id: \.self) { idx in
                        let item = filtered[idx]
                        let isLast = idx == filtered.count - 1
                        GroupedRow(isLast: isLast) {
                            wifiRow(item)
                        }
                    }
                }
            }
        }
    }

    private func wifiRow(_ item: WiFiNetworkRecord) -> some View {
        HStack(spacing: Space.xs) {
            IconSlot(
                systemName: item.securityKind.icon,
                size: 13,
                color: item.securityKind.color,
                width: 18
            )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.ssid)
                        .font(Typo.row)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)

                    if item.isCurrentActive {
                        HStack(spacing: 3) {
                            Circle()
                                .fill(Signal.positive)
                                .frame(width: 6, height: 6)
                            Text("当前连接")
                                .font(Typo.micro)
                                .foregroundStyle(Signal.positive)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Signal.positive.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }

                Text(item.securityKind.label)
                    .font(Typo.micro)
                    .foregroundStyle(item.securityKind.color)
            }

            Spacer(minLength: Space.xs)

            if !item.isCurrentActive {
                Button {
                    removeSingleNetwork(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("从已记住网络中移除 \"\(item.ssid)\"")
                .pressable()
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            } else {
                Text("受保护")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.quaternary)
                    .help("当前正在使用的网络受保护，防止误操作断网")
            }
        }
    }

    private var filteredNetworks: [WiFiNetworkRecord] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return networks
        }
        return networks.filter { $0.ssid.localizedCaseInsensitiveContains(searchQuery) }
    }

    // MARK: - 异步操作链路

    private func refreshData() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let iface = NetworkPrivacyInspector.shared.detectDefaultWiFiInterface()
            let list = NetworkPrivacyInspector.shared.listPreferredNetworks(interface: iface)

            DispatchQueue.main.async {
                self.currentInterface = iface
                self.networks = list
                self.isLoading = false
            }
        }
    }

    private func flushDNS() {
        isFlushingDNS = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = NetworkPrivacyInspector.shared.flushDNSCache()
            DispatchQueue.main.async {
                self.isFlushingDNS = false
                withAnimation(Motion.micro) {
                    self.feedbackBanner = res.message
                }
            }
        }
    }

    private func removeSingleNetwork(_ item: WiFiNetworkRecord) {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = NetworkPrivacyInspector.shared.removePreferredNetwork(ssid: item.ssid, interface: item.interface)
            DispatchQueue.main.async {
                if res.success {
                    withAnimation(Motion.micro) {
                        self.networks.removeAll { $0.ssid == item.ssid }
                        self.feedbackBanner = res.message
                    }
                } else {
                    withAnimation(Motion.micro) {
                        self.feedbackBanner = res.message
                    }
                }
            }
        }
    }

    private func cleanUnsecured() {
        isCleaningUnsecured = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = NetworkPrivacyInspector.shared.removeUnsecuredNetworks(interface: self.currentInterface)
            let updated = NetworkPrivacyInspector.shared.listPreferredNetworks(interface: self.currentInterface)

            DispatchQueue.main.async {
                self.isCleaningUnsecured = false
                withAnimation(Motion.micro) {
                    self.networks = updated
                    self.feedbackBanner = "已成功清除 \(res.removedCount) 个开放未加密网络记录"
                }
            }
        }
    }

    private func cleanAllHistory() {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = NetworkPrivacyInspector.shared.removeAllHistoricalNetworks(exceptCurrent: true, interface: self.currentInterface)
            let updated = NetworkPrivacyInspector.shared.listPreferredNetworks(interface: self.currentInterface)

            DispatchQueue.main.async {
                withAnimation(Motion.micro) {
                    self.networks = updated
                    self.feedbackBanner = "已清除 \(res.removedCount) 个历史网络记录（当前连接已安全保留）"
                }
            }
        }
    }
}
