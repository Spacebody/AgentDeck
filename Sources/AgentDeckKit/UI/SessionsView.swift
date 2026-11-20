// AgentDeck v2 — 会话页。复刻 index.html renderSessions/togglePreview/loadSessions 及交互：
// 搜索 + 筛选 chips(all/claude/codex) + 行(徽章/标题+livedot/元信息) + 悬浮操作(置顶/恢复/复制) + 点开预览。
import SwiftUI

struct SessionPreviewRequest: Equatable {
    let key: String
    let mtime: Double

    static func expanded(_ key: String?, in sessions: [SessionItem]) -> Self? {
        guard let session = sessions.first(where: { $0.rowKey == key }) else { return nil }
        return Self(key: session.rowKey, mtime: session.mtime)
    }
}

struct SessionsView: View {
    let sessions: [SessionItem]
    var active: [ActiveSession] = []
    var onOpenActive: (ActiveSession) -> Void = { _ in }
    var scrollable: Bool = true
    var query: String = ""
    var filter: String = "all"
    var total: Int = 0
    var hasMore: Bool = false
    var page: Int = 1
    var pageCount: Int = 1
    var pageSize: Int = 20
    var loading: Bool = false
    var indexing: Bool = false
    var loadFailed: Bool = false
    var onResume: (SessionItem) -> Void = { _ in }
    var onCopy: (SessionItem) -> Void = { _ in }
    var onPin: (SessionItem) -> Void = { _ in }
    var onRelocate: (SessionItem) -> Void = { _ in }
    var onForgetPath: (SessionItem) -> Void = { _ in }
    /// 加载某会话预览（接 store.preview，异步）。
    var loadPreview: (SessionItem) async -> [PreviewMsg] = { _ in [] }
    /// 搜索词/工具筛选由 AppStore 持有，切换 Tab 后仍保持一致。
    var onSearch: (String) -> Void = { _ in }
    var onFilter: (String) -> Void = { _ in }
    var onPreviousPage: () -> Void = {}
    var onNextPage: () -> Void = {}
    var onPageSize: (Int) -> Void = { _ in }
    /// 预览期可注入：默认展开某行 + 预置预览内容（静态渲染验证用）。
    var initialExpanded: String? = nil
    var seededPreviews: [String: [PreviewMsg]] = [:]

    @State private var expandedKey: String?
    @State private var previews: [String: [PreviewMsg]] = [:]
    @State private var previewOrder: [String] = []
    @State private var previewMtimes: [String: Double] = [:]
    @State private var showingCustomPageSize = false
    @State private var customPageSizeText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var customPageSizeFocused: Bool

