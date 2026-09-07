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
                        .font(Theme.displayFont(22, weight: .semibold))
                        .foregroundColor(Theme.ink)
                    Text("完成一次清理后，记录会显示在这里")
                        .font(Theme.bodyFont(13))
                        .foregroundColor(Theme.inkMuted48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(app.history.enumerated()), id: \.element.id) { index, record in
                            if index > 0 {
                                Divider()
                                    .overlay(Theme.separator.opacity(0.35))
                                    .padding(.leading, 38)
                            }
                            HistoryRow(record: record)
                        }
                    }
                    .macCard(cornerRadius: Theme.radiusMd)
                    .padding(Theme.spaceMd)
                }
            }

            footer
        }
        .background(Theme.windowBackground)
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
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .fill(Theme.actionBlue.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("清理历史")
                    .font(Theme.displayFont(24, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                Text("记录每一次清理动作，可追溯")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.labelSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .frostedBar()
    }

    private var footer: some View {
        HStack {
            Text("共 \(app.history.count) 次清理")
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.labelTertiary)
                .monospacedDigit()
            Text("累计释放 \(totalBytes.byteStringCN)")
                .font(Theme.bodyFont(13, weight: .semibold))
                .foregroundColor(Theme.labelPrimary)
                .monospacedDigit()
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
        .padding(.vertical, 10)
        .frostedBar()
        .overlay(alignment: .top) {
            Divider().overlay(Theme.separator)
        }
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
        HStack(spacing: 10) {
            Image(systemName: record.failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(record.failures > 0 ? Theme.warningOrange : Theme.actionBlue)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.categoryName)
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.labelPrimary)
                    Text(record.mode)
                        .font(Theme.bodyFont(11, weight: .medium))
                        .foregroundColor(record.mode == "彻底删除" ? Theme.textDanger : Theme.actionBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill((record.mode == "彻底删除" ? Theme.dangerRed : Theme.actionBlue).opacity(0.12))
                        )
                }
                Text(Self.formatter.string(from: record.date) + " · \(record.itemCount) 项" +
                     (record.failures > 0 ? " · \(record.failures) 项失败" : ""))
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
                    .monospacedDigit()
            }
            Spacer()
            Text(record.bytes.byteStringCN)
                .font(Theme.monoFont(12, weight: .semibold))
                .foregroundColor(Theme.labelPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .macRowHover(cornerRadius: 0)
    }
}

