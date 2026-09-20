import SwiftUI
import AppKit

// MARK: - 极速清理浮动微面板控制器

final class QuickCleanPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickCleanPanelController()

    private var panel: NSPanel?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    private override init() {
        super.init()
    }

    /// 切换微面板显示/隐藏
    func toggle(with app: AppState) {
        if let panel = panel, panel.isVisible {
            hide()
        } else {
            show(with: app)
        }
    }

    /// 呼出微面板
    func show(with app: AppState) {
        let p = panel ?? buildPanel(with: app)
        self.panel = p

        // 重新注入环境或刷新状态
        app.refreshDisk()
        SystemMonitor.shared.refresh()

        positionPanel(p)

        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1.0
        }

        installDismissMonitors()
    }

    /// 隐藏微面板
    func hide() {
        guard let p = panel, p.isVisible else { return }
        removeDismissMonitors()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0.0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }

    var isVisible: Bool {
        return panel?.isVisible == true
    }

    private func buildPanel(with app: AppState) -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.hasShadow = true
        p.delegate = self

        let contentView = QuickCleanPanelView()
            .environmentObject(app)
        p.contentView = NSHostingView(rootView: contentView)
        return p
    }

    private func positionPanel(_ p: NSPanel) {
        // 获取当前鼠标所在的屏幕或主屏幕
        let mouseLoc = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouseLoc, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        let screenFrame = screen.visibleFrame
        let panelWidth: CGFloat = 360
        let panelHeight: CGFloat = 260

        // 居中偏上（距离顶部 80 像素）
        let x = screenFrame.midX - (panelWidth / 2)
        let y = screenFrame.maxY - panelHeight - 80

        p.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()

        // 监听本地 Esc 键
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.hide()
                return nil
            }
            return event
        }

        // 监听全局鼠标点击（点击窗口外部自动收起）
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeDismissMonitors() {
        if let local = localEventMonitor {
            NSEvent.removeMonitor(local)
            localEventMonitor = nil
        }
        if let global = globalEventMonitor {
            NSEvent.removeMonitor(global)
            globalEventMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }
}

// MARK: - 极速清理微面板视图 (SwiftUI)

struct QuickCleanPanelView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var sysMonitor = SystemMonitor.shared
    @State private var cleanFeedback: String? = nil
    @State private var isFlushingDNS = false
    @State private var dnsFeedback: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏
            topHeader
            Hairline()

            // 仪表与快捷主卡片
            VStack(spacing: Space.xs) {
                metricsBar
                cleanActionCard
                toolsRow
            }
            .padding(Space.sm)
        }
        .frame(width: 360, height: 260)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Surface.window.opacity(0.85)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Surface.hairline.opacity(0.6), lineWidth: 1)
        )
        .accessibilityIdentifier("quickCleanPanel")
    }

    // MARK: - 顶栏
    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Accent.tint)

            Text("MacClean 极速清理")
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)

            Spacer()

            // 当前全局快捷键提示
            Text(app.diskMonitor.config.globalHotkeyPreset.shortDisplay)
                .font(Typo.micro)
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Button {
                QuickCleanPanelController.shared.hide()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closeQuickCleanButton")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
    }

    // MARK: - 仪表状态条
    private var metricsBar: some View {
        HStack(spacing: Space.sm) {
            // 磁盘可用
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.tertiary)
                    Text("磁盘可用")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                    Spacer()
                    Text(app.diskAvailable.byteStringCN)
                        .font(.mcNumeric(11, weight: .medium))
                        .foregroundStyle(Ink.primary)
                }
                CapacityBar(used: app.usedRatio, height: 5, isCritical: app.usedRatio > 0.88)
            }
            .frame(maxWidth: .infinity)

            // 内存压力
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.tertiary)
                    Text("内存占用")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                    Spacer()
                    Text("\(Int(sysMonitor.memory.usageRatio * 100))%")
                        .font(.mcNumeric(11, weight: .medium))
                        .foregroundStyle(sysMonitor.memory.pressure.color)
                }
                CapacityBar(used: sysMonitor.memory.usageRatio, height: 5, isCritical: sysMonitor.memory.pressure == .high)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 极速主操作卡片
    private var cleanActionCard: some View {
        VStack(spacing: 6) {
            if let feedback = cleanFeedback {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Signal.positive)
                    Text(feedback)
                        .font(Typo.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Signal.positive.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            } else {
                Button {
                    performQuickClean()
                } label: {
                    HStack(spacing: 6) {
                        if app.isCleaning {
                            ProgressView().controlSize(.small)
                            Text("正在安全清理…")
                        } else {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text(quickCleanButtonTitle)
                        }
                    }
                    .font(Typo.rowStrong)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Accent.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(app.isCleaning)
                .accessibilityIdentifier("quickCleanActionButton")
            }
        }
    }

    private var quickCleanButtonTitle: String {
        if app.totalSelected > 0 {
            return "极速释放选中项 (\(app.totalSelected.byteStringCN))"
        } else if app.smartRecommendedBytes > 0 {
            return "一键极速推荐瘦身 (\(app.smartRecommendedBytes.byteStringCN))"
        } else if app.totalCleanable > 0 {
            return "一键安全速清 (\(app.totalCleanable.byteStringCN))"
        } else {
            return "一键深度扫描与释放"
        }
    }

    private func performQuickClean() {
        if app.totalSelected > 0 {
            app.cleanSelectedAcrossCategories(permanently: false)
        } else if app.smartRecommendedBytes > 0 {
            app.quickCleanSmartRecommendations()
        } else if app.totalCleanable > 0 {
            app.quickCleanSafeItems()
        } else {
            app.scanAll()
            return
        }

        withAnimation(.easeOut(duration: 0.2)) {
            cleanFeedback = "已完成极速释放，空间已夺回！"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                self.cleanFeedback = nil
            }
        }
    }

    // MARK: - 工具栏
    private var toolsRow: some View {
        HStack(spacing: Space.xs) {
            // 刷新 DNS
            Button {
                isFlushingDNS = true
                DispatchQueue.global(qos: .userInitiated).async {
                    _ = NetworkPrivacyInspector.shared.flushDNSCache()
                    DispatchQueue.main.async {
                        self.isFlushingDNS = false
                        self.dnsFeedback = "DNS 已刷新"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self.dnsFeedback = nil
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.system(size: 11))
                    Text(dnsFeedback ?? (isFlushingDNS ? "刷新中…" : "刷新 DNS 缓存"))
                        .font(Typo.caption)
                }
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Surface.group)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isFlushingDNS)
            .accessibilityIdentifier("quickFlushDNSButton")

            Spacer()

            // 打开主窗口
            Button {
                QuickCleanPanelController.shared.hide()
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeMain {
                    window.makeKeyAndOrderFront(nil)
                    return
                }
            } label: {
                HStack(spacing: 4) {
                    Text("打开主面板")
                        .font(Typo.caption)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Surface.group)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("quickOpenMainButton")
        }
    }
}

// MARK: - 毛玻璃视图桥接

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
