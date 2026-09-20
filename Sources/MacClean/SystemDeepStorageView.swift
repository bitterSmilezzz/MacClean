import SwiftUI

// MARK: - 系统底层存储深度治理卡片（休眠镜像与 APFS 本地快照）

public struct SystemDeepStorageView: View {
    @State private var snapshots: [APFSSnapshot] = []
    @State private var vmInfo: VMMemoryInfo = VMMemoryInfo()
    @State private var isLoading: Bool = false
    @State private var bannerMessage: String? = nil
    @State private var showConfirmDeleteAllSnapshots: Bool = false
    @State private var showScriptSheet: Bool = false

    public init() {}

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
        .alert("释放所有 APFS 本地快照", isPresented: $showConfirmDeleteAllSnapshots) {
            Button("立即释放", role: .destructive) {
                deleteAllSnapshots()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除当前卷上的 \(snapshots.count) 个本地时间机器快照。已删除文件被快照锁定的底层数据块将被立即释放为可用 SSD 空间。")
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

                if !snapshots.isEmpty {
                    Button(action: { showConfirmDeleteAllSnapshots = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 9))
                            Text("一键释放所有快照")
                                .font(Typo.micro)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Signal.caution.opacity(0.15))
                        .foregroundColor(Signal.caution)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("deleteAllSnapshotsButton")
                }
            }

            if snapshots.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Signal.positive)
                        .font(.system(size: 11))
                    Text("当前没有残留的本地 APFS 快照，没有被快照锁定的幽灵空间。")
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
                            .help("删除此本地快照")
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
                        Text(vmInfo.sleepimageExists ? vmInfo.sleepimageSize.byteStringCN : "未生成 / 0 B")
                            .font(.mcNumeric(13, weight: .semibold))
                            .foregroundColor(vmInfo.sleepimageSize > 8 * 1024 * 1024 * 1024 ? Signal.caution : Ink.primary)
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
                    Text("Swap 交换文件 (\(vmInfo.swapFilesCount) 个)")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Text(vmInfo.totalSwapSize > 0 ? vmInfo.totalSwapSize.byteStringCN : "0 B (无压力)")
                        .font(.mcNumeric(13, weight: .semibold))
                        .foregroundColor(Ink.primary)
                }

                Divider().frame(height: 24)

                // 休眠模式
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前休眠模式")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Text("Mode \(vmInfo.hibernateMode ?? 3)")
                        .font(.mcNumeric(13, weight: .semibold))
                        .foregroundColor(Ink.primary)
                }
            }

            // 智能分析建议
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(Accent.tint)
                    .font(.system(size: 10))
                Text(vmInfo.suggestionText)
                    .font(Typo.micro)
                    .foregroundColor(Ink.secondary)
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
            let snaps = SystemDeepStorageInspector.listLocalSnapshots()
            let vm = SystemDeepStorageInspector.inspectVMMemory()
            DispatchQueue.main.async {
                self.snapshots = snaps
                self.vmInfo = vm
                self.isLoading = false
            }
        }
    }

    private func deleteSingleSnapshot(_ snapshot: APFSSnapshot) {
        DispatchQueue.global(qos: .userInitiated).async {
            let res = SystemDeepStorageInspector.deleteLocalSnapshot(snapshotName: snapshot.name)
            DispatchQueue.main.async {
                if res.success {
                    self.snapshots.removeAll { $0.id == snapshot.id }
                    self.bannerMessage = res.message
                } else {
                    self.bannerMessage = res.message
                }
            }
        }
    }

    private func deleteAllSnapshots() {
        DispatchQueue.global(qos: .userInitiated).async {
            let (succeeded, failed) = SystemDeepStorageInspector.deleteAllLocalSnapshots(snapshots: self.snapshots)
            let updated = SystemDeepStorageInspector.listLocalSnapshots()
            DispatchQueue.main.async {
                self.snapshots = updated
                self.bannerMessage = "已清理 \(succeeded) 个 APFS 快照\(failed > 0 ? "，\(failed) 个需管理员权限" : "")"
            }
        }
    }

    private func copyOptimizationScript() {
        let script = SystemDeepStorageInspector.generateHibernateOptimizationScript(targetMode: 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        bannerMessage = "已拷贝休眠瘦身优化 Shell 命令至剪贴板，可粘贴至终端执行"
    }
}
