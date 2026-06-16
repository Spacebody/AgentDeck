// AgentDeck v2 — /api/quota 数据模型。对应 agentdeckd.py api_quota()（行 826）。
// 形状：{claude:<node>, codex:<node>, accounts:{claude:[node],codex:[node]}, menubar, ts}
// 解码用 .convertFromSnakeCase（见 APIClient），故属性用 camelCase。
import Foundation

struct QuotaResponse: Decodable {
    let claude: QuotaNode?
    let codex: QuotaNode?
    let accounts: QuotaAccounts?
    let menubar: MenubarConfig?
    let ts: Double?
}

struct QuotaAccounts: Decodable {
    let claude: [QuotaNode]
    let codex: [QuotaNode]
}

/// 单账号额度节点。主账号（claude/codex 顶层）无 account_id；accounts 列表项带账号标识。
/// 失败时 ok=false 且带 error；隐藏时 hidden=true（设置里关掉该 agent）。
struct QuotaNode: Decodable, Identifiable {
    let ok: Bool
    let hidden: Bool?
    let accountId: String?      // account_id（仅 accounts 列表项）
    let account: String?        // 账号显示名（label）
    let isDefault: Bool?        // is_default
    let kind: String?           // claude="oauth"
    let windows: [QuotaWindow]?
    let error: String?
    let noQuota: Bool?          // no_quota（Codex 无额度信息）
    let sampledAt: String?      // sampled_at（Codex 采样时间戳）

    var id: String { accountId ?? account ?? kind ?? "primary" }
    var displayWindows: [QuotaWindow] { windows ?? [] }
}

/// 单个限额窗口（5h / 周限额 / Sonnet / Opus …）。
struct QuotaWindow: Decodable, Identifiable, Hashable {
    let id: String              // five_hour / seven_day / seven_day_sonnet …
    let label: String?
    let usedPercent: Double     // used_percent（0~100，已 round 1 位）
    let resetsAt: FlexibleDate? // resets_at（epoch 秒 或 ISO 串）

    /// 阈值配色：≥95 危险 / ≥80 告警 / 否则正常（对应 .wbar i.warn/.danger 与菜单栏 alertFor）。
    enum Level { case normal, warn, danger }
    var level: Level { usedPercent >= 95 ? .danger : usedPercent >= 80 ? .warn : .normal }
}

/// 菜单栏相关设置（随额度一并下发，供状态栏渲染）。
struct MenubarConfig: Decodable {
    let claude: Bool?
    let codex: Bool?
    let alertColor: Bool?       // alert_color
    let valueDim: String?       // value_dim：shortest / weekly / max
    let colorDim: String?       // color_dim
    let rotateSecs: Int?        // rotate_secs
}
