import Foundation

// MARK: - 浏览器隐私痕迹扫描与清理（v1.73.15，工具页矩阵）
//
// 职责边界：
// · `scan()` 本地**只读**：族探测以 `AppInventory.current()` 为唯一清单源（G16，
//   `isComplete == false` 时摘要降级明示）；路径一律来自 `BrowserFamily` 的固定路径表
//   （`~` 前缀常量 + `CleanPaths.expand`），**没有** hasPrefix("/System") 式字符串护栏
//   （G18）；G6/G8 注记读 `FileSystem` 的同一份共享判据（G19）。
// · 每格体积走 `FileSystem.directoryStats`（全仓唯一模块级 walker，v1.73.13 收口），
//   本文件不写第二份递归遍历；读不到的格子按三态呈现（G9）。
// · `clean()` 只接受用户点选的格子；每条路径作为 `ResidueDeletionGate.Candidate`
//   （domain nil = 主目录内常规护栏）；danger 格必须带 `confirmedDanger` 否则整格拒绝
//   并逐条带原因；结果 Outcome（成功/拒绝/失败逐条 + 历史记账，默认移废纸篓可撤销）。
//   删除**前**的真实体积与记账号网关全权负责，本模块不自计。

enum BrowserPrivacyScanner {

    /// 历史记账的分类名（与 B 系列分类清理、其他治理模块区分开）
    static let categoryName = "浏览器隐私"

    // MARK: 自检注入缝
    //
    // profile 根可注入：夹具在临时目录造假浏览器 profile，**自检永不碰真实浏览器 profile**。
    // 传入时：扫描的族集合 = 注入表的键（隔离语义：只扫注入的族），dataRoot/cacheRoot
    // 全部指向夹具；生产路径永远是 nil。Safari 不支持注入（它的路径是主目录固定位置，
    // 注入会碰到真实数据——自检里禁止把 Safari 放进 fixtureRoots）。
    struct FamilyFixture: Equatable {
        /// 族用户数据根（Chrome 布局：其下直接是 `Default` / `Profile N`；
        /// Firefox 布局：其下还有一层 `Profiles/`）
        let dataRoot: String
        /// 独立缓存根（Firefox 的 cache2 所在；nil = 该族没有独立缓存根）
        let cacheRoot: String?
    }
    static var fixtureRoots: [BrowserFamily: FamilyFixture]? = nil

    // MARK: - 根解析（fixture 注入优先）

    /// 族用户数据根（展开 + 归一化）。
    static func dataRoot(for family: BrowserFamily) -> String? {
        if let fixture = fixtureRoots?[family] { return FileSystem.normalizePath(fixture.dataRoot) }
        guard let raw = family.userDataRootRaw else { return nil }
        return FileSystem.normalizePath(CleanPaths.expand(raw))
    }

    /// 族 profile 枚举根（Firefox 数据根下还要进一层 `Profiles`；Chromium 就在数据根下）。
    static func profilesRoot(for family: BrowserFamily) -> String? {
        guard family.profilesSubdirRaw != nil else { return nil }
        if let fixture = fixtureRoots?[family] {
            return FileSystem.normalizePath((fixture.dataRoot as NSString).appendingPathComponent("Profiles"))
        }
        return FileSystem.normalizePath(CleanPaths.expand(family.profilesSubdirRaw!))
    }

    /// 族独立缓存根（Firefox）。
    static func cacheRoot(for family: BrowserFamily) -> String? {
        if let fixture = fixtureRoots?[family] { return fixture.cacheRoot.map(FileSystem.normalizePath) }
        guard let raw = family.cacheRootRaw else { return nil }
        return FileSystem.normalizePath(CleanPaths.expand(raw))
    }

