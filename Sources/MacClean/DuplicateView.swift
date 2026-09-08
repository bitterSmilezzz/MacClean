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

            if dup.isScanning {
                scanningView
            } else if dup.groups.isEmpty {
                emptyView
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
                    Text("重复文件查找")
                        .font(Theme.displayFont(16, weight: .semibold))
                        .foregroundColor(Theme.ink)
                }
                Text("基于 SHA-256 哈希精确比对，安全剔除多余副本，保留一份原始文件。")
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
                ForEach(dup.groups) { group in
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
                Text("已选 \(dup.selectedCount) 个重复副本（共可释放）")
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
            // 组头部：文件名 / 单文件大小 / 副本数量 / 浪费大小
            HStack(spacing: 8) {
                Image(systemName: "square.fill.on.square.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.actionBlue)

                Text(group.items.first?.name ?? "未知文件")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                    .lineLimit(1)

                Spacer()

                Text("每份 \(group.fileSize.byteStringCN) · 共 \(group.items.count) 份")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelSecondary)

                Text("浪费 \(group.wastedBytes.byteStringCN)")
                    .font(Theme.monoFont(11, weight: .medium))
                    .foregroundColor(Theme.dangerRed)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.dangerRed.opacity(0.08)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.025))

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
                    Text(item.path)
                        .font(Theme.monoFont(11))
                        .foregroundColor(Theme.labelPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if item.isOriginal {
                        Text("推荐保留")
                            .font(Theme.bodyFont(10, weight: .medium))
                            .foregroundColor(Theme.actionBlue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.actionBlue.opacity(0.1)))
                    }
                }

                if let mtime = item.modificationDate {
                    Text("修改时间：\(Date.usageFormatter.string(from: mtime))")
                        .font(Theme.bodyFont(10))
                        .foregroundColor(Theme.labelTertiary)
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
