// AgentDeck v2 — 额度卡。忠实复刻 index.html quotaCardInner()（行 1189）：
// 头部(徽章+名+账号+副信息) · 主体(进度环 + 窗口条) · 脚注 · 品牌辉光 · 玻璃卡。
import SwiftUI

/// 百分比文字：整数不带小数，否则保留 1 位（对应窗口条 ${used_percent}% 的原值，已 round 1）。
private func pctText(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}

/// 额度卡的展示环境。主面板双栏与桌面小组件必须使用独立排版指标，避免窄卡误套小组件字号。
enum QuotaCardPresentation {
    case panelWide
    case panelDual
    case widget

    var isWidget: Bool { self == .widget }
    var isDualPanel: Bool { self == .panelDual }
}

// MARK: - 进度环（.ring：r=27 / stroke 6 / 顶部起、顺时针；中心大号百分比）
struct RingView: View {
    let percent: Double
    let brand: Brand
    var size: CGFloat = 64
    var lineWidth: CGFloat = 6

    private var level: QuotaWindow.Level {
        percent >= 95 ? .danger : percent >= 80 ? .warn : .normal
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lineWidth)   // .track
            Circle()
                .trim(from: 0, to: min(percent, 100) / 100)
                .stroke(Theme.gradient(for: level, brand: brand),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))          // SVG rotate(-90)：从顶部起
                .animation(.easeOut(duration: 1), value: percent)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(Int(percent.rounded()))")
                    .font(.rounded(size * 0.23, weight: .bold)).foregroundStyle(Theme.ink)
                Text("%").font(.rounded(size * 0.14, weight: .semibold)).foregroundStyle(Theme.ink2)
            }
        }
        .padding(lineWidth / 2)                          // 防 stroke 被 frame 裁切
        .frame(width: size, height: size)
    }
}

// MARK: - 官方品牌字形（claude/codex tray 模板图，currentColor 上色）。
// 复刻 index.html badge()：claude mask-size 141%（图内留白，放大填充）、codex contain。
struct BrandGlyph: View {
    let brand: Brand
    /// 字形显示边长（v1：qbadge 20 内 glyph 12）
    var glyph: CGFloat = 12

    /// 资源包解析（不直接用 SwiftPM 生成的 Bundle.module——它只查 .app 根目录与开发机本地 .build 路径，
    /// 而 build.sh 把资源包放在 Contents/Resources，导致分发机两路皆空 → Bundle.module fatalError 崩溃）。
    /// 先按 Contents/Resources / .app 根 自行查找；都找不到才退回 .module（仅开发期 swift run 命中）。
    private static let kitBundle: Bundle = {
        let name = "AgentDeck_AgentDeckKit.bundle"
        let bases = [Bundle.main.resourceURL,
                     Bundle.main.bundleURL,
                     Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")]
        for base in bases.compactMap({ $0 }) {
            if let b = Bundle(url: base.appendingPathComponent(name)) { return b }
        }
        return .module   // 开发期 SwiftPM 上下文兜底（分发不会走到这里，故不会触发其 fatalError）
    }()

    private static func image(_ brand: Brand) -> NSImage? {
        guard let url = kitBundle.url(forResource: brand.rawValue, withExtension: "png",
                                      subdirectory: "Brand") else { return nil }
        let img = NSImage(contentsOf: url)
        img?.isTemplate = true
        return img
    }

    var body: some View {
        Group {
            if let img = Self.image(brand) {
                Image(nsImage: img).resizable().renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(brand == .claude ? 1.41 : 1)   // claude 放大填充留白
                    .foregroundStyle(brand.accent)
            } else {   // 资源缺失兜底
                Image(systemName: brand == .claude ? "sparkle" : "apple.terminal")
                    .font(.system(size: glyph, weight: .regular))
                    .foregroundStyle(brand.accent)
            }
        }
        .frame(width: glyph, height: glyph)
        .clipped()
    }
}

// MARK: - 品牌徽章（.qbadge：品牌色底 + 描边 + 官方字形）
struct BrandBadge: View {
    let brand: Brand
    var size: CGFloat = 20
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(brand.accent.opacity(0.14))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(brand.accent.opacity(0.28)))
            .overlay(BrandGlyph(brand: brand, glyph: size * 0.6))
            .frame(width: size, height: size)
    }
}

// MARK: - 单个窗口条（.wrow：标签 + 倒计时 + 百分比 + 进度条）
struct WindowRow: View {
    let window: QuotaWindow
    let brand: Brand
    var presentation: QuotaCardPresentation = .panelWide
    /// 五窗口小组件的有界密集模式；仍保留标签、倒计时和进度条，只压成单行。
    var dense: Bool = false

