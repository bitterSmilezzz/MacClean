import SwiftUI

/// 系统使用体验优化页。
///
/// ## 这一页与"清理"页的三点不同（都是刻意的）
///
/// 1. **没有"全选"、没有"一键优化全部"**。清爽与否是个人口味，工具不该替你一次改十项系统设置；
///    每条都要你自己点，而且点了还要再确认一次。
/// 2. **每条都写明收益与代价**。只讲收益的建议不值得信。
/// 3. **每条都先落撤销记录才动手**，页尾列出可还原的改动。
///
/// 页面上没有"清理"这个词的任何入口——这里改的是偏好，不是删文件。
struct SystemOptimizeView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        // 外层只负责取状态，内层用 `@ObservedObject` 观察它——
        // 这样 `state` 的 @Published 变化才能真正驱动重绘（仓库既有范式）。
        SystemOptimizeBody(state: app.tweaks)
    }
}

private struct SystemOptimizeBody: View {
    @ObservedObject var state: SystemTweakState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header

                if let outcome = state.lastOutcome {
                    outcomeBanner(outcome)
                }
                if let process = state.pendingRestart {
                    restartBanner(process)
                }

                ForEach(SystemTweakGroup.allCases, id: \.self) { group in
                    groupSection(group)
                }

                statusSection
                undoSection
                footerNote
            }
            .padding(Space.xl)
        }
        .onAppear { state.refresh() }
        .confirmationDialog(
            state.pendingApply.map { "确认修改：\($0.title)" } ?? "确认修改",
            isPresented: Binding(get: { state.pendingApply != nil },
                                 set: { if !$0 { state.cancelApply() } }),
            titleVisibility: .visible
        ) {
            Button("确认修改", role: .destructive) { state.confirmApply() }
            Button("取消", role: .cancel) { state.cancelApply() }
        } message: {
            if let tweak = state.pendingApply {
                Text("将把 \(tweak.domain) 的 \(tweak.key) 改成「\(tweak.recommended.display)」。"
                     + "改动会先写入一条撤销记录，随时可以在本页底部还原。\n\n"
                     + "代价：\(tweak.tradeoff)")
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                IconSlot(systemName: "slider.horizontal.3", size: 14, weight: .semibold,
                         color: Accent.tint, width: 20)
                Text("体验优化")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Space.sm)
                Button {
                    state.refresh()
                } label: {
                    Label("重新读取", systemImage: "arrow.clockwise")
                        .font(Typo.row)
                }
                .buttonStyle(.bordered)
                .disabled(state.isInspecting)
                .accessibilityIdentifier("optimizeRefreshButton")
            }
            Text(state.summaryText)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
                .accessibilityIdentifier("optimizeSummary")
            Text("这里改的是系统偏好（Dock / 访达 / 截图 / 键盘），不是删文件。"
                 + "每条都要你自己点、并且先确认；工具不做「一键优化全部」。"
                 + "下面的「系统状态」是只读的——SIP、加密、门禁这些安全边界工具不会替你动。")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func outcomeBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            IconSlot(systemName: "info.circle", size: 12, weight: .medium,
                     color: Signal.caution, width: 16)
            Text(text)
                .font(Typo.row)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Signal.caution.opacity(0.08))
        )
        .accessibilityIdentifier("optimizeOutcomeBanner")
    }

    private func restartBanner(_ process: String) -> some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "arrow.triangle.2.circlepath", size: 12, weight: .medium,
                     color: Accent.tint, width: 16)
            Text("改动已写入，需要重启 \(process) 才会生效。")
                .font(Typo.row)
                .foregroundStyle(Ink.primary)
            Spacer(minLength: Space.sm)
            Button("重启 \(process)") { state.restart(process) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("optimizeRestartButton")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Accent.tint.opacity(0.08))
        )
    }

    // MARK: - 分组

    private func groupSection(_ group: SystemTweakGroup) -> some View {
        let items = state.findings.filter { $0.tweak.group == group }
        return VStack(alignment: .leading, spacing: Space.sm) {
            Text(group.title)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.secondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { idx, finding in
                    GroupedRow(isLast: idx == items.count - 1) {
                        row(finding)
                    }
                }
            }
            .background(Surface.group)
            .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        }
    }

    private func row(_ finding: TweakFinding) -> some View {
        let tweak = finding.tweak
        let optimal = finding.status == .alreadyOptimal
        let unreadable = finding.status == .unreadable
        let busy = state.busyTweakID == tweak.id

        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(tweak.title)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)

                Spacer(minLength: Space.sm)

                // 现状 → 推荐。**"未设置"与"等于 0"显示得不一样**，用户才不会误判。
                HStack(spacing: 4) {
                    Text(unreadable ? "读不到" : (finding.current?.display ?? "读不到"))
                        .font(Typo.caption)
                        .foregroundStyle(unreadable ? Ink.tertiary : Ink.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9))
                        .foregroundStyle(Ink.tertiary)
                    Text(tweak.recommended.display)
                        .font(Typo.caption)
                        .foregroundStyle(optimal ? Signal.positive : Accent.tint)
                }
                .accessibilityIdentifier("optimizeValue_\(tweak.id)")

                statusChip(finding)
            }

            Text(tweak.benefit)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 代价必须一直看得见，不是藏在确认弹窗里
            if tweak.tradeoff != "无副作用" {
                Text("代价：\(tweak.tradeoff)")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: Space.xs) {
                Button {
                    state.requestApply(tweak)
                } label: {
                    Text(optimal ? "已是推荐值" : "应用")
                        .font(Typo.row)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(optimal || unreadable || busy)
                .accessibilityIdentifier("optimizeApply_\(tweak.id)")

                if unreadable {
                    Text("读不到当前值：读不到旧值就没有真正的撤销，所以这里不能改")
                        .font(Typo.caption)
                        .foregroundStyle(Signal.caution)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 2)
    }

    private func statusChip(_ finding: TweakFinding) -> some View {
        let (text, color): (String, Color) = {
            switch finding.status {
            case .alreadyOptimal: return ("已是推荐值", Signal.positive)
            case .deviates:       return ("可优化", Signal.caution)
            case .unreadable:     return ("读不到", Ink.tertiary)
            }
        }()
        return Text(text)
            .font(Typo.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    // MARK: - 系统状态（只读）

    /// 只读状态区。
    ///
    /// **一整块没有按钮**，这是刻意的：这里每一项要么需要管理员权限，要么动的是安全边界
    /// （SIP / 全盘加密 / 门禁 / 防火墙）。一个"帮你关掉 SIP 更自由"的按钮与清理软件的定位冲突——
    /// 工具把现状读准、说清含义、告诉你去哪儿改，剩下的交给你。
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                Text("系统状态（只读）")
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.secondary)
                Text("工具不会改这些")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            if state.statusFindings.isEmpty {
                Text("正在读取…")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.sm)
                    .background(Surface.group)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.statusFindings.enumerated()), id: \.element.id) { idx, finding in
                        GroupedRow(isLast: idx == state.statusFindings.count - 1) {
                            statusRow(finding)
                        }
                    }
                }
                .background(Surface.group)
                .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            }
        }
    }

    private func statusRow(_ finding: StatusFinding) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(finding.check.title)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
                Spacer(minLength: Space.sm)
                statusReadingChip(finding.reading)
            }

            Text(finding.check.whatItDoes)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 原始证据要看得见：用户能拿它去自己核对，而不是只能信这句结论
            Text(finding.reading.evidence)
                .font(Font.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)
                .lineLimit(2)
                .textSelection(.enabled)

            if let detail = finding.detail {
                Text(detail)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
            }

            Text("去哪儿改：\(finding.check.whereToChange)")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func statusReadingChip(_ reading: StatusReading) -> some View {
        let color: Color = {
            switch reading {
            case .on: return Signal.positive
            case .off: return Signal.caution
            case .unknown: return Ink.tertiary
            }
        }()
        return Text(reading.label)
            .font(Typo.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    // MARK: - 撤销

    private var undoSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("可还原的改动")
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.secondary)

            if state.records.isEmpty {
                Text("还没有改过任何设置。改过的每一条都会出现在这里，可随时还原。")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.sm)
                    .background(Surface.group)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.records.reversed().enumerated()), id: \.element.id) { idx, record in
                        GroupedRow(isLast: idx == state.records.count - 1) {
                            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(state.title(for: record))
                                        .font(Typo.row)
                                        .foregroundStyle(Ink.primary)
                                    Text("\(record.domain) · \(record.key) → "
                                         + "改前：\(record.previous.display)")
                                        .font(Typo.caption)
                                        .foregroundStyle(Ink.tertiary)
                                }
                                Spacer(minLength: Space.sm)
                                Button("撤销") { state.revert(record) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .disabled(state.busyTweakID != nil)
                                    .accessibilityIdentifier("optimizeRevert_\(record.key)")
                            }
                        }
                    }
                }
                .background(Surface.group)
                .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
            }
        }
    }

    private var footerNote: some View {
        Text("说明：这些是**偏好**改动，不删除任何文件，也不涉及磁盘空间。"
             + "每一条的旧值（含「原本没设过」）都会先写进撤销记录；"
             + "还原「原本没设过」的键时是把它删掉，而不是写一个看起来像默认值的数。")
            .font(Typo.caption)
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
