import SwiftUI

/// App 卸载器（融合 Pearcleaner / PureMac：选 App → 扫全部关联文件 → 移废纸篓）
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
            Divider().overlay(Theme.hairline)

            if uninstaller.apps.isEmpty && !uninstaller.isScanning {
                emptyView
            } else {
                HStack(spacing: 0) {
                    appList
                    Divider().overlay(Theme.hairline)
                    relatedPanel
                }
            }
        }
        .background(Theme.parchment)
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
        HStack(spacing: Theme.spaceMd) {
            Image(systemName: "app.dashed")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.actionBlue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text("App 卸载器")
                    .font(Theme.displayFont(28, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("选择 App，扫描其全部关联文件后一键清理 · 规则 A1–A4")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()

            Button {
                uninstaller.loadApps()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.actionBlue)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .background(Theme.canvas)
    }

    // MARK: - 空态

    private var emptyView: some View {
        VStack(spacing: Theme.spaceMd) {
            if uninstaller.isScanning {
                ProgressView().controlSize(.large).tint(Theme.actionBlue)
                Text("正在扫描已安装 App…").font(Theme.bodyFont(14)).foregroundColor(Theme.inkMuted48)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(Theme.inkMuted48.opacity(0.6))
                Text("未发现可卸载的 App")
                    .font(Theme.displayFont(24, weight: .semibold))
                    .foregroundColor(Theme.ink)
                Button {
                    uninstaller.loadApps()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.actionBlue)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - App 列表

    private var appList: some View {
        VStack(spacing: 0) {
            // 搜索
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.inkMuted48)
                TextField("搜索 App", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.bodyFont(12))
            }
            .padding(.horizontal, Theme.spaceMd)
            .padding(.vertical, Theme.spaceXs)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.canvas))
            
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, Theme.contentPadding)
            .padding(.bottom, Theme.spaceSm)

            ScrollView {
                VStack(spacing: Theme.spaceSm) {
                    ForEach(filteredApps) { app in
                        AppRow(app: app, isSelected: uninstaller.selectedApp == app)
                            .contentShape(Rectangle())
                            .onTapGesture { uninstaller.select(app) }
                    }
                }
                .padding(.horizontal, Theme.spaceSm)
                .padding(.bottom, Theme.contentPadding)
            }
        }
        .frame(width: 280)
        .background(Theme.parchment)
    }

    // MARK: - 关联文件面板

    private var relatedPanel: some View {
        VStack(spacing: 0) {
            if let app = uninstaller.selectedApp {
                // 所选 App 信息
                HStack(spacing: Theme.spaceSm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .font(Theme.displayFont(20, weight: .semibold))
                            .foregroundColor(Theme.ink)
                        Text(app.path)
                            .font(Theme.bodyFont(11))
                            .foregroundColor(Theme.inkMuted48)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let bundleID = app.bundleID {
                            Text(bundleID)
                                .font(Theme.bodyFont(11))
                                .foregroundColor(Theme.inkMuted48.opacity(0.8))
                        }
                    }
                    Spacer()
                    Text("本体 \(app.size.byteStringCN)")
                        .font(Theme.bodyFont(14, weight: .semibold))
                        .foregroundColor(Theme.inkMuted80)
                }
                .padding(Theme.spaceMd)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.canvas))
                
                .padding(Theme.spaceMd)

                if app.isRunning {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.warningOrange)
                        Text("该 App 正在运行，关联文件扫描已暂停。请先退出后再卸载。")
                            .font(Theme.bodyFont(14, weight: .medium))
                            .foregroundColor(Theme.warningOrange)
                    }
                    .padding(.horizontal, Theme.spaceMd)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.warningOrange.opacity(0.08)))
                    .padding(.horizontal, Theme.spaceMd)
                }

                if uninstaller.isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.actionBlue)
                        Text("正在查找关联文件…")
                            .font(Theme.bodyFont(12))
                            .foregroundColor(Theme.inkMuted48)
                    }
                    .padding(Theme.spaceMd)
                } else if uninstaller.related.isEmpty {
                    VStack(spacing: Theme.spaceXs) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(Theme.actionBlue.opacity(0.7))
                        Text("未发现残留文件")
                            .font(Theme.bodyFont(15, weight: .medium))
                            .foregroundColor(Theme.inkMuted48)
                        Text("该 App 很干净，或残留已被清理")
                            .font(Theme.bodyFont(11))
                            .foregroundColor(Theme.inkMuted48.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.spaceXl)
                } else {
                    relatedList(app: app)
                }
            } else {
                VStack(spacing: Theme.spaceXs) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(Theme.inkMuted48.opacity(0.6))
                    Text("从左侧选择一个 App")
                        .font(Theme.bodyFont(14))
                        .foregroundColor(Theme.inkMuted48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private func relatedList(app: InstalledApp) -> some View {
        VStack(spacing: 0) {
            // 全选行
            HStack {
                Button(uninstaller.allSelected ? "取消全选" : "全选") {
                    uninstaller.setAllSelected(!uninstaller.allSelected)
                }
                .buttonStyle(.plain)
                .font(Theme.bodyFont(14, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                Spacer()
                Text("\(uninstaller.related.count) 个关联文件 · 共 \(uninstaller.related.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
            }
            .padding(.horizontal, Theme.spaceMd)
            .padding(.vertical, Theme.spaceXs)

            ScrollView {
                LazyVStack(spacing: Theme.spaceSm) {
                    ForEach(Array(uninstaller.related.enumerated()), id: \.element.id) { _, file in
                        RelatedFileRow(file: file)
                            .contentShape(Rectangle())
                            .onTapGesture { uninstaller.toggle(file.id, !file.isSelected) }
                    }
                }
                .padding(.horizontal, Theme.spaceMd)
                .padding(.bottom, Theme.spaceMd)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.spaceMd) {
            if let summary = uninstaller.lastSummary {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.actionBlue)
                    Text(summary)
                        .font(Theme.bodyFont(14, weight: .medium))
                        .foregroundColor(Theme.inkMuted80)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(uninstaller.selectedFiles.count) 项")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
                Text(uninstaller.selectedSize.byteStringCN)
                    .font(Theme.displayFont(20, weight: .semibold))
                    .foregroundColor(Theme.ink)
            }

            // 彻底删除（红色，需二次确认）
            Button {
                confirmPermanent = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.dangerRed)
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
            .tint(Theme.actionBlue)
            .accessibilityIdentifier("uninstallTrashButton")
            .disabled(uninstaller.selectedFiles.isEmpty || uninstaller.isUninstalling)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceSm)
        .background(Theme.canvas.overlay(alignment: .top) {
            Divider().overlay(Theme.hairline)
        })
    }
}

/// App 行
struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Theme.spaceSm) {
            Image(systemName: "app.fill")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? Theme.actionBlue : Theme.inkMuted48)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Theme.actionBlue.opacity(0.12) : Theme.parchment))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(Theme.bodyFont(14, weight: .medium))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                Text(app.size.byteStringCN)
                    .font(Theme.bodyFont(10))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()
            if app.isRunning {
                Circle().fill(Theme.warningOrange).frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, Theme.spaceXs)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(isSelected ? Theme.actionBlue.opacity(0.08) : Theme.pearl)
                
        )
    }
}

