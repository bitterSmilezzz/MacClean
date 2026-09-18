import SwiftUI

/// 全局检索页：跨全部分类文件项 + 清理历史，内存过滤，即时结果
///
/// 重写要点：
///  - 表头去掉「图标彩色底板 + 26pt 大标题 + 装饰性副标题」。标题固定为 `Typo.title`，
///    唯一保留的副信息是真实数据（已扫描分类数），右侧留给 320pt 的搜索框。
///  - 检索框外观对齐 `SearchField` 原语（`Surface.sunken` 底 + 发丝描边 + 聚焦时强调色描边）。
///    这里没有再直接套 `SearchField`，是因为 `globalSearchField` 标识符与 `@FocusState`
///    自动聚焦都必须挂在 `TextField` 本身。
///  - 空状态全部换成 `EmptyState`；结果列表从"一张描边卡片 + 手写 Divider"改成
///    `GroupBox` + `GroupedRow`，结果条数放进分组 footer。
///  - `SearchResultRow` 去掉图标底板与分类胶囊：图标进 `IconSlot`，分类降级为说明文字，
///    体积列右对齐等宽显示。
struct SearchView: View {
    @EnvironmentObject private var app: AppState
    @FocusState private var isFocused: Bool

    private var results: [SearchResult] {
        GlobalSearch.search(query: app.searchQuery, items: app.searchableItems, history: app.history)
    }

    private var searchedCount: Int {
        app.scannedCount
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            content
        }
        .background(Surface.window)
        .onAppear { isFocused = true }
    }

    // MARK: - Header（搜索输入）

    private var header: some View {
        HStack(spacing: Space.sm) {
            Text("全局检索")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            HStack(spacing: 3) {
                Text("已扫描")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                Text("\(searchedCount)/\(CleanCategory.allCases.count)")
                    .font(.mcNumeric(11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .motionSafeNumericTransition()
            }

            Spacer(minLength: Space.md)

            searchField
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
    }

    /// 与 `SearchField` 原语同一套外观，区别只在于需要自持 `TextField` 的标识符与焦点。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Typo.micro)
                .foregroundStyle(Ink.tertiary)
            TextField("搜索文件名、路径、历史…", text: $app.searchQuery)
                .textFieldStyle(.plain)
                .font(Typo.row)
                .focused($isFocused)
                .accessibilityIdentifier("globalSearchField")
            if !app.searchQuery.isEmpty {
                Button {
                    app.searchQuery = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .contentShape(Rectangle())
                        .accessibilityLabel("清空搜索")
                }
                .pressable()
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 6)
        .frame(width: 320)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Surface.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(
                    isFocused ? Accent.tint.opacity(0.7) : Surface.hairline.opacity(0.6),
                    lineWidth: isFocused ? 1 : 0.5
                )
        )
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        let q = app.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            promptView
        } else if results.isEmpty {
            emptyResultView
        } else {
            resultList
        }
    }

    private var promptView: some View {
        EmptyState(
            icon: "magnifyingglass",
            title: "输入关键词开始检索",
            message: "支持文件名、路径片段、清理历史分类名；仅检索已扫描分类",
            actionTitle: searchedCount < CleanCategory.allCases.count
                ? "扫描全部 \(CleanCategory.allCases.count - searchedCount) 个未扫描分类"
                : nil
        ) {
            app.scanAll()
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyResultView: some View {
        EmptyState(
            icon: "questionmark.circle",
            title: "没有找到匹配项",
            message: "换个关键词试试，或先扫描未扫描的分类"
        )
        .frame(maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollView {
            GroupBox(footer: "\(results.count) 条结果") {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    GroupedRow(isLast: index == results.count - 1) {
                        SearchResultRow(result: result) {
                            switch result.kind {
                            case .item(let cat):
                                app.destination = .category(cat)
                            case .history:
                                app.destination = .history
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
    }
}

/// 单条搜索结果行
struct SearchResultRow: View {
    let result: SearchResult
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Space.sm) {
                // 类型图标
                IconSlot(systemName: iconName, size: 13, color: Ink.secondary, width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Space.xs) {
                        Text(result.name)
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        if let verdict = result.recommendation {
                            VerdictBadge(recommendation: verdict)
                        }
                        if case .item(let cat) = result.kind {
                            Text(cat.title)
                                .font(Typo.caption)
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                    Text(result.subtitle)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Space.sm)
                if result.size > 0 {
                    Text(result.size.byteStringCN)
                        .font(.mcNumeric(12, weight: .medium))
                        .foregroundStyle(Ink.primary)
                        .frame(width: 84, alignment: .trailing)
                }
            }
            .padding(.horizontal, Space.xxs)
            .contentShape(Rectangle())
            .rowHover()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("searchResultRow")
    }

    private var iconName: String {
        switch result.kind {
        case .item: return "doc"
        case .history: return "clock.arrow.circlepath"
        }
    }

    /// 处置结论徽标。
    ///
    /// 结论与颜色都来自新模型：文本用 `Recommendation.label`，颜色统一走 `Signal.tint(for: _:)`，
    /// 悬停给出 `reason`（为什么是这个结论）。这里刻意不再复用 `RiskBadge`（定义在
    /// `CategoryDetailView`，属旧风险轴视图、正在随模型迁移重写），检索页只依赖新模型本身；
    /// 嵌套定义也避免与别处新增的同类徽标重名。
    private struct VerdictBadge: View {
        let recommendation: Recommendation

        var body: some View {
            let color = Signal.tint(for: recommendation.kind)
            return Text(recommendation.label)
                .font(Typo.micro)
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .fill(color.opacity(0.13))
                )
                .help(recommendation.reason)
        }
    }
}
