import SwiftUI

/// 全局检索页：跨全部分类文件项 + 清理历史，内存过滤，即时结果
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
            Divider().overlay(Theme.hairline)
            content
        }
        .background(Theme.parchment)
        .onAppear { isFocused = true }
    }

    // MARK: - Header（搜索输入）

    private var header: some View {
        HStack(spacing: Theme.spaceMd) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.actionBlue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text("全局检索")
                    .font(Theme.displayFont(28, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("跨 \(CleanCategory.allCases.count) 个分类与清理历史 · 已扫 \(searchedCount) 个分类")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()

            // 搜索输入框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.inkMuted48)
                TextField("搜索文件名、路径、历史…", text: $app.searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.bodyFont(15))
                    .focused($isFocused)
                    .accessibilityIdentifier("globalSearchField")
                if !app.searchQuery.isEmpty {
                    Button {
                        app.searchQuery = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.inkMuted48)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.spaceSm)
            .padding(.vertical, 7)
            .frame(width: 320)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(Theme.pearl)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .stroke(isFocused ? Theme.actionBlue.opacity(0.6) : Theme.hairline, lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .background(Theme.canvas)
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
        VStack(spacing: Theme.spaceMd) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(Theme.inkMuted48.opacity(0.6))
            Text("输入关键词开始检索")
                .font(Theme.displayFont(24, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("支持文件名、路径片段、清理历史分类名；仅检索已扫描分类")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
            if searchedCount < CleanCategory.allCases.count {
                Button {
                    app.scanAll()
                } label: {
                    Label("扫描全部 \(CleanCategory.allCases.count - searchedCount) 个未扫描分类", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Theme.actionBlue)
                .padding(.top, Theme.spaceXs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResultView: some View {
        VStack(spacing: Theme.spaceSm) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Theme.inkMuted48.opacity(0.6))
            Text("没有找到匹配项")
                .font(Theme.displayFont(22, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("换个关键词试试，或先扫描未扫描的分类")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(results) { result in
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
            .padding(Theme.spaceLg)
        }
    }
}

/// 单条搜索结果行
struct SearchResultRow: View {
    let result: SearchResult
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.spaceSm) {
                // 类型图标
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.actionBlue)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.actionBlue.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(result.name)
                            .font(Theme.bodyFont(15, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                        if let risk = result.risk {
                            RiskBadge(risk: risk)
                        }
                        if case .item(let cat) = result.kind {
                            Text(cat.title)
                                .font(Theme.bodyFont(11, weight: .medium))
                                .foregroundColor(Theme.inkMuted48)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.parchment))
                        }
                    }
                    Text(result.subtitle)
                        .font(Theme.monoFont(11))
                        .foregroundColor(Theme.inkMuted48)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if result.size > 0 {
                    Text(result.size.byteStringCN)
                        .font(Theme.monoFont(13, weight: .semibold))
                        .foregroundColor(Theme.ink)
                }
            }
            .padding(.horizontal, Theme.spaceMd)
            .padding(.vertical, Theme.spaceXs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(Theme.pearl)
            )
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
}
