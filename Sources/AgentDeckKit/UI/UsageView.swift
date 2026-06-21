// AgentDeck v2 — 用量趋势卡。复刻 index.html 三视图：24h 曲线(loadCurve)、
// 近7天堆叠柱(loadUsage)、项目 Top(loadProjects)。SVG → SwiftUI Canvas。
import SwiftUI

// 纵轴 nice 刻度：取整到 1/2/2.5/5×10^n（对应 niceMax 计算）
func usageNiceMax(_ raw: Double) -> Double {
    let m = max(raw, 1)
    let p = pow(10.0, floor(log10(m)))
    return [1, 2, 2.5, 5, 10].map { $0 * p }.first { $0 >= m } ?? m
}
private func fmtAxis(_ n: Double) -> String { Fmt.tokens(n).replacingOccurrences(of: ".0", with: "") }

enum UsageMode: String, CaseIterable { case curve, usage, proj }

struct UsageView: View {
    let usage: UsageResponse?
    @State private var mode: UsageMode = .curve
    @Environment(\.adShowInfo) private var showInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Group {
                switch mode {
                case .curve: Curve24h(usage: usage)
                case .usage: Week7Bars(usage: usage)
                case .proj:  ProjectTop(usage: usage)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func label(_ m: UsageMode) -> String {
        switch m {
        case .curve: return L("usage.tabCurve")
        case .usage: return L("usage.tabUsage")
        case .proj:  return L("usage.tabProj")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(UsageMode.allCases, id: \.self) { m in
                    Chip(text: label(m), on: mode == m) { mode = m }
                }
            }
            Spacer(minLength: 6)
            if let u = usage {
                Text(L("usage.costEq", ["c7": "\(Int((u.cost7d ?? 0).rounded()))",
                                        "c30": "\(Int((u.cost30d ?? 0).rounded()))"]).strippingBold)
                    .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                    .lineLimit(1).truncationMode(.tail)
            }
            InfoButton { showInfo(.usage(mode)) }
        }
    }
}

extension String {
    /// 去掉文案里的 <b></b> 富文本标签（SwiftUI Text 用纯文本）。
    var strippingBold: String {
        replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
    }
}

// MARK: - 筛选 chip（.chip）
struct Chip: View {
    let text: String
    let on: Bool
    var size: CGFloat = 10.5
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: size, weight: .medium))
                .lineLimit(1).fixedSize()          // 永不竖排（设置里曾出现「1 分 钟」逐字换行）
                .foregroundStyle(on ? Theme.ink : Theme.ink3)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? Color.white.opacity(0.13) : .clear))
                .overlay(Capsule().strokeBorder(on ? Theme.edgeHi : Theme.edge))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Catmull-Rom 平滑路径（smoothPath）
private func smoothPath(_ pts: [CGPoint]) -> Path {
    var path = Path()
    guard pts.count >= 2 else { if let f = pts.first { path.move(to: f) }; return path }
    path.move(to: pts[0])
    for i in 0..<(pts.count - 1) {
        let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(pts.count - 1, i + 2)]
        let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
        let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
        path.addCurve(to: p2, control1: c1, control2: c2)
    }
    return path
}

// MARK: - 24h 额度曲线（loadCurve）
struct Curve24h: View {
    let usage: UsageResponse?

    var body: some View {
        let buckets = makeBuckets()
        VStack(spacing: 8) {
            Canvas { ctx, size in draw(ctx, size, buckets) }
            legend(buckets)
        }
    }

