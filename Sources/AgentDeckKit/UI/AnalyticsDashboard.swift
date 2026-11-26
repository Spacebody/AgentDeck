import SwiftUI
import UniformTypeIdentifiers

enum AnalyticsMode: String, CaseIterable {
    case trend, composition, performance
}

private struct RankingDetail: Identifiable {
    let id: String
    let title: String
    let query: AnalyticsQuery
    let fixture: AnalyticsSnapshot?
}

struct AnalyticsDashboard: View {
    let agents: Set<String>
    var scope: AnalyticsScope = .all
    var fixture: AnalyticsSnapshot?
    @Binding var days: Int
    @State private var dimension: String
    @State private var basis: String
    @State private var mode: AnalyticsMode
    @State private var detailMode = AnalyticsMode.trend
    @State private var detail: RankingDetail?
    @Environment(\.analyticsLive) private var live

    init(agents: Set<String>, scope: AnalyticsScope = .all, fixture: AnalyticsSnapshot? = nil,
         days: Binding<Int>, initialBasis: String = "recorded", initialMode: AnalyticsMode = .trend) {
        self.agents = agents; self.scope = scope; self.fixture = fixture; _days = days
        _dimension = State(initialValue: scope == .all ? "agent" : "model")
        _basis = State(initialValue: initialBasis)
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        let query = AnalyticsQuery(days: days, agents: agents, dimension: dimension, basis: basis, scope: scope)
        VStack(alignment: .leading, spacing: 14) {
            let period = AnalyticsSegments(title: L("analytics.period"), selected: $days, options: [
                (1, L("analytics.today")), (7, L("analytics.days", ["n": "7"])), (30, L("analytics.days", ["n": "30"])),
            ])
            let basisPicker = PanelChoiceMenu(title: L("analytics." + basis), selected: basis,
                                              choices: ["recorded", "sampled"].map { .init(id: $0, title: L("analytics." + $0)) }) { basis = $0 }
                .help(L("analytics.basis"))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { period; Spacer(minLength: 2); basisPicker }
                VStack(alignment: .leading, spacing: 6) { period; basisPicker }
            }
            if agents.isEmpty {
                Text(L("usage.noVisibleAgents")).foregroundStyle(Theme.ink3)
            } else {
                modePicker($mode)
                AnalyticsResults(query: query, fixture: fixture, dimension: $dimension, mode: mode) { row, label in
                    guard let key = row.key, let filter = AnalyticsGroupFilter(dimension: dimension, row: row) else { return }
                    detailMode = .trend
                    detail = RankingDetail(id: key, title: label, query: query.filtered(by: filter),
                        fixture: fixture.map { AnalyticsSnapshot(generation: $0.generation, status: $0.status,
                            summary: [row], series: [], rows: [], nextCursor: nil) })
                }
                    .id(query)
                    .environment(\.analyticsLive, live && detail == nil)
            }
        }.font(.system(size: 12)).foregroundStyle(Theme.ink)
        .onChange(of: query) { _ in detail = nil }
        .popover(item: $detail) { item in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button { detail = nil } label: { Label(L("common.back"), systemImage: "chevron.left") }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Text(item.title).font(.headline).lineLimit(2)
                    Spacer()
                    Text(L("analytics." + item.query.basis)).font(.caption).foregroundStyle(Theme.ink3)
                }
                modePicker($detailMode)
                ScrollView {
                    AnalyticsResults(query: item.query, fixture: item.fixture, dimension: .constant(dimension),
                                     mode: detailMode, openRow: nil)
                }
            }.padding(16).frame(width: 365, height: 430)
        }
    }

    private func modePicker(_ binding: Binding<AnalyticsMode>) -> some View {
        AnalyticsSegments(title: L("v3.viewUsage"), selected: binding,
                          options: AnalyticsMode.allCases.map { ($0, L("analytics." + $0.rawValue)) })
    }
}