    /// 族是否在列。Safari 是 macOS 自带组件，始终在列；其余按 AppInventory 探测（G16）。
    /// 数据存在但应用已卸载的残留不归本模块（那是孤儿残留排查的领域）。
    static func isPresent(_ family: BrowserFamily, inventory: AppInventory.Snapshot) -> Bool {
        if family == .safari { return true }
        return family.bundleIDs.contains { inventory.contains(bundleID: $0) }
    }

    // MARK: - 扫描（本地只读）

    static func scan(inventory: AppInventory.Snapshot? = nil) -> BrowserPrivacySummary {
        var summary = BrowserPrivacySummary()
        let inv = inventory ?? AppInventory.current()

        // G16：清单不可信时明示降级——「已安装」判定可能漏报，结论不许装作完整。
        if !inv.isComplete {
            let roots = inv.unreadableRoots.isEmpty ? "" : "（读取失败：\(inv.unreadableRoots.joined(separator: "、"))）"
            summary.issues.append("已安装应用清单不完整\(roots)：浏览器「已安装」判定可能漏报，"
                + "本页结论降级为需人工确认")
        }

        // 族集合：fixture 注入时只扫注入的族（自检隔离）；生产按 AppInventory 探测。
        let families: [BrowserFamily]
        if let fixtures = fixtureRoots {
            families = BrowserFamily.allCases.filter { $0 != .safari && fixtures[$0] != nil }
        } else {
            families = BrowserFamily.allCases.filter { isPresent($0, inventory: inv) }
        }

        for family in families {
            guard let root = dataRoot(for: family) else {
                // Safari：没有用户数据根，按固定位置建格（永远在列，缺席的格子如实标"无数据"）
                summary.blocks.append(.init(family: family, profiles: [],
                                            cells: fixedLocationCells(family)))
                continue
            }

            guard FileSystem.exists(root) else {
                // 数据根不存在：生产里若族已安装 → "已装但还没有数据"（不渲染成 0 体积）；
                // fixture 注入的族数据根必须存在，不存在即整族缺席。
                if fixtureRoots?[family] == nil && isPresent(family, inventory: inv) {
                    summary.installedWithoutData.append(family)
                }
                continue
            }

            // 先探根：读不到 ≠ 空（G9）。deferred 与 unreadable 分开说。
            switch FileSystem.probeDirectory(root) {
            case .unreadable:
                summary.blocks.append(blockedByProbe(family: family, root: root, state: .unreadable))
            case .deferred:
                summary.blocks.append(blockedByProbe(family: family, root: root, state: .deferred))
            case .readable:
                summary.blocks.append(enumeratedBlock(family: family, dataRoot: root))
            }
        }
        return summary
    }

    // MARK: 格子构建

    /// 枚举 profile 并逐 (kind) 建格。
    private static func enumeratedBlock(family: BrowserFamily,
                                        dataRoot: String) -> BrowserPrivacySummary.FamilyBlock {
        let profiles: [String]
        if let profilesDir = profilesRoot(for: family) {
            if FileSystem.probeDirectory(profilesDir) == .readable {
                profiles = FileSystem.children(of: profilesDir)
                    .filter { FileSystem.isRealDir($0) && family.isProfileDirName(($0 as NSString).lastPathComponent) }
                    .sorted()
            } else {
                // Profiles 层读不到：profile 级格子会落到"读不到"，这里先如实记录
                profiles = []
            }
        } else {
            // Chromium 布局：profile 直接是数据根的第一层子目录（按名字过滤）
            profiles = FileSystem.children(of: dataRoot)
                .filter { FileSystem.isRealDir($0) && family.isProfileDirName(($0 as NSString).lastPathComponent) }
                .sorted()
        }
        var cells: [BrowserPrivacyCell] = []
        for kind in family.supportedKinds {
            let paths = candidatePaths(family: family, kind: kind,
                                       profiles: profiles, dataRoot: dataRoot)
            cells.append(makeCell(family: family, kind: kind, paths: paths))
        }
        return .init(family: family, profiles: profiles, cells: cells)
    }

