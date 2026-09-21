import SwiftUI

/// App 卸载器与孤儿残留排查（融合 Pearcleaner / PureMac：选 App 卸载 + 孤儿文件全盘检索 + 偏好碎片反查）
struct UninstallerView: View {
    @EnvironmentObject private var app: AppState
    @State private var searchText = ""
    @State private var orphanSearchText = ""
    @State private var preferenceSearchText = ""
    @State private var pluginSearchText = ""
    @State private var selectedPluginKind: PluginExtensionKind? = nil
    @State private var selectedPluginStatus: PluginExtensionStatus? = nil
    @State private var localizationSearchText = ""
    @State private var confirmPermanent = false
    @State private var confirmPermanentOrphans = false
    @State private var confirmPermanentPreferences = false
    @State private var confirmPermanentPlugins = false
    @State private var confirmPermanentLocalization = false

    private var uninstaller: UninstallerState { app.uninstaller }

    private var filteredApps: [InstalledApp] {
        let list = uninstaller.apps
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredOrphanApps: [OrphanApp] {
        let list = uninstaller.orphanApps
        guard !orphanSearchText.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(orphanSearchText) ||
            ($0.bundleID?.localizedCaseInsensitiveContains(orphanSearchText) == true)
        }
    }

    private var filteredPreferences: [OrphanPreferenceItem] {
        let list = uninstaller.preferenceItems
        guard !preferenceSearchText.isEmpty else { return list }
        return list.filter {
            $0.appName.localizedCaseInsensitiveContains(preferenceSearchText) ||
            $0.bundleID.localizedCaseInsensitiveContains(preferenceSearchText) ||
            $0.fileName.localizedCaseInsensitiveContains(preferenceSearchText)
        }
    }

