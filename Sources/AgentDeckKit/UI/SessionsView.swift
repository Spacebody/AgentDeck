// AgentDeck v2 — 会话页。复刻 index.html renderSessions/togglePreview/loadSessions 及交互：
// 搜索 + 筛选 chips(all/claude/codex) + 行(徽章/标题+livedot/元信息) + 悬浮操作(置顶/恢复/复制) + 点开预览。
import SwiftUI

struct SessionsView: View {
    let sessions: [SessionItem]
    var scrollable: Bool = true
    var query: String = ""
    var filter: String = "all"
    var total: Int = 0
    var hasMore: Bool = false
    var loading: Bool = false
    var indexing: Bool = false
    var loadFailed: Bool = false
    var onResume: (SessionItem) -> Void = { _ in }
    var onCopy: (SessionItem) -> Void = { _ in }
    var onPin: (SessionItem) -> Void = { _ in }
    /// 加载某会话预览（接 store.preview，异步）。
    var loadPreview: (SessionItem) async -> [PreviewMsg] = { _ in [] }
    /// 搜索词/工具筛选由 AppStore 持有，切换 Tab 后仍保持一致。
    var onSearch: (String) -> Void = { _ in }
    var onFilter: (String) -> Void = { _ in }
    var onLoadMore: () -> Void = {}
    /// 预览期可注入：默认展开某行 + 预置预览内容（静态渲染验证用）。
    var initialExpanded: String? = nil
    var seededPreviews: [String: [PreviewMsg]] = [:]

    @State private var expandedKey: String?
    @State private var previews: [String: [PreviewMsg]] = [:]
    @State private var previewOrder: [String] = []
    @State private var previewMtimes: [String: Double] = [:]
    @State private var latestMtimes: [String: Double] = [:]

    init(sessions: [SessionItem], scrollable: Bool = true,
         query: String = "", filter: String = "all", total: Int = 0,
         hasMore: Bool = false, loading: Bool = false,
         indexing: Bool = false, loadFailed: Bool = false,
         onResume: @escaping (SessionItem) -> Void = { _ in },
         onCopy: @escaping (SessionItem) -> Void = { _ in },
         onPin: @escaping (SessionItem) -> Void = { _ in },
         loadPreview: @escaping (SessionItem) async -> [PreviewMsg] = { _ in [] },
         onSearch: @escaping (String) -> Void = { _ in },
         onFilter: @escaping (String) -> Void = { _ in },
         onLoadMore: @escaping () -> Void = {},
         initialExpanded: String? = nil, seededPreviews: [String: [PreviewMsg]] = [:]) {
        self.sessions = sessions; self.scrollable = scrollable
        self.query = query; self.filter = filter; self.total = total
        self.hasMore = hasMore; self.loading = loading
        self.indexing = indexing; self.loadFailed = loadFailed
        self.onResume = onResume; self.onCopy = onCopy; self.onPin = onPin; self.loadPreview = loadPreview
        self.onSearch = onSearch; self.onFilter = onFilter; self.onLoadMore = onLoadMore
        self.initialExpanded = initialExpanded; self.seededPreviews = seededPreviews
        _expandedKey = State(initialValue: initialExpanded)
        _previews = State(initialValue: seededPreviews)
        _previewOrder = State(initialValue: Array(seededPreviews.keys))
        let mtimes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.rowKey, $0.mtime) })
        _previewMtimes = State(initialValue: mtimes.filter { seededPreviews[$0.key] != nil })
        _latestMtimes = State(initialValue: mtimes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if sessions.isEmpty {
                emptyState
            } else {
                if scrollable { ScrollView { rows }.scrollIndicators(.hidden) } else { rows }
            }
        }
        .onChange(of: sessions.map { "\($0.rowKey)|\($0.mtime)" }) { _ in
            let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.rowKey, $0.mtime) })
            latestMtimes = current
            previews = previews.filter { previewMtimes[$0.key] == current[$0.key] }
            previewMtimes = previewMtimes.filter { current[$0.key] == $0.value }
            previewOrder.removeAll { previews[$0] == nil }
            if let expandedKey, current[expandedKey] == nil { self.expandedKey = nil }
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 2) {
            ForEach(sessions, id: \.rowKey) { s in
                SessionRow(
                    session: s,
                    expanded: expandedKey == s.rowKey,
                    preview: previews[s.rowKey],
                    onToggle: { toggle(s) },
                    onResume: { onResume(s) }, onCopy: { onCopy(s) }, onPin: { onPin(s) })
            }
            if indexing { statusRow("session.indexing", spinning: true) }
            if loadFailed { statusRow("session.loadFailed", spinning: false) }
            if hasMore { loadMoreButton }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if indexing || loading {
            statusRow(indexing ? "session.indexing" : "session.loading", spinning: true)
                .padding(.top, 22)
        } else {
            Text(loadFailed ? L("session.loadFailed") : L("session.noMatch"))
                .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 26)
        }
    }

    private func statusRow(_ key: String, spinning: Bool) -> some View {
        HStack(spacing: 7) {
            if spinning { ProgressView().controlSize(.small).scaleEffect(0.72) }
            Text(L(key)).font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 9)
    }

    private var loadMoreButton: some View {
        Button(action: onLoadMore) {
            HStack(spacing: 6) {
                if loading { ProgressView().controlSize(.small).scaleEffect(0.7) }
                else { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                Text(L("session.loadMore")).font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(Theme.ink2).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.plain).disabled(loading)
    }

    private func toggle(_ s: SessionItem) {
        if expandedKey == s.rowKey { expandedKey = nil; return }
        expandedKey = s.rowKey
        if previews[s.rowKey] == nil {
            Task {
                let messages = await loadPreview(s)
                if previews[s.rowKey] == nil, latestMtimes[s.rowKey] == s.mtime {
                    while previewOrder.count >= 20, let oldest = previewOrder.first {
                        previewOrder.removeFirst()
                        previews.removeValue(forKey: oldest)
                        previewMtimes.removeValue(forKey: oldest)
                    }
                    previews[s.rowKey] = messages
                    previewMtimes[s.rowKey] = s.mtime
                    previewOrder.append(s.rowKey)
                }
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                titleAndCount
                filterChips
                Spacer(minLength: 6)
                loadingIndicator
                searchField
            }
            VStack(spacing: 7) {
                HStack(spacing: 7) {
                    titleAndCount
                    Spacer(minLength: 6)
                    loadingIndicator
                    searchField
                }
                HStack(spacing: 7) { filterChips; Spacer(minLength: 0) }
            }
        }
    }

    private var titleAndCount: some View {
        HStack(spacing: 7) {
            Text(L("session.recent")).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if total > 0 {
                Text("\(total)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 7) {
            ForEach(["all", "claude", "codex"], id: \.self) { f in
                Chip(text: f == "all" ? L("session.all") : (f == "claude" ? "Claude" : "Codex"),
                     on: filter == f) { onFilter(f) }
            }
        }
    }

    @ViewBuilder private var loadingIndicator: some View {
        if loading && !sessions.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.7) }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.ink3)
            TextField(L("session.search"), text: Binding(get: { query }, set: onSearch))
                .textFieldStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.ink)
                .frame(width: 96)
            if !query.isEmpty {
                Button { onSearch("") } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Theme.edge))
    }
}

