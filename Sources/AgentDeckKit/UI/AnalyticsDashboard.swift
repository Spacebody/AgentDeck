import SwiftUI
import UniformTypeIdentifiers

struct AnalyticsDashboard: View {
    let agents: Set<String>
    var scope: AnalyticsScope = .all
    var fixture: AnalyticsSnapshot?
    @Binding var days: Int
    @State private var dimension: String
    @State private var basis: String

    init(agents: Set<String>, scope: AnalyticsScope = .all, fixture: AnalyticsSnapshot? = nil,
         days: Binding<Int>, initialBasis: String = "recorded") {
        self.agents = agents; self.scope = scope; self.fixture = fixture; _days = days
        _dimension = State(initialValue: scope == .all ? "agent" : "model")
        _basis = State(initialValue: initialBasis)
    }

    var body: some View {
        let query = AnalyticsQuery(days: days, agents: agents, dimension: dimension, basis: basis, scope: scope)
        VStack(alignment: .leading, spacing: 14) {
            let period = AnalyticsSegments(title: L("analytics.period"), selected: $days, options: [
                (1, L("analytics.today")), (7, L("analytics.days", ["n": "7"])), (30, L("analytics.days", ["n": "30"])),
            ])
            let basisPicker = AnalyticsSegments(title: L("analytics.basis"), selected: $basis,
                                                options: [("recorded", L("analytics.recorded")), ("sampled", L("analytics.sampled"))])
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { period; Spacer(minLength: 2); basisPicker }
                VStack(alignment: .leading, spacing: 6) { period; basisPicker }
            }
            if agents.isEmpty {
                Text(L("usage.noVisibleAgents")).foregroundStyle(Theme.ink3)
            } else {
                AnalyticsResults(query: query, fixture: fixture, dimension: $dimension)
                    .id(query)
            }
        }.font(.system(size: 12)).foregroundStyle(Theme.ink)
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
    @State private var open = false
    @State private var days = 30
    @Environment(\.analyticsFixture) private var fixture
    var body: some View {
        Button { open = true } label: {
            if iconOnly { Image(systemName: "chart.bar") }
            else { Label(L("v3.viewUsage"), systemImage: "chart.bar") }
        }.buttonStyle(.plain).help(L("v3.viewUsage")).accessibilityLabel(L("v3.viewUsage") + ": " + title)
            .popover(isPresented: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(title).font(.headline).lineLimit(2)
                        Spacer()
                        Button { open = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(L("common.close"))
                            .keyboardShortcut(.cancelAction)
                    }
                    ScrollView {
                        AnalyticsDashboard(agents: agents, scope: scope, fixture: fixture, days: $days)
                    }
                }.padding(14).frame(width: 365, height: 440)
            }
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
    @State private var snapshot: AnalyticsSnapshot?
    @State private var cursor: String?
    @State private var reload = 0
    @State private var loading = false
    @State private var issue: String?
    @State private var exporting = false
    @Environment(\.analyticsLive) private var live
    @Environment(\.analyticsRefresh) private var refreshSignal
    @State private var opened: String?
    @ObservedObject private var palette = AgentColors.shared
    private var visible: AnalyticsSnapshot? { fixture ?? snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DashboardHeading(text: L("v3.tokens"))
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
                    AnalyticsMetrics(slice: summary, color: tint, primary: true)
                    AnalyticsTrend(samples: visible.series.filter { $0.basis == query.basis }, query: query, color: tint)
                } else { Text(L("analytics.noSamples")).foregroundStyle(Theme.ink3) }
            } else if loading { ProgressView().controlSize(.small) }
            Divider()
            AnalyticsSegments(title: L("analytics.group"), selected: $dimension,
                              options: ["agent", "model", "project"].map { ($0, L("analytics." + $0)) })
            if let visible {
                ForEach(visible.rows.filter { $0.basis == query.basis }, id: \.key) { row in
                    let label = row.agent.flatMap(Brand.init(rawValue:))?.name ?? row.label ?? L("analytics.unknown")
                    Button { opened = opened == row.key ? nil : row.key } label: {
                        HStack(spacing: 8) {
                            if let brand = row.agent.flatMap(Brand.init(rawValue:)) {
                                BrandGlyph(brand: brand, glyph: 14)
                            }
                            Text(label).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(row.value("tokens_total").map(Fmt.tokens) ?? "—").monospacedDigit()
                            Image(systemName: opened == row.key ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundStyle(Theme.ink3)
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if opened == row.key {
                        AnalyticsMetrics(slice: row, color: row.agent.flatMap(Brand.init(rawValue:))?.accent ?? tint)
                    }
                    Divider()
                }
                if visible.rows.isEmpty { Text(L("analytics.noGroups")).font(.caption).foregroundStyle(Theme.ink3) }
                if let next = visible.nextCursor {
                    Button(L("analytics.more")) { cursor = next; reload += 1 }.disabled(loading)
                }
                Text(L("analytics.sourceNote")).font(.caption).foregroundStyle(Theme.ink3)
            }
        }
        .onChange(of: refreshSignal) { _ in cursor = nil; reload += 1 }
        .task(id: "\(reload)|\(live)") {
            guard live, fixture == nil else { return }
            var delay: UInt64 = 3
            while !Task.isCancelled {
                let retry = await load()
                guard retry else { return }
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
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
