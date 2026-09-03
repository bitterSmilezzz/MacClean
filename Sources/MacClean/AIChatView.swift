import SwiftUI

/// 侧边 AI 对话面板（针对清理项提问：用途/能否删/是否在用）
struct AIChatView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            if app.ai.messages.isEmpty {
                emptyState
            } else {
                messageList
            }

            Divider().overlay(Theme.hairline)
            inputBar
        }
        .frame(width: 300)
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
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.inkMuted48)
                .help("清空对话")
            }

            // 设置
            Button {
                app.ai.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Theme.inkMuted48)
            .help("AI 设置")
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
                    .font(Theme.bodyFont(10, weight: .semibold))
                    .foregroundColor(Theme.inkMuted48)
                Spacer()
            }
            if let ctx = app.ai.context {
                Text(ctx.title)
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                Text("\(ctx.category) · \(ctx.sizeString) · 风险 \(ctx.risk)")
                    .font(Theme.bodyFont(10))
                    .foregroundColor(Theme.inkMuted48)
                    .lineLimit(1)
                if !ctx.inUseBy.isEmpty {
                    Text("占用中：\(ctx.inUseBy.joined(separator: "、"))")
                        .font(Theme.bodyFont(10, weight: .medium))
                        .foregroundColor(Theme.warningOrange)
                        .lineLimit(1)
                }
            } else {
                Text("点击列表项旁的 ✨ 按钮即可针对该项提问")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
            }
        }
        .padding(Theme.spaceSm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.parchment))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 6)
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: Theme.spaceSm) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(Theme.actionBlue.opacity(0.5))
            Text("清理前先问一句")
                .font(Theme.bodyFont(14, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("点击列表项旁的 ✨ 按钮\n让 AI 判断用途、是否可删、是否在用")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.inkMuted48)
                .multilineTextAlignment(.center)
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
                                .font(Theme.bodyFont(11))
                                .foregroundColor(Theme.inkMuted48)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.spaceSm)
                    }
                    if let err = app.ai.lastError {
                        Text(err)
                            .font(Theme.bodyFont(11))
                            .foregroundColor(Theme.dangerRed)
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
                .font(Theme.bodyFont(12))
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
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).stroke(Theme.hairline, lineWidth: 1))
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
                .font(Theme.bodyFont(12))
                .foregroundColor(message.role == .user ? .white : Theme.ink)
                .textSelection(.enabled)
                .padding(.horizontal, Theme.spaceSm)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .fill(message.role == .user ? Theme.actionBlue : Theme.canvas)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .stroke(message.role == .user ? Color.clear : Theme.hairline, lineWidth: 1)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceMd) {
            Text("AI 接口设置")
                .font(Theme.displayFont(20, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(Theme.ink)

            Text("OpenAI 兼容接口。API Key 存入系统钥匙串，不写入代码、日志或任何文件。")
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.inkMuted48)

            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)
                TextField("https://api.deepseek.com", text: $baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodyFont(12))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(Theme.bodyFont(12, weight: .semibold))
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
                    .font(Theme.bodyFont(12))
                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Theme.inkMuted48)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模型")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)
                TextField("deepseek-chat", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.bodyFont(12))
            }

            HStack {
                Spacer()
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
            apiKey = AIConfig.loadAPIKey() ?? ""
        }
    }
}