    /// 根存在但读不到 / 本轮没试：整族每格都以根为证据按三态呈现，不渲染成 0 体积。
    private static func blockedByProbe(family: BrowserFamily, root: String,
                                       state: BrowserCellPath.PathState) -> BrowserPrivacySummary.FamilyBlock {
        let cells = family.supportedKinds.map { kind in
            BrowserPrivacyCell(
                family: family, kind: kind,
                paths: [BrowserCellPath(path: root, ownerRoot: root, relative: "",
                                        state: state, stats: nil, protection: nil)],
                status: state == .deferred ? .deferred : .unreadable,
                size: 0, newestModification: nil)
        }
        return .init(family: family, profiles: [], cells: cells)
    }

    /// Safari：主目录固定位置建格（homeFixed 锚点）。
    private static func fixedLocationCells(_ family: BrowserFamily) -> [BrowserPrivacyCell] {
        family.supportedKinds.map { kind in
            makeCell(family: family, kind: kind,
                     paths: candidatePaths(family: family, kind: kind, profiles: [], dataRoot: NSHomeDirectory()))
        }
    }

    /// 一个 (族, 数据类) 格子的全部候选路径，逐条落地存在性与可读性。
    /// 体积只走 `FileSystem.directoryStats`（全仓唯一模块级 walker），不写第二份递归。
    static func candidatePaths(family: BrowserFamily, kind: BrowserDataKind,
                               profiles: [String], dataRoot: String) -> [BrowserCellPath] {
        var out: [BrowserCellPath] = []
        for entry in family.kindPaths(for: kind) {
            switch entry.anchor {
            case .profile:
                for profile in profiles {
                    out.append(measure(ownerRoot: profile, relative: entry.relative))
                }
            case .profileCache:
                guard let cache = cacheRoot(for: family) else { continue }
                for profile in profiles {
                    let name = (profile as NSString).lastPathComponent
                    let base = (cache as NSString).appendingPathComponent("Profiles")
                    let root = (base as NSString).appendingPathComponent(name)
                    out.append(measure(ownerRoot: root, relative: entry.relative))
                }
            case .familyDataRoot:
                out.append(measure(ownerRoot: dataRoot, relative: entry.relative))
            case .familyCacheRoot:
                guard let cache = cacheRoot(for: family) else { continue }
                out.append(measure(ownerRoot: cache, relative: entry.relative))
            case .homeFixed:
                let expanded = FileSystem.normalizePath(CleanPaths.expand(entry.relative))
                out.append(measure(ownerRoot: (expanded as NSString).deletingLastPathComponent,
                                   relative: (expanded as NSString).lastPathComponent,
                                   absoluteOverride: expanded))
            }
        }
        return out
    }

    /// 单条路径的探测：存在性（lstat）→ 三态探测（`probeDirectory`，读不到记盲区）→
    /// 体积/最新 mtime（`directoryStats`，判龄只用 mtime）→ G6/G8 注记（共享判据）。
    private static func measure(ownerRoot: String, relative: String,
                                absoluteOverride: String? = nil) -> BrowserCellPath {
        let path = absoluteOverride
            ?? FileSystem.normalizePath((ownerRoot as NSString).appendingPathComponent(relative))
        let normalized = FileSystem.normalizePath(path)
        guard FileSystem.exists(normalized) else {
            return BrowserCellPath(path: normalized, ownerRoot: ownerRoot, relative: relative,
                                   state: .absent, stats: nil, protection: nil)
        }

        var state = BrowserCellPath.PathState.measured
        var stats: FileSystem.DirectoryStats?
        switch FileSystem.probeDirectory(normalized) {
        case .readable:
            let s = FileSystem.directoryStats(at: normalized)
            stats = s
            // 遍历被权限掐断过 → 体积是下限，整条按"读不到"呈现（G9）
            if !s.readable { state = .unreadable }
        case .unreadable:
            state = .unreadable   // 真去开了、被拒：盲区（probeDirectory 内已记账）
        case .deferred:
            state = .deferred     // 在途额度满等：根本没去 open，不冒充"读不到"
        }

        // G6/G8 注记：读**同一份**共享判据（isSystemProtected / isHardExcluded），
        // 不复制清单——扫描侧与删除侧必须是一个判据（G19）。
        var protection: String? = nil
        if FileSystem.isSystemProtectedNormalized(normalized) {
            protection = "系统硬保护（G8）"
        } else if FileSystem.isHardExcludedNormalized(normalized) {
            protection = "用户数据保护（G6）"
        }

        return BrowserCellPath(path: normalized, ownerRoot: ownerRoot, relative: relative,
                               state: state, stats: stats, protection: protection)
    }

