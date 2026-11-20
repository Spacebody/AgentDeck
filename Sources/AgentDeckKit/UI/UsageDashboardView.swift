import SwiftUI

struct UsageRangeSummary {
    let days: [String]
    let daily: [Double]
    let agents: [(String, Double)]
    let cost: Double?
    let projects: [(ProjectUsage, Double)]
    var total: Double { daily.reduce(0, +) }

    init(usage: UsageResponse, span: Int, visible: Set<String>) {
        let selectedDays = Array(usage.days.suffix(span))
        days = selectedDays
        func tokens(_ agent: String, _ day: String) -> Double {
            switch agent {
            case "claude": return (usage.claudeDaily[day] ?? [:]).values.reduce(0) { $0 + $1.reduce(0, +) }
            case "codex": return usage.codexDaily[day] ?? 0
            case "qoder": return usage.qoderDaily?[day] ?? 0
            case "qoder_cn": return usage.qoderCnDaily?[day] ?? 0
            default: return 0
            }
        }
        let ordered = Brand.allCases.map(\.rawValue).filter { visible.contains($0) }
        daily = days.map { day in ordered.reduce(0) { $0 + tokens($1, day) } }
        agents = ordered.map { agent in (agent, selectedDays.reduce(0) { $0 + tokens(agent, $1) }) }
        var estimate = 0.0
        var available = true
        for day in days {
            for agent in ordered where tokens(agent, day) > 0 {
                if let value = usage.costsByAgentDaily?[agent]?[day] ?? nil { estimate += value }
                else { available = false }
            }
        }
        cost = available ? estimate : nil
        let source = span == 30 ? usage.projectsAll30d ?? [] : usage.projectsAll7d ?? usage.projects7d ?? []
        projects = source.compactMap { project in
            let amount = ordered.reduce(0) { $0 + (project.agents?[$1] ?? 0) }
            return amount > 0 ? (project, amount) : nil
        }.sorted { $0.1 == $1.1 ? $0.0.cwd < $1.0.cwd : $0.1 > $1.1 }
    }
}

