import SwiftUI
import AppKit

// MARK: - 开发工程构建产物透视与治理卡片

public struct DevProjectInspectorCard: View {
    @ObservedObject private var scanner = DevProjectScanner.shared
    @EnvironmentObject private var app: AppState

    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var statusFilter: ProjectStatusFilter = .all
    @State private var selectedTechFilter: DevProjectType? = nil
    @State private var searchKeyword: String = ""
    @State private var expandedProjectIds: Set<String> = []
    @State private var showConfirmCleanAll: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var isCleaning: Bool = false

    public enum ProjectStatusFilter: String, CaseIterable, Identifiable {
        case all = "全部工程"
        case stale = "🍂 陈旧 (>30天)"
        case active = "🔥 活跃 (<7天)"
        case orphan = "👻 孤儿产物"

        public var id: String { rawValue }
    }

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if let feedback = bannerFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Signal.positive)
                    Text(feedback)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Signal.positive.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .motionSafeTransition(.opacity)
            }

            filterBar

            if scanner.isScanning {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Text("正在深潜探测工程根目录与构建产物…")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.secondary)
                    Spacer()
                }
                .frame(height: 120)
            } else if filteredProjects.isEmpty {
                emptyStateView
            } else {
                projectListView
            }

            bottomActionBar
        }
        .padding(12)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            if scanner.projects.isEmpty && !scanner.isScanning {
                scanner.scan()
            }
        }
        .alert("一键释放选中构建产物", isPresented: $showConfirmCleanAll) {
            Button("移入废纸篓", role: .destructive) {
                performBatchClean(permanently: false)
            }
            Button("彻底删除", role: .destructive) {
                performBatchClean(permanently: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(totalSelectedSize.byteStringCN) 构建产物（纯 target/.build/DerivedData/node_modules 目录，绝对不影响工程源码）。可在废纸篓中随时找回。")
        }
    }

    // MARK: - 过滤计算

    private var filteredProjects: [DevProject] {
        var res = scanner.projects

        switch statusFilter {
        case .all:
            break
        case .stale:
            res = res.filter(\.isStale)
        case .active:
            res = res.filter(\.isActive)
        case .orphan:
            res = res.filter(\.isOrphan)
        }

        if let tech = selectedTechFilter {
            res = res.filter { $0.types.contains(tech) }
        }

        let q = searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            res = res.filter {
                $0.name.localizedCaseInsensitiveContains(q) ||
                $0.path.localizedCaseInsensitiveContains(q)
            }
        }

        return res
    }

    private var totalArtifactSize: Int64 {
        scanner.projects.reduce(0) { $0 + $1.totalArtifactSize }
    }

    private var totalStaleOrOrphanSize: Int64 {
        scanner.projects.filter(\.isStale).reduce(0) { $0 + $1.totalArtifactSize }
    }

    private var totalSelectedSize: Int64 {
        scanner.projects.reduce(0) { $0 + $1.selectedArtifactSize }
    }

    // MARK: - 顶栏

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Accent.tint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("本地工程构建产物透视与治理")
                        .font(Typo.section)
                        .foregroundStyle(Ink.primary)

                    Text("v1.57.0")
                        .font(Typo.micro)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Accent.tint.opacity(0.15))
                        .foregroundStyle(Accent.tint)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }

                Text("已聚合 \(scanner.projects.count) 个本地工程 · 总产物 \(totalArtifactSize.byteStringCN) · 陈旧/孤儿 \(totalStaleOrOrphanSize.byteStringCN) 可释放")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
            }

            Spacer()

            Button {
                scanner.scan()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("重新扫描")
                        .font(Typo.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rescanDevProjectsButton")

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeDevProjectCardButton")
        }
    }

    // MARK: - 筛选条

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $statusFilter) {
                    ForEach(ProjectStatusFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.quaternary)
                    TextField("搜索工程名或路径…", text: $searchKeyword)
                        .textFieldStyle(.plain)
                        .font(Typo.caption)
                    if !searchKeyword.isEmpty {
                        Button {
                            searchKeyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Ink.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: 200)
            }

            HStack(spacing: 6) {
                Text("技术栈:")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)

                techTag(title: "全部", type: nil)

                ForEach(DevProjectType.allCases) { tech in
                    techTag(title: tech.rawValue, type: tech)
                }

                Spacer()
            }
        }
    }

    private func techTag(title: String, type: DevProjectType?) -> some View {
        let isSelected = selectedTechFilter == type
        return Button {
            withAnimation(Motion.micro) {
                selectedTechFilter = type
            }
        } label: {
            HStack(spacing: 3) {
                if let t = type {
                    Image(systemName: t.iconName)
                        .font(.system(size: 9))
                }
                Text(title)
                    .font(Typo.micro)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isSelected ? Accent.tint.opacity(0.18) : Surface.sunken)
            .foregroundStyle(isSelected ? Accent.tint : Ink.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工程列表视图

    private var projectListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredProjects) { project in
                    DevProjectRow(
                        project: project,
                        isExpanded: expandedProjectIds.contains(project.id),
                        onToggleExpand: {
                            if expandedProjectIds.contains(project.id) {
                                expandedProjectIds.remove(project.id)
                            } else {
                                expandedProjectIds.insert(project.id)
                            }
                        },
                        onToggleSelect: {
                            toggleProjectSelection(project)
                        },
                        onToggleArtifact: { art in
                            toggleArtifactSelection(project: project, artifact: art)
                        },
                        onClean: {
                            cleanSingleProject(project)
                        },
                        onCopyPath: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(project.path, forType: .string)
                            showBanner("已拷贝工程路径")
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 320)
    }

    // MARK: - 底部批量操作栏

    private var bottomActionBar: some View {
        HStack(spacing: 10) {
            Button {
                smartSelectStaleAndOrphan()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                    Text("智能勾选陈旧项 (跳过活跃工程)")
                        .font(Typo.caption)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("smartSelectStaleDevProjectsButton")

            Spacer()

            Text("已勾选 \(totalSelectedSize.byteStringCN)")
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)

            Button {
                showConfirmCleanAll = true
            } label: {
                HStack(spacing: 4) {
                    if isCleaning {
                        ProgressView().controlSize(.small)
                        Text("正在释放…")
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("一键释放选中产物")
                    }
                }
                .font(Typo.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(totalSelectedSize > 0 ? Accent.tint : Color.gray.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(totalSelectedSize == 0 || isCleaning)
            .accessibilityIdentifier("cleanAllSelectedDevArtifactsButton")
        }
        .padding(.top, 4)
    }

    private var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 20))
                    .foregroundStyle(Ink.quaternary)
                Text("当前筛选条件下未发现构建产物")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.vertical, 30)
            Spacer()
        }
    }

    // MARK: - 业务逻辑

    private func toggleProjectSelection(_ project: DevProject) {
        guard let idx = scanner.projects.firstIndex(where: { $0.id == project.id }) else { return }
        let shouldSelect = !scanner.projects[idx].isAllSelected
        for i in 0..<scanner.projects[idx].artifacts.count {
            scanner.projects[idx].artifacts[i].isSelected = shouldSelect
        }
    }

    private func toggleArtifactSelection(project: DevProject, artifact: DevProjectArtifact) {
        guard let pIdx = scanner.projects.firstIndex(where: { $0.id == project.id }) else { return }
        guard let aIdx = scanner.projects[pIdx].artifacts.firstIndex(where: { $0.id == artifact.id }) else { return }
        scanner.projects[pIdx].artifacts[aIdx].isSelected.toggle()
    }

    private func smartSelectStaleAndOrphan() {
        for pIdx in 0..<scanner.projects.count {
            let isStale = scanner.projects[pIdx].isStale
            for aIdx in 0..<scanner.projects[pIdx].artifacts.count {
                scanner.projects[pIdx].artifacts[aIdx].isSelected = isStale
            }
        }
        showBanner("已智能勾选所有陈旧与孤儿工程产物，活跃工程已安全跳过")
    }

    private func cleanSingleProject(_ project: DevProject) {
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = scanner.cleanProject(project, permanently: false)
            DispatchQueue.main.async {
                self.isCleaning = false
                if res.success {
                    self.showBanner("成功释放 \(project.name) 构建产物（\(res.freedBytes.byteStringCN)）")
                    self.onTriggerClean?()
                } else {
                    self.showBanner("清理遇到部分受限文件，已跳过")
                }
            }
        }
    }

    private func performBatchClean(permanently: Bool) {
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var totalFreed: Int64 = 0
            for proj in scanner.projects {
                let res = scanner.cleanProject(proj, permanently: permanently)
                totalFreed += res.freedBytes
            }
            DispatchQueue.main.async {
                self.isCleaning = false
                self.showBanner("批量释放完成！共夺回 \(totalFreed.byteStringCN) 存储空间")
                self.onTriggerClean?()
            }
        }
    }

    private func showBanner(_ message: String) {
        withAnimation(Motion.standard) {
            bannerFeedback = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation {
                self.bannerFeedback = nil
            }
        }
    }
}

