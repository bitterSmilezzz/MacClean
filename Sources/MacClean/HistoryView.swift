import SwiftUI

/// 清理历史（融合 Mole `mo history`）
struct HistoryView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmClear = false

    private var totalBytes: Int64 { app.history.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if app.history.isEmpty {
                VStack(spacing: Theme.spaceSm) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(Theme.inkMuted48.opacity(0.6))
                    Text("暂无清理记录")
                        .font(Theme.displayFont(18, weight: .semibold))
                        .foregroundColor(Theme.ink)
                    Text("完成一次清理后，记录会显示在这里")
                        .font(Theme.bodyFont(13))
                        .foregroundColor(Theme.inkMuted48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(app.history) { record in
                            HistoryRow(record: record)
                        }
                    }
                    .padding(Theme.spaceLg)
                }
            }

            footer
        }
        .background(Theme.parchment)
        .confirmationDialog("清空历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { app.clearHistory() }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spaceMd) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.actionBlue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text("清理历史")
                    .font(Theme.displayFont(24, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("记录每一次清理动作，可追溯 · 借鉴 Mole mo history")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .background(Theme.canvas)
    }

    private var footer: some View {
        HStack {
            Text("共 \(app.history.count) 次清理")
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.inkMuted48)
            Text("累计释放 \(totalBytes.byteStringCN)")
                .font(Theme.bodyFont(12, weight: .semibold))
                .foregroundColor(Theme.inkMuted80)
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Label("清空记录", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.dangerRed)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceSm)
        .background(Theme.canvas.overlay(alignment: .top) {
            Divider().overlay(Theme.hairline)
        })
    }
}

struct HistoryRow: View {
    let record: CleanRecord

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: Theme.spaceSm) {
            Image(systemName: record.failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundColor(record.failures > 0 ? Theme.warningOrange : Theme.actionBlue)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.categoryName)
                        .font(Theme.bodyFont(13, weight: .semibold))
                        .foregroundColor(Theme.ink)
                    Text(record.mode)
                        .font(Theme.bodyFont(10, weight: .medium))
                        .foregroundColor(record.mode == "彻底删除" ? Theme.dangerRed : Theme.actionBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill((record.mode == "彻底删除" ? Theme.dangerRed : Theme.actionBlue).opacity(0.1)))
                }
                Text(Self.formatter.string(from: record.date) + " · \(record.itemCount) 项" +
                     (record.failures > 0 ? " · \(record.failures) 项失败" : ""))
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()
            Text(record.bytes.byteStringCN)
                .font(Theme.bodyFont(13, weight: .semibold))
                .foregroundColor(Theme.ink)
                .monospacedDigit()
        }
        .padding(.horizontal, Theme.spaceMd)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
    }
}
