// AgentDeck v2 — 概览页其余卡片：今日摘要条 / 活跃会话 / 最近完成。
// 复刻 index.html loadToday/loadActive/loadDone 的排版与字段。文案暂中文字面量（#3 接管三语）。
import SwiftUI

// MARK: - 迷你模型分布环（miniDonut）：12 点起始、段间 1.2pt 缝
struct MiniDonut: View {
    let parts: [(value: Double, color: Color)]
    var size: CGFloat = 22

    var body: some View {
        let total = parts.reduce(0) { $0 + $1.value }
        Canvas { ctx, _ in
            guard total > 0 else { return }
            let r = size / 2 - 2.5
            let center = CGPoint(x: size / 2, y: size / 2)
            let gapDeg = Double(1.2 / (2 * .pi * r)) * 360
            var start = -90.0   // 12 点
            for p in parts where p.value > 0 {
                let sweep = p.value / total * 360
                var path = Path()
                path.addArc(center: center, radius: r,
                            startAngle: .degrees(start + gapDeg / 2),
                            endAngle: .degrees(start + sweep - gapDeg / 2),
                            clockwise: false)
                ctx.stroke(path, with: .color(p.color), style: StrokeStyle(lineWidth: 4))
                start += sweep
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - ⓘ 口径说明按钮（占位，弹层在设置/口径阶段接）
struct InfoButton: View {
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
                .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.42))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 今日摘要条（#today）
struct TodayBar: View {
    let summary: TodaySummary
    @Environment(\.adShowInfo) private var showInfo

    var body: some View {
        HStack(spacing: 10) {
            MiniDonut(parts: TodaySummary.Family.allCases.compactMap { f in
                let v = summary.byFamily[f] ?? 0
                return v > 0 ? (v, Color(hex: TodaySummary.color(f))) : nil
            })
            text
            Spacer(minLength: 6)
            InfoButton { showInfo(.today) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var text: some View {
        var s = Text("今日 ").foregroundColor(Theme.ink2)
            + Text(Fmt.tokens(summary.totalTokens)).font(.rounded(11.5, weight: .bold)).foregroundColor(Theme.ink)
            + Text(" tok").foregroundColor(Theme.ink2)
            + Text("  ·  ").foregroundColor(Theme.ink3)
            + Text("≈ $\(Int(summary.costUSD.rounded()))").foregroundColor(Theme.ink2)
        if let d = summary.deltaPercent {
            s = s + Text("  ·  ").foregroundColor(Theme.ink3)
                + Text("\(d >= 0 ? "↑" : "↓")\(abs(d))%")
                    .foregroundColor(d >= 0 ? Color(hex: 0xffb59d) : Color(hex: 0x8be9e2))
        }
        return s.font(.system(size: 11.5))
    }
}

// MARK: - 会话行（活跃/完成共用骨架）
private struct SessionRow: View {
    let tool: String
    let title: String
    let monospaced: Bool       // 活跃用等宽路径
    let trailing: AnyView
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                BrandBadge(brand: tool == "codex" ? .codex : .claude, size: 20)
                Text(title)
                    .font(.system(size: monospaced ? 10.5 : 11,
                                  weight: monospaced ? .semibold : .regular,
                                  design: monospaced ? .monospaced : .default))
                    .foregroundStyle(monospaced ? Theme.ink2 : Theme.ink)
                    .lineLimit(1).truncationMode(.head)   // 从左截断保尾部目录
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 活跃会话卡（#active）
struct ActiveCard: View {
    let sessions: [ActiveSession]
    var onTap: (ActiveSession) -> Void = { _ in }

    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.ok).frame(width: 6, height: 6)
                        .shadow(color: Theme.ok, radius: 3)
                    Text("\(sessions.count) 个运行中")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink2)
                }
                .padding(.bottom, 4)
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, a in
                    SessionRow(
                        tool: a.tool,
                        title: prettyPath(a),
                        monospaced: true,
                        trailing: AnyView(HStack(spacing: 6) {
                            if a.host == "app" { tag("App") }
                            Text("已运行 " + runtime(a)).font(.system(size: 10.5)).foregroundStyle(Theme.ink2)
                            if let st = a.status, !st.isEmpty { statePill(st) }
                        }),
                        onTap: { onTap(a) })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private func prettyPath(_ a: ActiveSession) -> String {
        let raw = a.cwd ?? a.project ?? ""
        let p = raw.replacingOccurrences(of: #"^/Users/[^/]+"#, with: "~", options: .regularExpression)
        return p == "~" ? "主目录" : p
    }
    private func runtime(_ a: ActiveSession) -> String {
        if let s = a.runtimeSecs { return Fmt.duration(s) }
        return a.runtime ?? ""
    }
    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 9)).foregroundStyle(Theme.ink2)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }
    private func statePill(_ st: String) -> some View {
        let busy = st == "busy"
        return Text(busy ? "忙碌" : "空闲")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(busy ? Theme.warn : Theme.ok)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((busy ? Theme.warn : Theme.ok).opacity(0.12)))
    }
}

// MARK: - 最近完成卡（#done）
struct DoneCard: View {
    let events: [DoneEvent]
    var onTap: (DoneEvent) -> Void = { _ in }

    var body: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("最近完成")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink2)
                    .padding(.bottom, 4)
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    SessionRow(
                        tool: e.tool,
                        title: (e.title?.isEmpty == false ? e.title! : "任务完成"),
                        monospaced: false,
                        trailing: AnyView(HStack(spacing: 6) {
                            if let p = e.project, !p.isEmpty {
                                Text(p).font(.system(size: 9)).foregroundStyle(Theme.ink2)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                            }
                            Text(Fmt.relative(Date(timeIntervalSince1970: e.ts)))
                                .font(.system(size: 9)).foregroundStyle(Theme.ink3)
                        }),
                        onTap: { onTap(e) })
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }
}