    /// 聚合一格：体积 = 可读路径之和；状态按"任一读不到 > 任一没试 > 全部读通 > 全缺席"。
    static func makeCell(family: BrowserFamily, kind: BrowserDataKind,
                         paths: [BrowserCellPath]) -> BrowserPrivacyCell {
        var size: Int64 = 0
        var newest: Date?
        var anyExists = false
        var anyUnreadable = false
        var anyDeferred = false
        for p in paths {
            switch p.state {
            case .absent:
                continue
            case .deferred:
                anyExists = true
                anyDeferred = true
            case .unreadable:
                anyExists = true
                anyUnreadable = true
            case .measured:
                anyExists = true
                if let s = p.stats {
                    size += s.size
                    if let m = s.newestModification, newest == nil || m > newest! { newest = m }
                    if !s.readable { anyUnreadable = true }   // 半途被掐：体积是下限
                }
            }
        }
        let status: BrowserCellStatus = !anyExists ? .absent
            : anyUnreadable ? .unreadable
            : anyDeferred ? .deferred
            : .readable
        return BrowserPrivacyCell(family: family, kind: kind, paths: paths,
                                  status: status, size: size, newestModification: newest)
    }

    // MARK: - 清理（用户点选；默认移废纸篓可撤销；统一网关）

    /// clean 时刻**重新推导**的合法路径集：与 `candidatePaths` 同一套构造（同一注入缝、
    /// 同一 profile 判别），只拼路径、不做测量。
    ///
    /// 为什么不能信格子里带来的路径：`clean(cells:)` 的实参在编译期可以是任何人拼装的
    /// 结构体，而网关的主目录放行挡不住"夹带一个家目录路径"——模块侧必须自己把
    /// "什么样的路径属于本模块"钉在固定路径表上。每条候选都必须能落进这个集合，
    /// 否则按 `outsideDomain` 拒绝（profile 在扫描与清理之间被删掉的路径同样会
    /// 落不进集合，按拒绝处理是诚实的：那次扫描的事实已经过期）。
    private static func legitimatePaths(family: BrowserFamily,
                                        kind: BrowserDataKind) -> Set<String> {
        var set = Set<String>()
        let root = dataRoot(for: family)

        // 与 scan 相同的 profile 枚举（fixture 注入同样生效）
        func profileChildren(of dir: String) -> [String] {
            FileSystem.children(of: dir)
                .filter { FileSystem.isRealDir($0) && family.isProfileDirName(($0 as NSString).lastPathComponent) }
        }
        var profiles: [String] = []
        if let profilesDir = profilesRoot(for: family),
           FileSystem.probeDirectory(profilesDir) == .readable {
            profiles = profileChildren(of: profilesDir)
        } else if let root, FileSystem.probeDirectory(root) == .readable {
            profiles = profileChildren(of: root)
        }

        for entry in family.kindPaths(for: kind) {
            switch entry.anchor {
            case .profile:
                for profile in profiles {
                    set.insert(FileSystem.normalizePath(
                        (profile as NSString).appendingPathComponent(entry.relative)))
                }
            case .profileCache:
                if let cache = cacheRoot(for: family) {
                    for profile in profiles {
                        let base = ((cache as NSString).appendingPathComponent("Profiles")
                            as NSString).appendingPathComponent((profile as NSString).lastPathComponent)
                        set.insert(FileSystem.normalizePath(
                            (base as NSString).appendingPathComponent(entry.relative)))
                    }
                }
            case .familyDataRoot:
                if let root {
                    set.insert(FileSystem.normalizePath(
                        (root as NSString).appendingPathComponent(entry.relative)))
                }
            case .familyCacheRoot:
                if let cache = cacheRoot(for: family) {
                    set.insert(FileSystem.normalizePath(
                        (cache as NSString).appendingPathComponent(entry.relative)))
                }
            case .homeFixed:
                set.insert(FileSystem.normalizePath(CleanPaths.expand(entry.relative)))
            }
        }
        return set
    }

