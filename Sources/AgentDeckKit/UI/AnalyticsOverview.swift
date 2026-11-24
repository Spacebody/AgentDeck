import SwiftUI

struct AnalyticsOverview<Quota: View>: View {
    let agents: Set<String>
    let active: Bool
    let open: () -> Void
    @ViewBuilder let quota: () -> Quota
    @Environment(\.analyticsFixture) private var fixture
    @Environment(\.analyticsRefresh) private var refreshSignal
    @ObservedObject private var palette = AgentColors.shared
    @State private var today: AnalyticsSnapshot?
    @State private var problem: String?
    private func query(_ days: Int) -> AnalyticsQuery {
        .init(days: days, agents: agents, dimension: "agent", basis: "recorded", scope: .all)
    }

    var body: some View {
        let daily = fixture ?? today
        let total = daily?.summary.first { $0.basis == "recorded" }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            MiniDonut(parts: (daily?.rows ?? []).compactMap { row in
                                guard row.basis == "recorded", let amount = row.value("tokens_total"),
                                      let brand = row.agent.flatMap(Brand.init(rawValue:)) else { return nil }
                                return (amount, brand.accent)
                            })
                            Text(L("analytics.today")).font(.headline)
                            Image(systemName: "arrow.up.right").font(.caption)
                        }
                        Text(total?.value("tokens_total").map(Fmt.tokens) ?? "—")
                            .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                        Text("\(L("analytics.recorded")) · \(L("v3.tokens"))").font(.caption).foregroundStyle(Theme.ink3)
                        if let cost = total?.value("api_equivalent_usd") {
                            Text(String(format: "≈ $%.2f", cost)).font(.caption)
                                .help(L("analytics.equivalent"))
                        }
                        if let problem {
                            Text(L(problem)).font(.caption).foregroundStyle(Theme.warn)
                        } else if daily?.status == "partial" || total?.quality["tokens_total"] == "partial" {
                            Text(L("analytics.indexing")).font(.caption).foregroundStyle(Theme.ink3)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("v3.viewUsage"))
                Divider()
                quota().frame(maxWidth: .infinity, alignment: .top)
            }.fixedSize(horizontal: false, vertical: true)
        }.task(id: "\(active)|\(refreshSignal)") {
            guard active, fixture == nil, !agents.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    let day: AnalyticsSnapshot = try await APIClient.shared.get("/api/analytics", query: query(1).parameters())
                    try Task.checkCancellation()
                    today = day; problem = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    problem = (error as? APIError).map { if case .http(503) = $0 { return "analytics.indexing" }; return "common.opFailed" } ?? "common.opFailed"
                }
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            }
        }
    }
}
