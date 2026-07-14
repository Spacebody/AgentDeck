// AgentDeck v2 — 概览页数据模型。对应 /api/usage、/api/active、/api/events。
// 解码用 .convertFromSnakeCase（snake→camel）；字典键（日期/模型名）无下划线不受影响。
import Foundation

// MARK: - /api/usage（今日摘要 + 24h 曲线 + 近7天柱 + 项目 Top 共用，对应 api_usage 行 2157）
struct UsageResponse: Decodable {
    let days: [String]                            // 日期键，末位=今天
    let claudeDaily: [String: [String: [Double]]] // claude_daily: 日 → 模型 → [token 分量]
    let codexDaily: [String: Double]              // codex_daily: 日 → token
    let costDaily: [String: Double]               // cost_daily: 日 → 等值美元
    let hourly: [HourBucket]                       // 覆盖 48h，每小时 c=claude x=codex
    let projects7d: [ProjectUsage]?               // projects_7d
    // 成本汇总（用量卡头部 + 口径弹层拆分）
    let cost7d: Double?
    let cost30d: Double?
    let claudeCost7d: Double?
    let claudeCost30d: Double?
    let codexCost7d: Double?
    let codexCost30d: Double?
    let coverage: UsageCoverage?
}

struct HourBucket: Decodable { let ts: Double; let c: Double; let x: Double }
struct ProjectUsage: Decodable { let name: String; let cwd: String; let tokens: Double; let cost: Double }
struct UsageCoverage: Decodable {
    let codexFiles: Int
    let codexMissingUsageFiles: Int
}

// MARK: - /api/active（活跃会话，对应 api_active 行 1244）
struct ActiveResponse: Decodable { let active: [ActiveSession] }
struct ActiveSession: Decodable {
    let tool: String
    let cwd: String?
    let project: String?
    let host: String?           // "app" 时显示 App 标
    let runtimeSecs: Double?    // runtime_secs（优先）
    let runtime: String?        // 后端预格式化兜底
    let status: String?         // busy / idle / ""
    let id: String?
    let pid: Int?
}

// MARK: - /api/events（最近完成事件流，对应 api_events 行 1591）
struct EventsResponse: Decodable { let events: [DoneEvent] }
struct DoneEvent: Decodable {
    let tool: String
    let title: String?
    let project: String?
    let ts: Double
    let session: String?
    let cwd: String?
}

// MARK: - 今日摘要派生（复刻 loadToday：按模型族聚合 + 24h 环比）
struct TodaySummary {
    enum Family: String, CaseIterable { case opus, sonnet, haiku, other, codex }
    var byFamily: [Family: Double] = [:]
    var totalTokens: Double = 0
    var costUSD: Double = 0
    var deltaPercent: Int?     // 近24h vs 前24h；nil=无对比基准

    /// 家族配色（FAM_COLORS）：opus/sonnet/haiku/other/codex。
    static func color(_ f: Family) -> UInt32 {
        switch f {
        case .opus:   return 0xe8744f
        case .sonnet: return 0x5f7de8
        case .haiku:  return 0x5fc78f
        case .other:  return 0x9a9aa5
        case .codex:  return 0x4fd1c5   // var(--codex-deep)
        }
    }

    init?(from u: UsageResponse, now: Date = Date()) {
        guard let today = u.days.last else { return nil }
        var fams: [Family: Double] = [:]
        for (model, parts) in (u.claudeDaily[today] ?? [:]) {
            let fam: Family = ["opus", "sonnet", "haiku"].first { model.hasPrefix($0) }
                .flatMap { Family(rawValue: $0) } ?? .other
            fams[fam, default: 0] += parts.reduce(0, +)
        }
        fams[.codex, default: 0] += u.codexDaily[today] ?? 0
        let tok = fams.values.reduce(0, +)
        guard tok > 0 else { return nil }
        // 环比：hourly 覆盖 48h，近 24h vs 前 24h
        let nowSec = now.timeIntervalSince1970
        var cur = 0.0, prev = 0.0
        for h in u.hourly { if h.ts >= nowSec - 86400 { cur += h.c + h.x } else { prev += h.c + h.x } }
        byFamily = fams
        totalTokens = tok
        costUSD = u.costDaily[today] ?? 0
        deltaPercent = prev > 0 ? Int(((cur - prev) / prev * 100).rounded()) : nil
    }
}