    /// 24 个整点桶（缺失记 0），中心点 ts+0.5h。
    private func makeBuckets() -> [(ts: Double, c: Double, x: Double)] {
        let now = Date().timeIntervalSince1970
        let hourMs = 3600.0
        let nowH = floor(now / hourMs) * hourMs
        let byTs = Dictionary(grouping: usage?.hourly ?? [], by: { $0.ts }).mapValues { $0[0] }
        return (0...23).reversed().map { i -> (Double, Double, Double) in
            let ts = nowH - Double(i) * hourMs
            let h = byTs[ts]
            return (ts + hourMs / 2, h?.c ?? 0, h?.x ?? 0)
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ buckets: [(ts: Double, c: Double, x: Double)]) {
        let W = size.width, H = size.height
        let X0 = 32.0, X1 = W - 6, Y0 = H - 24, Y1 = 8.0
        let now = Date().timeIntervalSince1970
        let nowH = floor(now / 3600) * 3600
        let t0 = nowH - 23 * 3600, t1 = nowH + 3600
        func px(_ ts: Double) -> Double { X0 + (ts - t0) / (t1 - t0) * (X1 - X0) }
        let peak = max(1, buckets.map { max($0.c, $0.x) }.max() ?? 1)
        let yMax = usageNiceMax(peak)
        func py(_ v: Double) -> Double { Y0 - v / yMax * (Y0 - Y1) }

        // 网格 + 纵轴刻度
        for f in [0.0, 0.5, 1.0] {
            let y = py(yMax * f)
            var line = Path(); line.move(to: CGPoint(x: X0, y: y)); line.addLine(to: CGPoint(x: X1, y: y))
            ctx.stroke(line, with: .color(.white.opacity(0.12)),
                       style: StrokeStyle(lineWidth: 1, dash: f == 0 ? [] : [2, 4]))
            ctx.draw(Text(f == 0 ? "0" : fmtAxis(yMax * f)).font(.system(size: 7)).foregroundColor(.white.opacity(0.52)),
                     at: CGPoint(x: X0 - 6, y: y), anchor: .trailing)
        }
        // 横轴每 6h
        let firstTick = ceil(t0 / 21600) * 21600
        var tk = firstTick
        while tk <= t1 {
            let x = px(tk)
            let hr = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: tk))
            ctx.draw(Text(String(format: "%02d:00", hr)).font(.system(size: 7)).foregroundColor(.white.opacity(0.52)),
                     at: CGPoint(x: x, y: Y0 + 10), anchor: .center)
            tk += 21600
        }
        // 双序列：面积 + 线 + 端点
        for (key, color) in [("c", Brand.claude.accent), ("x", Brand.codex.accent)] {
            let pts = buckets.map { CGPoint(x: px($0.ts), y: py(key == "c" ? $0.c : $0.x)) }
            let line = smoothPath(pts)
            var area = line
            area.addLine(to: CGPoint(x: pts.last!.x, y: Y0))
            area.addLine(to: CGPoint(x: pts.first!.x, y: Y0))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.28), color.opacity(0)]),
                                                 startPoint: CGPoint(x: 0, y: Y1), endPoint: CGPoint(x: 0, y: Y0)))
            ctx.stroke(line, with: .color(color.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            if let last = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 2.4, y: last.y - 2.4, width: 4.8, height: 4.8)),
                         with: .color(color.opacity(0.95)))
            }
        }
    }

    private func legend(_ buckets: [(ts: Double, c: Double, x: Double)]) -> some View {
        let cTot = buckets.reduce(0) { $0 + $1.c }, xTot = buckets.reduce(0) { $0 + $1.x }
        return HStack(spacing: 12) {
            legendItem(Brand.claude.accent, L("usage.legend24h", ["name": "Claude"]), cTot)
            legendItem(Brand.codex.accent, L("usage.legend24h", ["name": "Codex"]), xTot)
            Spacer()
        }
        .font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
    }
    private func legendItem(_ c: Color, _ name: String, _ total: Double) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 7, height: 7)
            Text(name) + Text(" \(Fmt.tokens(total))").foregroundColor(Theme.ink).bold()
        }
    }
}

// MARK: - 近 7 天堆叠柱（loadUsage）
struct Week7Bars: View {
    let usage: UsageResponse?

    private struct DayBar { let day: String; var per: [TodaySummary.Family: Double]; let all: Double }

    var body: some View {
        let bars = makeBars()
        VStack(spacing: 8) {
            Canvas { ctx, size in draw(ctx, size, bars) }
            legend
        }
    }

