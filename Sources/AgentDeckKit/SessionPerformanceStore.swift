import Foundation
import SwiftUI

struct SessionPerformanceRequest: Encodable, Hashable {
    let tool: String
    let account: String
    let source: String
    let id: String
    var key: String { "\(tool)|\(account)|\(source)|\(id)" }
}

extension SessionItem {
    var performanceRequest: SessionPerformanceRequest {
        .init(tool: tool, account: accountId ?? "default", source: source ?? "transcript", id: id)
    }
}

extension ActiveSession {
    var performanceRequest: SessionPerformanceRequest {
        .init(tool: tool, account: "*", source: source ?? "transcript", id: id ?? "")
    }
}

struct SessionPerformance: Decodable, Equatable {
    let state: String
    var mode: String?
    var tokensPerSecond: Double?
    var outputTokens: Double?
    var durationSecs: Double?
    var startedAt: Double?
    var sampledAt: Double?

    var rate: Double? {
        guard mode == "turn_average", state == "active" || state == "completed",
              let rate = tokensPerSecond, rate.isFinite, rate >= 0 else { return nil }
        return rate
    }

    var label: String? {
        if let rate {
            let formatted = rate < 1000 ? String(format: "%.1f", rate) : Fmt.tokens(rate)
            return L(state == "completed" ? "speed.last" : "speed.current", ["rate": formatted])
        }
        switch state {
        case "sampling": return L("speed.sampling")
        case "stale": return L("speed.stale")
        default: return nil
        }
    }
}

struct SessionPerformanceResponse: Decodable {
    let ok: Bool
    let metrics: [String: SessionPerformance]
}

@MainActor
final class SessionPerformanceStore: ObservableObject {
    @Published var metrics: [String: SessionPerformance] = [:]
    private let api: APIClient
    private var task: Task<Void, Never>?
    private var owners: Set<String> = []
    private var generation = 0

    init(api: APIClient = .shared) { self.api = api }
    func isVisible(_ owner: String) -> Bool { owners.contains(owner) }

    func setVisible(_ owner: String, _ visible: Bool,
                    requests: @escaping () -> [SessionPerformanceRequest]) {
        if visible { owners.insert(owner) } else { owners.remove(owner) }
        guard !owners.isEmpty else {
            generation += 1
            task?.cancel(); task = nil
            metrics = [:]
            return
        }
        guard task == nil else { return }
        generation += 1
        let current = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, current == self.generation else { return }
                let items = Array(Set(requests())).sorted { $0.key < $1.key }
                var next: [String: SessionPerformance] = [:]
                // Keep GET request lines below HTTPServer's limit, even for a
                // large configured page size and non-ASCII identifiers.
                for offset in stride(from: 0, to: items.count, by: 32) {
                    let batch = Array(items[offset..<min(offset + 32, items.count)])
                    guard let data = try? JSONEncoder().encode(batch),
                          let json = String(data: data, encoding: .utf8) else { continue }
                    let response: SessionPerformanceResponse? = try? await self.api.get(
                        "/api/session-performance", query: ["sessions": json])
                    if let response, response.ok { next.merge(response.metrics) { _, new in new } }
                }
                guard !Task.isCancelled, current == self.generation else { return }
                if next != self.metrics { self.metrics = next }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct PerformanceStoreKey: EnvironmentKey {
    static let defaultValue: SessionPerformanceStore? = nil
}

extension EnvironmentValues {
    var sessionPerformanceStore: SessionPerformanceStore? {
        get { self[PerformanceStoreKey.self] }
        set { self[PerformanceStoreKey.self] = newValue }
    }
}

struct SessionSpeedView: View {
    let request: SessionPerformanceRequest
    var expanded = false
    @Environment(\.sessionPerformanceStore) private var store

    var body: some View {
        if let store {
            SessionSpeedContent(store: store, key: request.key, expanded: expanded)
        }
    }
}

private struct SessionSpeedContent: View {
    @ObservedObject var store: SessionPerformanceStore
    let key: String
    let expanded: Bool

    var body: some View {
        let metric = store.metrics[key]
        if expanded {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric?.label ?? L("speed.unavailable"))
                    .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                if let tokens = metric?.outputTokens, let duration = metric?.durationSecs,
                   tokens.isFinite, duration.isFinite {
                    Text(L("speed.details", ["tokens": String(format: "%.0f", tokens),
                                             "duration": String(format: "%.1f s", duration)]))
                }
                if let stamp = metric?.sampledAt, stamp.isFinite {
                    Text(L("speed.sampled", ["time": Fmt.relative(Date(timeIntervalSince1970: stamp))]))
                }
                Text(L("speed.basis")).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 9.5)).foregroundStyle(Theme.ink2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        } else if let label = metric?.label {
            Text(label).font(.system(size: 9.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(Theme.ink2)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(width: 126, alignment: .leading)
                .help(L("speed.basis"))
                .transaction { $0.animation = nil }
        }
    }
}
