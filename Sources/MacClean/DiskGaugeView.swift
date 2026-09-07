import SwiftUI

/// 磁盘用量仪表（macOS HIG 纯正原生风格：克制利落的系统监控仪表）
struct DiskGaugeView: View {
    @EnvironmentObject private var app: AppState

    private var isHighUsage: Bool {
        app.usedRatio > 0.88
    }

    private var gaugeColor: Color {
        isHighUsage ? Theme.warningOrange : Theme.actionBlue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            HStack {
                Label("磁盘空间", systemImage: "internaldrive")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                Spacer()
                Text("Macintosh HD")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
            }

            ZStack {
                // 背景刻度环
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 7)

                // 用量进度弧线（纯正原生系统强调色，平滑利落）
                Circle()
                    .trim(from: 0, to: max(0.02, app.usedRatio))
                    .stroke(
                        gaugeColor,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: app.usedRatio)

                VStack(spacing: 2) {
                    Text(app.diskUsed.byteStringCN)
                        .font(Theme.displayFont(20, weight: .semibold))
                        .foregroundColor(Theme.labelPrimary)
                        .monospacedDigit()
                    Text("已用 · 共 \(app.diskTotal.byteStringCN)")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                        .monospacedDigit()
                }
            }
            .frame(width: 140, height: 140)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)

            HStack {
                HStack(spacing: 5) {
                    Circle()
                        .fill(gaugeColor)
                        .frame(width: 6, height: 6)
                    Text("可用 \(app.diskAvailable.byteStringCN)")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                        .monospacedDigit()
                }
                Spacer()
                Text("\(Int(app.usedRatio * 100))%")
                    .font(Theme.monoFont(11, weight: .medium))
                    .foregroundColor(isHighUsage ? Theme.textWarning : Theme.labelSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
        }
        .padding(Theme.spaceSm)
        .macCard(cornerRadius: Theme.radiusMd)
    }
}
