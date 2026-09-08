import SwiftUI

/// 重复文件查找与去重视图（macOS HIG 原生设计）
struct DuplicateView: View {
    @EnvironmentObject private var app: AppState
    @State private var showConfirmSheet = false
    @State private var permanentMode = false
    @State private var showSettingsPopover = false

    private var dup: DuplicateState { app.duplicateState }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if !dup.groups.isEmpty && !dup.isScanning {
                filterBar
                Divider().overlay(Theme.hairline)
            }

            if dup.isScanning {
                scanningView
            } else if dup.groups.isEmpty {
                emptyView
            } else if dup.filteredGroups.isEmpty {
                emptyFilterView
            } else {
                duplicateListView
            }

            Spacer(minLength: 0)

            if !dup.groups.isEmpty {
                Divider().overlay(Theme.hairline)
                footer
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showConfirmSheet) {
            confirmCleanSheet
        }
    }

    // MARK: - 顶栏
    private var header: some View {
        HStack(spacing: Theme.spaceSm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.actionBlue)
                    Text("重复与相似大文件")
                        .font(Theme.displayFont(16, weight: .semibold))
                        .foregroundColor(Theme.ink)
                }
                Text("基于 SHA-256 分块哈希与智能词干识别，精确去重并排查相似衍生副本。")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
            }

            Spacer()

            if !dup.groups.isEmpty && !dup.isScanning {
                Button("智能勾选副本") {
                    dup.autoSelectDuplicates()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("每组自动保留最早或主副本，仅勾选其余多余副本")

                Button("取消勾选") {
                    dup.deselectAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button {
                dup.startScan()
            } label: {
                Label(dup.groups.isEmpty ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Theme.actionBlue)
            .disabled(dup.isScanning)
            .accessibilityIdentifier("duplicateScanButton")
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceSm)
        .background(Theme.parchment)
    }

    // MARK: - 分类过滤栏
    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("查看分类", selection: Binding(
                get: { dup.filterKind },
                set: { dup.filterKind = $0 }
            )) {
                Text("全部 (\(dup.groups.count))").tag(DuplicateGroupFilter.all)
                Text("完全一致 (\(dup.exactGroupsCount))").tag(DuplicateGroupFilter.exact)
                Text("相似衍生 (\(dup.similarGroupsCount))").tag(DuplicateGroupFilter.similar)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            Text("浪费总计：\(dup.totalWastedBytes.byteStringCN)")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.labelSecondary)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 6)
        .background(Theme.parchment.opacity(0.6))
    }

    // MARK: - 分类过滤空态
    private var emptyFilterView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Theme.labelTertiary)
            Text("当前分类暂无文件")
                .font(Theme.bodyFont(13, weight: .medium))
                .foregroundColor(Theme.labelSecondary)
            Button("查看全部") {
                dup.filterKind = .all
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 扫描中视图
    private var scanningView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: dup.progressFraction)
                .progressViewStyle(.linear)
                .frame(width: 320)
                .tint(Theme.actionBlue)

            Text(dup.scanProgressMessage)
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted80)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 空态视图
    private var emptyView: some View {
        VStack(spacing: Theme.spaceMd) {
            Spacer()
            Image(systemName: "doc.on.doc.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(Theme.actionBlue.opacity(0.7))

            Text("未发现重复文件")
                .font(Theme.displayFont(18, weight: .semibold))
                .foregroundColor(Theme.ink)

            Text("扫描范围：\(dup.searchPaths.joined(separator: " · "))\n点击上方「开始扫描」检测重复占用")
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.inkMuted48)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 重复列表
    private var duplicateListView: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spaceSm) {
                ForEach(dup.filteredGroups) { group in
                    DuplicateGroupCard(group: group)
                }
            }
            .padding(Theme.spaceMd)
        }
    }

    // MARK: - 底栏统计与清理
    private var footer: some View {
        HStack(spacing: Theme.spaceMd) {
            if let summary = dup.lastSummary {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.actionBlue)
                    Text(summary)
                        .font(Theme.bodyFont(12, weight: .medium))
                        .foregroundColor(Theme.inkMuted80)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("已选 \(dup.selectedCount) 个副本（共可释放）")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
                Text(dup.selectedBytes.byteStringCN)
                    .font(Theme.displayFont(18, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                    .monospacedDigit()
            }

            Button {
                showConfirmSheet = true
            } label: {
                Label("清理已选副本", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .disabled(dup.selectedCount == 0 || dup.isScanning)
            .accessibilityIdentifier("duplicateCleanButton")
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceSm)
        .background(Theme.parchment)
    }

    private var confirmCleanSheet: some View {
        CleanConfirmSheet(
            count: dup.selectedCount,
            size: dup.selectedBytes,
            hasPermanent: false,
            hasDanger: false,
            permanent: $permanentMode,
            recentlyUsedCount: 0
        ) { permanent in
            _ = dup.cleanSelected(permanently: permanent)
        }
    }
}

/// 单组重复文件卡片
struct DuplicateGroupCard: View {
    @EnvironmentObject private var app: AppState
    let group: DuplicateGroup
    private var dup: DuplicateState { app.duplicateState }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 组头部：匹配类型徽标 / 文件名 / 副本数量 / 浪费大小
            HStack(spacing: 8) {
                // 匹配模式胶囊徽标
                if group.matchKind == .exact {
                    Text("完全一致")
                        .font(Theme.bodyFont(10, weight: .semibold))
                        .foregroundColor(Theme.actionBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.actionBlue.opacity(0.12)))
                } else {
                    Text("相似衍生")
                        .font(Theme.bodyFont(10, weight: .semibold))
                        .foregroundColor(Theme.warningOrange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.warningOrange.opacity(0.12)))
                }

                Text(group.items.first?.name ?? "未知文件")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                    .lineLimit(1)

                Spacer()

                if group.matchKind == .exact {
                    Text("每份 \(group.fileSize.byteStringCN) · 共 \(group.items.count) 份")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                } else {
                    Text("共 \(group.items.count) 个相似副本")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                }

                Text("可节省 \(group.wastedBytes.byteStringCN)")
                    .font(Theme.monoFont(11, weight: .medium))
                    .foregroundColor(Theme.dangerRed)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.dangerRed.opacity(0.08)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.025))

            if !group.suggestionNote.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.labelTertiary)
                    Text(group.suggestionNote)
                        .font(Theme.bodyFont(10))
                        .foregroundColor(Theme.labelTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }

            Divider().overlay(Theme.separator.opacity(0.3))

            // 副本文件行
            VStack(spacing: 0) {
                ForEach(group.items) { item in
                    DuplicateFileRow(group: group, item: item)
                }
            }
        }
        .macCard(cornerRadius: Theme.radiusMd)
    }
}

