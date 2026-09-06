import SwiftUI

/// 磁盘用量仪表（现代通透 macOS 风格，支持双模式自适应）
struct DiskGaugeView: View {
    @EnvironmentObject private var app: AppState

    private var isHighUsage: Bool {
        app.usedRatio > 0.88
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            HStack {
                Label("磁盘空间", systemImage: "internaldrive")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                Spacer()
                Text("Macintosh HD")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
            }

            ZStack {
                // 背景刻度环
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 10)

                // 用量进度弧线（带渐变与圆角端点）
                Circle()
                    .trim(from: 0, to: max(0.02, app.usedRatio))
                    .stroke(
                        isHighUsage ? Theme.diskWarningGradient : Theme.diskUsedGradient,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: app.usedRatio)

                VStack(spacing: 3) {
                    Text(app.diskUsed.byteStringCN)
                        .font(Theme.displayFont(22, weight: .bold))
                        .foregroundColor(Theme.labelPrimary)
                        .monospacedDigit()
                        .tracking(-0.4)
                    Text("已用 · 共 \(app.diskTotal.byteStringCN)")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 154, height: 154)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isHighUsage ? Theme.warningOrange : Theme.actionBlue)
                        .frame(width: 7, height: 7)
                    Text("可用 \(app.diskAvailable.byteStringCN)")
                        .font(Theme.bodyFont(11, weight: .medium))
                        .foregroundColor(Theme.labelSecondary)
                        .monospacedDigit()
                }
                Spacer()
                Text("\(Int(app.usedRatio * 100))%")
                    .font(Theme.monoFont(11, weight: .semibold))
                    .foregroundColor(isHighUsage ? Theme.textWarning : Theme.actionBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill((isHighUsage ? Theme.warningOrange : Theme.actionBlue).opacity(0.12))
                    )
            }
        }
        .padding(Theme.spaceMd)
        .modernCard(cornerRadius: Theme.radiusLg)
    }
}
