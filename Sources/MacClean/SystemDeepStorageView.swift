import SwiftUI

// MARK: - 系统底层存储深度治理卡片（休眠镜像与 APFS 本地快照）

public struct SystemDeepStorageView: View {
    @State private var snapshots: [APFSSnapshot] = []
    @State private var snapshotIssues: [GovernanceEvidenceIssue] = []
    /// 本轮是否真的拿到了快照清单（false = tmutil 没跑成，"0 个"不代表没有快照）
    @State private var snapshotListRead: Bool = false
    @State private var vmInfo: VMMemoryInfo = VMMemoryInfo()
    @State private var isLoading: Bool = false
    @State private var bannerMessage: String? = nil
    @State private var showConfirmDeleteAllSnapshots: Bool = false
    @State private var showScriptSheet: Bool = false
    /// **用户逐条点名**要删除的快照名（唯一可删集合，永不隐式全选）
    @State private var confirmedSnapshotNames: Set<String> = []
    /// 单条删除的二次确认状态
    @State private var showConfirmSingleDelete: Bool = false
    @State private var pendingDeleteName: String? = nil

    public init() {}

    /// 自检注入口：本卡片的勾选集是 `@State`（ViewInspector 在 macOS 上不传播它的变更），
    /// 只能从 init 播种，才能断言"未逐条点名就不给删 / 删除必经确认弹窗"。
    /// 生产调用方仍走 `SystemDeepStorageView()`，行为不变。
    internal init(initialSnapshots: [APFSSnapshot],
                  initiallyConfirmedNames: Set<String> = [],
                  initiallyConfirming: Bool = false) {
        _snapshots = State(initialValue: initialSnapshots)
        _confirmedSnapshotNames = State(initialValue: initiallyConfirmedNames)
        _snapshotListRead = State(initialValue: true)
        _showConfirmDeleteAllSnapshots = State(initialValue: initiallyConfirming)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部与刷新
            headerRow

            // 操作提示横幅
            if let msg = bannerMessage {
                bannerView(message: msg)
            }

            // APFS 本地快照卡片
            snapshotsCard

            // 休眠镜像与虚拟内存卡片
            vmMemoryCard
        }
        .padding(12)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onAppear {
            reload()
        }
        .alert("释放勾选的 APFS 本地快照", isPresented: $showConfirmDeleteAllSnapshots) {
            Button("确认删除这 \(confirmedSnapshotNames.count) 个", role: .destructive) {
                deleteConfirmedSnapshots()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会删除你逐条勾选的 \(confirmedSnapshotNames.count) 个快照（本工具不会整批静默执行）："
                 + confirmedSnapshotNames.sorted().prefix(6).map { $0 }.joined(separator: "、")
                 + "。删除后由快照锁定的已删数据块会被立即回收，无法撤销。")
        }
        .alert("释放单个本地快照", isPresented: $showConfirmSingleDelete) {
            Button("确认删除", role: .destructive) {
                if let name = pendingDeleteName { performDeleteSingleSnapshot(name: name) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("即将执行 tmutil deletelocalsnapshots \(pendingDeleteName ?? "")。"
                 + "该操作不可撤销，且需要该卷的管理员权限。")
        }
    }

    // MARK: - 头部
    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 13))
                .foregroundColor(Accent.tint)

            Text("系统底层存储深度洞察 (APFS 快照 & 休眠镜像)")
                .font(Typo.section)
                .foregroundColor(Ink.primary)

            Spacer()

            Button(action: { reload() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                    Text("刷新状态")
                        .font(Typo.micro)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Surface.sunken)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reloadDeepStorage")
        }
    }

    private func bannerView(message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(Accent.tint)
                .font(.system(size: 11))
            Text(message)
                .font(Typo.micro)
                .foregroundColor(Ink.primary)
            Spacer()
            Button(action: { bannerMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Ink.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Accent.soft)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .motionSafeTransition(.opacity)
    }

    // MARK: - APFS 快照卡片
    private var snapshotsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundColor(snapshots.isEmpty ? Signal.positive : Signal.caution)
                        .font(.system(size: 12))
                    Text("APFS 本地时间机器快照")
                        .font(Typo.body)
                        .foregroundColor(Ink.primary)
                    Text("(\(snapshots.count) 个)")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                }

                Spacer()

                // 只有用户**逐条勾选**过才允许触发删除；不再有"一键释放所有快照"
                Button(action: { showConfirmDeleteAllSnapshots = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                        Text(confirmedSnapshotNames.isEmpty
                             ? "先勾选要释放的快照"
                             : "释放已勾选 (\(confirmedSnapshotNames.count)) 个")
                            .font(Typo.micro)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(confirmedSnapshotNames.isEmpty
                                ? Surface.sunken
                                : Signal.caution.opacity(0.15))
                    .foregroundColor(confirmedSnapshotNames.isEmpty ? Ink.tertiary : Signal.caution)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(confirmedSnapshotNames.isEmpty)
                .accessibilityIdentifier("deleteAllSnapshotsButton")
            }

            // 取证失败提示：读不到快照清单时绝不显示"没有残留"
            if !snapshotIssues.isEmpty || !snapshotListRead {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshotIssues.isEmpty
                         ? "未能取得快照清单：以下结论不代表没有本地快照。"
                         : GovernanceEvidenceIssue.incompleteBanner(snapshotIssues))
                        .font(Typo.micro)
                        .foregroundColor(Ink.primary)
                    ForEach(snapshotIssues) { issue in
                        Text("· \(issue.message)")
                            .font(Typo.micro)
                            .foregroundColor(Ink.secondary)
                    }
                    Text("只读查询失败通常是权限不足，MacClean 不做提权；也可在终端自行执行 tmutil listlocalsnapshots / 复核。")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Signal.caution.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityIdentifier("snapshot-incomplete-notice")
            }

            if snapshots.isEmpty {
                HStack(spacing: 6) {
                    // 没读到清单就不给绿色对勾
                    Image(systemName: snapshotListRead ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundColor(snapshotListRead ? Signal.positive : Signal.caution)
                        .font(.system(size: 11))
                    Text(snapshotListRead
                         ? "当前卷没有本地 APFS 快照，没有被快照锁定的幽灵空间。"
                         : "未能确认是否存在本地快照（见上方提示）。")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                }
                .padding(.vertical, 2)
            } else {
                Text("本地快照会锁定已删除文件的数据块，导致即使删除了大文件也无法回收物理空间。")
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)

                VStack(spacing: 4) {
                    ForEach(snapshots.prefix(4)) { snapshot in
                        HStack {
                            // 逐条点名：勾了才可能删，不勾就一条命令都不执行
                            Button(action: {
                                if confirmedSnapshotNames.contains(snapshot.name) {
                                    confirmedSnapshotNames.remove(snapshot.name)
                                } else {
                                    confirmedSnapshotNames.insert(snapshot.name)
                                }
                            }) {
                                Image(systemName: confirmedSnapshotNames.contains(snapshot.name)
                                     ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 12))
                                    .foregroundColor(confirmedSnapshotNames.contains(snapshot.name)
                                                     ? Signal.caution : Ink.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("勾选后才会进入删除范围")

                            Image(systemName: "camera.fill")
                                .font(.system(size: 10))
                                .foregroundColor(Ink.tertiary)
                            Text(snapshot.dateString)
                                .font(.mcNumeric(11))
                                .foregroundColor(Ink.primary)
                            Text(snapshot.name)
                                .font(Typo.micro)
                                .foregroundColor(Ink.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(action: { deleteSingleSnapshot(snapshot) }) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundColor(Ink.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("单独释放这一条（需二次确认）")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if snapshots.count > 4 {
                        Text("及其余 \(snapshots.count - 4) 个较早快照...")
                            .font(Typo.micro)
                            .foregroundColor(Ink.tertiary)
                            .padding(.leading, 4)
                    }
                }
            }
        }
        .padding(10)
        .background(Surface.window)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 休眠镜像与虚拟内存卡片
    private var vmMemoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundColor(Accent.tint)
                        .font(.system(size: 12))
                    Text("休眠镜像与虚拟内存 (SleepImage & Swap)")
                        .font(Typo.body)
                        .foregroundColor(Ink.primary)
                }

                Spacer()

                Button(action: { copyOptimizationScript() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("拷贝优化命令")
                            .font(Typo.micro)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Surface.sunken)
                    .foregroundColor(Accent.tint)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("拷贝可直接在终端执行的休眠瘦身命令")
            }

            HStack(spacing: 16) {
                // 休眠镜像
                VStack(alignment: .leading, spacing: 2) {
                    Text("休眠镜像 (/var/vm/sleepimage)")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    HStack(spacing: 4) {
                        Text(vmInfo.vmDirectoryReadable
                             ? (vmInfo.sleepimageExists ? vmInfo.sleepimageSize.byteStringCN : "未生成 / 0 B")
                             : "读不到 (/var/vm 由 root 管理)")
                            .font(.mcNumeric(13, weight: .semibold))
                            .foregroundColor(vmInfo.vmDirectoryReadable
                                             && vmInfo.sleepimageSize > 8 * 1024 * 1024 * 1024
                                             ? Signal.caution : Ink.primary)
                        if vmInfo.sleepimageExists {
                            Text("(常驻 SSD 镜像)")
                                .font(Typo.micro)
                                .foregroundColor(Ink.tertiary)
                        }
                    }
                }

                Divider().frame(height: 24)

                // Swap 虚拟交换文件
                VStack(alignment: .leading, spacing: 2) {
                    Text(vmInfo.vmDirectoryReadable
                         ? "Swap 交换文件 (\(vmInfo.swapFilesCount) 个)"
                         : "Swap 交换文件（未知）")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Text(vmInfo.vmDirectoryReadable
                         ? (vmInfo.totalSwapSize > 0 ? vmInfo.totalSwapSize.byteStringCN : "0 B (无压力)")
                         : "无法判断")
                        .font(.mcNumeric(13, weight: .semibold))
                        .foregroundColor(vmInfo.vmDirectoryReadable ? Ink.primary : Signal.caution)
                }

                Divider().frame(height: 24)

                // 休眠模式
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前休眠模式")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Text(vmInfo.hibernateMode.map { "Mode \($0)" } ?? "未知")
                        .font(.mcNumeric(13, weight: .semibold))
                        .foregroundColor(vmInfo.hibernateMode == nil ? Signal.caution : Ink.primary)
                }
            }

            // 证据不足提示：读不到时不说"正常/最省空间"
            if !vmInfo.isResultComplete {
                VStack(alignment: .leading, spacing: 3) {
                    Text(vmInfo.incompletenessBanner
                         ?? "休眠设置未能读取：本轮不给任何优化建议。")
                        .font(Typo.micro)
                        .foregroundColor(Ink.primary)
                    ForEach(vmInfo.issues) { issue in
                        Text("· \(issue.message)")
                            .font(Typo.micro)
                            .foregroundColor(Ink.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Signal.caution.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityIdentifier("vm-incomplete-notice")
            }

            // 智能分析建议
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: vmInfo.isResultComplete ? "sparkles" : "exclamationmark.triangle")
                    .foregroundColor(vmInfo.isResultComplete ? Accent.tint : Signal.caution)
                    .font(.system(size: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(vmInfo.suggestionText)
                        .font(Typo.micro)
                        .foregroundColor(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(SystemDeepStorageInspector.hibernateRiskText)
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(Surface.window)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 数据操作

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let inventory = SystemDeepStorageInspector.snapshotInventory()
            let vm = SystemDeepStorageInspector.inspectVMMemory()
            DispatchQueue.main.async {
                self.snapshots = inventory.snapshots
                self.snapshotIssues = inventory.issues
                self.snapshotListRead = inventory.commandSucceeded
                // 已勾选项若已不在清单里就丢掉，避免把陈旧名字拼进命令
                let alive = Set(inventory.snapshots.map(\.name))
                self.confirmedSnapshotNames.formIntersection(alive)
                self.vmInfo = vm
                self.isLoading = false
            }
        }
    }

    private func deleteSingleSnapshot(_ snapshot: APFSSnapshot) {
        // 逐条确认：先弹说明，用户点"确认删除"才执行
        pendingDeleteName = snapshot.name
        showConfirmSingleDelete = true
    }

    private func performDeleteSingleSnapshot(name: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = SystemDeepStorageInspector.deleteLocalSnapshot(
                snapshotName: name, confirmed: true, knownSnapshots: self.snapshots)
            DispatchQueue.main.async {
                self.bannerMessage = res.message
                if res.success {
                    self.snapshots.removeAll { $0.name == name }
                    self.confirmedSnapshotNames.remove(name)
                }
                if res.success && self.snapshots.isEmpty {
                    // 删完必须重新取证，不能凭"列表空了"就下结论
                    self.reload()
                }
            }
        }
    }

    private func deleteConfirmedSnapshots() {
        let names = confirmedSnapshotNames.sorted()
        guard !names.isEmpty else {
            bannerMessage = "没有勾选任何快照，未执行 tmutil。"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = SystemDeepStorageInspector.deleteLocalSnapshots(
                names, confirmed: true, knownSnapshots: self.snapshots)
            DispatchQueue.main.async {
                // 逐项如实：成功数 / 失败数 / 未执行数，绝不说"已全部清理"
                self.bannerMessage = outcome.summary
                for entry in outcome.failed where self.bannerMessage?.contains(entry.message) != true {
                    self.bannerMessage = (self.bannerMessage ?? "") + "｜" + entry.message
                }
                for skipped in outcome.skipped where self.bannerMessage?.contains(skipped.reason) != true {
                    self.bannerMessage = (self.bannerMessage ?? "") + "｜" + skipped.reason
                }
                self.reload()
            }
        }
    }

    private func copyOptimizationScript() {
        let script = SystemDeepStorageInspector.generateHibernateOptimizationScript(targetMode: 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        bannerMessage = "已拷贝休眠瘦身命令（需 sudo，请在终端自行执行）。"
            + SystemDeepStorageInspector.hibernateRiskText
    }
}
