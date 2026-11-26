import SwiftUI

extension AnalyticsSlice {
    static let performanceKeys = ["calls", "latency_ms", "ttft_ms", "speed_output_tps"]

    var measuredPerformanceKeys: [String] {
        Self.performanceKeys.filter { value($0) != nil || subtotal($0) != nil }
    }

    var unclassifiedTokens: Double? {
        // A visible partial subtotal would overlap a remainder based on complete parts alone.
        guard let total = value("tokens_total"),
              !Self.components.contains(where: { quality[$0] == "partial" }) else { return nil }
        let remainder = total - composition.reduce(0) { $0 + $1.1 }
        return remainder > 0 ? remainder : nil
    }
}

struct AnalyticsMetrics: View {
    let slice: AnalyticsSlice
    let color: Color
    let mode: AnalyticsMode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .trend: trend
            case .composition: composition
            case .performance: performance
            }
            if slice.basis == "sampled" {
                Text(L("analytics.sampleNote")).font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(slice.value("tokens_total").map(Fmt.tokens) ?? "—")
                    .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    .fixedSize().accessibilityLabel(L("v3.tokens"))
                    .accessibilityValue(slice.value("tokens_total").map(Fmt.tokens) ?? "—")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 6) {
                    moneyRow("api_equivalent_usd", "analytics.equivalent")
                    if slice.value("cost_usd") != nil || slice.subtotal("cost_usd") != nil {
                        moneyRow("cost_usd", "analytics.actual")
                    }
                }
            }
            if let known = slice.subtotal("tokens_total") {
                Text(L("analytics.known", ["n": Fmt.tokens(known)])).font(.system(size: 13))
            } else if slice.quality["tokens_total"] != "complete" {
                Text(L("analytics.incomplete")).font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
        }
    }

    private func moneyRow(_ key: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            metricLabel(L(label), key: key, tint: color).font(.system(size: 13)).foregroundStyle(Theme.ink2)
            Text(display(key) { $0.formatted(.currency(code: "USD")) })
                .monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.system(size: 16, weight: .medium))
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 14) {
            let total = slice.value("tokens_total")
            ForEach(AnalyticsSlice.components, id: \.self) { key in
                componentRow(key, L("analytics." + key), text: display(key, format: Fmt.tokens),
                             value: slice.value(key), total: total, ink: ink(key))
            }
            if let remainder = slice.unclassifiedTokens {
                componentRow("unsplit", L("analytics.unsplit"), text: Fmt.tokens(remainder),
                             value: remainder, total: total, ink: Theme.ink3)
            }
            Divider()
            if slice.value("input_uncached_tokens") == nil, let input = slice.value("input_tokens") {
                metricLabel(L("analytics.reportedInput", ["n": Fmt.tokens(input)]), key: "input_uncached_tokens", tint: color)
                    .font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
            metricLabel(L("analytics.reasoning", ["n": display("reasoning_output_tokens", format: Fmt.tokens)]),
                        key: "reasoning_output_tokens", tint: color)
                .font(.system(size: 13)).foregroundStyle(Theme.ink2)
        }
    }

    private func componentRow(_ key: String, _ name: String, text: String, value: Double?, total: Double?, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                metricLabel(name, key: key, tint: ink)
                Spacer(minLength: 8)
                Text(text).monospacedDigit().multilineTextAlignment(.trailing)
            }
            if let value, let total, total > 0 {
                GeometryReader { box in
                    Capsule().fill(Theme.edge).overlay(alignment: .leading) {
                        Capsule().fill(ink).frame(width: box.size.width * min(max(0, value / total), 1))
                    }
                }.frame(height: 4).accessibilityHidden(true)
            }
        }.font(.system(size: 15, weight: .medium)).accessibilityElement(children: .combine)
    }

    @ViewBuilder private var performance: some View {
        let keys = slice.measuredPerformanceKeys
        if keys.isEmpty {
            Label(L("analytics.noPerformance"), systemImage: "gauge.with.dots.needle.0percent")
                .font(.callout).foregroundStyle(Theme.ink2).padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 260), spacing: 20,
                                             alignment: .topLeading)], alignment: .leading, spacing: 24) {
                    ForEach(keys, id: \.self) { measure($0) }
                }.padding(.vertical, 6)
                let missing = AnalyticsSlice.performanceKeys.filter { !keys.contains($0) }
                if !missing.isEmpty {
                    Divider()
                    Text(L("analytics.unreportedMetrics", ["items": missing.map { L("analytics." + $0) }
                        .formatted(.list(type: .and).locale(Locale(identifier: I18N.locale)))]))
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
            }
        }
    }

    private func measure(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            metricLabel(L("analytics." + key), key: key, tint: color)
                .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink2)
            Text(performanceValue(key)).font(.system(size: 22, weight: .semibold)).monospacedDigit()
            if let note = performanceNote(key) {
                Text(note).font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }

    private func performanceValue(_ key: String) -> String {
        guard let value = slice.value(key) ?? slice.subtotal(key) else { return "—" }
        let number = value.formatted(.number.precision(.fractionLength(0...1)))
        switch key {
        case "latency_ms", "ttft_ms": return number + " ms"
        case "speed_output_tps": return number + " tok/s"
        default: return L("analytics.callCount", ["n": number])
        }
    }

    private func metricLabel(_ title: String, key: String, tint: Color) -> some View {
        let symbol: String
        switch key {
        case "input_uncached_tokens": symbol = "arrow.down"
        case "output_tokens": symbol = "arrow.up"
        case "cache_read_tokens": symbol = "tray.and.arrow.up"
        case "cache_write_tokens": symbol = "tray.and.arrow.down"
        case "reasoning_output_tokens": symbol = "brain"
        case "api_equivalent_usd": symbol = "dollarsign.circle"
        case "cost_usd": symbol = "creditcard"
        case "calls": symbol = "arrow.left.arrow.right"
        case "latency_ms": symbol = "clock"
        case "ttft_ms": symbol = "stopwatch"
        case "speed_output_tps": symbol = "speedometer"
        default: symbol = "square.grid.2x2"
        }
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint).frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title)
        }
    }

    private func performanceNote(_ key: String) -> String? {
        let quality = slice.quality[key] == "complete" ? nil : qualityText(key)
        let sampleKey = ["latency_ms": "latency_samples", "ttft_ms": "ttft_samples",
                         "speed_output_tps": "speed_samples"][key]
        if let sampleKey, let n = slice.value(sampleKey) {
            let samples = L("analytics.samples", ["n": n.formatted()])
            let waitNote = key == "speed_output_tps" && (slice.value("speed_wait_samples") ?? 0) > 0
                ? L("analytics.speedIncludesWait") : nil
            return [samples, quality, waitNote].compactMap { $0 }.joined(separator: " · ")
        }
        return quality
    }

    private func qualityText(_ key: String) -> String {
        switch slice.quality[key] {
        case "complete": return L("analytics.complete")
        case "partial": return L("analytics.partial")
        default: return L("analytics.incomplete")
        }
    }

    private func display(_ key: String, format: (Double) -> String) -> String {
        if let value = slice.value(key) { return format(value) }
        if let known = slice.subtotal(key) { return L("analytics.known", ["n": format(known)]) }
        return "—"
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
        let series = AnalyticsTrendSeries(samples: samples, query: query)
        let peak = series.days.compactMap(\.sample.value).max()
        VStack(alignment: .leading, spacing: 4) {
            if let peak {
                Canvas { context, size in
                    let inset = 3.5
                    let width = max(0, size.width - 2 * inset)
                    let height = max(0, size.height - 2 * inset)
                    for fraction in [0.0, 0.5, 1.0] {
                        let y = inset + fraction * height
                        var rule = Path()
                        rule.move(to: CGPoint(x: inset, y: y))
                        rule.addLine(to: CGPoint(x: inset + width, y: y))
                        context.stroke(rule, with: .color(Theme.edge), lineWidth: 0.5)
                    }
                    var previous: CGPoint?
                    for (i, day) in series.days.enumerated() {
                        guard let value = day.sample.value else { previous = nil; continue }
                        let point = CGPoint(x: inset + width * series.position(i),
                                            y: inset + height * (1 - value / max(1, peak)))
                        if series.joinsPrevious(i), let previous {
                            var path = Path(); path.move(to: previous)
                            let mid = (previous.x + point.x) / 2
                            path.addCurve(to: point, control1: CGPoint(x: mid, y: previous.y),
                                          control2: CGPoint(x: mid, y: point.y))
                            context.stroke(path, with: .color(color), lineWidth: 1.6)
                        }
                        let radius = day.sample.isComplete ? 2.0 : 2.7
                        let dot = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                         width: 2 * radius, height: 2 * radius))
                        if day.sample.isComplete { context.fill(dot, with: .color(color)) }
                        else { context.stroke(dot, with: .color(color), lineWidth: 1.4) }
                        previous = point
                    }
                }.frame(height: 104)
                .accessibilityElement(children: .ignore).accessibilityLabel(L("v3.daily"))
                .accessibilityValue(series.days.map { "\($0.date): \(description($0.sample))" }.joined(separator: ", "))
                HStack {
                    Text(series.days.first?.date ?? "")
                    Spacer()
                    if series.days.count > 1 { Text(series.days.last?.date ?? "") }
                }.accessibilityHidden(true)
                if series.days.contains(where: { !$0.sample.isComplete && $0.sample.value != nil }) {
                    Text(L("analytics.trendPartial"))
                }
            } else if series.days.allSatisfy({ $0.sample == .missing }) {
                Text(L("analytics.trendEmpty"))
            }
            if series.days.contains(where: { $0.sample == .unknown || $0.sample == .partial(nil) }) {
                Text(L("analytics.incomplete"))
            }
            let gaps = series.missingRanges
            if !gaps.isEmpty {
                Text(L("analytics.trendGaps", ["dates": gaps.joined(separator: ", ")]))
            }
        }.font(.system(size: 13)).foregroundStyle(Theme.ink2)
    }

    private func description(_ sample: AnalyticsTrendSeries.Sample) -> String {
        switch sample {
        case let .complete(value): return Fmt.tokens(value)
        case let .partial(value): return value.map { L("analytics.known", ["n": Fmt.tokens($0)]) } ?? L("analytics.partial")
        case .unknown: return L("analytics.incomplete")
        case .missing: return L("analytics.noSamples")
        }
    }
}