// MARK: - 子视图拆分：单个工程卡片行

struct DevProjectRow: View {
    let project: DevProject
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onToggleSelect: () -> Void
    let onToggleArtifact: (DevProjectArtifact) -> Void
    let onClean: () -> Void
    let onCopyPath: () -> Void

    private var selectCheckbox: some View {
        let isSelected = project.isAllSelected || project.isPartiallySelected
        let icon = project.isAllSelected ? "checkmark.square.fill" : (project.isPartiallySelected ? "minus.square.fill" : "square")
        let color = isSelected ? Accent.tint : Ink.quaternary
        return Button(action: onToggleSelect) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }

    private var projectHeaderTitle: some View {
        HStack(spacing: 4) {
            ForEach(project.types) { t in
                Image(systemName: t.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(t.badgeColor)
            }
            Text(project.name)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)
        }
    }

    private var statusBadge: some View {
        Text(project.statusBadgeText)
            .font(Typo.micro)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(project.statusBadgeColor.opacity(0.14))
            .foregroundStyle(project.statusBadgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            selectCheckbox
            projectHeaderTitle
            statusBadge
            Spacer()
            Text(project.totalArtifactSize.byteStringCN)
                .font(.mcNumeric(12, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Button(action: onToggleExpand) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
        }
    }

    private var cleanActionButton: some View {
        let hasArtifacts = project.selectedArtifactSize > 0
        let textColor = hasArtifacts ? Signal.critical : Ink.tertiary
        return Button(action: onClean) {
            HStack(spacing: 3) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                Text("释放产物 (\(project.selectedArtifactSize.byteStringCN))")
                    .font(Typo.micro)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Surface.sunken)
            .foregroundStyle(textColor)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!hasArtifacts)
    }

    private var metaAndActionRow: some View {
        HStack(spacing: 8) {
            Text(project.path)
                .font(Typo.micro)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button(action: onCopyPath) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 9))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("拷贝绝对路径")

            if !project.isOrphan {
                Button {
                    NSWorkspace.shared.selectFile(project.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(Ink.secondary)
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }

            Spacer()

            cleanActionButton
        }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        if isExpanded {
            VStack(spacing: 4) {
                ForEach(project.artifacts) { art in
                    DevArtifactRow(
                        artifact: art,
                        onToggle: { onToggleArtifact(art) }
                    )
                }
            }
            .padding(6)
            .background(Surface.sunken.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow
            metaAndActionRow
            artifactsSection
        }
        .padding(10)
        .background(Surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 子视图拆分：单个产物目录行

struct DevArtifactRow: View {
    let artifact: DevProjectArtifact
    let onToggle: () -> Void

    var body: some View {
        let iconName = artifact.isSelected ? "checkmark.circle.fill" : "circle"
        let iconColor = artifact.isSelected ? Accent.tint : Ink.quaternary
        return HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
            }
            .buttonStyle(.plain)

            Image(systemName: artifact.kind.iconName)
                .font(.system(size: 10))
                .foregroundStyle(Ink.secondary)

            Text(artifact.name)
                .font(Typo.caption)
                .foregroundStyle(Ink.primary)

            Text(artifact.path)
                .font(Typo.micro)
                .foregroundStyle(Ink.quaternary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(artifact.size.byteStringCN)
                .font(.mcNumeric(11, weight: .medium))
                .foregroundStyle(Ink.secondary)
        }
        .padding(.leading, 18)
        .padding(.vertical, 2)
    }
}
