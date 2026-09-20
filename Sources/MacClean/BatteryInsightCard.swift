import SwiftUI

// MARK: - 系统电池健康度与充放电循环深度体检卡片

public struct BatteryInsightCard: View {
    @ObservedObject private var monitor = BatteryMonitor.shared

    public var onClose: (() -> Void)?

    public init(onClose: (() -> Void)? = nil) {
        self.onClose = onClose
    }

    private var info: BatteryInfo {
        monitor.info
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            if info.hasBattery {
                batteryMetricsContent
            } else {
                desktopMacContent
            }
        }
        .padding(Space.sm)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                .stroke(Surface.hairline, lineWidth: 1)
        )
    }

    // MARK: - 顶栏

    private var topHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: info.hasBattery ? (info.isCharging ? "battery.100.bolt" : "battery.75percent") : "desktopcomputer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Accent.tint)

            Text("电池健康与电源体检")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            if info.hasBattery {
                Text(info.condition.rawValue)
                    .font(Typo.micro)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(info.condition.badgeColor.opacity(0.14))
                    .foregroundStyle(info.condition.badgeColor)
                    .clipShape(Capsule())
            }

            Spacer()

            Button(action: {
                monitor.refresh()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("刷新电池硬件数据")

            if let closeAction = onClose {
                Button(action: closeAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Ink.tertiary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("关闭卡片")
            }
        }
    }

    // MARK: - 内置电池核心指标区

    private var batteryMetricsContent: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            // 健康度与主仪表条
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(format: "%.1f", info.healthPercent))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(info.condition.badgeColor)
                        Text("%")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                    }
                    Text("当前电池真实健康度")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                }

                Divider()
                    .frame(height: 32)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(info.isCharging ? "⚡ 正在充电" : (info.isPluggedIn ? "🔌 已连接电源" : "🔋 电池供电中"))
                            .font(Typo.caption)
                            .foregroundStyle(Ink.primary)
                        Spacer()
                        if let timeStr = info.timeRemainingString {
                            Text(info.isCharging ? "预计充满: \(timeStr)" : "剩余可用: \(timeStr)")
                                .font(Typo.micro)
                                .foregroundStyle(Accent.tint)
                        }
                    }

                    ProgressView(value: Double(info.currentPercent), total: 100.0)
                        .tint(info.condition.badgeColor)
                        .scaleEffect(x: 1, y: 0.85, anchor: .center)
                }
            }
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 8)
            .background(Surface.sunken)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))

            // 4 栏紧凑指标网格
            HStack(spacing: 8) {
                metricBox(
                    title: "循环计数",
                    value: "\(info.cycleCount) 次",
                    subtitle: "设计寿命 1000 次",
                    icon: "arrow.triangle.2.circlepath",
                    color: Ink.primary
                )

                metricBox(
                    title: "实际最大容量",
                    value: "\(info.maxCapacity) mAh",
                    subtitle: "设计 \(info.designCapacity) mAh",
                    icon: "bolt.fill",
                    color: Accent.tint
                )

                metricBox(
                    title: info.isCharging ? "充电功率" : "放电功率",
                    value: String(format: "%.1f W", info.wattage),
                    subtitle: "\(info.isCharging ? "+" : "-")\(abs(info.amperageMilliamp)) mA",
                    icon: "speedometer",
                    color: info.isCharging ? Signal.positive : Signal.caution
                )

                metricBox(
                    title: "电池温度",
                    value: info.temperatureCelsius != nil ? String(format: "%.1f°C", info.temperatureCelsius!) : "--",
                    subtitle: (info.temperatureCelsius ?? 0) > 38 ? "⚠️ 温度偏高" : "正常温区",
                    icon: "thermometer.medium",
                    color: (info.temperatureCelsius ?? 0) > 38 ? Signal.caution : Ink.primary
                )
            }
        }
    }

    private func metricBox(title: String, value: String, subtitle: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.secondary)
                Text(title)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
            }
            Text(value)
                .font(.mcNumeric(12, weight: .semibold))
                .foregroundStyle(color)
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundStyle(Ink.quaternary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - 桌面设备展示（Mac mini / Mac Studio / Mac Pro / iMac）

    private var desktopMacContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 22))
                .foregroundStyle(Accent.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("当前为桌面台式 Mac 设备")
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
                Text("设备由外接交流电直接供电，无内置锂电池损耗与充放电循环老化影响。")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}
