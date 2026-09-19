import SwiftUI

/// 侧边 AI 对话面板（针对清理项提问：用途/能否删/是否在用）
///
/// 重写要点：
///  - 抽屉本身是浮层，保留材质底（宿主已给投影）；内部不再有第二层"卡片套卡片"。
///  - 对话记录改成原生消息流：说话人标签 + 等宽时间戳 + 左侧 2pt 竖线区分角色，
///    不再是"气泡套在描边卡片套在面板里"。
///  - 空态文案里的 emoji 删掉，改用 SF Symbol；开始提问的入口文案直接说清楚下一步。
///  - 整个面板只有一个强调色 `Accent.tint`；橙色只用于"文件正被进程占用"这类真实警告。
struct AIChatView: View {
    @EnvironmentObject private var app: AppState

    /// 是否处于分类页（「问当前列表」的前置条件）
    private var isOnCategoryPage: Bool {
        if case .category = app.destination { return true }
        return false
    }

    /// 是否已有任一分类完成扫描（「问全部」的前置条件）
    private var hasAnyScanned: Bool {
        app.categories.contains { $0.isScanned && !$0.items.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            // 列表级提问入口（grill Q4：按钮 + 输入框自动携带）
            quickActions

            if app.ai.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            Hairline()
            inputBar
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .sheet(isPresented: $app.ai.showSettings) {
            AISettingsView()
                .environmentObject(app)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Accent.tint)

            Text("AI 助手")
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)

            Spacer()

            // 清空对话
            if !app.ai.messages.isEmpty {
                Button {
                    app.ai.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Ink.secondary)
                .accessibilityLabel("清空对话")
                .help("清空对话")
            }

            // 设置
            Button {
                app.ai.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Ink.secondary)
            .accessibilityLabel("AI 设置")
            .help("AI 设置")

            // 关闭抽屉（d1 抽屉式）
            Button {
                app.ai.closeDrawer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Ink.secondary)
            .accessibilityLabel("收起 AI 面板")
            .help("收起 AI 面板")
            .accessibilityIdentifier("aiCloseDrawer")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 10)
    }

    // MARK: - 提问范围入口

    private var quickActions: some View {
        HStack(spacing: Space.xs) {
            Button {
                app.ai.askAboutCurrentList()
                app.ai.openDrawer()
            } label: {
                Label("问当前列表", systemImage: "list.bullet")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(app.ai.isLoading || !isOnCategoryPage)
            .help(isOnCategoryPage ? "分析当前分类扫描结果" : "请先进入一个分类")

            Button {
                app.ai.askAboutAll()
                app.ai.openDrawer()
            } label: {
                Label("问全部", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(app.ai.isLoading || !hasAnyScanned)
            .help(hasAnyScanned ? "分析全部已扫描分类" : "请先扫描至少一个分类")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
    }

    // MARK: - 上下文（当前提问目标）

    private var contextCard: some View {
        GroupBox {
            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Space.xxs) {
                        IconSlot(systemName: "target", size: 10, color: Ink.tertiary, width: 14)
                        Text("当前询问目标")
                            .font(Typo.section)
                            .foregroundStyle(Ink.tertiary)
                        Spacer(minLength: 0)
                    }

                    if let ctx = app.ai.context {
                        if ctx.isListMode {
                            // 列表模式：显示汇总与截断信息
                            Text(ctx.listSummary)
                                .font(Typo.rowStrong)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            Text(listDetailText(ctx))
                                .font(.mcNumeric(11))
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                        } else {
                            Text(ctx.title)
                                .font(Typo.rowStrong)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                            Text("\(ctx.category) · \(ctx.sizeString) · 风险 \(ctx.risk)")
                                .font(.mcNumeric(11))
                                .foregroundStyle(Ink.tertiary)
                                .lineLimit(1)
                            if !ctx.inUseBy.isEmpty {
                                Text("占用中：\(ctx.inUseBy.joined(separator: "、"))")
                                    .font(Typo.caption)
                                    .foregroundStyle(Signal.caution)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("从上方选择提问范围，或在列表项旁点「问 AI」")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, Space.sm)
    }

    private func listDetailText(_ ctx: AskContext) -> String {
        "列出最大 \(ctx.listItems.count) 项" + (ctx.listItems.count < ctx.listTotal ? " · 其余 \(ctx.listTotal - ctx.listItems.count) 项未列出" : "")
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: Space.sm) {
            Spacer(minLength: Space.md)

            // MED#3：空态也渲染 lastError（如「当前不在分类页面」），避免静默
            if let err = app.ai.lastError {
                HStack(spacing: Space.xxs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(err)
                        .font(Typo.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Signal.critical)
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xxs)
                .background(Capsule().fill(Signal.critical.opacity(0.08)))
                .padding(.horizontal, Space.sm)
            }

            EmptyState(
                icon: "bubble.left.and.text.bubble.right",
                title: "清理前先问一句",
                message: hintText
            )

            // P3 首启引导：未配置 AI 时给明确入口
            if !AIConfig.load().enabled {
                Button {
                    app.ai.showSettings = true
                } label: {
                    Label("去配置 AI 接口", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            contextCard
            Spacer(minLength: Space.md)
        }
    }

    private var hintText: String {
        if AIConfig.load().enabled {
            return "点列表项旁的「问 AI」按钮，AI 会判断用途、是否可删、是否在用。"
        }
        return "首次使用：先配置 AI 接口（默认已填 opencode go 网关，只需粘贴 Key）。"
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.sm) {
                    contextCard
                        .padding(.top, Space.xs)

                    ForEach(app.ai.messages) { msg in
                        MessageBubble(message: msg)
                    }

                    if app.ai.isLoading {
                        HStack(spacing: Space.xs) {
                            ProgressView().controlSize(.small)
                            Text("AI 思考中…")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.sm)
                    }

                    if let err = app.ai.lastError {
                        HStack(alignment: .top, spacing: Space.xs) {
                            Text(err)
                                .font(Typo.caption)
                                .foregroundStyle(Signal.critical)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                app.ai.retry()
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(Accent.tint)
                            .disabled(app.ai.isLoading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.sm)
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, Space.xs)
            }
            .onChange(of: app.ai.messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.ai.isLoading) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: Space.xs) {
            TextField("补充问题…（Enter 发送）", text: $app.ai.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .lineLimit(1...4)
                .onSubmit { app.ai.send() }

            Button {
                app.ai.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(app.ai.canSend ? Accent.tint : Ink.quaternary)
            }
            .pressable()
                .accessibilityLabel("发送消息")
            .accessibilityIdentifier("aiSendButton")
            .disabled(!app.ai.canSend)
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Surface.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Surface.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .padding(Space.sm)
    }
}

// MARK: - 消息

/// 一条消息 = 说话人标签（+ 等宽时间戳）+ 正文。用左侧竖线区分角色，
/// 不用气泡——面板本身已经是浮层，再套气泡就变成"卡片套卡片"。
struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isUser ? Accent.tint.opacity(0.5) : Surface.hairline)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.xxs) {
                    Image(systemName: isUser ? "person" : "bubble.left.and.text.bubble.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isUser ? Ink.tertiary : Accent.tint)
                    Text(isUser ? "我" : "AI 助手")
                        .font(Typo.section)
                        .foregroundStyle(Ink.secondary)
                    Spacer(minLength: Space.xs)
                    Text(message.date, style: .time)
                        .font(.mcNumeric(10))
                        .foregroundStyle(Ink.quaternary)
                }

                Text(message.content)
                    .font(Typo.body)
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Space.sm)
    }
}


// MARK: - 设置弹窗

struct AISettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: SettingsTab = .ai
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var showKey = false
    @State private var isTesting = false
    @State private var testResult: (ok: Bool, message: String)?

    // 白名单添加临时输入
    @State private var manualWhitelistPath = ""
    @State private var manualWhitelistComment = ""
    @State private var manualWhitelistExt = ""

    enum SettingsTab: String, CaseIterable, Identifiable {
        case ai = "AI 接口"
        case monitor = "定时巡检与预警"
        case whitelist = "白名单保护"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .ai: return "bubble.left.and.text.bubble.right"
            case .monitor: return "timer"
            case .whitelist: return "shield.checkered"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // 顶部分段选择器
            Picker("", selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Hairline()

            ScrollView {
                switch selectedTab {
                case .ai:
                    aiSettingsSection
                case .monitor:
                    monitorSettingsSection
                case .whitelist:
                    whitelistSettingsSection
                }
            }
            .frame(maxHeight: .infinity)

            Hairline()

            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(Space.lg)
        .frame(width: 540, height: 560)
        .onAppear {
            let cfg = AIConfig.load()
            baseURL = cfg.baseURL
            model = cfg.model
            DispatchQueue.global(qos: .userInitiated).async {
                let key = AIConfig.loadAPIKey() ?? ""
                DispatchQueue.main.async { apiKey = key }
            }
        }
    }

    // MARK: - AI 接口设置
    private var aiSettingsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("OpenAI 兼容接口。API Key 存入系统钥匙串，不写入代码或任何日志。")
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)

            fieldLabel("Base URL")
            TextField("https://api.deepseek.com", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)

            fieldLabel("API Key")
            HStack(spacing: Space.xs) {
                Group {
                    if showKey {
                        TextField("sk-…", text: $apiKey)
                    } else {
                        SecureField("sk-…", text: $apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Ink.secondary)
                .help(showKey ? "隐藏 API Key" : "显示 API Key")
                .accessibilityLabel(showKey ? "隐藏 API Key" : "显示 API Key")
            }

            fieldLabel("模型")
            TextField("deepseek-chat", text: $model)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)

            if let result = testResult {
                HStack(spacing: Space.xs) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(result.ok ? Signal.positive : Signal.critical)
                    Text(result.message)
                        .font(Typo.caption)
                        .foregroundStyle(result.ok ? Ink.secondary : Signal.critical)
                        .lineLimit(2)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill((result.ok ? Signal.positive : Signal.critical).opacity(0.08))
                )
            }

            HStack(spacing: Space.xs) {
                if isTesting {
                    ProgressView().controlSize(.small)
                    Text("测试中…")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer()
                Button("测试连接") {
                    testConnection()
                }
                .buttonStyle(.bordered)
                .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.trimmingCharacters(in: .whitespaces).isEmpty)

                Button("保存 AI 配置") {
                    var cfg = AIConfig.load()
                    cfg.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
                    cfg.model = model.trimmingCharacters(in: .whitespaces)
                    cfg.enabled = true
                    cfg.save()
                    let persisted = AIConfig.saveAPIKey(apiKey.trimmingCharacters(in: .whitespaces))
                    testResult = persisted
                        ? (true, "配置已保存，API Key 存入系统钥匙串")
                        : (false, "API Key 未写入钥匙串：本次可用，重启后需重新输入")
                }
                .buttonStyle(.borderedProminent)
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, Space.xxs)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Typo.row)
            .foregroundStyle(Ink.secondary)
    }

    // MARK: - 定时巡检与低空间警戒
    private var monitorSettingsSection: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("自动化磁盘健康检查：在后台定时发起无感巡检，并在磁盘空间紧张时预警。")
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)

            autoScanSetting

            lowSpaceAlertSetting

            Hairline()

            autoCleanSetting

            Hairline()

            menuBarAssistantSetting
        }
    }

    /// 后台定时巡检开关 + 巡检间隔（开启后才显示）
    @ViewBuilder
    private var autoScanSetting: some View {
        Toggle("开启后台定时自动巡检扫描", isOn: $app.diskMonitor.config.autoScanEnabled)
            .font(Typo.body)
            .toggleStyle(.switch)

        if app.diskMonitor.config.autoScanEnabled {
            HStack {
                Text("巡检时间间隔")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Stepper(value: $app.diskMonitor.config.scanIntervalHours, in: 1...24) {
                    Text("每 \(app.diskMonitor.config.scanIntervalHours) 小时")
                        .font(.mcNumeric(13))
                        .foregroundStyle(Accent.tint)
                }
            }
            .padding(.leading, Space.sm)
        }
    }

    /// 低空间警戒开关 + 警戒阈值（开启后才显示）
    @ViewBuilder
    private var lowSpaceAlertSetting: some View {
        Toggle("开启磁盘空间不足警戒弹窗", isOn: $app.diskMonitor.config.lowSpaceAlertEnabled)
            .font(Typo.body)
            .toggleStyle(.switch)

        if app.diskMonitor.config.lowSpaceAlertEnabled {
            HStack {
                Text("空间警戒阈值 (GB)")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Stepper(value: $app.diskMonitor.config.lowSpaceThresholdGB, in: 5...100, step: 5) {
                    Text("低于 \(app.diskMonitor.config.lowSpaceThresholdGB) GB")
                        .font(.mcNumeric(13))
                        .foregroundStyle(Signal.critical)
                }
            }
            .padding(.leading, Space.sm)
        }
    }

    /// 智能静默清理开关 + 免打扰时段（开启后才显示）
    @ViewBuilder
    private var autoCleanSetting: some View {
        Toggle("开启智能定时静默清理（仅限安全缓存与日志）", isOn: $app.diskMonitor.config.autoCleanEnabled)
            .font(Typo.body)
            .toggleStyle(.switch)

        if app.diskMonitor.config.autoCleanEnabled {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("遵循最高安全护栏：自动清理仅限「安全」风险且长期未在用项目，默认安全移入废纸篓，绝不影响正在运行的 App。")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("免打扰/闲时时间段保护", isOn: $app.diskMonitor.config.dndEnabled)
                    .font(Typo.body)
                    .toggleStyle(.checkbox)

                if app.diskMonitor.config.dndEnabled {
                    dndWindowRow
                }
            }
            .padding(.leading, Space.sm)
        }
    }

    /// 允许自动清理的时段窗口（起止小时选择）
    private var dndWindowRow: some View {
        HStack(spacing: Space.xs) {
            Text("允许自动清理时段：")
                .font(Typo.body)
                .foregroundStyle(Ink.secondary)
            Picker("", selection: $app.diskMonitor.config.dndStartHour) {
                ForEach(0..<24) { h in Text("\(h):00").tag(h) }
            }
            .labelsHidden()
            .frame(width: 80)
            Text("至")
                .font(Typo.body)
                .foregroundStyle(Ink.secondary)
            Picker("", selection: $app.diskMonitor.config.dndEndHour) {
                ForEach(0..<24) { h in Text("\(h):00").tag(h) }
            }
            .labelsHidden()
            .frame(width: 80)
        }
    }

    /// 菜单栏常驻助手：显示内容模式与说明
    private var menuBarAssistantSetting: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("系统菜单栏常驻助手")
                .font(Typo.section)
                .foregroundStyle(Ink.secondary)

            HStack {
                Text("菜单栏常驻图标显示内容")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
                Spacer()
                Picker("", selection: $app.diskMonitor.config.menuBarDisplayMode) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
            .padding(.leading, Space.sm)

            Text("常驻于系统右上角菜单栏，随时查看实时磁盘空间、内存压力分布并进行快捷全盘扫描与清理。")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Space.sm)
        }
    }

    // MARK: - 白名单保护设置
    private var whitelistSettingsSection: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("添加到白名单的文件、文件夹或 App 将被绝对排除，不会被扫描或清理。")
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)

            whitelistActionBar

            whitelistLoadWarning

            whitelistRulesList

            manualWhitelistPathRow

            manualWhitelistExtensionRow
        }
    }

    /// 白名单操作栏：选择文件夹 / 选择文件 / 已有规则条数
    private var whitelistActionBar: some View {
        HStack(spacing: Space.xs) {
            Button {
                chooseFolderForWhitelist()
            } label: {
                Label("选择文件夹…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                chooseFileForWhitelist()
            } label: {
                Label("选择文件…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            if !app.whitelist.rules.isEmpty {
                Text("共 \(app.whitelist.rules.count) 条保护规则")
                    .font(.mcNumeric(11))
                    .foregroundStyle(Ink.tertiary)
            }
        }
    }

    /// 白名单加载/保存异常必须显式告知。
    /// 白名单读不出来不只是"数据丢了"，而是**安全降级**：用户明确保护过的路径
    /// 会重新变成"可清理"。历史写法是静默返回空表，用户完全无从察觉。
    @ViewBuilder
    private var whitelistLoadWarning: some View {
        if let warning = app.whitelist.loadWarning {
            HStack(alignment: .top, spacing: Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.caution)
                Text(warning)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(Signal.caution.opacity(0.10))
            )
            .accessibilityIdentifier("whitelistLoadWarning")
        }
    }

    /// 规则列表：空态提示，或可滚动的分组规则列表
    @ViewBuilder
    private var whitelistRulesList: some View {
        if app.whitelist.rules.isEmpty {
            EmptyState(
                icon: "shield.slash",
                title: "暂无自定义白名单",
                message: "可通过上方按钮添加，或在清理项上右键选择「加入白名单」。"
            )
            .background(
                RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                    .fill(Surface.group)
            )
        } else {
            ScrollView {
                GroupBox {
                    ForEach(Array(app.whitelist.rules.enumerated()), id: \.element.id) { idx, rule in
                        GroupedRow(isLast: idx == app.whitelist.rules.count - 1) {
                            whitelistRuleRow(rule)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 180)
        }
    }

    /// 手动输入保护路径
    private var manualWhitelistPathRow: some View {
        HStack(spacing: Space.xs) {
            TextField("输入保护路径 (例如 ~/my-data)", text: $manualWhitelistPath)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)
            Button("添加路径") {
                let path = manualWhitelistPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return }
                app.addPathToWhitelist(path, comment: "手动添加路径")
                manualWhitelistPath = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(manualWhitelistPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    /// 手动输入排除扩展名
    private var manualWhitelistExtensionRow: some View {
        HStack(spacing: Space.xs) {
            TextField("输入排除扩展名 (例如 dmg, iso, psd, raw)", text: $manualWhitelistExt)
                .textFieldStyle(.roundedBorder)
                .font(Typo.body)
            Button("排除扩展名") {
                let ext = manualWhitelistExt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ext.isEmpty else { return }
                app.addExtensionToWhitelist(ext, comment: "自定义排除扩展名")
                manualWhitelistExt = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(manualWhitelistExt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func whitelistRuleRow(_ rule: WhitelistRule) -> some View {
        HStack(spacing: Space.xs) {
            IconSlot(
                systemName: rule.type == .appName ? "app.badge"
                    : rule.type == .extension ? "doc.badge.gearshape"
                    : "folder.badge.shield.half.filled",
                size: 13,
                color: Ink.secondary,
                width: 18
            )

            VStack(alignment: .leading, spacing: 1) {
                if rule.type == .extension {
                    Text("扩展名: .\(rule.pattern)")
                        .font(.mcNumeric(12, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                } else {
                    Text(rule.pattern)
                        .font(Typo.row)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !rule.comment.isEmpty {
                    Text(rule.comment)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                }
            }
            Spacer()
            Button {
                app.whitelist.removeRule(id: rule.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Ink.tertiary)
            }
            .pressable()
            .help("移除白名单")
            .accessibilityLabel("移除白名单")
        }
    }

    private func chooseFolderForWhitelist() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择保护文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            app.addPathToWhitelist(url.path, comment: url.lastPathComponent)
        }
    }

    private func chooseFileForWhitelist() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择保护文件"
        if panel.runModal() == .OK, let url = panel.url {
            app.addPathToWhitelist(url.path, comment: url.lastPathComponent)
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let mdl = model.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                let reply = try await AIService.testConnection(baseURL: url, apiKey: key, model: mdl)
                await MainActor.run {
                    var cfg = AIConfig.load()
                    cfg.baseURL = url
                    cfg.model = mdl
                    cfg.enabled = true
                    cfg.save()
                    let persisted = AIConfig.saveAPIKey(key)
                    testResult = persisted
                        ? (true, "连接成功，模型回复：\(reply.prefix(30))")
                        : (false, "连接成功，但 API Key 未写入钥匙串：本次可用，重启后需重新输入")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = (false, "连接失败：\(error.localizedDescription)")
                    isTesting = false
                }
            }
        }
    }
}
