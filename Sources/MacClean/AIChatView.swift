import SwiftUI

/// 侧边 AI 对话面板（针对清理项提问：用途/能否删/是否在用）
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
            Divider().overlay(Theme.hairline)

            // 列表级提问入口（grill Q4：按钮 + 输入框自动携带）
            HStack(spacing: 6) {
                Button {
                    app.ai.askAboutCurrentList()
                    app.ai.openDrawer()
                } label: {
                    Label("问当前列表", systemImage: "list.bullet")
                        .font(Theme.bodyFont(13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.actionBlue)
                .disabled(app.ai.isLoading || !isOnCategoryPage)
                .help(isOnCategoryPage ? "分析当前分类扫描结果" : "请先进入一个分类")

                Button {
                    app.ai.askAboutAll()
                    app.ai.openDrawer()
                } label: {
                    Label("问全部", systemImage: "square.grid.2x2")
                        .font(Theme.bodyFont(13, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.actionBlue)
                .disabled(app.ai.isLoading || !hasAnyScanned)
                .help(hasAnyScanned ? "分析全部已扫描分类" : "请先扫描至少一个分类")

                Spacer()
            }
            .padding(.horizontal, Theme.spaceSm)
            .padding(.vertical, 6)
            .background(Theme.parchment)

            if app.ai.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            Divider().overlay(Theme.hairline)
            inputBar
        }
        .frame(width: 340)
        .background(Theme.canvas)
        .sheet(isPresented: $app.ai.showSettings) {
            AISettingsView()
                .environmentObject(app)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.actionBlue)
            Text("AI 助手")
                .font(Theme.bodyFont(13, weight: .semibold))
                .foregroundColor(Theme.ink)
            Spacer()

            // 清空对话
            if !app.ai.messages.isEmpty {
                Button {
                    app.ai.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.inkMuted48)
                .accessibilityLabel("清空对话")
                .help("清空对话")
            }

            // 设置
            Button {
                app.ai.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Theme.inkMuted48)
            .accessibilityLabel("AI 设置")
            .help("AI 设置")

            // 关闭抽屉（d1 抽屉式）
            Button {
                app.ai.closeDrawer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Theme.inkMuted48)
            .accessibilityLabel("收起 AI 面板")
            .help("收起 AI 面板")
            .accessibilityIdentifier("aiCloseDrawer")
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 10)
        .background(Theme.canvas)
    }

    // MARK: - 上下文卡片（当前提问目标）

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.actionBlue)
                Text("当前询问目标")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.inkMuted48)
                Spacer()
            }
            if let ctx = app.ai.context {
                if ctx.isListMode {
                    // 列表模式：显示汇总与截断信息
                    Text(ctx.listSummary)
                        .font(Theme.bodyFont(13, weight: .semibold))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    Text("列出最大 \(ctx.listItems.count) 项" + (ctx.listItems.count < ctx.listTotal ? " · 其余 \(ctx.listTotal - ctx.listItems.count) 项未列出" : ""))
                        .font(Theme.bodyFont(13))
                        .foregroundColor(Theme.inkMuted48)
                        .lineLimit(1)
                } else {
                    Text(ctx.title)
                        .font(Theme.bodyFont(13, weight: .semibold))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    Text("\(ctx.category) · \(ctx.sizeString) · 风险 \(ctx.risk)")
                        .font(Theme.bodyFont(13))
                        .foregroundColor(Theme.inkMuted48)
                        .lineLimit(1)
                    if !ctx.inUseBy.isEmpty {
                        Text("占用中：\(ctx.inUseBy.joined(separator: "、"))")
                            .font(Theme.bodyFont(13, weight: .medium))
                            .foregroundColor(Theme.textWarning)
                            .lineLimit(1)
                    }
                }
            } else {
                Text("点「问当前列表/问全部」或列表项旁的 ✨ 提问")
                    .font(Theme.bodyFont(13))
                    .foregroundColor(Theme.inkMuted48)
            }
        }
        .padding(Theme.spaceSm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.parchment))
        
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 6)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: Theme.spaceSm) {
            Spacer()
            // MED#3：空态也渲染 lastError（如「当前不在分类页面」），避免静默
            if let err = app.ai.lastError {
                Text(err)
                    .font(Theme.bodyFont(13, weight: .medium))
                    .foregroundColor(Theme.textDanger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.dangerRed.opacity(0.08)))
            }
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Theme.actionBlue.opacity(0.5))
            Text("清理前先问一句")
                .font(Theme.bodyFont(14, weight: .semibold))
                .foregroundColor(Theme.ink)
            if AIConfig.load().enabled {
                Text("点击列表项旁的 ✨ 按钮\n让 AI 判断用途、是否可删、是否在用")
                    .font(Theme.bodyFont(13))
                    .foregroundColor(Theme.inkMuted48)
                    .multilineTextAlignment(.center)
            } else {
                // P3 首启引导：未配置 AI 时给明确入口
                Text("首次使用：先配置 AI 接口\n（默认已填 opencode go 网关，只需粘贴 Key）")
                    .font(Theme.bodyFont(13))
                    .foregroundColor(Theme.inkMuted48)
                    .multilineTextAlignment(.center)
                Button {
                    app.ai.showSettings = true
                } label: {
                    Label("去配置 AI 接口", systemImage: "gearshape")
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 18)
                        .background(Capsule().fill(Theme.actionBlue))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
            contextCard
            Spacer()
        }
    }

    // MARK: - 消息列表

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    contextCard
                    ForEach(app.ai.messages) { msg in
                        MessageBubble(message: msg)
                    }
                    if app.ai.isLoading {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(Theme.actionBlue)
                            Text("AI 思考中…")
                                .font(Theme.bodyFont(13))
                                .foregroundColor(Theme.inkMuted48)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.spaceSm)
                    }
                    if let err = app.ai.lastError {
                        HStack(spacing: 6) {
                            Text(err)
                                .font(Theme.bodyFont(13))
                                .foregroundColor(Theme.textDanger)
                            Button {
                                app.ai.retry()
                            } label: {
                                Label("重试", systemImage: "arrow.clockwise")
                                    .font(Theme.bodyFont(13, weight: .medium))
                            }
                            .buttonStyle(.borderless)
                            .foregroundColor(Theme.actionBlue)
                            .disabled(app.ai.isLoading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.spaceSm)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, Theme.spaceXs)
            }
            .onChange(of: app.ai.messages.count) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: app.ai.isLoading) { _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .background(Theme.parchment)
    }

    // MARK: - 输入栏

    private var inputBar: some View {
        HStack(spacing: 6) {
            TextField("补充问题…（Enter 发送）", text: $app.ai.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.bodyFont(13))
                .lineLimit(1...4)
                .onSubmit { app.ai.send() }

            Button {
                app.ai.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(app.ai.canSend ? Theme.actionBlue : Theme.inkMuted48.opacity(0.4))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("aiSendButton")
            .disabled(!app.ai.canSend)
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.parchment)
                
        )
        .padding(Theme.spaceSm)
    }
}