    // 模型分段图例（对应 #usageview .legend：Opus/Sonnet/Haiku/Codex）
    private var legend: some View {
        HStack(spacing: 9) {
            ForEach([(TodaySummary.Family.opus, "Opus"), (.sonnet, "Sonnet"),
                     (.haiku, "Haiku"), (.codex, "Codex")], id: \.1) { fam, name in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: grad(fam), startPoint: .top, endPoint: .bottom))
                        .frame(width: 7, height: 7)
                    Text(name)
                }
            }
            Spacer()
        }
        .font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
    }

    private func makeBars() -> [DayBar] {
        guard let u = usage else { return [] }
        let days = Array(u.days.suffix(7))
        return days.map { day in
            var per: [TodaySummary.Family: Double] = [:]
            for (model, parts) in (u.claudeDaily[day] ?? [:]) {
                let t = parts.reduce(0, +)
                guard t > 0 else { continue }
                let fam: TodaySummary.Family = ["opus", "sonnet", "haiku"].first { model.hasPrefix($0) }
                    .flatMap { TodaySummary.Family(rawValue: $0) } ?? .other
                per[fam, default: 0] += t
            }
            let cx = u.codexDaily[day] ?? 0
            if cx > 0 { per[.codex, default: 0] += cx }
            return DayBar(day: day, per: per, all: per.values.reduce(0, +))
        }
    }

    // 段渐变（GRAD）：opus/sonnet/haiku/other/codex
    private func grad(_ f: TodaySummary.Family) -> [Color] {
        switch f {
        case .opus:   return [Color(hex: 0xffb38a), Color(hex: 0xe8744f)]
        case .sonnet: return [Color(hex: 0x9db8ff), Color(hex: 0x5f7de8)]
        case .haiku:  return [Color(hex: 0xaef0c8), Color(hex: 0x5fc78f)]
        case .other:  return [Color(hex: 0x9a9aa5), Color(hex: 0x6a6a75)]
        case .codex:  return [Brand.codex.accent, Brand.codex.deep]
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, _ bars: [DayBar]) {
        guard !bars.isEmpty else { return }
        let W = size.width, H = size.height
        let X0 = 32.0, X1 = W - 6, Y0 = H - 26, Y1 = 8.0, BW = 16.0
        let niceMax = usageNiceMax(bars.map { $0.all }.max() ?? 1)
        let slot = (X1 - X0) / 7
        let today = DateFormatter.localDay.string(from: Date())   // 本地时区，对齐 daemon 日期键

        for f in [0.0, 0.5, 1.0] {
            let y = Y0 - f * (Y0 - Y1)
            var line = Path(); line.move(to: CGPoint(x: X0, y: y)); line.addLine(to: CGPoint(x: X1, y: y))
            ctx.stroke(line, with: .color(.white.opacity(0.12)),
                       style: StrokeStyle(lineWidth: 1, dash: f == 0 ? [] : [2, 4]))
            ctx.draw(Text(f == 0 ? "0" : fmtAxis(niceMax * f)).font(.system(size: 7)).foregroundColor(.white.opacity(0.52)),
                     at: CGPoint(x: X0 - 6, y: y), anchor: .trailing)
        }

        for (i, b) in bars.enumerated() {
            let cx = X0 + slot * Double(i) + slot / 2, x = cx - BW / 2
            let totalH = b.all / niceMax * (Y0 - Y1)
            let isToday = b.day == today
            if b.all > 0 {
                let clip = Path(roundedRect: CGRect(x: x, y: Y0 - max(totalH, 4), width: BW, height: max(totalH, 4)),
                                cornerRadius: 4.5)
                var cur = Y0
                for f in [TodaySummary.Family.opus, .sonnet, .haiku, .other, .codex] {
                    let v = b.per[f] ?? 0
                    guard v > 0 else { continue }
                    let h = v / niceMax * (Y0 - Y1)
                    var seg = ctx
                    seg.clip(to: clip)
                    seg.fill(Path(CGRect(x: x, y: cur - h, width: BW, height: h + 0.5)),
                             with: .linearGradient(Gradient(colors: grad(f)),
                                                   startPoint: CGPoint(x: x, y: Y1), endPoint: CGPoint(x: x, y: Y0)))
                    cur -= h
                }
                ctx.draw(Text(Fmt.tokens(b.all)).font(.system(size: 6.5, weight: .medium))
                    .foregroundColor(.white.opacity(isToday ? 0.92 : 0.4)),
                         at: CGPoint(x: cx, y: Y0 - totalH - 6), anchor: .center)
            } else {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: Y0 - 2, width: BW, height: 2), cornerRadius: 1),
                         with: .color(.white.opacity(0.08)))
            }
            // 轴标签：今日 / 星期 + 日期
            let wd = weekdayLabel(b.day, isToday: isToday)
            ctx.draw(Text(wd).font(.system(size: 7, weight: isToday ? .bold : .regular))
                .foregroundColor(.white.opacity(isToday ? 0.92 : 0.52)),
                     at: CGPoint(x: cx, y: Y0 + 10), anchor: .center)
            ctx.draw(Text(String(b.day.suffix(5)).replacingOccurrences(of: "-", with: "/"))
                .font(.system(size: 7)).foregroundColor(.white.opacity(0.52)),
                     at: CGPoint(x: cx, y: Y0 + 20), anchor: .center)
        }
    }

    private func weekdayLabel(_ day: String, isToday: Bool) -> String {
        if isToday { return L("usage.today") }
        let wds = I18N.weekdays[I18N.locale] ?? I18N.weekdays["en"]!
        guard let d = DateFormatter.localDay.date(from: day) else { return "" }
        let name = wds[Calendar.current.component(.weekday, from: d) - 1]
        return L("weekPrefix") + name   // zh 前缀「周」，en/ja 为空（对应 v1）
    }
}

// MARK: - 项目 Top（loadProjects）
struct ProjectTop: View {
    let usage: UsageResponse?
    var body: some View {
        let list = usage?.projects7d ?? []
        if list.isEmpty {
            Text(L("proj.none7d")).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let maxTok = max(list.map { $0.tokens }.max() ?? 1, 1)
            // 纯 VStack（由主面板统一滚动，避免嵌套 ScrollView）
            VStack(spacing: 8) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, p in
                    let isCodex = p.cwd.contains("/Codex")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(p.name).font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: 6)
                            Text("$\(Int(p.cost.rounded()))").font(.system(size: 9)).foregroundStyle(Theme.ink3)
                            Text(Fmt.tokens(p.tokens)).font(.rounded(11, weight: .semibold)).foregroundStyle(Theme.ink2)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.08))
                                Capsule().fill((isCodex ? Brand.codex : Brand.claude).gradient)
                                    .frame(width: geo.size.width * p.tokens / maxTok)
                            }
                        }.frame(height: 4)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

extension DateFormatter {
    /// 本地时区 yyyy-MM-dd，对齐 daemon 的日期键（daemon 按本地日分桶）。
    static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