/// 关联文件行
struct RelatedFileRow: View {
    @EnvironmentObject private var app: AppState
    let file: RelatedFile

    private var uninstaller: UninstallerState { app.uninstaller }

    var body: some View {
        HStack(spacing: Theme.spaceSm) {
            Button(action: { uninstaller.toggle(file.id, !file.isSelected) }) {
                Image(systemName: file.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18))
                    .foregroundColor(file.isSelected ? Theme.actionBlue : Theme.hairline)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("relatedFileToggle")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(Theme.bodyFont(14, weight: .semibold))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    Text(file.kind)
                        .font(Theme.bodyFont(12, weight: .medium))
                        .foregroundColor(Theme.inkMuted48)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.parchment))
                }
                Text(file.path)
                    .font(Theme.bodyFont(10))
                    .foregroundColor(Theme.inkMuted48)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(file.size.byteStringCN)
                .font(Theme.bodyFont(14, weight: .semibold))
                .foregroundColor(Theme.ink)
                .monospacedDigit()

            // 问 AI：针对该关联文件提问
            Button {
                app.ai.askAbout(file: file)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.actionBlue)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.actionBlue.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("askAIFileButton")
            .help("问 AI：这个残留是什么？能删吗？")
        }
        .padding(.horizontal, Theme.spaceMd)
        .padding(.vertical, Theme.spaceXs)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.pearl)
                
        )
    }
}