private struct AnalyticsSegments<Value: Hashable>: View {
    let title: String
    @Binding var selected: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { value, label in
                Button { selected = value } label: {
                    Text(label).font(.system(size: 11, weight: selected == value ? .semibold : .regular))
                        .foregroundStyle(selected == value ? Theme.ink : Theme.ink2)
                        .padding(.horizontal, 8).frame(height: 23)
                        .background(RoundedRectangle(cornerRadius: 4).fill(selected == value ? Theme.edgeHi : .clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title + ": " + label)
                    .accessibilityAddTraits(selected == value ? .isSelected : [])
            }
        }.padding(2).fixedSize().background(RoundedRectangle(cornerRadius: 6).fill(Theme.edge.opacity(0.6)))
    }
}

struct AnalyticsDetailLink: View {
    let scope: AnalyticsScope
    let title: String
    let agents: Set<String>
    var iconOnly = false
    @Environment(\.openAnalytics) private var openAnalytics
    @Environment(\.analyticsFixture) private var fixture
    private var actionTitle: String {
        switch scope {
        case .project: return L("analytics.openProject")
        case .session: return L("analytics.openSession")
        case .all: return L("v3.viewUsage")
        }
    }
    var body: some View {
        Button { openAnalytics(.init(scope: scope, title: title, agents: agents), fixture) } label: {
            if iconOnly { Image(systemName: "chart.bar") }
            else { Label(actionTitle, systemImage: "chart.bar") }
        }.buttonStyle(.plain).help(actionTitle).accessibilityLabel(actionTitle + ": " + title)
    }
}

private struct AnalyticsFixtureKey: EnvironmentKey {
    static let defaultValue: AnalyticsSnapshot? = nil
}
private struct AnalyticsLiveKey: EnvironmentKey {
    static let defaultValue = true
}
private struct AnalyticsRefreshKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var analyticsRefresh: Int {
        get { self[AnalyticsRefreshKey.self] }
        set { self[AnalyticsRefreshKey.self] = newValue }
    }
    var analyticsLive: Bool {
        get { self[AnalyticsLiveKey.self] }
        set { self[AnalyticsLiveKey.self] = newValue }
    }
    var analyticsFixture: AnalyticsSnapshot? {
        get { self[AnalyticsFixtureKey.self] }
        set { self[AnalyticsFixtureKey.self] = newValue }
    }
}