    private var filteredPlugins: [PluginExtensionItem] {
        var list = uninstaller.pluginItems
        if let kind = selectedPluginKind {
            list = list.filter { $0.kind == kind }
        }
        if let status = selectedPluginStatus {
            list = list.filter { $0.status == status }
        }
        guard !pluginSearchText.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(pluginSearchText) ||
            ($0.bundleID?.localizedCaseInsensitiveContains(pluginSearchText) == true) ||
            ($0.hostAppName?.localizedCaseInsensitiveContains(pluginSearchText) == true) ||
            $0.path.localizedCaseInsensitiveContains(pluginSearchText)
        }
    }

    private var filteredLocalizationBundles: [AppLocalizationBundle] {
        let list = uninstaller.localizationBundles
        guard !localizationSearchText.isEmpty else { return list }
        return list.filter {
            $0.appName.localizedCaseInsensitiveContains(localizationSearchText) ||
            ($0.bundleID?.localizedCaseInsensitiveContains(localizationSearchText) == true)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            switch uninstaller.currentTab {
            case .apps:
                if uninstaller.apps.isEmpty && !uninstaller.isScanning {
                    emptyAppsView
                } else {
                    HStack(spacing: 0) {
                        appList
                        Divider()
                        relatedPanel
                    }
                }
            case .orphans:
                if uninstaller.orphanApps.isEmpty && !uninstaller.isScanningOrphans {
                    emptyOrphansView
                } else {
                    HStack(spacing: 0) {
                        orphanAppList
                        Divider()
                        orphanRelatedPanel
                    }
                }
            case .preferences:
                preferencePanel
            case .extensions:
                pluginsPanel
            case .localization:
                localizationPanel
            case .loginItems:
                loginItemsPanel
            }
        }
        .background(Surface.window)
        .onAppear {
            if uninstaller.apps.isEmpty { uninstaller.loadApps() }
            if uninstaller.orphanApps.isEmpty { uninstaller.loadOrphans() }
            if uninstaller.preferenceItems.isEmpty { uninstaller.loadPreferences() }
            if uninstaller.pluginItems.isEmpty { uninstaller.loadPlugins() }
            if uninstaller.localizationBundles.isEmpty { uninstaller.loadLocalization() }
        }
        .confirmationDialog("彻底删除不可恢复", isPresented: $confirmPermanent, titleVisibility: .visible) {
            Button("彻底删除所选", role: .destructive) {
                _ = uninstaller.uninstallSelected(permanently: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(uninstaller.selectedFiles.count) 个关联文件（\(uninstaller.selectedSize.byteStringCN)），此操作无法恢复。建议优先使用「移入废纸篓」。")
        }
        .confirmationDialog("彻底删除孤儿残留", isPresented: $confirmPermanentOrphans, titleVisibility: .visible) {
            Button("彻底删除所选", role: .destructive) {
                _ = uninstaller.cleanSelectedOrphans(permanently: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(uninstaller.selectedOrphanCount) 个孤儿残留组件（\(uninstaller.selectedOrphanSize.byteStringCN)），此操作无法恢复。建议优先使用「移入废纸篓」。")
        }
        .confirmationDialog("彻底删除偏好碎片", isPresented: $confirmPermanentPreferences, titleVisibility: .visible) {
            Button("彻底删除所选", role: .destructive) {
                _ = uninstaller.cleanSelectedPreferences(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(uninstaller.selectedPreferencesCount) 个偏好碎片（\(uninstaller.selectedPreferencesSize.byteStringCN)），此操作无法恢复。建议优先使用「移入废纸篓」。")
        }
        .confirmationDialog("彻底删除插件与扩展", isPresented: $confirmPermanentPlugins, titleVisibility: .visible) {
            Button("彻底删除所选", role: .destructive) {
                _ = uninstaller.cleanSelectedPlugins(permanently: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将彻底删除 \(uninstaller.selectedPluginCount) 个插件与扩展（\(uninstaller.selectedPluginSize.byteStringCN)），此操作无法恢复。建议优先使用「移入废纸篓」。")
        }
        .confirmationDialog("彻底删除选定语言包不可恢复", isPresented: $confirmPermanentLocalization, titleVisibility: .visible) {
            Button("彻底删除所选语言包", role: .destructive) {
                if let bundle = uninstaller.selectedLocalizationBundle {
                    _ = uninstaller.cleanSelectedLocalization(bundle: bundle, permanently: true)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let bundle = uninstaller.selectedLocalizationBundle {
                Text("将彻底删除【\(bundle.appName)】中的 \(bundle.selectedPackCount) 个外语包（\(bundle.reclaimableSize.byteStringCN)），此操作无法恢复。中文、英文与基础资源将始终保留。")
            } else {
                Text("此操作无法恢复。")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            IconSlot(systemName: "app.dashed", size: 14, weight: .medium,
                     color: Ink.secondary, width: 18)

            Text("App 卸载与残留排查")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Spacer()

            Picker("模式切换", selection: Binding(
                get: { uninstaller.currentTab },
                set: { uninstaller.currentTab = $0 }
            )) {
                ForEach(UninstallerState.UninstallerTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 640)
            .accessibilityIdentifier("uninstallerTabPicker")

            Spacer()

            switch uninstaller.currentTab {
            case .apps:
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
            case .orphans:
                if !uninstaller.orphanApps.isEmpty {
                    Text("\(filteredOrphanApps.count) 个孤儿应用")
                        .font(.mcNumeric(11))
                        .foregroundStyle(Ink.tertiary)
                }

                Button {
                    uninstaller.loadOrphans()
                } label: {
                    Label("重新排查", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            case .preferences:
                if !uninstaller.preferenceItems.isEmpty {
                    Text("\(filteredPreferences.count) 个偏好碎片")
                        .font(.mcNumeric(11))
                        .foregroundStyle(Ink.tertiary)
                }

                Button {
                    uninstaller.loadPreferences()
                } label: {
                    Label("重新反查", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("refreshPreferencesButton")
            case .extensions:
                if !uninstaller.pluginItems.isEmpty {
                    Text("\(filteredPlugins.count) 个扩展项")
                        .font(.mcNumeric(11))
                        .foregroundStyle(Ink.tertiary)
                }

                Button {
                    uninstaller.loadPlugins()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("refreshPluginsButton")
            case .localization:
                if !uninstaller.localizationBundles.isEmpty {
                    Text("\(filteredLocalizationBundles.count) 个可瘦身 App")
                        .font(.mcNumeric(11))
                        .foregroundStyle(Ink.tertiary)
                }

                Button {
                    uninstaller.loadLocalization()
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("refreshLocalizationButton")
            case .loginItems:
                EmptyView()
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    // MARK: - 已安装 App 视图

    @ViewBuilder
    private var emptyAppsView: some View {
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
            appFooter
        }
    }

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

    private var appFooter: some View {
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

    // MARK: - 孤儿残留排查视图

    @ViewBuilder
    private var emptyOrphansView: some View {
        if uninstaller.isScanningOrphans {
            VStack(spacing: Space.sm) {
                ProgressView().controlSize(.large)
                Text("正在排查已卸载应用的孤儿残留…")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyState(
                icon: "sparkles",
                title: "未发现孤儿残留",
                message: "系统很干净，所有残留已被清理，或均属于正常已安装的应用。",
                actionTitle: "重新排查",
                action: { uninstaller.loadOrphans() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var orphanAppList: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: "搜索孤儿应用", text: $orphanSearchText)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredOrphanApps) { orphanApp in
                        Button {
                            withAnimation(Motion.micro) {
                                uninstaller.selectOrphanApp(orphanApp)
                            }
                        } label: {
                            OrphanAppRow(orphanApp: orphanApp, isSelected: uninstaller.selectedOrphanApp?.id == orphanApp.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("orphanAppRow_\(orphanApp.name)")
                    }
                }
                .padding(.horizontal, Space.xs)
                .padding(.bottom, Space.md)
            }
        }
        .frame(width: 280)
        .background(Surface.group)
    }

    private var orphanRelatedPanel: some View {
        VStack(spacing: 0) {
            if let orphanApp = uninstaller.selectedOrphanApp {
                orphanSummary(orphanApp)
                orphanItemsList(orphanApp: orphanApp)
            } else {
                EmptyState(
                    icon: "hand.point.up.left",
                    title: "从左侧选择一个孤儿应用",
                    message: "查看其留在沙盒容器、偏好设置与窗口状态中的孤儿文件并清理。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Spacer(minLength: 0)
            orphanFooter
        }
    }

    private func orphanSummary(_ orphanApp: OrphanApp) -> some View {
        GroupBox {
            GroupedRow(isLast: true) {
                HStack(spacing: Space.sm) {
                    Image(systemName: "questionmark.app")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(Ink.secondary)
                        .frame(width: 32, height: 32)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: Space.xs) {
                            Text(orphanApp.name)
                                .font(Typo.title)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)

                            Text("已卸载")
                                .font(Typo.micro)
                                .foregroundStyle(Signal.caution)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Signal.caution.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }

                        if let bundleID = orphanApp.bundleID {
                            Text(bundleID)
                                .font(Typo.caption)
                                .foregroundStyle(Ink.quaternary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Space.sm)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(orphanApp.totalSize.byteStringCN)
                            .font(.mcNumeric(15, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                        Text("\(orphanApp.items.count) 个残留组件")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.md)
    }

    private func orphanItemsList(orphanApp: OrphanApp) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                Button(orphanApp.allSelected ? "取消全选" : "全选该应用") {
                    uninstaller.toggleOrphanApp(appID: orphanApp.id, on: !orphanApp.allSelected)
                }
                .pressable()
                .font(Typo.row)
                .foregroundStyle(Accent.tint)

                Spacer()

                Text("\(orphanApp.items.count) 项 · \(orphanApp.totalSize.byteStringCN)")
                    .font(.mcNumeric(11))
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)

            ScrollView {
                GroupBox {
                    ForEach(Array(orphanApp.items.enumerated()), id: \.element.id) { index, item in
                        GroupedRow(isLast: index == orphanApp.items.count - 1) {
                            OrphanItemRow(item: item, appID: orphanApp.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    uninstaller.toggleOrphanItem(appID: orphanApp.id, itemID: item.id, on: !item.isSelected)
                                }
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.md)
            }
        }
    }

    private var orphanFooter: some View {
        HStack(spacing: Space.md) {
            if let summary = uninstaller.lastOrphanSummary {
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

            Button(uninstaller.allOrphansSelected ? "取消全部勾选" : "勾选全部孤儿残留") {
                uninstaller.setAllOrphansSelected(!uninstaller.allOrphansSelected)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier("orphanSelectAllButton")

            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(uninstaller.selectedOrphanCount) 项")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .motionSafeNumericTransition()
                Text(uninstaller.selectedOrphanSize.byteStringCN)
                    .font(.mcNumeric(17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            Button {
                confirmPermanentOrphans = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Signal.critical)
            .accessibilityIdentifier("orphanPermanentButton")
            .disabled(uninstaller.selectedOrphanItems.isEmpty || uninstaller.isCleaningOrphans)

            Button {
                _ = uninstaller.cleanSelectedOrphans(permanently: false)
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("orphanTrashButton")
            .disabled(uninstaller.selectedOrphanItems.isEmpty || uninstaller.isCleaningOrphans)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Hairline()
        }
    }

    // MARK: - 偏好碎片反查视图 (v1.53.0)

    @ViewBuilder
    private var preferencePanel: some View {
        if uninstaller.isScanningPreferences {
            VStack(spacing: Space.sm) {
                ProgressView().controlSize(.large)
                Text("正在深度反查已卸载应用偏好设置碎片…")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("preferenceLoadingView")
        } else if uninstaller.preferenceItems.isEmpty {
            EmptyState(
                icon: "gearshape.2",
                title: "未发现已卸载 App 的偏好碎片",
                message: "系统偏好设置目录保持纯净，所有 plist 均归属在用应用或受安全保护。",
                actionTitle: "重新反查",
                action: { uninstaller.loadPreferences() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("preferenceEmptyView")
        } else {
            VStack(spacing: 0) {
                preferenceToolbar
                Hairline()
                preferenceListView
                preferenceFooter
            }
            .accessibilityIdentifier("preferencePanel")
        }
    }

    private var preferenceToolbar: some View {
        HStack(spacing: Space.sm) {
            SearchField(placeholder: "搜索 App 名称、Bundle ID 或 plist 文件…", text: $preferenceSearchText, width: 280)

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(Accent.tint)
                Text("7天缓冲保护期 · 系统白名单已排除")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Surface.sunken)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text("共 \(filteredPreferences.count) 项 · \(filteredPreferences.reduce(0) { $0 + $1.size }.byteStringCN)")
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(Surface.group)
    }

    private var preferenceListView: some View {
        ScrollView {
            if filteredPreferences.isEmpty {
                VStack(spacing: Space.sm) {
                    Text("无匹配结果")
                        .font(Typo.body)
                        .foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                GroupBox {
                    ForEach(Array(filteredPreferences.enumerated()), id: \.element.id) { index, item in
                        GroupedRow(isLast: index == filteredPreferences.count - 1) {
                            OrphanPreferenceRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    uninstaller.togglePreferenceItem(id: item.id, on: !item.isSelected)
                                }
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.md)
            }
        }
    }

    private var preferenceFooter: some View {
        HStack(spacing: Space.md) {
            if let summary = uninstaller.lastPreferenceSummary {
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

            Button(uninstaller.allPreferencesSelected ? "取消全部勾选" : "全选所有碎片") {
                uninstaller.setAllPreferencesSelected(!uninstaller.allPreferencesSelected)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier("preferenceSelectAllButton")

            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(uninstaller.selectedPreferencesCount) 项")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .motionSafeNumericTransition()
                Text(uninstaller.selectedPreferencesSize.byteStringCN)
                    .font(.mcNumeric(17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            Button {
                confirmPermanentPreferences = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Signal.critical)
            .accessibilityIdentifier("preferencePermanentButton")
            .disabled(uninstaller.selectedPreferencesCount == 0 || uninstaller.isCleaningPreferences)

            Button {
                _ = uninstaller.cleanSelectedPreferences(toTrash: true)
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("preferenceTrashButton")
            .disabled(uninstaller.selectedPreferencesCount == 0 || uninstaller.isCleaningPreferences)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Hairline()
        }
    }

    // MARK: - 插件与系统扩展治理视图 (v1.55.0)

    @ViewBuilder
    private var pluginsPanel: some View {
        if uninstaller.isScanningPlugins {
            VStack(spacing: Space.sm) {
                ProgressView().controlSize(.large)
                Text("正在深度排查 QuickLook、Spotlight 与系统扩展残留…")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("pluginLoadingView")
        } else if uninstaller.pluginItems.isEmpty {
            EmptyState(
                icon: "puzzlepiece.extension",
                title: "未发现可疑的插件与扩展残留",
                message: "系统扩展目录保持纯净，所有组件均正常归属在用应用或受安全保护。",
                actionTitle: "重新扫描",
                action: { uninstaller.loadPlugins() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("pluginEmptyView")
        } else {
            VStack(spacing: 0) {
                pluginsToolbar
                Hairline()
                pluginsListView
                pluginsFooter
            }
            .accessibilityIdentifier("pluginPanel")
        }
    }

    private var pluginsToolbar: some View {
        VStack(spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                SearchField(placeholder: "搜索插件名称、Bundle ID 或宿主 App…", text: $pluginSearchText, width: 280)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(Signal.positive)
                    Text("系统内置组件受保护 · 优先清理孤儿与损坏项")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                Text("共 \(filteredPlugins.count) 项 · \(filteredPlugins.reduce(0) { $0 + $1.size }.byteStringCN)")
                    .font(.mcNumeric(11))
                    .foregroundStyle(Ink.tertiary)
            }

            // 过滤胶囊条（按种类与健康状态）
            HStack(spacing: Space.xs) {
                // 种类过滤器
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button {
                            selectedPluginKind = nil
                        } label: {
                            Text("全部类型")
                                .font(Typo.micro)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(selectedPluginKind == nil ? Accent.tint.opacity(0.15) : Surface.sunken)
                                .foregroundStyle(selectedPluginKind == nil ? Accent.tint : Ink.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        ForEach(PluginExtensionKind.allCases) { kind in
                            Button {
                                selectedPluginKind = (selectedPluginKind == kind) ? nil : kind
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: kind.icon)
                                        .font(.system(size: 9))
                                    Text(kind.shortTitle)
                                }
                                .font(Typo.micro)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(selectedPluginKind == kind ? Accent.tint.opacity(0.15) : Surface.sunken)
                                .foregroundStyle(selectedPluginKind == kind ? Accent.tint : Ink.secondary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                // 状态过滤器
                HStack(spacing: 6) {
                    Button {
                        selectedPluginStatus = (selectedPluginStatus == .orphan) ? nil : .orphan
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(Color.red).frame(width: 5, height: 5)
                            Text("仅孤儿残留")
                        }
                        .font(Typo.micro)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selectedPluginStatus == .orphan ? Color.red.opacity(0.15) : Surface.sunken)
                        .foregroundStyle(selectedPluginStatus == .orphan ? Color.red : Ink.secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        selectedPluginStatus = (selectedPluginStatus == .broken) ? nil : .broken
                    } label: {
                        HStack(spacing: 3) {
                            Circle().fill(Color.orange).frame(width: 5, height: 5)
                            Text("仅损坏项")
                        }
                        .font(Typo.micro)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selectedPluginStatus == .broken ? Color.orange.opacity(0.15) : Surface.sunken)
                        .foregroundStyle(selectedPluginStatus == .broken ? Color.orange : Ink.secondary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .background(Surface.group)
    }

    private var pluginsListView: some View {
        ScrollView {
            if filteredPlugins.isEmpty {
                VStack(spacing: Space.sm) {
                    Text("无匹配结果")
                        .font(Typo.body)
                        .foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                GroupBox {
                    ForEach(Array(filteredPlugins.enumerated()), id: \.element.id) { index, item in
                        GroupedRow(isLast: index == filteredPlugins.count - 1) {
                            PluginExtensionRow(item: item)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if item.status != .system {
                                        uninstaller.togglePluginItem(id: item.id, on: !item.isSelected)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.md)
            }
        }
    }

    private var pluginsFooter: some View {
        HStack(spacing: Space.md) {
            if let summary = uninstaller.lastPluginSummary {
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

            Button(uninstaller.allPluginsSelected ? "取消全部勾选" : "全选可清理项") {
                uninstaller.setAllPluginsSelected(!uninstaller.allPluginsSelected, safeOnly: true)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier("pluginSelectAllButton")

            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(uninstaller.selectedPluginCount) 项")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .motionSafeNumericTransition()
                Text(uninstaller.selectedPluginSize.byteStringCN)
                    .font(.mcNumeric(17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            Button {
                confirmPermanentPlugins = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Signal.critical)
            .accessibilityIdentifier("pluginPermanentButton")
            .disabled(uninstaller.selectedPluginCount == 0 || uninstaller.isCleaningPlugins)

            Button {
                _ = uninstaller.cleanSelectedPlugins(permanently: false)
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("pluginTrashButton")
            .disabled(uninstaller.selectedPluginCount == 0 || uninstaller.isCleaningPlugins)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Hairline()
        }
    }

    // MARK: - 多语言瘦身面板 (v1.60.0)

    private var localizationPanel: some View {
        Group {
            if uninstaller.localizationBundles.isEmpty && !uninstaller.isScanningLocalization {
                emptyLocalizationView
            } else {
                HStack(spacing: 0) {
                    localizationAppList
                    Divider()
                    localizationRelatedPanel
                }
            }
        }
    }

    private var emptyLocalizationView: some View {
        VStack(spacing: Space.md) {
            EmptyState(
                icon: "globe.asia.australia.fill",
                title: "未发现可瘦身的应用多语言资源",
                message: "所有扫描到的应用均已为极简语言配置，或仅包含中文与英文资源。"
            )
            Button("重新扫描应用多语言包") {
                uninstaller.loadLocalization()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var localizationAppList: some View {
        VStack(spacing: 0) {
            SearchField(placeholder: "搜索应用名称 / Bundle ID", text: $localizationSearchText)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.sm)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredLocalizationBundles) { bundle in
                        Button {
                            withAnimation(Motion.micro) {
                                uninstaller.selectLocalizationBundle(bundle)
                            }
                        } label: {
                            LocalizationAppRow(
                                bundle: bundle,
                                isSelected: uninstaller.selectedLocalizationBundle?.id == bundle.id
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("localizationAppRow_\(bundle.appName)")
                    }
                }
                .padding(.horizontal, Space.xs)
                .padding(.bottom, Space.md)
            }
        }
        .frame(width: 280)
        .background(Surface.group)
    }

    private var localizationRelatedPanel: some View {
        VStack(spacing: 0) {
            if let bundle = uninstaller.selectedLocalizationBundle {
                localizationSummary(bundle)
                localizationPacksList(bundle)
                Spacer(minLength: 0)
                localizationFooter(bundle)
            } else {
                EmptyState(
                    icon: "hand.point.up.left",
                    title: "从左侧选择一个应用",
                    message: "查看其内部包含的多国语言包（.lproj）。中文、英文与系统语言始终保留；删除包内资源会破坏该 App 的签名校验，请只对你确认不再需要的语言手动勾选。"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func localizationSummary(_ bundle: AppLocalizationBundle) -> some View {
        GroupBox {
            GroupedRow(isLast: true) {
                HStack(spacing: Space.sm) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.appPath))
                        .resizable()
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.xs) {
                            Text(bundle.appName)
                                .font(Typo.title)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)

                            Text("共 \(bundle.totalPackCount) 种语言")
                                .font(Typo.micro)
                                .foregroundStyle(Ink.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Surface.sunken)
                                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        }

                        if let bid = bundle.bundleID {
                            Text(bid)
                                .font(Typo.caption)
                                .foregroundStyle(Ink.quaternary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Space.sm)

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(bundle.totalReclaimablePotential.byteStringCN)
                            .font(.mcNumeric(15, weight: .semibold))
                            .foregroundStyle(Signal.positive)
                        Text("可瘦身外语潜能")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.md)
    }

    private func localizationPacksList(_ bundle: AppLocalizationBundle) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                Text("语言包明细 (\(bundle.languagePacks.count))")
                    .font(Typo.section)
                    .foregroundStyle(Ink.tertiary)

                Spacer()

                Button("全选外语包") {
                    uninstaller.setAllLocalizationPacksSelected(bundleID: bundle.id, on: true)
                }
                .buttonStyle(.plain)
                .font(Typo.caption)
                .foregroundStyle(Accent.tint)

                Text("·")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.quaternary)

                Button("取消勾选") {
                    uninstaller.setAllLocalizationPacksSelected(bundleID: bundle.id, on: false)
                }
                .buttonStyle(.plain)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Space.sm)
            .padding(.bottom, Space.xs)

            ScrollView {
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(Array(bundle.languagePacks.enumerated()), id: \.element.id) { index, pack in
                            GroupedRow(isLast: index == bundle.languagePacks.count - 1) {
                                LanguagePackRow(item: pack) { on in
                                    uninstaller.toggleLocalizationPack(bundleID: bundle.id, packID: pack.id, on: on)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Space.md)
                .padding(.bottom, Space.md)
            }
        }
    }

    private func localizationFooter(_ bundle: AppLocalizationBundle) -> some View {
        HStack(spacing: Space.md) {
            if let summary = uninstaller.lastLocalizationSummary {
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
                Text("已选 \(bundle.selectedPackCount) 个外语包")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .motionSafeNumericTransition()
                Text(bundle.reclaimableSize.byteStringCN)
                    .font(.mcNumeric(17, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            Button {
                confirmPermanentLocalization = true
            } label: {
                Label("彻底删除", systemImage: "trash.slash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Signal.critical)
            .accessibilityIdentifier("localizationPermanentButton")
            .disabled(bundle.selectedPackCount == 0 || uninstaller.isCleaningLocalization)

            Button {
                _ = uninstaller.cleanSelectedLocalization(bundle: bundle, permanently: false)
            } label: {
                Label("移入废纸篓", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("localizationTrashButton")
            .disabled(bundle.selectedPackCount == 0 || uninstaller.isCleaningLocalization)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .background(.bar)
        .overlay(alignment: .top) {
            Hairline()
        }
    }

    // MARK: - 自启死链排查面板 (v1.67.0)

    private var loginItemsPanel: some View {
        ScrollView {
            VStack(spacing: Space.md) {
                LoginItemCleanerCard(
                    onTriggerClean: {
                        app.refreshDisk()
                    }
                )
            }
            .padding(Space.gutter)
        }
        .background(Surface.window)
    }
}

// MARK: - 孤儿应用与条目组件

struct OrphanAppRow: View {
    @EnvironmentObject private var appState: AppState
    let orphanApp: OrphanApp
    let isSelected: Bool

    private var uninstaller: UninstallerState { self.appState.uninstaller }

    var body: some View {
        HStack(spacing: Space.xs) {
            Button(action: { uninstaller.toggleOrphanApp(appID: self.orphanApp.id, on: !self.orphanApp.isSelected) }) {
                Image(systemName: self.orphanApp.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(self.orphanApp.isSelected ? Accent.tint : Ink.tertiary)
            }
            .buttonStyle(.plain)

            Image(systemName: "questionmark.app")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Ink.secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(self.orphanApp.name)
                    .font(isSelected ? Typo.rowStrong : Typo.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                Text("\(self.orphanApp.items.count) 项 · \(self.orphanApp.totalSize.byteStringCN)")
                    .font(.mcNumeric(10))
                    .foregroundStyle(Ink.tertiary)
            }
            Spacer(minLength: Space.xxs)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .selectionHighlight(isSelected)
        .rowHover()
    }
}

struct OrphanItemRow: View {
    @EnvironmentObject private var app: AppState
    let item: OrphanItem
    let appID: UUID

    private var uninstaller: UninstallerState { app.uninstaller }

    var body: some View {
        HStack(spacing: Space.sm) {
            Button(action: { uninstaller.toggleOrphanItem(appID: appID, itemID: item.id, on: !item.isSelected) }) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("orphanItemToggle")

            Image(systemName: item.kind.icon)
                .font(.system(size: 14))
                .foregroundStyle(Accent.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(item.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)

                    Text(item.kind.rawValue)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }

                Text(item.path)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.xs)

            Text(item.size.byteStringCN)
                .font(.mcNumeric(12, weight: .medium))
                .foregroundStyle(Ink.primary)
        }
        .contentShape(Rectangle())
        .rowHover()
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: item.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
                Label("加入白名单排除（不再识别为孤儿）", systemImage: "shield.slash")
            }
        }
    }
}

/// App 行（展示真实应用图标 + 右键访达定位）
struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: Space.xs) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            } else {
                // 占位保持同尺寸：图标到位时列表不跳行
                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                    .fill(Color.clear)
                    .frame(width: 24, height: 24)
            }

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
        .onAppear(perform: loadIcon)
    }

    /// 图标走 `ThumbnailCache`：`NSWorkspace.icon(forFile:)` 是一趟 iconservices IPC，
    /// 原先写在计算属性里 → 每次 body 求值（含悬停高亮）都会打一次。
    private func loadIcon() {
        if let hit = ThumbnailCache.shared.cached(app.path, asIcon: true) {
            icon = hit
            return
        }
        ThumbnailCache.shared.image(for: app.path, asIcon: true) { loaded in
            icon = loaded
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

            Image(systemName: file.fileKind.icon)
                .font(.system(size: 14))
                .foregroundStyle(Accent.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Space.xs) {
                    Text(file.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(file.fileKind.rawValue)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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

// MARK: - 偏好碎片行组件 (v1.53.0)

struct OrphanPreferenceRow: View {
    @EnvironmentObject private var app: AppState
    let item: OrphanPreferenceItem

    private var uninstaller: UninstallerState { app.uninstaller }

    var body: some View {
        HStack(spacing: Space.sm) {
            Button(action: { uninstaller.togglePreferenceItem(id: item.id, on: !item.isSelected) }) {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("preferenceItemToggle_\(item.fileName)")

            Image(systemName: item.location.icon)
                .font(.system(size: 14))
                .foregroundStyle(Accent.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(item.appName)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)

                    Text(item.location.shortTitle)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                    if item.ageDays > 0 {
                        Text("\(item.ageDays)天前修改")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.quaternary)
                    }
                }

                HStack(spacing: Space.xs) {
                    Text(item.bundleID)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.secondary)

                    Text("·")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.quaternary)

                    Text(item.path)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.quaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Space.xs)

            Text(item.size.byteStringCN)
                .font(.mcNumeric(12, weight: .medium))
                .foregroundStyle(Ink.primary)
        }
        .contentShape(Rectangle())
        .rowHover()
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: item.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
                uninstaller.togglePreferenceItem(id: item.id, on: !item.isSelected)
            } label: {
                Label(item.isSelected ? "取消选择" : "勾选清理", systemImage: item.isSelected ? "xmark.circle" : "checkmark.circle")
            }

            Divider()

            Button {
                app.addPathToWhitelist(item.path, comment: item.appName)
            } label: {
                Label("加入白名单排除（不再反查）", systemImage: "shield.slash")
            }
        }
    }
}

// MARK: - 插件与系统扩展列表行组件 (v1.55.0)

struct PluginExtensionRow: View {
    @EnvironmentObject private var app: AppState
    let item: PluginExtensionItem

    private var uninstaller: UninstallerState { app.uninstaller }

    var body: some View {
        HStack(spacing: Space.sm) {
            if item.status == .system {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.quaternary)
            } else {
                Button(action: {
                    uninstaller.togglePluginItem(id: item.id, on: !item.isSelected)
                }) {
                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: item.kind.icon)
                .font(.system(size: 15))
                .foregroundStyle(item.status == .orphan ? Color.red : (item.status == .broken ? Color.orange : Accent.tint))
                .frame(width: 22, height: 22)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(item.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)

                    if let ver = item.version, !ver.isEmpty {
                        Text("v\(ver)")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.tertiary)
                    }

                    Text(item.kind.shortTitle)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                    HStack(spacing: 2) {
                        Image(systemName: item.status.icon)
                            .font(.system(size: 9))
                        Text(item.status.rawValue)
                    }
                    .font(Typo.micro)
                    .foregroundStyle(item.status.badgeColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(item.status.badgeColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                    if !item.isUserDomain {
                        Text("全局 /Library")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.quaternary)
                    }
                }

                HStack(spacing: Space.xs) {
                    if let host = item.hostAppName {
                        Text("归属宿主: \(host)")
                            .font(Typo.micro)
                            .foregroundStyle(item.status == .orphan ? Color.red.opacity(0.8) : Ink.secondary)
                        Text("·")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.quaternary)
                    }

                    if let bid = item.bundleID {
                        Text(bid)
                            .font(Typo.micro)
                            .foregroundStyle(Ink.tertiary)
                        Text("·")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.quaternary)
                    }

                    Text(item.path)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.quaternary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Space.xs)

            Text(item.size.byteStringCN)
                .font(.mcNumeric(12, weight: .medium))
                .foregroundStyle(Ink.primary)
        }
        .contentShape(Rectangle())
        .rowHover()
        .contextMenu {
            Button {
                let url = URL(fileURLWithPath: item.path)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }

            if item.status != .system {
                Divider()

                Button {
                    uninstaller.togglePluginItem(id: item.id, on: !item.isSelected)
                } label: {
                    Label(item.isSelected ? "取消选择" : "勾选清理", systemImage: item.isSelected ? "xmark.circle" : "checkmark.circle")
                }
            }

            Divider()

            Button {
                app.addPathToWhitelist(item.path, comment: item.name)
            } label: {
                Label("加入白名单排除（不再扫描）", systemImage: "shield.slash")
            }
        }
    }
}
