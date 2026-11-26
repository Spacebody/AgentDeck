import SwiftUI

extension AnalyticsSnapshot {
    static var sampledPreview: Self {
        let s = AnalyticsSlice(basis: "sampled", metrics: ["tokens_total": 3300, "input_uncached_tokens": nil,
                "input_tokens": 2400, "output_tokens": 900], quality: ["tokens_total": "complete", "input_tokens": "complete",
                "output_tokens": "complete", "input_uncached_tokens": "unknown"], knownSubtotals: nil,
                key: "unknown-model", label: nil)
        return Self(generation: "fixture:2", status: "ready", summary: [s], series: [], rows: [s], nextCursor: nil)
    }

    static var preview: Self { recordedPreview(todayOnly: false) }
    static var todayPreview: Self { recordedPreview(todayOnly: true) }

    private static func recordedPreview(todayOnly: Bool) -> Self {
        func slice(_ key: String, _ count: Double, basis: String = "recorded", day: String? = nil) -> AnalyticsSlice {
            let metrics: [String: Double?] = [
                "tokens_total": count, "output_tokens": count * 0.2,
                "input_uncached_tokens": count * 0.45, "cache_read_tokens": count * 0.3,
                "cache_write_tokens": count * 0.05, "reasoning_output_tokens": count * 0.07,
                "calls": 81, "latency_ms": 740, "speed_output_tps": 46.8, "cost_usd": nil,
                "api_equivalent_usd": 4.29 * count / 146_000,
            ]
            return AnalyticsSlice(basis: basis, metrics: metrics,
                                  quality: metrics.mapValues { $0 == nil ? "unknown" : "complete" },
                                  knownSubtotals: nil, day: day, key: key, label: Brand(rawValue: key)?.name,
                                  agent: Brand(rawValue: key)?.rawValue)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        let days = (0..<7).map { fmt.string(from: Calendar.current.date(byAdding: .day, value: $0 - 6, to: Date())!) }
        let daily = [12_000.0, 16_000, 14_500, 27_500, 19_000, 31_000, 26_000]
        if todayOnly {
            let day = slice("all", 26_000, day: days.last)
            return Self(generation: "fixture:today", status: "ready", summary: [day], series: [day],
                        rows: [slice("claude", 15_300), slice("codex", 8_600), slice("qoder", 2_100)], nextCursor: nil)
        }
        return Self(generation: "fixture:1", status: "ready",
                    summary: [slice("all", daily.reduce(0, +))],
                    series: zip(days, daily).map { slice("all", $0.1, day: $0.0) },
                    rows: [slice("claude", 86_000), slice("codex", 48_000), slice("qoder", 12_000)], nextCursor: nil)
    }
}

extension PreviewRender {
    public static func analyticsPNG(sampled: Bool = false, mode: String = "trend", noPerformance: Bool = false,
                                    gaps: Bool = false, scale: CGFloat = 2) -> Data? {
        let empty = AnalyticsSlice(basis: "recorded", metrics: ["tokens_total": 420, "speed_samples": 0],
                                   quality: ["tokens_total": "complete", "speed_samples": "complete"], knownSubtotals: nil)
        var fixture: AnalyticsSnapshot = noPerformance
            ? .init(generation: "fixture:empty-performance", status: "ready", summary: [empty], series: [], rows: [], nextCursor: nil)
            : (sampled ? .sampledPreview : .preview)
        if gaps {
            fixture = .init(generation: fixture.generation, status: fixture.status, summary: fixture.summary,
                            series: fixture.series.enumerated().compactMap { (3...4).contains($0.offset) ? nil : $0.element },
                            rows: fixture.rows, nextCursor: nil)
        }
        return png(AnalyticsDashboard(agents: sampled ? ["antigravity"] : ["claude", "codex", "qoder"],
                               fixture: fixture, days: .constant(noPerformance ? 1 : 7), initialBasis: sampled ? "sampled" : "recorded",
                               initialMode: AnalyticsMode(rawValue: mode) ?? .trend)
            .padding(16).frame(width: 380).background(Color(hex: 0x17181a))
            .environment(\.colorScheme, .dark), scale: scale)
    }
}