    private var labelSize: CGFloat {
        if dense { return 9 }
        switch presentation {
        case .panelWide: return 11.5
        case .panelDual: return 10.5
        case .widget: return 9
        }
    }
    private var valueSize: CGFloat {
        if dense { return 10 }
        switch presentation {
        case .panelWide: return 14
        case .panelDual: return 13
        case .widget: return 10
        }
    }
    private var detailSize: CGFloat {
        if dense { return 8.5 }
        switch presentation {
        case .panelWide: return 10
        case .panelDual: return 9.5
        case .widget: return 8.5
        }
    }
    private var wraps: Bool { presentation != .panelWide }
    private var visibleLabel: String {
        let label = window.displayLabel
        guard dense, let separator = label.range(of: " · ") else { return label }
        return String(label[separator.upperBound...])
    }
    private var minimumScale: CGFloat { dense ? 0.8 : 0.72 }

    var body: some View {
        VStack(alignment: .leading, spacing: dense ? 1 : (presentation.isWidget ? 2 : 3)) {
            HStack(alignment: .firstTextBaseline, spacing: presentation.isWidget ? 4 : 6) {
                Text(visibleLabel)
                    .font(.system(size: labelSize, weight: .semibold)).foregroundStyle(Theme.ink2)
                    .lineLimit(dense ? 1 : (wraps ? 2 : 1))
                    .minimumScaleFactor(minimumScale)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text("\(pctText(window.usedPercent))%")
                    .font(.rounded(valueSize, weight: .semibold)).foregroundStyle(Theme.ink)
                    .fixedSize()
            }
            let cd = Fmt.countdown(window.resetsAt?.date, compact: true)
            if !cd.isEmpty {
                Text(cd).font(.system(size: detailSize, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(dense ? 1 : (wraps ? 2 : 1))
                    .minimumScaleFactor(minimumScale)
                    .fixedSize(horizontal: false, vertical: true)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(Theme.gradient(for: window.level, brand: brand))
                        .frame(width: geo.size.width * min(window.usedPercent, 100) / 100)
                        .animation(.easeOut(duration: 1), value: window.usedPercent)
                }
            }
            .frame(height: dense ? 2.5 : (presentation.isWidget ? 3 : 4))
        }
    }
}

/// 上游窗口 id 理论上应唯一，但展示层不能依赖该约束；用原始数组位置保持行身份稳定。
private struct IndexedQuotaWindow: Identifiable {
    let id: Int
    let window: QuotaWindow
}

// MARK: - 多账号 carousel（对应 renderQuotaTool）：单账号→单卡；多账号→横向翻页 + 圆点。
// macOS 13 无 scrollTargetBehavior，手写 offset + 拖拽翻页（宽度经 PreferenceKey 量取）。
private struct CarouselWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct QuotaCarousel: View {
    let brand: Brand
    let accounts: [QuotaNode]
    var presentation: QuotaCardPresentation = .panelWide
    /// 双栏中只要一侧有账号翻页，两侧都预留圆点槽，保证卡片背景本身等高。
    var reservePageIndicator: Bool = false

    @State private var page = 0
    @State private var width: CGFloat = 0
    @GestureState private var dragX: CGFloat = 0

    private var clampedPage: Int {
        min(max(page, 0), max(0, accounts.count - 1))
    }

    var body: some View {
        if accounts.count <= 1 {
            if reservePageIndicator {
                VStack(spacing: 8) {
                    QuotaCardView(brand: brand, node: accounts.first,
                                  presentation: presentation)
                    Color.clear.frame(height: 6)
                }
            } else {
                QuotaCardView(brand: brand, node: accounts.first,
                              presentation: presentation)
            }
        } else {
            let safePage = clampedPage
            let current = accounts[safePage]
            VStack(spacing: 8) {
                QuotaCardView(brand: brand, node: current, accountLabel: current.account,
                              presentation: presentation)
                    .id(current.id)
                    .offset(x: dragX)
                    .allowsHitTesting(false)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragX) { v, s, _ in s = v.translation.width }
                        .onEnded { v in
                            let t = max(40, width * 0.2)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                if v.translation.width < -t, safePage < accounts.count - 1 {
                                    page = safePage + 1
                                } else if v.translation.width > t, safePage > 0 {
                                    page = safePage - 1
                                }
                            }
                        })
                dots
            }
            .background(GeometryReader { p in
                Color.clear.preference(key: CarouselWidthKey.self, value: p.size.width)
            })
            .onPreferenceChange(CarouselWidthKey.self) { width = $0 }
            .onChange(of: accounts.map(\.id)) { _ in
                page = min(page, max(0, accounts.count - 1))
            }
        }
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(accounts.indices, id: \.self) { i in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { page = i }
                } label: {
                    Capsule()
                        .fill(i == clampedPage ? brand.accent : Color.white.opacity(0.22))
                        .frame(width: i == clampedPage ? 15 : 6, height: 6)
                }.buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: clampedPage)
    }
}

