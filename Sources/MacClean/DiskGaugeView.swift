import SwiftUI

/// 磁盘用量仪表（Apple 深色 tile 风格）
struct DiskGaugeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            HStack {
                Text("磁盘空间")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.bodyMuted)
                Spacer()
                Text("Macintosh HD")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.bodyMuted.opacity(0.7))
            }

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: max(0.02, app.usedRatio))
                    .stroke(
                        Theme.skyLinkBlue,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(app.diskUsed.byteStringCN)
                        .font(Theme.displayFont(22, weight: .semibold))
                        .foregroundColor(.white)
                        .tracking(-0.3)
                    Text("已用 · 共 \(app.diskTotal.byteStringCN)")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.bodyMuted)
                }
            }
            .frame(width: 150, height: 150)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            HStack {
                Circle().fill(Theme.skyLinkBlue).frame(width: 7, height: 7)
                Text("可用 \(app.diskAvailable.byteStringCN)")
                    .font(Theme.bodyFont(11, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
            }
        }
        .padding(Theme.spaceLg)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .fill(Theme.tile1)
        )
    }
}
