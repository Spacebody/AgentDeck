import SwiftUI

struct OverviewMeasurement {
    static func query(agents: Set<String>, now: Date = Date(), timezone: TimeZone = .current) -> AnalyticsQuery {
        .init(days: 1, agents: agents, dimension: "agent", basis: "recorded", scope: .all,
              now: now, timezone: timezone)
    }

    let summary: AnalyticsSlice?
    let parts: [(Brand, Double)]

    init(snapshot: AnalyticsSnapshot?, query: AnalyticsQuery) {
        summary = query.agents.isEmpty ? nil : snapshot?.summary.first { $0.basis == query.basis }
        parts = (snapshot?.rows ?? []).compactMap { row in
            guard row.basis == query.basis, let id = row.agent, query.agents.contains(id),
                  let brand = Brand(rawValue: id), let count = row.value("tokens_total"), count > 0 else { return nil }
            return (brand, count)
        }
    }
}

struct AnalyticsOverview<Quota: View>: View {
    let agents: Set<String>
    let active: Bool
    let open: () -> Void
    @ViewBuilder let quota: () -> Quota
    @Environment(\.analyticsFixture) private var fixture
    @Environment(\.analyticsRefresh) private var refreshSignal
    @ObservedObject private var palette = AgentColors.shared
    @State private var today: (AnalyticsQuery, AnalyticsSnapshot)?
    @State private var problem: String?
    private struct TaskID: Hashable {
        let active: Bool
        let refresh: Int
        let query: AnalyticsQuery
    }

    var body: some View {
        let query = OverviewMeasurement.query(agents: agents)
        let daily = fixture.map { $0.series.count > 1 && $0.generation == AnalyticsSnapshot.preview.generation
            ? AnalyticsSnapshot.todayPreview : $0 } ?? (today?.0 == query ? today?.1 : nil)
        let reading = OverviewMeasurement(snapshot: daily, query: query)
        let total = reading.summary
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            Text(L("analytics.today")).font(.subheadline.weight(.semibold))
                            Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Theme.ink3)
                            Spacer(minLength: 0)
                            MiniDonut(parts: reading.parts.map { ($0.1, $0.0.accent) }).accessibilityHidden(true)
                        }
                        Text(total?.value("tokens_total").map(Fmt.tokens) ?? "—")
                            .font(.system(size: 32, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("\(L("analytics.recorded")) · \(L("v3.tokens"))").font(.caption).foregroundStyle(Theme.ink3)
                        if let cost = total?.value("api_equivalent_usd") {
                            Text("\(L("analytics.equivalent")) · \(String(format: "≈ $%.2f", cost))")
                                .font(.caption).foregroundStyle(Theme.ink2)
                        }
                        if agents.isEmpty {
                            Text(L("usage.noVisibleAgents")).font(.caption).foregroundStyle(Theme.ink3)
                        } else if let problem {
                            Text(L(problem)).font(.caption).foregroundStyle(Theme.warn)
                        } else if let known = total?.subtotal("tokens_total") {
                            Text(L("analytics.known", ["n": Fmt.tokens(known)])).font(.caption).foregroundStyle(Theme.ink2)
                        } else if daily?.status == "partial" {
                            Text(L("analytics.indexing")).font(.caption).foregroundStyle(Theme.ink3)
                        } else if let total, total.value("tokens_total") == nil {
                            Text(L("analytics.incomplete")).font(.caption).foregroundStyle(Theme.ink3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("v3.viewUsage"))
                Divider()
                quota().frame(maxWidth: .infinity, alignment: .top)
            }.fixedSize(horizontal: false, vertical: true)
        }.task(id: TaskID(active: active, refresh: refreshSignal, query: query)) {
            problem = nil
            guard active, fixture == nil, !agents.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    let current = OverviewMeasurement.query(agents: agents)
                    let day: AnalyticsSnapshot = try await APIClient.shared.get("/api/analytics", query: current.parameters())
                    try Task.checkCancellation()
                    today = (current, day); problem = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = (error as? APIError).map { if case .http(503) = $0 { return "analytics.indexing" }; return "common.opFailed" } ?? "common.opFailed"
                }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }
}
