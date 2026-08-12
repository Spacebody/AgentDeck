// AgentDeck v2 — 无头预览渲染。用 SwiftUI ImageRenderer 把视图离屏渲染成 PNG，
// 供命令行 PreviewGen 调用（绕开 Xcode 可执行目标 Preview 限制；也便于自动核对）。
import SwiftUI
import AppKit

@MainActor
public enum PreviewRender {
    private static var previewFontScale: CGFloat = 1.2

    /// 开发期切换预览语言（zh-CN / en / ja），验证三语布局。
    public static func setLocale(_ l: String) { I18N.locale = l }

    /// AD_FONT_SCALE=80...160，用真实“内容缩放 + 窗口同步放大”路径验证边界字号。
    public static func setFontScalePercent(_ percent: Int) {
        previewFontScale = min(max(CGFloat(percent) / 100, 0.8), 1.6)
    }

    /// 无头渲染前调用：玻璃回退 SwiftUI 材质（ImageRenderer 渲不出 NSVisualEffectView）。
    public static func useMaterialGlass() { GlassRender.useNativeEffect = false }

    /// 渲染概览页（额度卡）到 PNG 数据。scale=2 出 @2x 清晰图。
    public static func overviewPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 1080) {
            OverviewView(quota: PreviewSamples.response, usage: PreviewSamples.usage,
                         today: PreviewSamples.today, active: PreviewSamples.active, done: PreviewSamples.done)
        }, scale: scale)
    }

    /// Codex 当前仅周限额 + 设置中隐藏 Claude 的真实形态。
    public static func codexOnlyOverviewPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 820) {
            OverviewView(quota: PreviewSamples.codexOnlyResponse, usage: PreviewSamples.usage,
                         today: PreviewSamples.today, active: PreviewSamples.active.filter { $0.tool == "codex" },
                         done: PreviewSamples.done.filter { $0.tool == "codex" },
                         showClaudeAgent: false, showCodexAgent: true)
        }, scale: scale)
    }

    /// 本地设置已关闭 Claude，但 quota 仍是上一轮双 Agent 数据：主面板必须立即只显示 Codex。
    public static func agentVisibilityOffPNG(scale: CGFloat = 2) -> Data? {
        let store = mockStore()
        store.settings["font_scale"] = .int(100)
        store.settings["show_claude"] = .bool(false)
        store.settings["show_codex"] = .bool(true)
        store.quota = PreviewSamples.response
        return png(AgentDeckRootView(previewStore: store, version: "2.7.5")
            .frame(width: 420, height: 920), scale: scale)
    }

    /// 本地设置已重新启用 Claude、daemon 仍返回 hidden：立即显示加载卡，随后缓存刷新替换数据。
    public static func agentVisibilityOnPNG(scale: CGFloat = 2) -> Data? {
        let store = mockStore()
        store.settings["font_scale"] = .int(100)
        store.settings["show_claude"] = .bool(true)
        store.settings["show_codex"] = .bool(true)
        store.quota = PreviewSamples.codexOnlyResponse
        return png(AgentDeckRootView(previewStore: store, version: "2.7.5")
            .frame(width: 420, height: 920), scale: scale)
    }

    /// 额度卡窗口数矩阵：1 个用整行条，2...5 个用左环右 1...4 条。
    public static func quotaCasesPNG(scale: CGFloat = 2) -> Data? {
        let sampledNow = ISO8601DateFormatter().string(from: Date())
        let one = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 23, resetIn: 6 * 86400),
        ])
        let two = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 53, resetIn: 4 * 86400),
            PreviewSamples.win("gpt-5.3-codex-spark", "GPT-5.3-Codex-Spark", 0,
                               resetIn: 6 * 86400),
        ], sampledAt: sampledNow)
        let three = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3 * 86400),
        ])
        let four = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3 * 86400),
            QuotaWindow(id: "seven_day_oauth_apps", label: "周限额 · OAuth Apps",
                        usedPercent: 0, resetsAt: nil),
        ])
        let five = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day_sonnet", "周限额 · Sonnet", 71, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_oauth_apps", "周限额 · OAuth Apps", 0, resetIn: 3 * 86400),
        ])
        return png(PanelChrome(height: 1010) {
            VStack(spacing: 12) {
                quotaCase("1 个额度", node: one)
                quotaCase("2 个额度", node: two)
                quotaCase("3 个额度", node: three)
                quotaCase("4 个额度（含 0% 且无重置时间）", node: four)
                quotaCase("5 个额度", node: five)
            }
        }, scale: scale)
    }

    /// 双 Agent 半宽矩阵：覆盖 1+1 与用户截图中的 2+1，以及 3+2。
    public static func quotaDualCasesPNG(scale: CGFloat = 2) -> Data? {
        let one = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 23, resetIn: 6 * 86400),
        ])
        let two = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 84, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
        ])
        let three = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3 * 86400),
        ])
        return png(PanelChrome(height: 620) {
            VStack(spacing: 14) {
                dualQuotaCase("双 Agent · 1 + 1 个额度", claude: one, codex: one)
                dualQuotaCase("双 Agent · 2 + 1 个额度", claude: two, codex: one)
                dualQuotaCase("双 Agent · 3 + 2 个额度", claude: three, codex: two)
            }
        }, scale: scale)
    }

    /// Claude 宽卡矩阵：验证 1 个额度整行条，以及 2...5 个额度的 1:2 环条布局。
    public static func quotaClaudeCasesPNG(scale: CGFloat = 2) -> Data? {
        let one = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 23, resetIn: 6 * 86400),
        ])
        let two = quotaNode([
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
        ])
        let three = quotaNode([
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88,
                               resetIn: 3 * 86400),
        ])
        let four = quotaNode([
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_sonnet", "周限额 · Sonnet", 71,
                               resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88,
                               resetIn: 3 * 86400),
        ])
        let five = quotaNode([
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_sonnet", "周限额 · Sonnet", 71,
                               resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88,
                               resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_oauth_apps", "周限额 · OAuth Apps", 0,
                               resetIn: 3 * 86400),
        ])
        return png(PanelChrome(height: 1120) {
            VStack(spacing: 12) {
                quotaCase("Claude · 1 个额度", brand: .claude, node: one)
                quotaCase("Claude · 2 个额度", brand: .claude, node: two)
                quotaCase("Claude · 3 个额度", brand: .claude, node: three)
                quotaCase("Claude · 4 个额度", brand: .claude, node: four)
                quotaCase("Claude · 5 个额度", brand: .claude, node: five)
            }
        }, scale: scale)
    }

    /// 上游异常边界：重复 id 的两个窗口仍须各占一行，不能被 SwiftUI 复用或吞掉。
    public static func quotaDuplicatePNG(scale: CGFloat = 2) -> Data? {
        let duplicate = quotaNode([
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("custom_pool", "Team pool A", 48, resetIn: 2 * 86400),
            PreviewSamples.win("custom_pool", "Team pool B", 79, resetIn: 4 * 86400),
        ])
        return png(PanelChrome(height: 250) {
            quotaCase("重复窗口 ID（两行都必须显示）", node: duplicate)
        }, scale: scale)
    }

    /// 实机协调性场景：Claude 两窗口限流回退 + Codex 单窗口陈旧采样。
    public static func quotaHarmonyPNG(scale: CGFloat = 2) -> Data? {
        let claude = QuotaNode(
            ok: true, hidden: false, accountId: nil, account: nil, isDefault: true, kind: "oauth",
            windows: [
                QuotaWindow(id: "five_hour", label: "5 小时窗口",
                            usedPercent: 0, resetsAt: nil),
                PreviewSamples.win("seven_day", "周限额", 84, resetIn: 2 * 86400),
            ],
            error: nil, noQuota: nil, sampledAt: nil, stale: true,
            credits: nil, raw: nil)
        let sampled = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-6 * 3600))
        let codex = QuotaNode(
            ok: true, hidden: false, accountId: nil, account: nil, isDefault: true, kind: nil,
            windows: [PreviewSamples.win("seven_day", "周限额", 28, resetIn: 5 * 86400)],
            error: nil, noQuota: nil, sampledAt: sampled, stale: nil,
            credits: nil, raw: nil)
        return png(PanelChrome(height: 300) {
            EqualHeightQuotaRow(spacing: 10) {
                QuotaCardView(brand: .claude, node: claude, presentation: .panelDual)
                QuotaCardView(brand: .codex, node: codex, presentation: .panelDual)
            }
        }, scale: scale)
    }

    /// 三种用量图各自渲染（验证 tab 切换后的视图，静态渲染拿不到 @State）。
    public static func chartsPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 620) {
            VStack(spacing: 10) {
                Curve24h(usage: PreviewSamples.usage).frame(height: 160).padding(12).glassCard()
                Week7Bars(usage: PreviewSamples.usage).frame(height: 160).padding(12).glassCard()
                ProjectTop(usage: PreviewSamples.usage).frame(height: 140).padding(12).glassCard()
            }
        }, scale: scale)
    }

    /// 展示 Agent 仅启用 Codex 时，Claude 序列和图例必须完全消失。
    public static func filteredChartsPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 430) {
            VStack(spacing: 10) {
                Curve24h(usage: PreviewSamples.usage, showClaude: false, showCodex: true)
                    .frame(height: 160).padding(12).glassCard()
                Week7Bars(usage: PreviewSamples.usage, showClaude: false, showCodex: true)
                    .frame(height: 160).padding(12).glassCard()
            }
        }, scale: scale)
    }

    /// 会话页（含一行展开预览 + 操作可见）。
    public static func sessionsPNG(scale: CGFloat = 2) -> Data? {
        let firstKey = PreviewSamples.sessions.first!.rowKey
        return png(PanelChrome(height: 560) {
            SessionsView(sessions: PreviewSamples.sessions, scrollable: false,
                         total: 92, hasMore: true, page: 2, pageCount: 5, pageSize: 20,
                         initialExpanded: firstKey, seededPreviews: [firstKey: PreviewSamples.previewMsgs])
        }, scale: scale)
    }

    /// 设置页（全展开，不滚动以便整图自检）。
    public static func settingsPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 1480) {
            SettingsView(values: PreviewSamples.settingsValues, scrollable: false, version: "2.7.5")
        }, scale: scale)
    }

    /// Agent 管理子页：所有 Agent 同级纵向展示面板、状态栏和主题色设置。
    public static func agentSettingsPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 420) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                    Text(L("set.agentManager")).font(.rounded(17, weight: .bold))
                    Spacer()
                }
                .foregroundStyle(Theme.ink)
                SettingsView(values: PreviewSamples.settingsValues, scrollable: false,
                             page: .agents, version: "2.7.5")
            }
        }, scale: scale)
    }

    /// 桌面小组件紧凑视图。
    public static func widgetPNG(scale: CGFloat = 2) -> Data? {
        png(WidgetChrome {
            WidgetView(quota: PreviewSamples.response, today: PreviewSamples.today,
                       active: PreviewSamples.active)
        }, scale: scale)
    }

    /// 小组件宽度矩阵，日文环境可用于验证最坏文案下的最小可用宽度。
    public static func widgetSizesPNG(scale: CGFloat = 2) -> Data? {
        png(VStack(spacing: 12) {
            widgetSizeCase("360 × 300", width: 360)
            widgetSizeCase("340 × 300", width: 340)
            widgetSizeCase("280 × 300", width: 280)
        }
        .padding(12)
        .background(Theme.bg)
        .preferredColorScheme(.dark), scale: scale)
    }

    /// 后端最大窗口数压力场景：Claude 5 个窗口 + Codex 1 个窗口，固定 360×300。
    public static func widgetStressPNG(scale: CGFloat = 2) -> Data? {
        let claude = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day_sonnet", "周限额 · Sonnet", 71, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_oauth_apps", "周限额 · OAuth Apps", 0, resetIn: 3 * 86400),
        ])
        let codex = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 23, resetIn: 6 * 86400),
        ])
        let response = QuotaResponse(
            claude: claude, codex: codex,
            accounts: QuotaAccounts(claude: [claude], codex: [codex]),
            menubar: nil, ts: nil)
        return png(WidgetChrome(width: 360, height: 300) {
            WidgetView(quota: response, today: PreviewSamples.today,
                       active: PreviewSamples.active)
        }, scale: scale)
    }

    /// 四窗口边界：进入密集排版并只保留一条活跃会话，避免比五窗口场景反而更高。
    public static func widgetFourWindowPNG(scale: CGFloat = 2) -> Data? {
        let claude = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 62, resetIn: 3 * 86400),
            PreviewSamples.win("five_hour", "5 小时窗口", 35, resetIn: 2 * 3600),
            PreviewSamples.win("seven_day_sonnet", "周限额 · Sonnet", 71, resetIn: 3 * 86400),
            PreviewSamples.win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3 * 86400),
        ])
        let codex = quotaNode([
            PreviewSamples.win("seven_day", "周限额", 23, resetIn: 6 * 86400),
        ])
        let response = QuotaResponse(
            claude: claude, codex: codex,
            accounts: QuotaAccounts(claude: [claude], codex: [codex]),
            menubar: nil, ts: nil)
        return png(WidgetChrome(width: 360, height: 300) {
            WidgetView(quota: response, today: PreviewSamples.today,
                       active: PreviewSamples.active)
        }, scale: scale)
    }

    /// 整壳（顶栏 + 更新横幅 + 双 tab + 概览）。验证 #4+#10 组装。
    public static func rootPNG(scale: CGFloat = 2) -> Data? {
        // mock 使用 120% 字体；真实窗口也会同步放大，预览必须匹配外框尺寸，
        // 否则 ScaledContainer 会被固定 420pt 画布裁掉左右边缘。
        let fontScale = previewFontScale
        return png(AgentDeckRootView(previewStore: mockStore(), version: "2.7.5")
            .frame(width: 420 * fontScale, height: 1040 * fontScale), scale: scale)
    }

    /// 小组件整壳（store 驱动）。
    public static func widgetRootPNG(scale: CGFloat = 2) -> Data? {
        png(WidgetChrome {
            AgentDeckWidgetRootView(store: mockStore())
        }, scale: scale)
    }

    /// 拍平 carousel（同 Agent 多账号 + 不同 Agent 均为同级页面）。
    public static func carouselPNG(scale: CGFloat = 2) -> Data? {
        let acct2 = QuotaNode(
            ok: true, hidden: false, accountId: "acct2", account: "work@co", isDefault: false, kind: "oauth",
            windows: [PreviewSamples.win("seven_day", "周限额", 44, resetIn: 6 * 86400),
                      PreviewSamples.win("five_hour", "5 小时窗口", 71, resetIn: 1.1 * 3600)],
            error: nil, noQuota: nil, sampledAt: nil, stale: nil, credits: nil, raw: nil)
        let qoder = QuotaNode(
            ok: true, hidden: false, accountId: "default", account: "默认", isDefault: true,
            kind: "teams", windows: [
                PreviewSamples.win("total", "综合额度", 36, resetIn: 5 * 86400),
                PreviewSamples.win("plan", "套餐额度", 41, resetIn: 5 * 86400),
            ], error: nil, noQuota: nil, sampledAt: nil, stale: nil, credits: nil, raw: nil)
        let response = QuotaResponse(
            claude: PreviewSamples.claude, codex: PreviewSamples.codex, qoder: qoder,
            agents: [
                AgentQuota(id: "claude", name: "Claude", hidden: false,
                           accounts: [PreviewSamples.claude, acct2]),
                AgentQuota(id: "codex", name: "Codex", hidden: false,
                           accounts: [PreviewSamples.codex]),
                AgentQuota(id: "qoder", name: "Qoder", hidden: false,
                           accounts: [qoder]),
            ], accounts: QuotaAccounts(claude: [PreviewSamples.claude, acct2],
                                       codex: [PreviewSamples.codex], qoder: [qoder]),
            menubar: nil, ts: nil)
        return png(PanelChrome(height: 360) {
            FlatQuotaCarousel(pages: response.flatPages(), autoRotate: false)
        }, scale: scale)
    }

    private static func quotaNode(_ windows: [QuotaWindow],
                                  sampledAt: String? = nil) -> QuotaNode {
        QuotaNode(ok: true, hidden: false, accountId: nil, account: nil, isDefault: true,
                  kind: nil, windows: windows, error: nil, noQuota: nil, sampledAt: sampledAt,
                  stale: nil, credits: nil, raw: nil)
    }

    private static func quotaCase(_ title: String, brand: Brand = .codex,
                                  node: QuotaNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink2)
            QuotaCardView(brand: brand, node: node)
        }
    }

    private static func dualQuotaCase(_ title: String, claude: QuotaNode,
                                      codex: QuotaNode) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink2)
            EqualHeightQuotaRow(spacing: 10) {
                QuotaCardView(brand: .claude, node: claude,
                              presentation: .panelDual)
                QuotaCardView(brand: .codex, node: codex,
                              presentation: .panelDual)
            }
        }
    }

    private static func widgetSizeCase(_ title: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink2)
            WidgetChrome(width: width, height: 300) {
                WidgetView(quota: PreviewSamples.response, today: PreviewSamples.today,
                           active: PreviewSamples.active)
            }
        }
    }

    /// 预览用 mock store（同模块可直接塞 @Published）。
    static func mockStore() -> AppStore {
        let s = AppStore()
        s.quota = PreviewSamples.response
        s.usage = PreviewSamples.usage
        s.active = PreviewSamples.active
        s.done = PreviewSamples.done
        s.sessions = PreviewSamples.sessions
        s.settings = PreviewSamples.settingsValues
        s.settings["font_scale"] = .int(Int((previewFontScale * 100).rounded()))
        s.update = UpdateInfo(current: "2.7.5", latest: "2.8.0", available: true,
                              url: "https://github.com/Spacebody/AgentDeck/releases",
                              dmg: nil, notesUrl: nil)
        return s
    }

    static func png<V: View>(_ view: V, scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
