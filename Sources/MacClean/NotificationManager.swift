import Foundation
import AppKit
import UserNotifications

/// 系统通知与 Dock 徽标管理中心
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// 是否处于标准的 macOS .app bundle 运行环境（命令行/无头自检模式下 UNUserNotificationCenter 会崩溃）
    static var isAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? {
        guard Self.isAppBundle else { return nil }
        return UNUserNotificationCenter.current()
    }

    override private init() {
        super.init()
        if Self.isAppBundle {
            center?.delegate = self
        }
    }

    /// 请求系统通知权限（仅在 .app bundle 环境生效）
    func requestAuthorization() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("[NotificationManager] 授权请求错误: \(error.localizedDescription)")
            }
        }
    }

    /// 记录最近发送的通知记录（测试验证与状态追溯）
    struct SentNotification: Equatable {
        let title: String
        let body: String
    }
    private(set) var lastNotification: SentNotification?

    /// 测试覆盖使用：强制允许发送/记录通知
    var allowNotificationsForTesting: Bool = false

    /// 更新 Dock 图标徽标（显示当前可清理项目总数或释放容量，为 0 时清除）
    func updateDockBadge(count: Int) {
        if Thread.isMainThread {
            if count > 0 {
                NSApplication.shared.dockTile.badgeLabel = "\(count)"
            } else {
                NSApplication.shared.dockTile.badgeLabel = nil
            }
        } else {
            DispatchQueue.main.async {
                self.updateDockBadge(count: count)
            }
        }
    }

    /// 发送扫描完成系统通知
    func notifyScanCompleted(categoryName: String?, itemCount: Int, totalBytes: Int64) {
        guard itemCount > 0 else { return }

        let title: String
        let body: String
        if let categoryName {
            title = "\(categoryName) 扫描完成"
            body = "发现 \(itemCount) 个可清理项目，共可释放 \(totalBytes.byteStringCN)。"
        } else {
            title = "系统全部分类扫描完成"
            body = "共发现 \(itemCount) 个可清理项目，累计可释放 \(totalBytes.byteStringCN)。"
        }

        lastNotification = SentNotification(title: title, body: body)

        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.macclean.scan.complete.\(UUID().uuidString)",
            content: content,
            trigger: nil // 立即触发
        )

        center.add(request) { error in
            if let error {
                print("[NotificationManager] 发送通知失败: \(error.localizedDescription)")
            }
        }
    }

    /// 发送清理完成系统通知
    func notifyCleanCompleted(releasedBytes: Int64, failureCount: Int) {
        let title = "MacClean 清理完成"
        let body: String
        if failureCount > 0 {
            body = "成功释放 \(releasedBytes.byteStringCN)，另有 \(failureCount) 项清理失败或跳过。"
        } else {
            body = "已成功安全释放 \(releasedBytes.byteStringCN) 空间！"
        }

        lastNotification = SentNotification(title: title, body: body)

        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.macclean.clean.complete.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error {
                print("[NotificationManager] 发送清理完成通知失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate
    // 应用在前台时同样显示通知横幅
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