    /// 清理选中的格子。
    /// - Parameters:
    ///   - cells: 调用方传入的格子。**只接受 `isSelected == true` 的格子**（用户点选），
    ///     且只接受 `isCleanable` 的格子（读不到/没试/缺席的不进删除管道，G9）。
    ///   - confirmedDanger: danger 格（savedLogins / sessionRestore）的独立确认。
    ///     未带此确认时 danger 格**整格拒绝**并逐条带原因。
    @discardableResult
    static func clean(cells: [BrowserPrivacyCell], toTrash: Bool = true,
                      confirmedDanger: Bool = false) -> ResidueDeletionGate.Outcome {
        var blocked: [ResidueDeletionGate.Rejection] = []
        var candidates: [ResidueDeletionGate.Candidate] = []

        for cell in cells {
            let title = "\(cell.family.displayName) · \(cell.kind.displayName)"

            // ① 只接受用户点选的格子
            guard cell.isSelected else {
                blocked.append(.make(name: title, path: cell.paths.first?.path ?? "",
                                     reason: .notDeletable,
                                     message: "该格子未被勾选，本次忽略"))
                continue
            }
            // ② 读不到 / 没试 / 缺席的格子不进删除管道：不能凭残缺事实删除（G9）
            guard cell.isCleanable else {
                for p in cell.paths where p.state != .absent {
                    blocked.append(.make(name: title, path: p.path, reason: .notDeletable,
                                         message: "格子\(cell.status.label)，不能凭残缺事实删除"))
                }
                continue
            }
            // ③ danger 格必须经独立确认，否则整格拒绝、逐条带原因
            if cell.kind.danger && !confirmedDanger {
                for p in cell.paths where p.state != .absent {
                    blocked.append(.make(name: title, path: p.path, reason: .notDeletable,
                                         message: "危险项未确认：\(cell.kind.warning ?? "该数据类为危险项")（整格拒绝）"))
                }
                continue
            }
            // ④ 模块判据：只删固定路径表登记过的位置（防拼装格子夹带任意主目录路径——
            //    网关的主目录放行挡不住这种夹带）
            let legit = legitimatePaths(family: cell.family, kind: cell.kind)
            for p in cell.paths where p.state != .absent {
                let norm = FileSystem.normalizePath(p.path)
                guard legit.contains(norm) else {
                    blocked.append(.make(name: title, path: norm, reason: .outsideDomain,
                                         message: "路径不是本模块登记的浏览器数据位置，拒绝删除"))
                    continue
                }
                candidates.append(.init(title, path: norm, domain: nil))
            }
        }

        // 模块侧先拦的在前，网关结果随后并入（RELEASE-CHECKLIST 的 Outcome 形状）。
        // journal 在模块内钉死为 .module(categoryName:)——自检不喂实参，
        // 默认值被改坏时历史断言必须红（RELEASE-CHECKLIST 变异验证条）。
        let gate = ResidueDeletionGate.execute(candidates, toTrash: toTrash,
                                               journal: .module(categoryName: Self.categoryName))
        return ResidueDeletionGate.Outcome(rejected: blocked).merging(gate)
    }
}
