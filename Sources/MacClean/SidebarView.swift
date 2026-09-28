import SwiftUI

/// 侧边栏。
///
/// 重写要点：
///  - 用原生 `List(selection:)` + `.listStyle(.sidebar)`，拿回 macOS 真正的高亮态、
///    键盘导航、滚动惯性与 vibrancy，而不是手搓一堆 `Button` 假装是列表。
///  - 删掉每一行下面的装饰性副标题（"磁盘与清理总览"这种），它们不携带信息，只制造噪音。
///    右侧位置留给真正的实时数据：已扫描体积、风险数、重复组数。
///  - 删掉图标底下的彩色圆角方块。分类身份由 SF Symbol + 文字承担。
///  - 大圆环仪表盘换成一条横向容量条：同样信息量，占用不到三分之一的高度。
struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    /// `List` 需要 `Destination?`；侧边栏不允许"无选中"，所以 nil 时保持原值。
    private var selection: Binding<Destination?> {
        Binding(
            get: { app.destination },
            set: { if let next = $0 { app.destination = next } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            capacityHeader

            List(selection: selection) {
                Section {
                    navRow(.dashboard, title: "概览", icon: "square.grid.2x2")
                    navRow(.search, title: "检索", icon: "magnifyingglass")
                    navRow(.spaceTreemap, title: "空间透视", icon: "square.split.bottomrightquarter")
                    navRow(.spaceAudit, title: "空间审计", icon: "chart.bar.doc.horizontal",
                           trailing: app.allAuditItems.isEmpty ? nil : "\(app.allAuditItems.count)",
                           trailingColor: Ink.tertiary)
                }

                Section("清理") {
                    ForEach(CleanCategory.allCases) { cat in
                        categoryRow(cat)
                            .tag(Destination.category(cat))
                            .accessibilityIdentifier("sidebarCategory_\(cat.rawValue)")
                    }
                }

                Section("工具") {
                    navRow(.riskCheck, title: "风险提醒", icon: "exclamationmark.shield",
                           trailing: app.riskScanned && !app.riskItems.isEmpty ? "\(app.totalRiskCount)" : nil,
                           trailingColor: Signal.caution)
                        .accessibilityIdentifier("toolRow_风险提醒")

                    navRow(.uninstaller, title: "App 卸载器", icon: "app.dashed")
                        .accessibilityIdentifier("toolRow_App 卸载器")

                    navRow(.duplicates, title: "重复文件", icon: "doc.on.doc",
                           trailing: app.duplicateState.groups.isEmpty ? nil : "\(app.duplicateState.groups.count)")
                        .accessibilityIdentifier("toolRow_重复文件")

                    navRow(.startupItems, title: "启动项管理", icon: "bolt.horizontal.circle")
                        .accessibilityIdentifier("toolRow_启动项管理")

                    // 文件粉碎器：不可恢复删除的极端档。只对用户逐条点名的路径，
                    // 永远不出现在任何扫描结果的默认勾选里。
                    navRow(.shredder, title: "文件粉碎器", icon: "flame")
                        .accessibilityIdentifier("toolRow_文件粉碎器")

                    // 系统体验优化：改偏好（可还原），不是删文件。放在「工具」里而不是
                    // 「清理」里，是因为它一条可清理项都不产出。
                    navRow(.systemOptimize, title: "体验优化", icon: "slider.horizontal.3")
                        .accessibilityIdentifier("toolRow_体验优化")

                    // App 更新检查：默认关闭；开启后只访问 App 自己声明的更新源，
                    // 只列示与跳转，不代下载不代装。
                    navRow(.appUpdate, title: "App 更新检查", icon: "arrow.triangle.2.circlepath")
                        .accessibilityIdentifier("toolRow_App 更新检查")

                    // 维护面板（v1.73.15）：磁盘 First Aid / DNS 刷新 / Spotlight 索引重建，
                    // 全部逐条确认，外部命令走 SafeProcess。
                    navRow(.maintenance, title: "系统维护", icon: "wrench.and.screwdriver")
                        .accessibilityIdentifier("toolRow_系统维护")

                    // 浏览器隐私痕迹（v1.73.15）：按 (浏览器 × 数据类) 一格一判据，
                    // 默认全不选、危险格带警示；Safari 侧 TCC 读不到时明示。
                    navRow(.browserPrivacy, title: "浏览器隐私", icon: "globe")
                        .accessibilityIdentifier("toolRow_浏览器隐私")

                    // Mail 附件清理（v1.73.15）：附件本体是用户数据，只列示、零默认勾选。
                    navRow(.mailAttachments, title: "邮件附件", icon: "envelope")
                        .accessibilityIdentifier("toolRow_邮件附件")

                    navRow(.history, title: "清理历史", icon: "clock.arrow.circlepath",
                           trailing: app.history.isEmpty ? nil : "\(app.history.count)")
                        .accessibilityIdentifier("toolRow_清理历史")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            scanFooter
        }
    }

    // MARK: - 顶部容量区

    private var capacityHeader: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.tertiary)
                Text("Macintosh HD")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: Space.xs)
                Text("\(Int(app.usedRatio * 100))%")
                    .font(.mcNumeric(11, weight: .medium))
                    .foregroundStyle(app.usedRatio > 0.88 ? Signal.caution : Ink.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(app.diskUsed.byteStringCN)
                    .font(Typo.metric)
                    .monospacedDigit()
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
                Text("已用")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            CapacityBar(
                used: app.usedRatio,
                reclaimable: app.diskTotal > 0 ? Double(app.totalCleanable) / Double(app.diskTotal) : 0,
                height: 6,
                isCritical: app.usedRatio > 0.88
            )
            .padding(.top, 1)

            Text("共 \(app.diskTotal.byteStringCN) · 可用 \(app.diskAvailable.byteStringCN)")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .monospacedDigit()
                .motionSafeNumericTransition()
        }
        .padding(.horizontal, Space.md)
        .padding(.top, Space.sm)
        .padding(.bottom, Space.sm)
    }

    // MARK: - 底部动作区

    private var scanFooter: some View {
        VStack(spacing: Space.xs) {
            Hairline()

            HStack(spacing: Space.xs) {
                Text("\(app.scannedCount)/\(CleanCategory.allCases.count) 已扫描")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                    .motionSafeNumericTransition()
                Spacer(minLength: Space.xs)
                if app.totalCleanable > 0 {
                    Text("可清理 \(app.totalCleanable.byteStringCN)")
                        .font(.mcNumeric(11, weight: .medium))
                        .foregroundStyle(Accent.tint)
                        .motionSafeNumericTransition()
                }
            }

            Button {
                app.scanAll()
            } label: {
                Label(app.scannedCount > 0 ? "重新扫描" : "扫描全部分类", systemImage: "arrow.clockwise")
                    .font(Typo.rowStrong)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(app.categories.contains { $0.isScanning })
        }
        .padding(.horizontal, Space.md)
        .padding(.bottom, Space.md)
        .padding(.top, Space.xs)
    }

    // MARK: - 行

    @ViewBuilder
    private func navRow(_ dest: Destination, title: String, icon: String,
                        trailing: String? = nil, trailingColor: Color = Ink.tertiary) -> some View {
        Label {
            HStack(spacing: Space.xs) {
                Text(title)
                if let trailing {
                    Spacer(minLength: Space.xs)
                    Text(trailing)
                        .font(.mcNumeric(11))
                        .foregroundStyle(trailingColor)
                }
            }
        } icon: {
            Image(systemName: icon)
        }
        .tag(dest)
    }

    @ViewBuilder
    private func categoryRow(_ cat: CleanCategory) -> some View {
        let st = app.state(for: cat)

        Label {
            HStack(spacing: Space.xs) {
                Text(cat.title)

                Spacer(minLength: Space.xs)

                if st.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                } else if st.isScanned, st.totalSize > 0 {
                    Text(st.totalSize.byteStringCN)
                        .font(.mcNumeric(11))
                        .foregroundStyle(Ink.tertiary)
                        .motionSafeNumericTransition()
                }
            }
        } icon: {
            Image(systemName: cat.icon)
        }
    }
}