// MARK: - 会话行
private struct SessionRow: View {
    let session: SessionItem
    let expanded: Bool
    let preview: [PreviewMsg]?
    var onToggle: () -> Void = {}
    var onResume: () -> Void = {}
    var onCopy: () -> Void = {}
    var onPin: () -> Void = {}

    @State private var hovering = false
    private var brand: Brand { session.tool == "codex" ? .codex : .claude }
    private var live: Bool { Date().timeIntervalSince1970 - session.mtime < 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                BrandBadge(brand: brand, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if live { Circle().fill(Theme.ok).frame(width: 5, height: 5).shadow(color: Theme.ok, radius: 3).pulse(1.6) }   // .livedot 呼吸
                        Text(session.title ?? "—").font(.system(size: 11)).foregroundStyle(Theme.ink).lineLimit(1)
                    }
                    Text(meta).font(.system(size: 8.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer(minLength: 6)
                if hovering || expanded { actions }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if expanded { previewBox.padding(.leading, 35).padding(.trailing, 4).padding(.bottom, 6) }
        }
        .background(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
            .fill(session.pinned == true ? Color(hex: 0xffd479).opacity(0.045)
                  : (hovering ? Color.white.opacity(0.06) : .clear)))
        .onHover { hovering = $0 }
    }

    private var meta: String {
        var s = session.project?.isEmpty == false ? session.project! : "—"
        if let b = session.branch, !b.isEmpty, b != "HEAD" { s += " · " + b }
        s += " · " + Fmt.relative(Date(timeIntervalSince1970: session.mtime))
        return s
    }

    private var actions: some View {
        HStack(spacing: 5) {
            Button(action: onPin) {
                Image(systemName: session.pinned == true ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(session.pinned == true ? Color(hex: 0xffd479) : Theme.ink2)
            }.buttonStyle(.plain)
            Button(action: onResume) {
                Text(L("session.resume")).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 11).frame(height: 25)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Theme.edgeHi))
            }.buttonStyle(.plain)
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(Theme.ink2)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 4).padding(.vertical, 3)
        .background(Capsule().fill(Color(hex: 0x101018).opacity(0.82)))
        .overlay(Capsule().strokeBorder(Theme.edge))
    }

    @ViewBuilder private var previewBox: some View {
        if let msgs = preview {   // 已加载：有内容→渲染；空→无预览
            if msgs.isEmpty {
                Text(L("session.noPreview")).font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(msgs.enumerated()), id: \.offset) { _, m in
                        HStack(alignment: .top, spacing: 7) {
                            Text(m.role == "user" ? L("session.roleUser") : L("session.roleAI"))
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(m.role == "user" ? Brand.codex.accent : Brand.claude.accent)
                                .frame(width: 18, alignment: .leading)
                            Text(m.text).font(.system(size: 10.5)).foregroundStyle(Theme.ink2)
                                .lineLimit(2).lineSpacing(2)
                        }
                    }
                }
            }
        } else {   // 仍在加载（preview 尚为 nil）
            Text(L("session.loadingPreview")).font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
        }
    }
}