/// 单个副本行
struct DuplicateFileRow: View {
    @EnvironmentObject private var app: AppState
    let group: DuplicateGroup
    let item: DuplicateFileItem

    var body: some View {
        HStack(spacing: 10) {
            Button {
                app.duplicateState.toggleItem(groupID: group.id, itemID: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundColor(item.isSelected ? Theme.actionBlue : Theme.labelTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(Theme.bodyFont(12, weight: .medium))
                        .foregroundColor(Theme.labelPrimary)
                        .lineLimit(1)

                    if item.isOriginal {
                        Text(item.recommendationReason ?? "推荐保留")
                            .font(Theme.bodyFont(10, weight: .medium))
                            .foregroundColor(Theme.actionBlue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.actionBlue.opacity(0.1)))
                    } else if let reason = item.recommendationReason {
                        Text(reason)
                            .font(Theme.bodyFont(10))
                            .foregroundColor(Theme.labelTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.04)))
                    }
                }

                HStack(spacing: 8) {
                    Text(item.path)
                        .font(Theme.monoFont(10))
                        .foregroundColor(Theme.labelTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("·")
                        .foregroundColor(Theme.labelTertiary)

                    Text(item.size.byteStringCN)
                        .font(Theme.monoFont(10))
                        .foregroundColor(Theme.labelSecondary)

                    if let mtime = item.modificationDate {
                        Text("·")
                            .foregroundColor(Theme.labelTertiary)
                        Text(Date.usageFormatter.string(from: mtime))
                            .font(Theme.bodyFont(10))
                            .foregroundColor(Theme.labelTertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .macRowHover(cornerRadius: 0)
        .contextMenu {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                app.addPathToWhitelist(item.path, comment: item.name)
            } label: {
                Label("加入白名单排除", systemImage: "shield.slash")
            }
        }
    }
}
