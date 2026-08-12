// AgentDeck v2 — /api/quota 数据模型。对应 agentdeckd.py api_quota()（行 826）。
// 形状：{claude:<node>, codex:<node>, accounts:{claude:[node],codex:[node]}, menubar, ts}
// 解码用 .convertFromSnakeCase（见 APIClient），故属性用 camelCase。
import Foundation

struct QuotaResponse: Decodable {
    let claude: QuotaNode?
    let codex: QuotaNode?
    let qoder: QuotaNode?
    let agents: [AgentQuota]?
    let accounts: QuotaAccounts?
    let menubar: MenubarConfig?
    let quotaRevision: Int?
    let quotaBootId: String?
    let ts: Double?

    init(
        claude: QuotaNode?,
        codex: QuotaNode?,
        qoder: QuotaNode? = nil,
        agents: [AgentQuota]? = nil,
        accounts: QuotaAccounts?,
        menubar: MenubarConfig?,
        quotaRevision: Int? = nil,
        quotaBootId: String? = nil,
        ts: Double?
    ) {
        self.claude = claude
        self.codex = codex
        self.qoder = qoder
        self.agents = agents
        self.accounts = accounts
        self.menubar = menubar
        self.quotaRevision = quotaRevision
        self.quotaBootId = quotaBootId
        self.ts = ts
    }
}

/// `/api/quota/changes` 长轮询响应。bootId 处理 daemon 重启后 revision 回绕；
/// quota 始终来自 daemon 内存快照，不会在实时通道里触发慢速外部查询。
struct QuotaChangesResponse: Decodable {
    let bootId: String
    let revision: Int
    let quota: QuotaResponse
}

struct QuotaAccounts: Decodable {
    let claude: [QuotaNode]
    let codex: [QuotaNode]
    let qoder: [QuotaNode]?

    init(claude: [QuotaNode], codex: [QuotaNode], qoder: [QuotaNode]? = nil) {
        self.claude = claude
        self.codex = codex
        self.qoder = qoder
    }
}

struct AgentQuota: Decodable, Identifiable {
    let id: String
    let name: String
    let hidden: Bool?
    let accounts: [QuotaNode]
}

/// 概览轮播唯一页面单位。所有 Agent 和账号都在同一数组中，不保留二级选择状态。
struct QuotaPage: Identifiable {
    let id: String
    let agentID: String
    let agentName: String
    let brand: Brand
    let account: QuotaNode
}

func reconciledQuotaSelection(currentID: String?, pages: [QuotaPage]) -> String? {
    if let currentID, pages.contains(where: { $0.id == currentID }) { return currentID }
    return pages.first?.id
}

func normalizedQuotaRotationInterval(_ value: Int) -> Int {
    [4, 6, 8, 10].contains(value) ? value : 6
}

extension QuotaResponse {
    func flatPages(visibleAgents: Set<String>? = nil) -> [QuotaPage] {
        let groups: [AgentQuota]
        if let agents, !agents.isEmpty {
            groups = agents
        } else {
            groups = [
                AgentQuota(id: "claude", name: "Claude", hidden: claude?.hidden,
                           accounts: legacyAccounts(accounts?.claude, primary: claude)),
                AgentQuota(id: "codex", name: "Codex", hidden: codex?.hidden,
                           accounts: legacyAccounts(accounts?.codex, primary: codex)),
                AgentQuota(id: "qoder", name: "Qoder", hidden: qoder?.hidden,
                           accounts: legacyAccounts(accounts?.qoder, primary: qoder)),
            ]
        }
        return groups.flatMap { group -> [QuotaPage] in
            guard Brand(rawValue: group.id) != nil,
                  visibleAgents?.contains(group.id) ?? !(group.hidden ?? false) else { return [] }
            let ordered = group.accounts.enumerated().sorted { lhs, rhs in
                let ld = lhs.element.isDefault == true
                let rd = rhs.element.isDefault == true
                return ld == rd ? lhs.offset < rhs.offset : ld && !rd
            }.map(\.element)
            return ordered.enumerated().compactMap { offset, account in
                guard let brand = Brand(rawValue: group.id) else { return nil }
                let accountID = account.accountId ?? (account.isDefault == true ? "default" : "account-\(offset)")
                return QuotaPage(id: "\(group.id)::\(accountID)", agentID: group.id,
                                 agentName: group.name, brand: brand, account: account)
            }
        }
    }

