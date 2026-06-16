// AgentDeck v2 — 格式化助手。对应 index.html 的 cd()/fmtDur()/rel()/fmtTokens()。
// 文案暂用中文字面量（里程碑期）；完整三语表在 #3「App 状态 store + i18n」统一接管。
import Foundation

enum Fmt {
    /// 重置倒计时（对应 cd(iso, compact)）。compact=true 时 >0h 丢分钟（副窗口空间小）。
    static func countdown(_ date: Date?, compact: Bool = false, now: Date = Date()) -> String {
        guard let date else { return "" }
        let ms = date.timeIntervalSince(now)
        if ms <= 0 { return "已重置" }
        let h = Int(ms / 3600), m = Int(ms.truncatingRemainder(dividingBy: 3600) / 60)
        if h > 48 { return "\(h / 24) 天后" }
        if h > 0 { return compact ? "\(h)h 后" : "\(h)h \(m)m 后" }
        return "\(m)m 后"
    }

    /// 秒 → 时长（对应 fmtDur）。活跃会话运行时长 / 预测耗尽复用。
    static func duration(_ secs: Double) -> String {
        let s = max(0, Int(secs.rounded()))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)天 \(h)小时" }
        if h > 0 { return "\(h)小时 \(m)分" }
        return "\(m)分"
    }

    /// 相对时间（对应 rel(ts)）。
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86400)) 天前"
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
    /// 窗口显示名（对应 winLabel）：里程碑期直接用后端 label（已是中文）；
    /// 完整 win.<id> 三语覆盖在 #3 接管。
    var displayLabel: String { label ?? id }

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