// MARK: - 消息气泡

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 30) }
            Text(message.content)
                .font(Theme.bodyFont(13))
                .foregroundColor(message.role == .user ? .white : Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.spaceSm)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .fill(message.role == .user ? Theme.actionBlue : Theme.canvas)
                )
                
            if message.role == .assistant { Spacer(minLength: 30) }
        }
        .padding(.horizontal, Theme.spaceSm)
    }
}

// MARK: - 设置弹窗

struct AISettingsView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var showKey = false
    @State private var isTesting = false
    @State private var testResult: (ok: Bool, message: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceMd) {
            Text("AI 接口设置")
                .font(Theme.displayFont(20, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(Theme.ink)

            Text("OpenAI 兼容接口。API Key 存入系统钥匙串，不写入代码、日志或任何文件。")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)

            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)
                TextField("https://api.deepseek.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodyFont(13))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)
                HStack {
                    Group {
                        if showKey {
                            TextField("sk-…", text: $apiKey)
                        } else {
                            SecureField("sk-…", text: $apiKey)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodyFont(13))
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.inkMuted48)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)
                TextField("deepseek-chat", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodyFont(13))
            }

            // 连通性测试
            if let result = testResult {
                HStack(spacing: 6) {
                    Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.ok ? Theme.actionBlue : Theme.dangerRed)
                    Text(result.message)
                        .font(Theme.bodyFont(13))
                        .foregroundColor(result.ok ? Theme.inkMuted80 : Theme.textDanger)
                        .lineLimit(2)
                }
                .padding(.horizontal, Theme.spaceSm)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill((result.ok ? Theme.actionBlue : Theme.dangerRed).opacity(0.08)))
            }

            HStack {
                if isTesting {
                    ProgressView().controlSize(.small).tint(Theme.actionBlue)
                    Text("测试中…")
                        .font(Theme.bodyFont(13))
                        .foregroundColor(Theme.inkMuted48)
                }
                Spacer()
                Button("测试连接") {
                    testConnection()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("保存") {
                    var cfg = AIConfig.load()
                    cfg.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
                    cfg.model = model.trimmingCharacters(in: .whitespaces)
                    cfg.enabled = true
                    cfg.save()
                    AIConfig.saveAPIKey(apiKey.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.actionBlue)
                .disabled(baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.spaceXl)
        .frame(width: 440)
        .onAppear {
            let cfg = AIConfig.load()
            baseURL = cfg.baseURL
            model = cfg.model
            // MED#5：钥匙串迁移路径可能阻塞 3s——后台读取后回主线程填充
            DispatchQueue.global(qos: .userInitiated).async {
                let key = AIConfig.loadAPIKey() ?? ""
                DispatchQueue.main.async { apiKey = key }
            }
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
                    testResult = (true, "连接成功，模型回复：\(reply.prefix(30))")
                    isTesting = false
                    // 关键修复：测试成功即把配置写入 UserDefaults + key 文件，并置 enabled=true。
                    // 否则用户测试成功但问答仍报「尚未配置」（问答读的是 AIConfig.load() 而非表单值）
                    var cfg = AIConfig.load()
                    cfg.baseURL = url
                    cfg.model = mdl
                    cfg.enabled = true
                    cfg.save()
                    AIConfig.saveAPIKey(key)
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
