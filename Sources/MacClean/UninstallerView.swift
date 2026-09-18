import SwiftUI

/// App 卸载器（融合 Pearcleaner / PureMac：选 App → 扫全部关联文件 → 移废纸篓）
///
/// 重写要点：
///  - 44×44 的蓝色圆角图标底板、26pt 的巨大标题都删掉：图标就是图标，标题回到 `Typo.title`。
///  - 装饰性副标题（"· 规则 A1–A4"）删掉，右侧位置改放真实数据：已列出的 App 数量。
///  - 浮空卡片换成 inset group：所选 App 信息、关联文件列表都是 `GroupBox` + `GroupedRow`。
///  - 空态统一走 `EmptyState`，搜索框走 `SearchField`，行悬停走 `.rowHover()`。
///  - 全 App 只剩 `Accent.tint` 一个强调色；橙色只留给"App 正在运行"这个真实警告。
struct UninstallerView: View {
    @EnvironmentObject private var app: AppState
    @State private var searchText = ""
    @State private var confirmPermanent = false

    private var uninstaller: UninstallerState { app.uninstaller }

    private var filteredApps: [InstalledApp] {
        let list = uninstaller.apps
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if uninstaller.apps.isEmpty && !uninstaller.isScanning {
                emptyView
            } else {
                HStack(spacing: 0) {
                    appList
                    Divider()
                    relatedPanel
                }
            }
        }
        .background(Surface.window)
        .onAppear {
            if uninstaller.apps.isEmpty { uninstaller.loadApps() }
        }
        .confirmationDialog("彻底删除不可恢复", isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("彻底删除所选", role: .destructive) {
                _ = uninstaller.uninstallSelected(permanently: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(uninstaller.selectedFiles.count) 个关联文件（\(uninstaller.selectedSize.byteStringCN)），此操作无法恢复。建议优先使用「移入废纸篓」。")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            IconSlot(systemName: "app.dashed", size: 14, weight: .medium,
                     color: Ink.secondary, width: 18)

            Text("App 卸载器")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Spacer()

            if !uninstaller.apps.isEmpty {
                Text("\(filteredApps.count) 个 App")
                    .font(.mcNumeric(11))
                    .foregroundStyle(Ink.tertiary)
            }

            Button {
                uninstaller.loadApps()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    // MARK: - 空态

    @ViewBuilder
    private var emptyView: some View {
        if uninstaller.isScanning {
            VStack(spacing: Space.sm) {
                ProgressView().controlSize(.large)
                Text("正在扫描已安装 App…")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(
                icon: "app.dashed",
                title: "未发现可卸载的 App",
                message: "如果刚刚安装过 App，可以重新扫描一次。",
                actionTitle: "重新扫描",
                action: { uninstaller.loadApps() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - App 列表

    private var appList: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: "搜索 App", text: $searchText)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredApps) { app in
                        Button {
                            withAnimation(Motion.micro) {
                                uninstaller.select(app)
                            }
                        } label: {
                            AppRow(app: app, isSelected: uninstaller.selectedApp == app)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("uninstallAppRow")
                    }
                }
                .padding(.horizontal, Space.xs)
                .padding(.bottom, Space.md)
            }
        }
        .frame(width: 280)
        .background(Surface.group)
    }

    // MARK: - 关联文件面板

    private var relatedPanel: some View {
        VStack(spacing: 0) {
            if let app = uninstaller.selectedApp {
                appSummary(app)

                if app.isRunning {
                    runningWarning
                }

                if uninstaller.isScanning {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("正在查找关联文件…")
                            .font(Typo.body)
                            .foregroundStyle(Ink.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.md)
                    .padding(.top, Space.md)
                } else if uninstaller.related.isEmpty {
                    EmptyState(
                        icon: "checkmark.circle",
                        title: "未发现残留文件",
                        message: "该 App 很干净，或残留已被清理。"
                    )
                } else {
                    relatedList(app: app)
                }
            } else {
                EmptyState(
                    icon: "hand.point.up.left",
                    title: "从左侧选择一个 App",
                    message: "选中后会扫描它的关联文件，可逐项勾选清理。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    // MARK: - 所选 App 概要

    private func appSummary(_ app: InstalledApp) -> some View {
        GroupBox {
            GroupedRow(isLast: true) {
                HStack(spacing: Space.sm) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(Typo.title)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)

                        Text(app.path)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let bundleID = app.bundleID {
                            Text(bundleID)
                                .font(Typo.caption)
                                .foregroundStyle(Ink.quaternary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Space.sm)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(app.size.byteStringCN)
                            .font(.mcNumeric(15, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text("本体")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.md)
    }

    private var runningWarning: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "exclamationmark.triangle.fill", size: 12,
                     color: Signal.caution, width: 16)
            Text("该 App 正在运行，关联文件扫描已暂停。请先退出后再卸载。")
                .font(Typo.body)
                .foregroundStyle(Signal.caution)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Signal.caution.opacity(0.1))
        )
        .padding(.horizontal, Space.md)
        .padding(.top, Space.sm)
    }

    private func relatedList(app: InstalledApp) -> some View {
        VStack(spacing: 0) {
            // 全选行
            HStack(spacing: Space.xs) {
                Button(uninstaller.allSelected ? "取消全选" : "全选") {
                    uninstaller.setAllSelected(!uninstaller.allSelected)
                }
                .pressable()
                .font(Typo.row)
                .foregroundStyle(Accent.tint)

                Spacer()

                Text("\(uninstaller.related.count) 项 · \(uninstaller.related.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                    .font(.mcNumeric(11))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)

            ScrollView {
                GroupBox {
                    ForEach(Array(uninstaller.related.enumerated()), id: \.element.id) { index, file in
                        GroupedRow(isLast: index == uninstaller.related.count - 1) {
                            RelatedFileRow(file: file)
                                .contentShape(Rectangle())
                                .onTapGesture { uninstaller.toggle(file.id, !file.isSelected) }
                                // 行内 checkbox 已是真 Button（键盘可激活）；整行点击补 VO 按钮语义
                                .accessibilityAddTraits(file.isSelected ? [.isSelected] : [])
                                .accessibilityLabel("\(file.name)，\(file.size.byteStringCN)")
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.md)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            if let summary = uninstaller.lastSummary {
                HStack(spacing: Space.xxs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.positive)
                    Text(summary)
                        .font(Typo.body)
                        .foregroundStyle(Ink.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(uninstaller.selectedFiles.count) 项")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .motionSafeNumericTransition()
                Text(uninstaller.selectedSize.byteStringCN)
                    .font(.mcNumeric(17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            // 彻底删除（红色，需二次确认）
            Button {
                confirmPermanent = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Signal.critical)
            .accessibilityIdentifier("uninstallPermanentButton")
            .disabled(uninstaller.selectedFiles.isEmpty || uninstaller.isUninstalling)

            // 移入废纸篓（默认安全路径）
            Button {
                _ = uninstaller.uninstallSelected(permanently: false)
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("uninstallTrashButton")
            .disabled(uninstaller.selectedFiles.isEmpty || uninstaller.isUninstalling)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Hairline()
        }
    }
}

/// App 行（展示真实应用图标 + 右键访达定位）
struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: app.path)
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text(app.name)
                    .font(isSelected ? Typo.rowStrong : Typo.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text(app.size.byteStringCN)
                    .font(.mcNumeric(10))
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: Space.xxs)
            if app.isRunning {
                Circle().fill(Signal.caution).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .selectionHighlight(isSelected)
        .rowHover()
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: app.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.path, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
        }
    }
}

/// 关联文件行（支持右键访达定位与拷贝路径）
struct RelatedFileRow: View {
    @EnvironmentObject private var app: AppState
    let file: RelatedFile

    private var uninstaller: UninstallerState { app.uninstaller }

    var body: some View {
        HStack(spacing: Space.sm) {
            Button(action: { uninstaller.toggle(file.id, !file.isSelected) }) {
                Image(systemName: file.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(file.isSelected ? Accent.tint : Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("relatedFileToggle")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(file.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(file.kind)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                }
                Text(file.path)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.xs)
            Text(file.size.byteStringCN)
                .font(.mcNumeric(12, weight: .medium))
                .foregroundStyle(Ink.primary)

            // 问 AI：针对该关联文件提问（LOW-2：请求在途时禁用）
            Button {
                app.ai.askAbout(file: file)
            } label: {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(app.ai.isLoading ? Ink.quaternary : Accent.tint)
            }
            .buttonStyle(.plain)
            .disabled(app.ai.isLoading)
            .accessibilityIdentifier("askAIFileButton")
            .help(app.ai.isLoading ? "AI 回复中，请稍候" : "问 AI：这个残留是什么？能删吗？")
            .accessibilityLabel(app.ai.isLoading ? "AI 回复中，请稍候" : "问 AI：这个残留是什么？能删吗？")
        }
        .contentShape(Rectangle())
        .rowHover()
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: file.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                uninstaller.toggle(file.id, !file.isSelected)
            } label: {
                Label(file.isSelected ? "取消选择" : "勾选删除", systemImage: file.isSelected ? "xmark.circle" : "checkmark.circle")
            }

            Divider()

            Button {
                app.addPathToWhitelist(file.path, comment: file.name)
            } label: {
                Label("加入白名单排除（不再关联）", systemImage: "shield.slash")
            }
        }
    }
}
