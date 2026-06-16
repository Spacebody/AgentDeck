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
        if id.hasPrefix("win_"), let mins = Int(id.dropFirst(4)) {
            return L("quota.winMins", ["n": "\(mins)"])
        }
        return label ?? id
    }

    /// 该窗口的窗口长度（秒），用于「重置进度微条」。对应 winLen 映射。
    var windowSeconds: Double? {
        switch id {
        case "five_hour": return 5 * 3600
        case "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps":
            return 7 * 86400
        default:
            if id.hasPrefix("win_"), let mins = Int(id.dropFirst(4)) { return Double(mins) * 60 }
            return nil
        }
    }

    /// 重置进度（0~1，已流逝占比）。对应 resetBar 的 elapsed 计算。
    func resetElapsed(now: Date = Date()) -> Double? {
        guard let len = windowSeconds, let reset = resetsAt?.date else { return nil }
        let remain = reset.timeIntervalSince(now)
        return min(1, max(0, 1 - remain / len))
    }
}
