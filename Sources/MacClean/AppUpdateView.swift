import SwiftUI

// MARK: - App 更新检查（工具页，v1.73.14）
//
// 隐私口径与 AppUpdateScanner 的 doc comment 同源：
// 默认关闭；开启并扫描后，「检查更新」只访问各 App 自己声明的更新源，
// 请求里不含本机文件路径；只列示与跳转，不下载、不代装。
//
// 结果状态全部放在 `AppUpdateScanner`（@StateObject 外部对象）里，
// 不用 ViewInspector 读不回的 @State 选中态。
struct AppUpdateView: View {
    @StateObject private var scanner = AppUpdateScanner()
    /// 打开总开关前的说明弹窗（纯呈现态，不承载结果）
    @State private var pendingEnable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                enableGroup
                if scanner.isEnabled {
                    actionGroup
                    if let notice = scanner.summary?.degradationNotice {
                        degradationBanner(notice)
                    }
                    resultGroups
                }
            }
            .padding(Space.md)
        }
        // 确认弹窗挂在有尺寸的容器（ScrollView）上——挂在 EmptyView 上会"自检绿、真机不弹"
        .alert("开启 App 更新检查", isPresented: $pendingEnable) {
            Button("开启") { scanner.setEnabled(true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("开启后，点「检查更新」会访问各 App 自己声明的更新源；请求里不含本机文件路径；只列示与跳转，不代下载、不代安装。")
        }
    }

    // MARK: 总开关

    private var enableGroup: some View {
        GroupBox {
            GroupedRow(isLast: !scanner.isEnabled) {
                HStack(spacing: Space.sm) {
                    IconSlot(systemName: "arrow.triangle.2.circlepath")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App 更新检查")
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)
                        Text("读取已装应用自己声明的更新源（Sparkle appcast / App Store 收据）。默认关闭。")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                    Spacer(minLength: Space.xs)
                    Toggle("", isOn: Binding(
                        get: { scanner.isEnabled },
                        set: { newValue in
                            if newValue {
                                pendingEnable = true   // 先弹说明，确认才真正打开
                            } else {
                                scanner.setEnabled(false)
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(scanner.isWorking)
                    .accessibilityIdentifier("appUpdateEnableToggle")
                }
            }
            if scanner.isEnabled {
                GroupedRow(isLast: true) {
                    Text("隐私边界：请求只发往各 App 自己声明的更新域名，内容不含本机文件路径与机器信息；发现更新后只打开更新页，不代下载、不代安装。")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
        }
    }

    // MARK: 动作

    private var actionGroup: some View {
        GroupBox {
            GroupedRow(isLast: true) {
                HStack(spacing: Space.sm) {
                    Button("扫描更新源") { scanner.scanSources() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(scanner.isWorking)
                        .accessibilityIdentifier("appUpdateScanButton")
                    Button("检查更新") { scanner.runUpdateCheck() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(scanner.isWorking || scanner.summary == nil)
                        .accessibilityIdentifier("appUpdateCheckButton")
                    if scanner.isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    Text("扫描只读本机清单；「检查更新」才访问已声明的更新源")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.quaternary)
                }
            }
        }
    }

    // MARK: G16 降级横幅

    private func degradationBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            IconSlot(systemName: "exclamationmark.triangle", color: Signal.caution)
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Ink.primary)
                .textSelection(.enabled)
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner))
        .overlay(RoundedRectangle(cornerRadius: Radius.inner).stroke(Surface.hairline, lineWidth: 0.5))
    }

    // MARK: 结果分组

    @ViewBuilder
    private var resultGroups: some View {
        if let summary = scanner.summary {
            if summary.entries.isEmpty {
                EmptyState(icon: "tray",
                           title: "清单里没有可检查的应用",
                           message: "已安装应用清单为空或全部读取失败。",
                           actionTitle: "重新扫描") { scanner.scanSources() }
            } else {
                if !summary.updatable.isEmpty {
                    updateGroup("有可用更新", entries: summary.updatable) { entry in
                        if case .available(let latest) = entry.result {
                            Text("\(entry.displayVersion) → \(latest)")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.primary)
                        }
                    }
                }
                let pending = summary.entries.filter { isPending($0) }
                if !pending.isEmpty {
                    updateGroup("已声明更新源，尚未检查", entries: pending) { entry in
                        Text("更新源：\(declaredHost(entry))")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                if !summary.upToDate.isEmpty {
                    updateGroup("已是最新", entries: summary.upToDate) { entry in
                        Text("当前 \(entry.displayVersion)")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                if !summary.unreachable.isEmpty {
                    updateGroup("检查失败", entries: summary.unreachable) { entry in
                        if case .unreachable(let reason) = entry.result {
                            Text(reason)
                                .font(Typo.caption)
                                .foregroundStyle(Ink.primary)
                        }
                    }
                }
                if !summary.appStore.isEmpty {
                    updateGroup("App Store 来源", entries: summary.appStore) { entry in
                        Text("通过 App Store 安装；更新请在 App Store 的「更新」页查看")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                    }
                }
                if !summary.noUpdater.isEmpty {
                    updateGroup("无更新机制", entries: summary.noUpdater) { entry in
                        Text("Info.plist 里没有更新源声明，也没有 App Store 收据")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.quaternary)
                    }
                }
            }
        } else {
            EmptyState(icon: "magnifyingglass",
                       title: "尚未扫描更新源",
                       message: "扫描只读 /Applications 与 ~/Applications 下各应用的 Info.plist 与收据存在性，不访问网络。",
                       actionTitle: "扫描更新源") { scanner.scanSources() }
        }
    }

    private func isPending(_ entry: AppUpdateEntry) -> Bool {
        if case .sparkle = entry.source { return entry.result == .notChecked }
        return false
    }

    private func declaredHost(_ entry: AppUpdateEntry) -> String {
        if case .sparkle(let urlString) = entry.source {
            return URL(string: urlString)?.host ?? urlString
        }
        return ""
    }

    /// 一组结果。空组不渲染（调用方已过滤），行内分隔线由 GroupedRow 画。
    private func updateGroup<Detail: View>(_ title: String, entries: [AppUpdateEntry],
                                           @ViewBuilder detail: @escaping (AppUpdateEntry) -> Detail) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(title) · \(entries.count)")
                    .font(Typo.section)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, Space.xs)
                ForEach(entries) { entry in
                    entryRow(entry, isLast: entry.id == entries.last?.id) {
                        detail(entry)
                    }
                }
            }
        }
    }

    private func entryRow<Detail: View>(_ entry: AppUpdateEntry, isLast: Bool,
                                        @ViewBuilder detail: () -> Detail) -> some View {
        GroupedRow(isLast: isLast) {
            HStack(spacing: Space.sm) {
                IconSlot(systemName: "app")
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                    detail()
                }
                Spacer(minLength: Space.xs)
                if entry.source != AppUpdateEntry.Source.none {
                    RowActionButton(systemName: "arrow.up.forward.square",
                                    identifier: "appUpdateOpenButton-\(entry.name)",
                                    help: entry.source == .appStore ? "打开 App Store" : "打开更新页") {
                        AppUpdateScanner.openUpdatePage(entry)
                    }
                }
            }
        }
    }
}
