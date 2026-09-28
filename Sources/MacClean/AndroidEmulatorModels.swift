import Foundation

// MARK: - Android 模拟器与 SDK 系统镜像孤儿治理 (v1.73.10)

/// 判据（全部由文件系统自证）：
/// - **孤儿 AVD**：`~/.android/avd/*.avd` 目录存在，但**没有任何 `*.ini` 描述符的 `path=` 指向它**。
///   注意配对看的是**描述符内容**而不是文件名：`avdmanager` 按 ini 里的 `path=` 定位数据目录，
///   描述符名与目录名可以不同（本机实测 `zz-descriptor-name.ini` → `probe.avd` 照样被 `list avd` 列出）。
///   按"同名 .ini 是否存在"配对会把一台活的 AVD 判成孤儿并默认勾选——v1.73.10 独立复审的 P0。
///   只剩没人指向的 `.avd` = 描述符被单独删过 / 手工挪动过，模拟器列不出它，磁盘上还占着
///   GB 级 `userdata-qemu.img`，界面上再也看不见，是典型的"删不干净的残留"。
/// - **镜像已删的 AVD（broken image）**：`.avd/config.ini` 里的 `image.sysdir.1`（相对 SDK 根的
///   系统镜像子路径，如 `system-images/android-35/google_apis/arm64-v8a/`）在**可读的** SDK 根下
///   **不存在** = 底层系统镜像被 `sdkmanager --uninstall` 删了，AVD 起不来。**这一类只报不删默认**：
///   它是用户可能还想保留数据盘的 AVD，删除决定权交回用户（见 `AndroidEmulatorStatus.isProvenOrphan`）。
///   SDK 根存在但读不到时**不判这一档**，改判「证据不足」——"没看到镜像"不等于"镜像被删"。
enum AndroidEmulatorKind: String, Codable, CaseIterable, Identifiable {
    case orphanAVD        // 没有描述符指向的 `.avd`：孤儿数据目录
    case brokenImageAVD   // 有描述符指向，但 `image.sysdir.1` 指向的镜像已删：AVD 起不来
    case liveAVD          // 两条判据都通过的健康 AVD（只计数，不列为可清理）

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .orphanAVD: return "trash.slash"
        case .brokenImageAVD: return "exclamationmark.triangle"
        case .liveAVD: return "checkmark.circle"
        }
    }
}

/// 处置状态。安全语义与打印机/音频 HAL 模块**逐字对齐**（G14/G16）：
/// `.needsConfirmation` 与 `.liveHealthy` 的 `isProvenOrphan == false` —— 界面默认不勾选、
/// `clean()` 不放行；只有 `.orphanUnused` 才是默认可清理项。
enum AndroidEmulatorStatus: String {
    case orphanUnused = "孤儿（可清理）"
    case brokenImageNeedsConfirm = "镜像已删（需确认，可能仍想保留）"
    case liveHealthy = "健康（勿动）"
    case needsConfirmation = "证据不足（需确认）"

    /// 唯一被允许"默认勾选 + 进入删除放行"的状态。名字刻意不叫 "orphanOrCorrupted"：
    /// 「镜像已删」看着像损坏，但它**不在**放行集合里（数据盘可能还要留），叫错名字会诱导
    /// 后来者把 brokenImage 也加进来。
    var isProvenOrphan: Bool {
        self == .orphanUnused
    }

    var icon: String {
        switch self {
        case .orphanUnused: return "trash.slash"
        case .brokenImageNeedsConfirm, .needsConfirmation: return "questionmark.circle"
        case .liveHealthy: return "checkmark.circle"
        }
    }
}

/// `config.ini` 读取的三态结果（v1.73.10 复审待议 #3）。此前 `readConfigIni` 把
/// 「文件读不出来」与「键不存在」都折成 nil，两种"证据不足"共用一句「未写明」文案——
/// 把"我们没能看到这份 config"和"看到了、它没写"混为一谈，文案于是当面撒谎。
enum AndroidConfigIniReading: Equatable {
    /// 读到了 `image.sysdir.1` 的值（已按 whitespacesAndNewlines 清洗，保证非空）。
    case value(String)
    /// config.ini **读出来了**，但没有写 `image.sysdir.1`（老式 AVD / config 残缺）。
    case keyMissing
    /// config.ini 本身**读不出来**（不存在 / 权限不足 / IO 错误）——镜像存在性这一眼根本没看成。
    case unreadable

    /// 判据输入留痕用：`.value` 时给出键值，其余两种为 nil。
    var value: String? {
        if case .value(let v) = self { return v }
        return nil
    }
}

/// 单个待清理 / 待确认条目。`deletionTargets` 是**整棵 `.avd` 目录**（孤儿情形）——`.avd` 里是这台
/// AVD 的全部状态（磁盘镜像、快照、config），删它就是回收它占的字节。非孤儿不进这张表。
struct AndroidEmulatorItem: Identifiable, Equatable, Hashable {
    let id: String                 // AVD 目录绝对路径
    let name: String               // 展示名（`.avd` 去掉后缀的 AVD 名）
    let path: String               // `.avd` 目录绝对路径
    let kind: AndroidEmulatorKind
    let status: AndroidEmulatorStatus
    let size: Int64
    /// 遍历是否完整（`WalkBlockFlag`）。false = size 是"至少这么多"，不得据此默认勾选（v1.73.7 契约）。
    let readable: Bool
    /// 镜像判据的输入留痕：config.ini 的 image.sysdir.1（相对 SDK 根）。
    /// config 缺失 / 读不出来 / 未写明时为 nil。判定的**结论**（镜像在不在）已编码进
    /// `status` 与 `note`，这里不再留 `imagePresent` 副本（v1.73.10 待议 #2：算了没人读的字段一律删）。
    let imageSysdir: String?
    let note: String?
    var isSelected: Bool

    /// 交给删除网关的具体目标：孤儿 = 整棵 `.avd` 目录；其余 = 空（不删，但拒绝原因由
    /// `AndroidEmulatorScanner.clean` 显式带进 `Outcome.rejected`，不留沉默）。
    var deletionTargets: [String] {
        status.isProvenOrphan ? [path] : []
    }
}

struct AndroidEmulatorSummary: Equatable {
    var items: [AndroidEmulatorItem] = []
    var orphanCount: Int = 0
    var orphanSize: Int64 = 0
    var brokenImageCount: Int = 0
    var liveCount: Int = 0
    /// 证据不完整（根读不到 / AVD 未读全 / 有 `.avd` 是软链未判定）时的说明；
    /// 非空即 `isResultComplete == false`。
    var issues: [GovernanceEvidenceIssue] = []
    /// 扫描用的 AVD 根（已 normalize；可能是 `$ANDROID_AVD_HOME` 重定位后的位置）。
    var avdRoot: String = ""
    /// 本轮**可读**的 SDK 根（只用于镜像判据、不作为删除根）。
    var detectedSDKRoots: [String] = []

    /// 与 v1.73.7 契约对齐：**只要 issues 非空即结果不完整**，卡片必须显示"结果不完整"，
    /// 不得把空列表渲染成"这台机器没有可清理的 AVD"。
    var isResultComplete: Bool { issues.isEmpty }
}
