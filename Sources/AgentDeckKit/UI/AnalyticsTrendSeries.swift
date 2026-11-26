import Foundation

struct AnalyticsTrendSeries {
    enum Sample: Equatable {
        case complete(Double), partial(Double?), missing, unknown

        var value: Double? {
            switch self {
            case let .complete(value): return value
            case let .partial(value): return value
            default: return nil
            }
        }

        var isComplete: Bool {
            if case .complete = self { return true }
            return false
        }
    }

    let days: [(date: String, sample: Sample)]

    init(samples: [AnalyticsSlice], query: AnalyticsQuery) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: query.timezone) ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var byDate: [String: Sample] = [:]
        for slice in samples where slice.basis == query.basis {
            guard let date = slice.day else { continue }
            if let value = slice.value("tokens_total") { byDate[date] = .complete(value) }
            else if slice.quality["tokens_total"] == "partial" { byDate[date] = .partial(slice.subtotal("tokens_total")) }
            else { byDate[date] = .unknown }
        }
        var result: [(String, Sample)] = []
        var date = Date(timeIntervalSince1970: Double(query.start))
        while date.timeIntervalSince1970 < Double(query.end) {
            let key = formatter.string(from: date)
            result.append((key, byDate[key] ?? .missing))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        days = result
    }

    func position(_ index: Int) -> Double {
        days.count > 1 ? Double(index) / Double(days.count - 1) : 0.5
    }

    var missingRanges: [String] {
        var ranges: [String] = []
        var i = 0
        while i < days.count {
            guard days[i].sample == .missing else { i += 1; continue }
            let first = i
            while i + 1 < days.count, days[i + 1].sample == .missing { i += 1 }
            let start = String(days[first].date.suffix(5))
            ranges.append(first == i ? start : start + "–" + days[i].date.suffix(5))
            i += 1
        }
        return ranges
    }

    func joinsPrevious(_ index: Int) -> Bool {
        index > 0 && days[index - 1].sample.isComplete && days[index].sample.isComplete
    }
}
