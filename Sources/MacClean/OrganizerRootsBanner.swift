import SwiftUI

// MARK: - 归档面板的"这一轮没看全"提示

/// 两张归档面板（下载治理 / 截图归档）共用的不完整提示。
///
/// 两种情形必须分开讲，混起来就是谎报：
/// - **读不到**（权限被拒、或授权请求未决导致超时）→ 警示 + 锁形图标，并说明列表不完整；
/// - **本轮没顾上读**（门禁读取的在途额度已满，见 `FileSystem.gatedReadSlots`）→ 中性提示。
///   这一种**根本没去 `open`**，说成"读不到/权限不足"就是凭空造一条告警，
///   会把真该授权的目录（Safari 容器那类）的信用一起稀释掉。
///
/// 放在一处是为了让文案只有一个来源：两张卡片各写一份的话，改一处漏一处，
/// 而"没读到"与"没有文件"同时出现在屏幕上正是这么来的。
struct OrganizerRootsBanner: View {
    let unreadable: [String]
    let deferred: [String]

    var hasAnything: Bool { !unreadable.isEmpty || !deferred.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !unreadable.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.caution)
                    Text("本轮没能读到 \(names(unreadable))，下面这份列表不完整")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: 0)
                }
            }
            if !deferred.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12))
                        .foregroundStyle(Ink.secondary)
                    Text("本轮没顾上读 \(names(deferred))，请稍后重试")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("organizerRootsBanner")
    }

    /// 只报第一个名字会让用户以为只少了一个目录（截图面板有三个默认根）。
    private func names(_ roots: [String]) -> String {
        let list = roots.map { ($0 as NSString).lastPathComponent }
        if list.count <= 2 { return list.joined(separator: "、") }
        return "\(list.prefix(2).joined(separator: "、")) 等 \(list.count) 个目录"
    }
}
