// AgentDeck v2 — 会话页。复刻 index.html renderSessions/togglePreview/loadSessions 及交互：
// 搜索 + 筛选 chips(all/claude/codex) + 行(徽章/标题+livedot/元信息) + 悬浮操作(置顶/恢复/复制) + 点开预览。
import SwiftUI

struct SessionsView: View {
    let sessions: [SessionItem]
    var scrollable: Bool = true
    var onResume: (SessionItem) -> Void = { _ in }
    var onCopy: (SessionItem) -> Void = { _ in }
    var onPin: (SessionItem) -> Void = { _ in }
    /// 加载某会话预览（接 store.preview，异步）。
    var loadPreview: (SessionItem) async -> [PreviewMsg] = { _ in [] }
    /// 搜索词变化（驱动 store.search，服务端全量匹配；sessions 已是结果）。
    var onSearch: (String) -> Void = { _ in }
    /// 预览期可注入：默认展开某行 + 预置预览内容（静态渲染验证用）。
    var initialExpanded: String? = nil
    var seededPreviews: [String: [PreviewMsg]] = [:]

    @State private var query = ""
    @State private var filter = "all"
    @State private var expandedKey: String?
    @State private var previews: [String: [PreviewMsg]] = [:]

    init(sessions: [SessionItem], scrollable: Bool = true,
         onResume: @escaping (SessionItem) -> Void = { _ in },
         onCopy: @escaping (SessionItem) -> Void = { _ in },
         onPin: @escaping (SessionItem) -> Void = { _ in },
         loadPreview: @escaping (SessionItem) async -> [PreviewMsg] = { _ in [] },
         onSearch: @escaping (String) -> Void = { _ in },
         initialExpanded: String? = nil, seededPreviews: [String: [PreviewMsg]] = [:]) {
        self.sessions = sessions; self.scrollable = scrollable
        self.onResume = onResume; self.onCopy = onCopy; self.onPin = onPin; self.loadPreview = loadPreview
        self.onSearch = onSearch
        self.initialExpanded = initialExpanded; self.seededPreviews = seededPreviews
        _expandedKey = State(initialValue: initialExpanded)
        _previews = State(initialValue: seededPreviews)
    }

    // 仅做工具筛选；搜索词由服务端匹配（sessions 已是结果），不再客户端二次过滤。
    private var filtered: [SessionItem] {
        sessions.filter { filter == "all" || $0.tool == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if filtered.isEmpty {
                Text(L("session.noMatch")).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 26)
            } else {
                let rows = VStack(spacing: 2) {
                    ForEach(filtered, id: \.rowKey) { s in
                        SessionRow(
                            session: s,
                            expanded: expandedKey == s.rowKey,
                            preview: previews[s.rowKey],
                            onToggle: { toggle(s) },
                            onResume: { onResume(s) }, onCopy: { onCopy(s) }, onPin: { onPin(s) })
                    }
                }
                if scrollable { ScrollView { rows }.scrollIndicators(.hidden) } else { rows }
            }
        }
    }

    private func toggle(_ s: SessionItem) {
        if expandedKey == s.rowKey { expandedKey = nil; return }
        expandedKey = s.rowKey
        if previews[s.rowKey] == nil {
            Task { previews[s.rowKey] = await loadPreview(s) }
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Text(L("session.recent")).font(.system(size: 12.5, weight: .bold))
            ForEach(["all", "claude", "codex"], id: \.self) { f in
                Chip(text: f == "all" ? L("session.all") : (f == "claude" ? "Claude" : "Codex"),
                     on: filter == f) { filter = f }
            }
            Spacer(minLength: 6)
            searchField
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.ink3)
            TextField(L("session.search"), text: $query)
                .textFieldStyle(.plain).font(.system(size: 10.5)).foregroundStyle(Theme.ink)
                .frame(width: 96)
                .onChange(of: query) { onSearch($0) }
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
                        if live { Circle().fill(Theme.ok).frame(width: 5, height: 5).shadow(color: Theme.ok, radius: 3) }
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
                Text(L("session.resume")).font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.ink)
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
                    ForEach(msgs) { m in
                        HStack(alignment: .top, spacing: 7) {
                            Text(m.role == "user" ? L("session.roleUser") : L("session.roleAI"))
                                .font(.system(size: 8.5, weight: .heavy))
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
