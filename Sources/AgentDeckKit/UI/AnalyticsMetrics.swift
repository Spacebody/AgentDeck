import SwiftUI

struct AnalyticsMetrics: View {
    let slice: AnalyticsSlice
    let color: Color
    var primary = false
    private let measures = ["calls", "latency_ms", "ttft_ms", "speed_output_tps"]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(slice.value("tokens_total").map(Fmt.tokens) ?? "—")
                    .font(.system(size: primary ? 29 : 18, weight: .semibold)).monospacedDigit()
                Text(L("v3.tokens")).font(.caption).foregroundStyle(Theme.ink3)
                Spacer()
                VStack(alignment: .trailing) {
                    Text(L("analytics.equivalent")).foregroundStyle(Theme.ink3)
                    Text(slice.value("api_equivalent_usd").map { String(format: "≈ $%.2f", $0) } ?? L("v3.unavailable"))
                }.font(.caption).foregroundStyle(Theme.ink2)
            }
            if let cost = slice.value("cost_usd") {
                Text("\(L("analytics.actual"))  \(String(format: "$%.2f", cost))").font(.caption)
            }
            if let subtotal = slice.subtotal("tokens_total") {
                Text(L("analytics.known", ["n": Fmt.tokens(subtotal)])).font(.caption)
            }
            if let subtotal = slice.subtotal("cost_usd") {
                Text(L("analytics.known", ["n": String(format: "≈ $%.2f", subtotal)])).font(.caption)
            }
            if !slice.composition.isEmpty {
                let parts = slice.composition
                let sum = parts.reduce(0) { $0 + $1.1 }
                let denominator = max(sum, slice.value("tokens_total") ?? sum)
                if denominator > 0 {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(parts, id: \.0) { key, value in
                                Rectangle().fill(ink(key)).frame(width: geometry.size.width * value / denominator)
                            }
                            Spacer(minLength: 0)
                        }
                    }.frame(height: 5).background(Theme.edge).clipShape(Capsule()).accessibilityHidden(true)
                }
                TrendLegendLayout {
                    ForEach(parts, id: \.0) { key, value in
                        Label {
                            Text("\(L("analytics." + key))  \(Fmt.tokens(value))")
                        } icon: { Circle().fill(ink(key)).frame(width: 6, height: 6) }
                    }
                    if let total = slice.value("tokens_total"), total > sum {
                        Text("\(L("analytics.unsplit"))  \(Fmt.tokens(total - sum))")
                    }
                }.font(.caption).foregroundStyle(Theme.ink2)
            }
            if let reasoning = slice.value("reasoning_output_tokens") {
                Text(L("analytics.reasoning", ["n": Fmt.tokens(reasoning)])).font(.caption).foregroundStyle(Theme.ink3)
            }
            if slice.value("input_uncached_tokens") == nil, let input = slice.value("input_tokens") {
                Text(L("analytics.reportedInput", ["n": Fmt.tokens(input)])).font(.caption).foregroundStyle(Theme.ink3)
            }
            TrendLegendLayout {
                ForEach(measures, id: \.self) { key in
                    if let value = slice.value(key) ?? slice.subtotal(key) {
                        Text(measureText(key, value))
                            .monospacedDigit()
                    }
                }
            }.font(.caption)
            if slice.quality["tokens_total"] != "complete" || slice.basis == "sampled" {
                Text(L(slice.basis == "sampled" ? "analytics.sampleNote" : "analytics.incomplete"))
                    .font(.caption).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func measureText(_ key: String, _ value: Double) -> String {
        var text = "\(L("analytics." + key))  \(value.formatted(.number.precision(.fractionLength(0...1))))"
        if slice.quality[key] == "partial" { text += " · " + L("analytics.partial") }
        if let sampleKey = ["latency_ms": "latency_samples", "ttft_ms": "ttft_samples",
                            "speed_output_tps": "speed_samples"][key],
           let n = slice.value(sampleKey) {
            text += " · " + L("analytics.samples", ["n": n.formatted()])
        }
        return text
    }

    private func ink(_ key: String) -> Color {
        switch key {
        case "input_uncached_tokens": return color
        case "output_tokens": return .green
        case "cache_write_tokens": return .orange
        default: return .secondary
        }
    }
}

struct AnalyticsTrend: View {
    let samples: [AnalyticsSlice]
    let query: AnalyticsQuery
    let color: Color

    var body: some View {
        let values = buckets
        if values.contains(where: { $0.1 != nil }) {
            VStack(spacing: 4) {
                Canvas { context, size in
                    let peak = max(1, values.compactMap(\.1).max() ?? 1)
                    let dx = size.width / CGFloat(max(1, values.count))
                    for fraction in [0.0, 0.5, 1.0] {
                        var rule = Path()
                        rule.move(to: CGPoint(x: 0, y: fraction * size.height))
                        rule.addLine(to: CGPoint(x: size.width, y: fraction * size.height))
                        context.stroke(rule, with: .color(Theme.edge), lineWidth: 0.5)
                    }
                    var previous: CGPoint?
                    for (i, bucket) in values.enumerated() {
                        guard let value = bucket.1 else { previous = nil; continue }
                        let point = CGPoint(x: (CGFloat(i) + 0.5) * dx, y: 3 + (size.height - 6) * (1 - value / peak))
                        if let previous {
                            var p = Path(); p.move(to: previous)
                            let mid = (previous.x + point.x) / 2
                            p.addCurve(to: point, control1: CGPoint(x: mid, y: previous.y), control2: CGPoint(x: mid, y: point.y))
                            context.stroke(p, with: .color(color), lineWidth: 1.6)
                        }
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(color))
                        previous = point
                    }
                }.frame(height: 58)
                HStack { Text(values.first?.0 ?? ""); Spacer(); Text(values.count > 1 ? values.last?.0 ?? "" : "") }
                    .font(.caption2).foregroundStyle(Theme.ink3)
            }.accessibilityElement(children: .ignore).accessibilityLabel(L("v3.daily"))
                .accessibilityValue(values.map { "\($0.0): \($0.1.map(Fmt.tokens) ?? "—")" }.joined(separator: ", "))
        }
    }

    private var buckets: [(String, Double?)] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: query.timezone) ?? .current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.calendar = cal; fmt.timeZone = cal.timeZone; fmt.dateFormat = "yyyy-MM-dd"
        var values: [(String, Double?)] = []
        var date = Date(timeIntervalSince1970: Double(query.start))
        while date.timeIntervalSince1970 < Double(query.end), values.count < 31 {
            let key = fmt.string(from: date)
            values.append((key, samples.first { $0.day == key }?.value("tokens_total")))
            guard let next = cal.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return values
    }
}
