import SwiftUI

/// 清理确认弹窗（G2 二次确认 + G3 废纸篓/彻底删除选择）
/// permanent 用 @Binding 注入：状态归属调用方（也便于 ViewInspector 稳定测试）
///
/// 重写要点：
///  - 标题回到语义字号阶梯（`Typo.title`），不再逐处硬编码 22pt。
///  - 两个方式选项去掉"自绘描边卡片"，改为 `GroupBox` 分组内的可选行：
///    选中态用 `mcSelection`（强调色轻填充）+ 单选图标表达。
///  - 警示文案去掉 emoji，图标交给 SF Symbol；强调色只有 `Accent.tint` 一个，
///    `Signal.*` 只出现在风险提示与彻底删除按钮上。
///  - 操作区收成一个主按钮 + 一个文字动作，不再并排两个等权按钮。
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
        VStack(alignment: .leading, spacing: Space.md) {
            // 标题与概要
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("确认清理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)

                Text("将清理 \(count) 项，共 \(size.byteStringCN)" + (hint.map { "（\($0)）" } ?? ""))
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
            }

            // 近期使用警告（用户诉求：最近在用/频繁使用的项先提醒）
            if recentlyUsedCount > 0 {
                noticeRow(icon: "clock.badge.exclamationmark",
                          text: "其中 \(recentlyUsedCount) 项近期或频繁使用中，确认删除前请留意",
                          color: Signal.caution)
            }

            // 方式选择（G3）
            GroupBox(title: "清理方式") {
                optionRow(title: "移入废纸篓（推荐）",
                          detail: "可随时恢复，最安全",
                          isSelected: !permanent,
                          identifier: "trashOption") {
                    permanent = false
                }

                optionRow(title: "彻底删除",
                          detail: "不可恢复，请谨慎",
                          isSelected: permanent,
                          identifier: "permanentOption",
                          isLast: true) {
                    permanent = true
                }
            }

            // 警告区
            if hasPermanent {
                noticeRow(icon: "trash",
                          text: "包含废纸篓内容，将直接彻底删除",
                          color: Signal.caution)
            }
            if hasDanger {
                noticeRow(icon: "exclamationmark.triangle.fill",
                          text: "包含高风险项，建议仅移入废纸篓并逐一确认",
                          color: Signal.critical)
            }

            // 操作：一个主按钮 + 一个文字动作
            HStack(spacing: Space.sm) {
                Spacer(minLength: Space.sm)

                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(Typo.row)
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .pressable()
                .rowHover()
                .keyboardShortcut(.cancelAction)
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
                .tint(permanent ? Signal.critical : Accent.tint)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("confirmButton")
            }
        }
        .padding(Space.xl)
        .frame(width: 420)
    }

    // MARK: - 方式选项（分组内的可选行）

    private func optionRow(title: String, detail: String, isSelected: Bool,
                           identifier: String, isLast: Bool = false,
                           action: @escaping () -> Void) -> some View {
        GroupedRow(isLast: isLast) {
            Button(action: action) {
                HStack(spacing: Space.xs) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Accent.tint : Ink.tertiary)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)
                        Text(detail)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                    }

                    Spacer(minLength: Space.xs)
                }
                .contentShape(Rectangle())
            }
            .pressable()
            .rowHover()
            .selectionHighlight(isSelected)
            .accessibilityIdentifier(identifier)
        }
    }

    // MARK: - 提示行（近期使用 / 风险）

    private func noticeRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: icon, size: 12, weight: .medium, color: color, width: 16)
            Text(text)
                .font(Typo.row)
                .foregroundStyle(Ink.primary)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }
}
