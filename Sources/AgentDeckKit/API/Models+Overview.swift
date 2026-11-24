// AgentDeck v2 — 概览页数据模型。对应 /api/usage、/api/active、/api/events。
// 解码用 .convertFromSnakeCase（snake→camel）；字典键（日期/模型名）无下划线不受影响。
import Foundation

// MARK: - /api/usage（今日摘要 + 24h 曲线 + 近7天柱 + 项目 Top 共用，对应 api_usage 行 2157）
struct UsageResponse: Decodable {
    let days: [String]                            // 日期键，末位=今天
    let claudeDaily: [String: [String: [Double]]] // claude_daily: 日 → 模型 → [token 分量]
    let codexDaily: [String: Double]              // codex_daily: 日 → token
    let qoderDaily: [String: Double]?              // qoder_daily: 日 → token（旧 daemon 可缺失）
    let costDaily: [String: Double]               // cost_daily: 日 → 等值美元
    var antigravityDaily: [String: Double]? = nil
    var qoderCnDaily: [String: Double]? = nil
    let hourly: [HourBucket]                       // 覆盖 48h，每小时 c=claude x=codex q=qoder
    let projects7d: [ProjectUsage]?               // projects_7d
    var projectsAll7d: [ProjectUsage]? = nil
    var projectsAll30d: [ProjectUsage]? = nil
    var costsByAgentDaily: [String: [String: Double?]]? = nil
    // 成本汇总（用量卡头部 + 口径弹层拆分）
    let cost7d: Double?
    let cost30d: Double?
    let claudeCost7d: Double?
    let claudeCost30d: Double?
    let codexCost7d: Double?
    let codexCost30d: Double?
    let coverage: UsageCoverage?

    func hasAntigravitySamples(on days: [String]) -> Bool {
        coverage?.antigravityAvailable != false && days.contains { antigravityDaily?[$0] != nil }
    }
}

struct HourBucket: Decodable {
    let ts: Double
    let c: Double
    let x: Double
    let q: Double?
    var qcn: Double? = nil
    var ag: Double? = nil
}
struct ProjectUsage: Decodable {
    let name: String
    let cwd: String
    let tokens: Double
    let cost: Double
    let agents: [String: Double]?
    var costsByAgent: [String: Double]? = nil
}
struct UsageCoverage: Decodable {
    let codexFiles: Int
    let codexMissingUsageFiles: Int
    var antigravityAvailable: Bool? = nil
}

// MARK: - /api/active（活跃会话，对应 api_active 行 1244）
struct ActiveResponse: Decodable { let active: [ActiveSession] }
struct ActiveSession: Decodable {
    let tool: String
    let cwd: String?
    let project: String?
    let host: String?           // "app" 时显示 App 标
    var source: String? = nil   // qoder_app 等需要专用聚焦路径的来源
    var indexedRowKey: String? = nil
    var title: String? = nil
    var indexedSession: SessionItem? = nil
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
    enum Family: String, CaseIterable { case opus, sonnet, haiku, other, codex, qoder, antigravity }
    var byFamily: [Family: Double] = [:]
    var byAgent: [Brand: Double] = [:]
    var totalTokens: Double = 0
    var costUSD: Double?
    var deltaPercent: Int?     // 近24h vs 前24h；nil=无对比基准

    /// 家族配色（FAM_COLORS）：opus/sonnet/haiku/other/codex/qoder。
    static func color(_ f: Family) -> UInt32 {
        switch f {
        case .opus:   return 0xe8744f
        case .sonnet: return 0x5f7de8
        case .haiku:  return 0x5fc78f
        case .other:  return 0x9a9aa5
        case .codex:  return 0x4fd1c5   // var(--codex-deep)
        case .qoder:  return 0x7c3aed
        case .antigravity: return 0x3683d4
        }
    }

    init?(from u: UsageResponse, now: Date = Date(),
          visibleAgents: Set<String> = Set(Brand.allCases.map(\.rawValue))) {
        guard let today = u.days.last else { return nil }
        var fams: [Family: Double] = [:]
        if visibleAgents.contains("claude") {
            for (model, parts) in (u.claudeDaily[today] ?? [:]) {
                let fam: Family = ["opus", "sonnet", "haiku"].first { model.hasPrefix($0) }
                    .flatMap { Family(rawValue: $0) } ?? .other
                fams[fam, default: 0] += parts.reduce(0, +)
            }
        }
        if visibleAgents.contains("codex") {
            fams[.codex, default: 0] += u.codexDaily[today] ?? 0
        }
        if visibleAgents.contains("qoder") {
            fams[.qoder, default: 0] += u.qoderDaily?[today] ?? 0
        }
        let cn = visibleAgents.contains("qoder_cn") ? u.qoderCnDaily?[today] ?? 0 : 0
        let ag = visibleAgents.contains("antigravity") && u.hasAntigravitySamples(on: [today]) ? u.antigravityDaily?[today] ?? 0 : 0
        byAgent = [.codex: fams[.codex] ?? 0, .qoder: fams[.qoder] ?? 0, .qoderCn: cn,
                   .claude: [.opus, .sonnet, .haiku, .other].reduce(0) { $0 + (fams[$1] ?? 0) }]
        if ag > 0 { byAgent[.antigravity] = ag; fams[.antigravity] = ag }
        fams[.qoder, default: 0] += cn
        let tok = byAgent.values.reduce(0, +)
        guard tok > 0 else { return nil }
        // 环比：hourly 覆盖 48h，近 24h vs 前 24h
        let nowSec = now.timeIntervalSince1970
        var cur = 0.0, prev = 0.0
        for h in u.hourly {
            let total = (visibleAgents.contains("claude") ? h.c : 0)
                + (visibleAgents.contains("codex") ? h.x : 0)
                + (visibleAgents.contains("qoder") ? h.q ?? 0 : 0)
            let cnTotal = visibleAgents.contains("qoder_cn") ? h.qcn ?? 0 : 0
            let agTotal = visibleAgents.contains("antigravity") ? h.ag ?? 0 : 0
            if h.ts >= nowSec - 86400 { cur += total + cnTotal + agTotal } else { prev += total + cnTotal + agTotal }
        }
        byFamily = fams
        totalTokens = tok
        costUSD = UsageRangeSummary(usage: u, span: 1, visible: visibleAgents).cost
        deltaPercent = prev > 0 ? Int(((cur - prev) / prev * 100).rounded()) : nil
    }
}