    private func legacyAccounts(_ listed: [QuotaNode]?, primary: QuotaNode?) -> [QuotaNode] {
        guard let listed, !listed.isEmpty else { return primary.map { [$0] } ?? [] }
        return listed
    }
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
    let stale: Bool?            // 接口限流 → 显示上次成功数据
    let credits: CreditsInfo?   // Codex Credits 余额
    let raw: RawUsage?          // Claude 原始响应（取 extra_usage）

    var id: String { accountId ?? account ?? kind ?? "primary" }
    var displayWindows: [QuotaWindow] { windows ?? [] }
}

/// 上游（Codex credits / Claude extra_usage）的金额字段偶尔以字符串形式下发（如 balance "0"）。
/// Codable 是「全有或全无」：单个字段类型漂移会让整张 /api/quota 解码失败 → 两张额度卡全
/// 显示「额度获取失败」。故这些透传数值一律按「数字或字符串皆容」解。
private extension KeyedDecodingContainer {
    func flexDouble(_ key: Key) -> Double? {
        if let n = try? decode(Double.self, forKey: key) { return n }
        if let s = try? decode(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// Codex Credits 余额（credits 透传自上游）。
struct CreditsInfo: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: Double?
    enum CodingKeys: String, CodingKey { case hasCredits, unlimited, balance }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasCredits = (try? c.decodeIfPresent(Bool.self, forKey: .hasCredits)) ?? nil
        unlimited = (try? c.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? nil
        balance = c.flexDouble(.balance)
    }
}

/// Claude 原始用量响应里只取 extra_usage（其余键忽略）。
struct RawUsage: Decodable {
    let extraUsage: ExtraUsage?
}
struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?    // 单位：美分
    let monthlyLimit: Double?   // 单位：美分
    enum CodingKeys: String, CodingKey { case isEnabled, usedCredits, monthlyLimit }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? nil
        usedCredits = c.flexDouble(.usedCredits)
        monthlyLimit = c.flexDouble(.monthlyLimit)
    }
}

/// 单个限额窗口（5h / 周限额 / Sonnet / Opus …）。
struct QuotaWindow: Decodable, Identifiable, Hashable {
    let id: String              // five_hour / seven_day / seven_day_sonnet …
    let label: String?
    let usedPercent: Double     // used_percent（0~100，已 round 1 位）
    let resetsAt: FlexibleDate? // resets_at（epoch 秒 或 ISO 串）
    let used: Double?
    let total: Double?
    let remaining: Double?
    let unit: String?
    let bucketKind: String?

    init(id: String, label: String?, usedPercent: Double, resetsAt: FlexibleDate?,
         used: Double? = nil, total: Double? = nil, remaining: Double? = nil,
         unit: String? = nil, bucketKind: String? = nil) {
        self.id = id; self.label = label; self.usedPercent = usedPercent
        self.resetsAt = resetsAt; self.used = used; self.total = total
        self.remaining = remaining; self.unit = unit; self.bucketKind = bucketKind
    }

    /// 阈值配色：≥95 危险 / ≥80 告警 / 否则正常（对应 .wbar i.warn/.danger 与菜单栏 alertFor）。
    enum Level { case normal, warn, danger }
    var level: Level { usedPercent >= 95 ? .danger : usedPercent >= 80 ? .warn : .normal }
}

/// 菜单栏相关设置（随额度一并下发，供状态栏渲染）。
struct MenubarConfig: Decodable {
    let claude: Bool?
    let codex: Bool?
    let qoder: Bool?
    let alertColor: Bool?       // alert_color
    let valueDim: String?       // value_dim：shortest / weekly / max
    let colorDim: String?       // color_dim
    let rotateSecs: Int?        // rotate_secs
}