// MARK: - 额度卡
struct QuotaCardView: View {
    let brand: Brand
    let node: QuotaNode?
    /// 多账号时显示的账号名（carousel 页）。
    var accountLabel: String? = nil
    var presentation: QuotaCardPresentation = .panelWide

    private var name: String { brand == .claude ? "Claude" : "Codex" }
    private var compact: Bool { presentation.isWidget }
    private var narrow: Bool { presentation.isDualPanel }
    private var radius: CGFloat { compact ? 16 : Theme.rLg }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(compact ? EdgeInsets(top: 10, leading: 11, bottom: 8, trailing: 11)
                         : EdgeInsets(top: 13, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity,
               maxHeight: presentation.isDualPanel ? .infinity : nil,
               alignment: .topLeading)
        .background(alignment: .topTrailing) {   // qcard::before 品牌辉光（右上角径向）
            RadialGradient(colors: [brand.tint, .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 170)
                .allowsHitTesting(false)
        }
        .glassCard(radius: radius)   // 小组件里由 \.flatCard 环境令其扁平（见 GlassCard）
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        if let node, node.ok {
            let windows = node.displayWindows
            head
            if windows.count == 1, let window = windows.first {
                singleWindowBody(window)
            } else if let mainIndex = primaryWindowIndex(in: windows) {
                let main = windows[mainIndex]
                let rest = windows.indices.filter { $0 != mainIndex }.map {
                    IndexedQuotaWindow(id: $0, window: windows[$0])
                }
                multiWindowBody(main: main, rest: rest)
            } else {
                Text(L("quota.noOther"))
                    .font(.system(size: compact ? 9 : 10.5)).foregroundStyle(Theme.ink3)
                    .padding(.vertical, compact ? 5 : 7)
            }
            if !compact, let foot = footer(node) {   // .qfoot：限流警示 / 烧录速率 / 额外用量 / Credits / 新鲜度
                if presentation.isDualPanel { Spacer(minLength: 0) }
                Divider().overlay(Color.white.opacity(0.07)).padding(.top, 9)
                Text(foot.text).font(.system(size: 9.5))
                    .foregroundStyle(foot.stale ? Color(hex: 0xffb38a) : Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        } else {
            // 错误/无额度态
            head
            Text(node?.hidden == true ? L("quota.loading")
                 : (node?.noQuota == true ? L("quota.noQuota") : L("quota.fetchFailed")))
                .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                .padding(.vertical, 6)
        }
    }

    /// 单窗口不再保留“主环 + 空副窗口”骨架，改为使用整行宽度表达唯一额度。
    private func singleWindowBody(_ window: QuotaWindow) -> some View {
        let used = pctText(window.usedPercent)
        let remaining = pctText(max(0, 100 - min(window.usedPercent, 100)))
        let countdown = Fmt.countdown(window.resetsAt?.date, compact: compact)
        let labelSize: CGFloat = compact ? 10 : (narrow ? 10.5 : 11.5)
        let valueSize: CGFloat = compact ? 11.5 : (narrow ? 13 : 14)
        let detailSize: CGFloat = compact ? 8.5 : (narrow ? 9.5 : 10)
        return VStack(alignment: .leading, spacing: compact ? 5 : 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.displayLabel)
                    .font(.system(size: labelSize, weight: .semibold))
                    .foregroundStyle(narrow ? Theme.ink2 : Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                Text("\(used)%")
                    .font(.rounded(valueSize, weight: .semibold))
                    .foregroundStyle(Theme.ink).fixedSize()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(Theme.gradient(for: window.level, brand: brand))
                        .frame(width: geo.size.width * min(max(window.usedPercent, 0), 100) / 100)
                        .animation(.easeOut(duration: 1), value: window.usedPercent)
                }
            }
            .frame(height: compact ? 4 : (narrow ? 4 : 5))
            HStack(spacing: 8) {
                Text(L("quota.remainingPercent", ["pct": remaining]))
                Spacer(minLength: 6)
                if !countdown.isEmpty { Text(countdown) }
            }
            .font(.system(size: detailSize, weight: .medium))
            .foregroundStyle(Theme.ink2).lineLimit(1)
        }
        .padding(.top, compact ? 7 : 9)
        .frame(minHeight: narrow ? 80 : nil, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("quota.windowSummary", [
            "window": window.displayLabel, "used": used,
            "remaining": remaining, "reset": countdown,
        ]))
    }

    /// 两个及以上窗口固定为“左环右条”：2 个窗口右侧 1 条，3 个窗口右侧 2 条，以此类推。
    private func multiWindowBody(main: QuotaWindow, rest: [IndexedQuotaWindow]) -> some View {
        let dense = compact && rest.count >= 3
        let ringSize: CGFloat = dense ? 44 : (compact ? 48 : (narrow ? 54 : 64))
        let ringWidth: CGFloat = dense ? 54 : (compact ? 58 : (narrow ? 66 : 76))
        return HStack(alignment: .top, spacing: compact ? 6 : (narrow ? 8 : 11)) {
            primaryRing(main, size: ringSize, columnWidth: ringWidth)
            VStack(alignment: .leading, spacing: dense ? 3 : (compact ? 6 : (narrow ? 7 : 9))) {
                ForEach(rest) {
                    WindowRow(window: $0.window, brand: brand,
                              presentation: presentation, dense: dense)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, dense ? 5 : (compact ? 7 : 9))
        .frame(minHeight: narrow ? 80 : nil, alignment: .top)
    }

    private func primaryRing(_ window: QuotaWindow, size: CGFloat,
                             columnWidth: CGFloat) -> some View {
        VStack(spacing: 3) {
            RingView(percent: window.usedPercent, brand: brand,
                     size: size, lineWidth: compact ? 5 : 6)
            Text(L("quota.primaryUsed", ["window": window.displayLabel]))
                .font(.system(size: compact ? 7.5 : 8.5, weight: .medium))
                .foregroundStyle(Theme.ink2).lineLimit(1).minimumScaleFactor(0.68)
            let countdown = Fmt.countdown(window.resetsAt?.date, compact: true)
            if !countdown.isEmpty {
                Text(countdown).font(.system(size: compact ? 7.5 : 8.5))
                    .foregroundStyle(Theme.ink3).lineLimit(1).minimumScaleFactor(0.68)
            }
        }
        .frame(width: columnWidth)
        .accessibilityElement(children: .combine)
    }

    /// 按窗口周期选择最短额度；未知周期排在已知周期之后，并保持上游原始顺序。
    private func primaryWindowIndex(in windows: [QuotaWindow]) -> Int? {
        windows.indices.min { lhs, rhs in
            let left = windows[lhs].windowSeconds ?? .greatestFiniteMagnitude
            let right = windows[rhs].windowSeconds ?? .greatestFiniteMagnitude
            return left == right ? lhs < rhs : left < right
        }
    }

    /// 卡片脚注（对应 quotaCardInner 的 .qfoot）：限流警示优先；
    /// Claude → 烧录速率 / 额外用量；Codex → 数据新鲜度 / Credits 余额 / 采样时间。
    private func footer(_ node: QuotaNode) -> (text: String, stale: Bool)? {
        if node.stale == true { return (L("quota.stale"), true) }
        if brand == .claude {
            let burn = Fmt.burnHint(node.displayWindows.first { $0.id == "five_hour" })
            if !burn.isEmpty { return (burn, false) }
            if let ex = node.raw?.extraUsage, ex.isEnabled == true {
                func cents(_ c: Double?) -> String {
                    let d = (c ?? 0) / 100
                    return d == d.rounded() ? "\(Int(d))" : String(format: "%.2f", d)
                }
                return (L("quota.extra", ["used": cents(ex.usedCredits), "limit": cents(ex.monthlyLimit)]).strippingBold, false)
            }
            return nil
        } else {
            // 新鲜度警示优先：数据不可信时其他信息没意义
            if let s = node.sampledAt, let d = Fmt.parseISO(s) {
                let age = Date().timeIntervalSince(d)
                if age > 2 * 3600 {
                    return (L("quota.dataStale", ["h": "\(Int((age / 3600).rounded()))"]), true)
                }
            }
            if let cr = node.credits, cr.hasCredits == true {
                let bal = cr.unlimited == true ? "∞" : "$\(creditFmt(cr.balance))"
                return (L("quota.credits", ["bal": bal]).strippingBold, false)
            }
            if let s = node.sampledAt, let d = Fmt.parseISO(s) {
                return (L("quota.sampledAt", ["time": Fmt.relative(d)]), false)
            }
            return nil
        }
    }
    private func creditFmt(_ b: Double?) -> String {
        let v = b ?? 0
        return v == v.rounded() ? "\(Int(v))" : String(format: "%.2f", v)
    }

    // .qhead：只承载品牌与账号；窗口语义放回对应的数据图形旁边。
    private var head: some View {
        HStack(alignment: .center, spacing: 6) {
            BrandBadge(brand: brand)
            Text(name).font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 名称不被右侧挤换行
            if let acct = accountLabel, !acct.isEmpty {
                Text(acct).font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
            }
            Spacer(minLength: 0)
        }
    }
}