struct UsageDashboardView: View {
    @ObservedObject private var palette = AgentColors.shared
    let usage: UsageResponse?
    let agents: Set<String>
    var onExport: (Int) async -> Void
    @State private var span = 7
    @State private var exporting = false
    @Environment(\.adShowInfo) private var showInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                HStack(spacing: 4) {
                    ForEach([7, 30], id: \.self) { days in
                        let selected = span == days
                        Button { span = days } label: {
                            Text(L("v3.range", ["n": "\(days)"]))
                                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? DashboardStyle.accent : Theme.ink2)
                                .padding(.horizontal, 11).frame(height: 28)
                                .background(RoundedRectangle(cornerRadius: 7)
                                    .fill(selected ? DashboardStyle.accent.opacity(0.12) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                Spacer(minLength: 8)
                Button {
                    exporting = true
                    Task { await onExport(span); exporting = false }
                } label: {
                    Label(L("v3.export"), systemImage: "square.and.arrow.down")
                        .font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(DashboardStyle.accent)
                    .help(L("v3.exportRange", ["n": "\(span)"]))
                    .disabled(exporting || usage == nil)
            }
            if let usage {
                let summary = UsageRangeSummary(usage: usage, span: span, visible: agents)
                if agents.contains("codex"), let missing = usage.coverage?.codexMissingUsageFiles, missing > 0 {
                    Label(L("usage.incomplete", ["count": "\(missing)"]), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(Theme.warn)
                }
                HStack(alignment: .top, spacing: 20) {
                    metric(L("v3.tokens"), value: Fmt.tokens(summary.total))
                    Divider()
                    metric(L("v3.cost"), value: summary.cost.map { String(format: "$%.2f", $0) } ?? L("v3.unavailable"))
                }.fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 16) {
                    DashboardHeading(text: L("v3.daily"))
                    DailyUsageChart(days: summary.days, values: summary.daily,
                                    ink: agents.count == 1 ? agents.first.flatMap(Brand.init(rawValue:))?.accent ?? DashboardStyle.accent : DashboardStyle.accent)
                        .frame(height: 150)
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 14) {
                    DashboardHeading(text: L("v3.agents"))
                    ForEach(summary.agents, id: \.0) { agent, tokens in
                        HStack(spacing: 10) {
                            BrandGlyph(brand: Brand(rawValue: agent) ?? .codex, glyph: 15)
                            Text(Brand(rawValue: agent)?.name ?? agent).fixedSize().frame(minWidth: 56, alignment: .leading)
                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.06))
                                    Capsule().fill(Brand(rawValue: agent)?.accent ?? DashboardStyle.accent)
                                        .frame(width: summary.total > 0 ? proxy.size.width * tokens / summary.total : 0)
                                }
                            }.frame(height: 5)
                            Text(Fmt.tokens(tokens)).monospacedDigit().frame(width: 60, alignment: .trailing)
                            Text("\(summary.total > 0 ? Int((tokens / summary.total * 100).rounded()) : 0)%")
                                .foregroundStyle(Theme.ink3).monospacedDigit().frame(width: 34, alignment: .trailing)
                        }.font(.system(size: 11))
                    }
                }
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 12) {
                    DashboardHeading(text: L("v3.ranking"))
                    if summary.projects.isEmpty { Text(L("v3.projectsEmpty")).foregroundStyle(Theme.ink3) }
                    ForEach(Array(summary.projects.prefix(10).enumerated()), id: \.element.0.cwd) { index, item in
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", index + 1)).foregroundStyle(Theme.ink3).monospacedDigit()
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.0.name).fontWeight(.medium).lineLimit(1)
                                Text(item.0.cwd).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                                    .lineLimit(1).truncationMode(.middle)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(Fmt.tokens(item.1)).monospacedDigit()
                        }.font(.system(size: 11)).padding(.vertical, 5)
                    }
                }
                HStack(alignment: .top, spacing: 7) {
                    InfoButton { showInfo(.range(span)) }.accessibilityLabel(L("info.title"))
                    Text(L("v3.estimate")).font(.system(size: 10)).foregroundStyle(Theme.ink3)
                }
            } else {
                Text(L("common.loading")).foregroundStyle(Theme.ink3).padding(.vertical, 40)
            }
        }.foregroundStyle(Theme.ink)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.ink3)
            Text(value).font(.system(size: 27, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DailyUsageChart: View {
    let days: [String]
    let values: [Double]
    var ink = DashboardStyle.accent
    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty, values.count == days.count else { return }
            let plot = CGRect(x: 32, y: 10, width: max(0, size.width - 34), height: max(0, size.height - 32))
            let ceiling = max(values.max() ?? 0, 1)
            for ratio in [0.0, 0.5, 1.0] {
                let y = plot.maxY - plot.height * ratio
                var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: ratio == 0 ? [] : [3, 4]))
                context.draw(Text(Fmt.tokens(ceiling * ratio)).font(.system(size: 10)).foregroundColor(Theme.ink2),
                             at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
            let step = plot.width / CGFloat(days.count)
            for index in days.indices {
                let height = plot.height * max(0, values[index]) / ceiling
                let rect = CGRect(x: plot.minX + CGFloat(index) * step + step * 0.2, y: plot.maxY - height,
                                  width: step * 0.6, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(ink))
                if days.count <= 7 || index % 5 == 0 || index == days.count - 1 {
                    context.draw(Text(String(days[index].suffix(5))).font(.system(size: 10)).foregroundColor(Theme.ink2),
                                 at: CGPoint(x: plot.minX + (CGFloat(index) + 0.5) * step, y: plot.maxY + 14))
                }
            }
        }.accessibilityLabel(L("v3.daily"))
            .accessibilityValue(zip(days, values).map { "\($0): \(Fmt.tokens($1))" }.joined(separator: ", "))
    }
}