    init(sessions: [SessionItem], active: [ActiveSession] = [],
         onOpenActive: @escaping (ActiveSession) -> Void = { _ in }, scrollable: Bool = true,
         query: String = "", filter: String = "all", total: Int = 0,
         hasMore: Bool = false, page: Int = 1, pageCount: Int = 1,
         pageSize: Int = 20, loading: Bool = false,
         indexing: Bool = false, loadFailed: Bool = false,
         onResume: @escaping (SessionItem) -> Void = { _ in },
         onCopy: @escaping (SessionItem) -> Void = { _ in },
         onPin: @escaping (SessionItem) -> Void = { _ in },
         onRelocate: @escaping (SessionItem) -> Void = { _ in },
         onForgetPath: @escaping (SessionItem) -> Void = { _ in },
         loadPreview: @escaping (SessionItem) async -> [PreviewMsg] = { _ in [] },
         onSearch: @escaping (String) -> Void = { _ in },
         onFilter: @escaping (String) -> Void = { _ in },
         onPreviousPage: @escaping () -> Void = {},
         onNextPage: @escaping () -> Void = {},
         onPageSize: @escaping (Int) -> Void = { _ in },
         initialExpanded: String? = nil, seededPreviews: [String: [PreviewMsg]] = [:]) {
        self.sessions = sessions; self.scrollable = scrollable
        self.active = active; self.onOpenActive = onOpenActive
        self.query = query; self.filter = filter; self.total = total
        self.hasMore = hasMore; self.loading = loading
        self.page = page; self.pageCount = pageCount; self.pageSize = pageSize
        self.indexing = indexing; self.loadFailed = loadFailed
        self.onResume = onResume; self.onCopy = onCopy; self.onPin = onPin
        self.onRelocate = onRelocate; self.onForgetPath = onForgetPath
        self.loadPreview = loadPreview
        self.onSearch = onSearch; self.onFilter = onFilter
        self.onPreviousPage = onPreviousPage; self.onNextPage = onNextPage
        self.onPageSize = onPageSize
        self.initialExpanded = initialExpanded; self.seededPreviews = seededPreviews
        _expandedKey = State(initialValue: initialExpanded)
        _previews = State(initialValue: seededPreviews)
        _previewOrder = State(initialValue: Array(seededPreviews.keys))
        let mtimes = Dictionary(uniqueKeysWithValues: sessions.map { ($0.rowKey, $0.mtime) })
        _previewMtimes = State(initialValue: mtimes.filter { seededPreviews[$0.key] != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if !filteredActive.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    DashboardHeading(text: L("active.running", ["n": "\(filteredActive.count)"]))
                    ForEach(Array(filteredActive.enumerated()), id: \.offset) { _, active in
                        if let session = previewSessions.first(where: { $0.rowKey == active.indexedRowKey }) {
                            sessionRow(session, onOpen: { onOpenActive(active) })
                        } else {
                            DashboardActiveList(sessions: [active], showsHeading: false, onOpen: onOpenActive)
                        }
                    }
                }.padding(.vertical, 12)
                Divider().opacity(0.4)
            }
            titleAndCount.padding(.top, 12)
            if sessions.isEmpty {
                emptyState
                if page > 1 { pagination }
            } else {
                if scrollable { ScrollView { rows }.scrollIndicators(.hidden) } else { rows }
                pagination
            }
        }
        .onChange(of: previewSessions.map { "\($0.rowKey)|\($0.mtime)" }) { _ in
            let current = Dictionary(uniqueKeysWithValues: previewSessions.map { ($0.rowKey, $0.mtime) })
            previews = previews.filter { previewMtimes[$0.key] == current[$0.key] }
            previewMtimes = previewMtimes.filter { current[$0.key] == $0.value }
            previewOrder.removeAll { previews[$0] == nil }
            if let expandedKey, current[expandedKey] == nil { self.expandedKey = nil }
        }
        .task(id: SessionPreviewRequest.expanded(expandedKey, in: previewSessions)) {
            guard let request = SessionPreviewRequest.expanded(expandedKey, in: previewSessions),
                  let session = previewSessions.first(where: { $0.rowKey == request.key }),
                  previews[request.key] == nil || previewMtimes[request.key] != request.mtime
            else { return }
            let messages = await loadPreview(session)
            // A loader may finish despite cancellation after collapse, paging, or a file update.
            guard !Task.isCancelled else { return }
            previewOrder.removeAll { $0 == request.key }
            while previewOrder.count >= 20, let oldest = previewOrder.first {
                previewOrder.removeFirst()
                previews.removeValue(forKey: oldest)
                previewMtimes.removeValue(forKey: oldest)
            }
            previews[request.key] = messages
            previewMtimes[request.key] = request.mtime
            previewOrder.append(request.key)
        }
    }

    private var rows: some View {
        LazyVStack(spacing: 2) {
            ForEach(sessions.filter { session in !filteredActive.contains { $0.indexedRowKey == session.rowKey } }, id: \.rowKey) { s in
                sessionRow(s)
            }
            if indexing { statusRow("session.indexing", spinning: true) }
            if loadFailed { statusRow("session.loadFailed", spinning: false) }
        }
    }

    private var previewSessions: [SessionItem] {
        var keys = Set(sessions.map(\.rowKey))
        return sessions + active.compactMap(\.indexedSession).filter { keys.insert($0.rowKey).inserted }
    }

    private func sessionRow(_ s: SessionItem, onOpen: (() -> Void)? = nil) -> some View {
        SessionRow(session: s, expanded: expandedKey == s.rowKey,
                   preview: previewMtimes[s.rowKey] == s.mtime ? previews[s.rowKey] : nil,
                   onToggle: { toggle(s) }, onResume: { onResume(s) }, onCopy: { onCopy(s) }, onPin: { onPin(s) },
                   onRelocate: { onRelocate(s) }, onForgetPath: { onForgetPath(s) }, onOpen: onOpen)
    }

    private var filteredActive: [ActiveSession] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return active.filter { item in
            guard filter == "all" || filter == item.tool else { return false }
            let text = [item.project ?? "", item.cwd ?? "", item.title ?? ""].joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
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

    private var pagination: some View {
        HStack(spacing: 8) {
            let sizes = Array(Set([10, 20, 30, 50, pageSize])).sorted()
            PanelChoiceMenu(title: L("session.perPage", ["n": "\(pageSize)"]), selected: String(pageSize),
                            choices: sizes.map { .init(id: String($0), title: String($0)) }
                                + [.init(id: "custom", title: L("session.customPageSize"))]) { id in
                if let size = Int(id) { onPageSize(size) }
                else {
                    customPageSizeText = String(pageSize)
                    DispatchQueue.main.async { showingCustomPageSize = true }
                }
            }
            .background(Color.clear.popover(isPresented: $showingCustomPageSize) { customPageSizeEditor })

            Spacer(minLength: 4)

            Text(L("session.pageOf", ["page": "\(page)", "pages": "\(pageCount)"]))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .fixedSize()

            pageButton(
                system: "chevron.left", help: L("session.previousPage"),
                disabled: page <= 1, action: onPreviousPage)
            pageButton(
                system: "chevron.right", help: L("session.nextPage"),
                disabled: !hasMore, action: onNextPage)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 3)
    }

    static func parseCustomPageSize(_ input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text), (5...100).contains(value) else { return nil }
        return value
    }

    private var parsedCustomPageSize: Int? {
        Self.parseCustomPageSize(customPageSizeText)
    }

    private var customPageSizeEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("session.customPageSizeTitle"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)

            TextField("", text: $customPageSizeText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .multilineTextAlignment(.trailing)
                .frame(width: 88)
                .focused($customPageSizeFocused)
                .onSubmit { applyCustomPageSize() }

            Text(L("session.pageSizeRange"))
                .font(.system(size: 10.5))
                .foregroundStyle(parsedCustomPageSize == nil ? Theme.danger : Theme.ink3)

            HStack(spacing: 8) {
                Spacer()
                Button(L("session.cancel")) {
                    showingCustomPageSize = false
                }
                .buttonStyle(.bordered)

                Button(L("session.applyPageSize")) {
                    applyCustomPageSize()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(parsedCustomPageSize == nil || loading)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 230)
        .onAppear { customPageSizeFocused = true }
    }

    private func applyCustomPageSize() {
        guard let size = parsedCustomPageSize else { return }
        onPageSize(size)
        showingCustomPageSize = false
    }

    private func pageButton(
        system: String, help: String, disabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(disabled ? Theme.ink3.opacity(0.45) : Theme.ink2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(disabled ? 0.025 : 0.055)))
                .overlay(Circle().strokeBorder(Theme.edge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
        .help(help)
        .accessibilityLabel(help)
    }

    private func toggle(_ s: SessionItem) {
        if expandedKey == s.rowKey { expandedKey = nil; return }
        expandedKey = s.rowKey
    }

    private var header: some View {
        HStack(spacing: 10) {
            searchField
            loadingIndicator
            let agents = ["all", "claude", "codex", "qoder"]
            PanelChoiceMenu(title: filter == "all" ? L("session.all") : filter.capitalized,
                            selected: filter, choices: agents.map {
                .init(id: $0, title: $0 == "all" ? L("session.all") : $0.capitalized)
            }, onSelect: onFilter)
        }
    }

    private var titleAndCount: some View {
        HStack(spacing: 7) {
            Text(L("session.recent")).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink).lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if total > 0 {
                Text("\(total)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2)
                    .monospacedDigit()
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 7) {
            ForEach(["all", "claude", "codex", "qoder"], id: \.self) { f in
                Chip(text: f == "all" ? L("session.all") :
                     (f == "claude" ? "Claude" : f == "codex" ? "Codex" : "Qoder"),
                     on: filter == f) { onFilter(f) }
            }
        }
    }

    @ViewBuilder private var loadingIndicator: some View {
        if loading && !sessions.isEmpty { ProgressView().controlSize(.small).scaleEffect(0.7) }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink3)
            TextField(L("session.search"), text: Binding(get: { query }, set: onSearch))
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onExitCommand { searchFocused = false }
                .frame(maxWidth: .infinity)
            if !query.isEmpty {
                Button { onSearch("") } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(L("session.clearSearch"))
                .accessibilityLabel(L("session.clearSearch"))
            }
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
        .background(PanelInputRegion(.focusedSearch, active: searchFocused) { searchFocused = false })
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(searchFocused ? 0.09 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? DashboardStyle.accent : Theme.edge, lineWidth: 1))
        .animation(.easeOut(duration: 0.16), value: searchFocused)
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
    var onRelocate: () -> Void = {}
    var onForgetPath: () -> Void = {}
    var onOpen: (() -> Void)? = nil

    @State private var hovering = false
    private var brand: Brand { Brand(rawValue: session.tool) ?? .claude }
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
                    SessionSpeedView(request: session.performanceRequest)
                }
                Spacer(minLength: 6)
                if hovering || expanded { actions.fixedSize(horizontal: true, vertical: false) }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }

            if expanded {
                SessionSpeedView(request: session.performanceRequest, expanded: true)
                    .padding(.leading, 35).padding(.trailing, 9)
                previewBox.padding(.leading, 35).padding(.trailing, 4).padding(.bottom, 6)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous)
            .fill(session.pinned == true ? Color(hex: 0xffd479).opacity(0.045)
                  : (hovering ? Color.white.opacity(0.06) : .clear)))
        .onHover { hovering = $0 }
        .contextMenu {
            if let onOpen { Button(L("v3.open"), action: onOpen) }
            Button(L("session.resume"), action: onResume)
            if session.source != "qoder_app" { Button(L("session.copyCmd"), action: onCopy) }
            if session.cwd?.isEmpty == false {
                Button(action: onRelocate) {
                    Label(L("session.relocate"), systemImage: "folder.badge.gearshape")
                }
                Button(action: onForgetPath) {
                    Label(L("session.forgetPath"), systemImage: "arrow.uturn.backward")
                }
            }
        }
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
            Button(action: onOpen ?? onResume) {
                Text(L(onOpen != nil ? "v3.open" : session.source == "qoder_app" ? "session.open" : "session.resume"))
                    .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 11).frame(height: 25)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Theme.edgeHi))
            }.buttonStyle(.plain)
            if session.source != "qoder_app" {
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(Theme.ink2)
                }.buttonStyle(.plain)
            }
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
