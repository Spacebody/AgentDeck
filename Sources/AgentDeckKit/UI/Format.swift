// AgentDeck v2 — 格式化助手。对应 index.html 的 cd()/fmtDur()/rel()/fmtTokens()/winLabel()。
// 文案经 L() 走三语表（I18N.swift）。
import Foundation

enum Fmt {
    /// 重置倒计时（对应 cd(iso, compact)）。compact=true 时 >0h 丢分钟（副窗口空间小）。
    static func countdown(_ date: Date?, compact: Bool = false, now: Date = Date()) -> String {
        guard let date else { return "" }
        let ms = date.timeIntervalSince(now)
        if ms <= 0 { return L("cd.reset") }
        let h = Int(ms / 3600), m = Int(ms.truncatingRemainder(dividingBy: 3600) / 60)
        if h > 48 { return L("cd.inDays", ["n": "\(h / 24)"]) }
        if h > 0 { return compact ? L("cd.inH", ["h": "\(h)"]) : L("cd.inHM", ["h": "\(h)", "m": "\(m)"]) }
        return L("cd.inM", ["m": "\(m)"])
    }

    /// 半宽额度卡圆环下方使用的极简倒计时；上下文已明确是重置时间。
    static func countdownToken(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return L("cd.reset") }
        let hours = Int(seconds / 3600)
        if hours > 48 { return "\(hours / 24)d" }
        if hours > 0 { return "\(hours)h" }
        return "\(max(0, Int(seconds / 60)))m"
    }

    /// 秒 → 时长（对应 fmtDur）。活跃会话运行时长 / 预测耗尽复用。
    static func duration(_ secs: Double) -> String {
        let s = max(0, Int(secs.rounded()))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return L("dur.dh", ["d": "\(d)", "h": "\(h)"]) }
        if h > 0 { return L("dur.hm", ["h": "\(h)", "m": "\(m)"]) }
        return L("dur.m", ["m": "\(m)"])
    }

    /// 相对时间（对应 rel(ts)）。
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return L("time.justNow") }
        if s < 3600 { return L("time.minAgo", ["n": "\(Int(s / 60))"]) }
        if s < 86400 { return L("time.hourAgo", ["n": "\(Int(s / 3600))"]) }
        return L("time.dayAgo", ["n": "\(Int(s / 86400))"])
    }

    /// 按 5h 窗口消耗速率预测耗尽（对应 burnHint）。仅 8%~100% 间给提示。
    static func burnHint(_ w: QuotaWindow?, now: Date = Date()) -> String {
        guard let w, let reset = w.resetsAt?.date, w.usedPercent >= 8, w.usedPercent < 100 else { return "" }
        let winSec = 5.0 * 3600
        let el = now.timeIntervalSince(reset.addingTimeInterval(-winSec))
        guard el > 0 else { return "" }
        let burnSec = el / w.usedPercent * 100 - el   // 距 100% 还能跑多久
        if burnSec > reset.timeIntervalSince(now) { return L("quota.burnSafe") }
        return L("quota.burnWarn", ["dur": duration(burnSec)])
    }

    /// 解析 ISO8601 时间串（含/不含小数秒），用于 Codex sampled_at。
    static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
    }

    /// token 数缩写（对应 fmtTokens）。
    static func tokens(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.0fK", n / 1e3) }
        return String(Int(n))
    }
}

extension QuotaWindow {
    /// 窗口显示名（对应 winLabel）：先按稳定 id 本地化（win.<id>），win_<分钟> 走模板，
    /// 未知 id 回退后端 label。
    var displayLabel: String {
        let key = "win.\(id)"
        let fixed = L(key)
        if fixed != key { return fixed }
        let rawLabel = label ?? id
        let baseLabel: String = {
            guard let separator = rawLabel.range(of: " · ", options: .backwards) else {
                return rawLabel
            }
            let suffix = rawLabel[separator.upperBound...]
            guard suffix.hasSuffix("m"), Int(suffix.dropLast()) != nil else {
                return rawLabel
            }
            return String(rawLabel[..<separator.lowerBound])
        }()
        if id.hasPrefix("five_hour_") {
            return L("quota.namedFiveHour", ["name": baseLabel])
        }
        if id.hasPrefix("seven_day_") {
            return L("quota.namedWeekly", ["name": baseLabel])
        }
        if id.hasPrefix("win_"), let mins = Int(id.dropFirst(4)) {
            return L("quota.winMins", ["n": "\(mins)"])
        }
        return baseLabel
    }

    /// 该窗口的窗口长度（秒），用于「重置进度微条」。对应 winLen 映射。
    var windowSeconds: Double? {
        QuotaWindowPolicy.durationSeconds(for: id)
    }

    /// 重置进度（0~1，已流逝占比）。对应 resetBar 的 elapsed 计算。
    func resetElapsed(now: Date = Date()) -> Double? {
        guard let len = windowSeconds, let reset = resetsAt?.date else { return nil }
        let remain = reset.timeIntervalSince(now)
        return min(1, max(0, 1 - remain / len))
    }
}

/// Shared quota-window ordering for cards and menu-bar summaries.
public enum QuotaWindowPolicy {
    public static func isGeneral(_ id: String) -> Bool {
        if ["five_hour", "seven_day", "primary", "secondary", "total", "plan"].contains(id) {
            return true
        }
        return id.hasPrefix("win_") && Int(id.dropFirst(4)) != nil
    }

    public static func durationSeconds(for id: String) -> Double? {
        if id == "five_hour" || id.hasPrefix("five_hour_") { return 5 * 3600 }
        if id == "seven_day" || id.hasPrefix("seven_day_") { return 7 * 86400 }
        if id.hasPrefix("win_"), let mins = Int(id.dropFirst(4)) {
            return Double(mins) * 60
        }
        return nil
    }

    /// Prefer general account limits; only fall back to model-specific limits when
    /// no general window exists. Within the same tier, use the shortest period.
    public static func preferredPrimaryIndex(ids: [String]) -> Int? {
        guard !ids.isEmpty else { return nil }
        let all = Array(ids.indices)
        let general = all.filter { isGeneral(ids[$0]) }
        let candidates = general.isEmpty ? all : general
        return candidates.min { lhs, rhs in
            let left = durationSeconds(for: ids[lhs]) ?? .greatestFiniteMagnitude
            let right = durationSeconds(for: ids[rhs]) ?? .greatestFiniteMagnitude
            return left == right ? lhs < rhs : left < right
        }
    }

    public static func preferredIndex(ids: [String], usedPercents: [Double?],
                                      dimension: String) -> Int? {
        guard ids.count == usedPercents.count, !ids.isEmpty else { return nil }
        switch dimension {
        case "max":
            return ids.indices.compactMap { index in
                usedPercents[index].map { (index, $0) }
            }.max { $0.1 < $1.1 }?.0
        case "weekly":
            let weekly = ids.indices.filter {
                durationSeconds(for: ids[$0]) == 7 * 86400
            }
            return weekly.first(where: { isGeneral(ids[$0]) })
                ?? weekly.first
                ?? preferredPrimaryIndex(ids: ids)
        default:
            return preferredPrimaryIndex(ids: ids)
        }
    }
}
