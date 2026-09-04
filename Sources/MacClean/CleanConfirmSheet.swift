import SwiftUI

/// 清理确认弹窗（G2 二次确认 + G3 废纸篓/彻底删除选择）
/// permanent 用 @Binding 注入：状态归属调用方（也便于 ViewInspector 稳定测试）
struct CleanConfirmSheet: View {
    @Environment(\.dismiss) private var dismiss
    let count: Int
    let size: Int64
    let hasPermanent: Bool
    let hasDanger: Bool
    /// 附加提示（如"含隐藏已选 N 项"），非必填
    var hint: String? = nil
    /// 其中近期使用中的项数（用户诉求：清理前明确提示"最近在用"）
    var recentlyUsedCount: Int = 0
    let onConfirm: (Bool) -> Void
    @Binding var permanent: Bool

    init(count: Int, size: Int64, hasPermanent: Bool, hasDanger: Bool,
         permanent: Binding<Bool>, hint: String? = nil, recentlyUsedCount: Int = 0,
         onConfirm: @escaping (Bool) -> Void) {
        self.count = count
        self.size = size
        self.hasPermanent = hasPermanent
        self.hasDanger = hasDanger
        self.hint = hint
        self.recentlyUsedCount = recentlyUsedCount
        self.onConfirm = onConfirm
        self._permanent = permanent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 标题
            VStack(alignment: .leading, spacing: 4) {
                Text("确认清理")
                    .font(Theme.displayFont(22, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("将清理 \(count) 项，共 \(size.byteStringCN)" + (hint.map { "（\($0)）" } ?? ""))
                    .font(Theme.bodyFont(13))
                    .foregroundColor(Theme.inkMuted48)
                // 近期使用警告（用户诉求：最近在用/频繁使用的项先提醒）
                if recentlyUsedCount > 0 {
                    Text("⚠️ 其中 \(recentlyUsedCount) 项近期或频繁使用中，确认删除前请留意")
                        .font(Theme.bodyFont(13, weight: .semibold))
                        .foregroundColor(Theme.textWarning)
                        .padding(.top, 2)
                }
            }

            // 方式选择（G3）
            VStack(alignment: .leading, spacing: 10) {
                Text("清理方式")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)

                Button(action: { permanent = false }) {
                    HStack(spacing: 10) {
                        Image(systemName: permanent ? "circle" : "largecircle.fill.circle")
                            .foregroundColor(permanent ? Theme.inkMuted48 : Theme.actionBlue)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("移入废纸篓（推荐）")
                                .font(Theme.bodyFont(13, weight: .medium))
                                .foregroundColor(Theme.ink)
                            Text("可随时恢复，最安全")
                                .font(Theme.bodyFont(11))
                                .foregroundColor(Theme.inkMuted48)
                        }
                        Spacer()
                    }
                    .padding(Theme.spaceSm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .fill(permanent ? Theme.parchment : Theme.actionBlue.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radiusMd)
                                    .stroke(permanent ? Theme.hairline : Theme.actionBlue.opacity(0.5), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("trashOption")

                Button(action: { permanent = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: permanent ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(permanent ? Theme.dangerRed : Theme.inkMuted48)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("彻底删除")
                                .font(Theme.bodyFont(13, weight: .medium))
                                .foregroundColor(Theme.ink)
                            Text("不可恢复，请谨慎")
                                .font(Theme.bodyFont(11))
                                .foregroundColor(Theme.inkMuted48)
                        }
                        Spacer()
                    }
                    .padding(Theme.spaceSm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .fill(permanent ? Theme.dangerRed.opacity(0.06) : Theme.parchment)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radiusMd)
                                    .stroke(permanent ? Theme.dangerRed.opacity(0.5) : Theme.hairline, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("permanentOption")
            }

            // 警告区
            if hasPermanent {
                warningRow(icon: "trash",
                           text: "包含废纸篓内容，将直接彻底删除",
                           color: Theme.warningOrange)
            }
            if hasDanger {
                warningRow(icon: "exclamationmark.triangle.fill",
                           text: "包含高风险项，建议仅移入废纸篓并逐一确认",
                           color: Theme.dangerRed)
            }

            // 操作
            HStack(spacing: Theme.spaceSm) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("cancelButton")

                Button {
                    onConfirm(permanent)
                    dismiss()
                } label: {
                    Label(permanent ? "彻底删除 \(count) 项" : "移入废纸篓",
                          systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(permanent ? Theme.textDanger : Theme.actionBlue)
                .accessibilityIdentifier("confirmButton")
            }
        }
        .padding(Theme.spaceXl)
        .frame(width: 420)
    }

    private func warningRow(icon: String, text: String, color: Color) -> some View {
        // 三巡：警示文字用深色变体（亮色 2.2:1/3.5:1 不达标），图标保留亮色
        let textColor: Color = color == Theme.dangerRed ? Theme.textDanger : Theme.textWarning
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
            Text(text)
                .font(Theme.bodyFont(12, weight: .medium))
                .foregroundColor(textColor)
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(color.opacity(0.08)))
    }
}