private struct AnalyticsResults: View {
    let query: AnalyticsQuery
    let fixture: AnalyticsSnapshot?
    @Binding var dimension: String
    let mode: AnalyticsMode
    let openRow: ((AnalyticsSlice, String) -> Void)?
    @State private var snapshot: AnalyticsSnapshot?
    @State private var cursor: String?
    @State private var reload = 0
    @State private var loading = false
    @State private var issue: String?
    @State private var exporting = false
    @Environment(\.analyticsLive) private var live
    @Environment(\.analyticsRefresh) private var refreshSignal
    @ObservedObject private var palette = AgentColors.shared
    private var visible: AnalyticsSnapshot? { fixture ?? snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DashboardHeading(text: L(mode == .trend ? "v3.tokens" : "analytics." + mode.rawValue))
                Spacer()
                Button { reload += 1; cursor = nil } label: { Image(systemName: "arrow.clockwise") }
                    .help(L("header.refresh")).accessibilityLabel(L("header.refresh"))
                    .disabled(loading || exporting || fixture != nil)
                Button { exporting = true } label: {
                    Label("CSV", systemImage: "square.and.arrow.down").font(.system(size: 12))
                }.help(L("v3.export")).disabled(visible == nil || exporting || loading || fixture != nil)
            }.buttonStyle(.plain)
            if let issue {
                Text(L(issue)).font(.caption).foregroundStyle(Theme.warn)
            }
            if let visible {
                if visible.status != "ready" { Text(L("analytics.indexing")).foregroundStyle(Theme.ink3) }
                if let summary = visible.summary.first(where: { $0.basis == query.basis }) {
                    AnalyticsMetrics(slice: summary, color: tint, mode: mode)
                    if mode == .trend && !query.isSingleCalendarDay {
                        AnalyticsTrend(samples: visible.series.filter { $0.basis == query.basis }, query: query, color: tint)
                            .padding(.vertical, 6)
                    }
                } else { Text(L("analytics.noSamples")).foregroundStyle(Theme.ink3) }
            } else if loading { ProgressView().controlSize(.small) }
            if mode == .trend, let openRow {
                Divider()
                HStack {
                    DashboardHeading(text: L("analytics.ranking"))
                    Spacer()
                    PanelChoiceMenu(title: L("analytics." + dimension), selected: dimension,
                                    choices: ["agent", "model", "project"].map { .init(id: $0, title: L("analytics." + $0)) }) { dimension = $0 }
                }
                if let visible {
                    ForEach(visible.rows.filter { $0.basis == query.basis }, id: \.key) { row in
                        let label = row.agent.flatMap(Brand.init(rawValue:))?.name ?? row.label ?? L("analytics.unknown")
                        Button { openRow(row, label) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 8) {
                                    if let brand = row.agent.flatMap(Brand.init(rawValue:)) {
                                        BrandGlyph(brand: brand, glyph: 14)
                                    }
                                    Text(label).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(row.value("tokens_total").map(Fmt.tokens) ?? "—").monospacedDigit()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(Theme.ink3)
                                }
                                if let value = row.value("tokens_total"),
                                   let sum = visible.summary.first(where: { $0.basis == query.basis })?.value("tokens_total"), sum > 0 {
                                    GeometryReader { geo in
                                        Capsule().fill(row.agent.flatMap(Brand.init(rawValue:))?.accent ?? tint)
                                            .frame(width: geo.size.width * min(1, max(0, value / sum)))
                                    }.frame(height: 3).background(Theme.edge).clipShape(Capsule()).accessibilityHidden(true)
                                }
                            }.font(.system(size: 14)).padding(.vertical, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    if visible.rows.isEmpty { Text(L("analytics.noGroups")).font(.caption).foregroundStyle(Theme.ink3) }
                    if let next = visible.nextCursor {
                        Button(L("analytics.more")) { cursor = next; reload += 1 }.disabled(loading)
                    }
                    Text(L("analytics.sourceNote")).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
            }
        }
        .onChange(of: refreshSignal) { _ in cursor = nil; reload += 1 }
        .onChange(of: mode) { newMode in
            if newMode == .performance { cursor = nil }
        }
        .task(id: "\(reload)|\(live)|\(mode == .performance)") {
            guard live, fixture == nil else { return }
            // A covered dashboard can become visible again after this page was appended.
            if let cursor, let snapshot, cursor != snapshot.nextCursor { return }
            var delay: UInt64 = 3
            while !Task.isCancelled {
                let retry = await load()
                guard retry || (mode == .performance && cursor == nil) else { return }
                do { try await Task.sleep(nanoseconds: (retry ? delay : 30) * 1_000_000_000) } catch { return }
                delay = min(delay * 2, 30)
            }
        }
        .task(id: exporting) { if exporting { await saveCSV() } }
    }

    private var tint: Color {
        query.agents.count == 1 ? Brand(rawValue: query.agents[0])?.accent ?? DashboardStyle.accent : DashboardStyle.accent
    }

    private func load() async -> Bool {
        loading = true; issue = nil
        do {
            var params = query.parameters(generation: cursor == nil ? nil : snapshot?.generation, cursor: cursor)
            params["limit"] = "15"
            let page: AnalyticsSnapshot = try await APIClient.shared.get("/api/analytics", query: params)
            try Task.checkCancellation()
            if cursor == nil { snapshot = page } else { try snapshot?.append(page) }
            loading = false
            return cursor == nil && page.status == "partial"
        } catch {
            guard !Task.isCancelled else { return false }
            handle(error)
            loading = false
            if case APIError.http(503) = error { return true }
            return false
        }
    }

    private func handle(_ error: Error) {
        if case APIError.http(409) = error { snapshot = nil; issue = "analytics.expired" }
        else if case APIError.http(413) = error { issue = "analytics.exportTooLarge" }
        else if case APIError.http(503) = error { issue = "analytics.indexing" }
        else { issue = "common.opFailed" }
    }

    private func saveCSV() async {
        defer { exporting = false }
        guard let generation = snapshot?.generation else { return }
        issue = nil
        do {
            let data = try await APIClient.shared.analyticsCSV(query: query.parameters(generation: generation))
            try Task.checkCancellation()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = "AgentDeck-\(query.dimension)-\(query.basis).csv"
            if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic) }
        } catch {
            if !Task.isCancelled { handle(error) }
        }
    }
}
