// AgentDeck v2 — 额度卡。忠实复刻 index.html quotaCardInner()（行 1189）：
// 头部(徽章+名+账号+副信息) · 主体(进度环 + 窗口条) · 脚注 · 品牌辉光 · 玻璃卡。
import SwiftUI

/// 百分比文字：整数不带小数，否则保留 1 位（对应窗口条 ${used_percent}% 的原值，已 round 1）。
private func pctText(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
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
                Text("\(Int(percent.rounded()))").font(.rounded(15, weight: .bold))
                Text("%").font(.rounded(9, weight: .semibold)).foregroundStyle(Theme.ink2)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(window.displayLabel)
                        .font(.system(size: 10.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    let cd = Fmt.countdown(window.resetsAt?.date, compact: true)
                    if !cd.isEmpty {
                        Text(cd).font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text("\(pctText(window.usedPercent))%")
                    .font(.rounded(11, weight: .semibold)).foregroundStyle(Theme.ink)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(Theme.gradient(for: window.level, brand: brand))
                        .frame(width: geo.size.width * min(window.usedPercent, 100) / 100)
                        .animation(.easeOut(duration: 1), value: window.usedPercent)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - 多账号 carousel（对应 renderQuotaTool）：单账号→单卡；多账号→横向翻页 + 圆点。
// macOS 13 无 scrollTargetBehavior，手写 offset + 拖拽翻页（宽度经 PreferenceKey 量取）。
private struct CarouselWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct QuotaCarousel: View {
    let brand: Brand
    let accounts: [QuotaNode]
    var compact: Bool = false
    var fillHeight: Bool = false

    @State private var page = 0
    @State private var width: CGFloat = 0
    @GestureState private var dragX: CGFloat = 0

    var body: some View {
        if accounts.count <= 1 {
            QuotaCardView(brand: brand, node: accounts.first, compact: compact, fillHeight: fillHeight)
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(Array(accounts.enumerated()), id: \.offset) { _, node in
                        QuotaCardView(brand: brand, node: node, accountLabel: node.account,
                                      compact: compact, fillHeight: fillHeight)
                            .frame(width: width > 0 ? width : nil)
                    }
                }
                .frame(width: width > 0 ? width : nil, alignment: .leading)
                .offset(x: -CGFloat(page) * width + dragX)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .updating($dragX) { v, s, _ in s = v.translation.width }
                        .onEnded { v in
                            let t = max(40, width * 0.2)
                            if v.translation.width < -t, page < accounts.count - 1 { page += 1 }
                            else if v.translation.width > t, page > 0 { page -= 1 }
                        })
                .animation(.spring(response: 0.35, dampingFraction: 0.86), value: page)
                .animation(.interactiveSpring(), value: dragX)
                dots
            }
            .background(GeometryReader { p in
                Color.clear.preference(key: CarouselWidthKey.self, value: p.size.width)
            })
            .onPreferenceChange(CarouselWidthKey.self) { width = $0 }
        }
    }

    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(accounts.indices, id: \.self) { i in
                Button { page = i } label: {
                    Capsule()
                        .fill(i == page ? brand.accent : Color.white.opacity(0.22))
                        .frame(width: i == page ? 15 : 6, height: 6)
                }.buttonStyle(.plain)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: page)
    }
}

// MARK: - 额度卡
struct QuotaCardView: View {
    let brand: Brand
    let node: QuotaNode?
    /// 多账号时显示的账号名（carousel 页）。
    var accountLabel: String? = nil
    /// 小组件紧凑模式：圆角 16、去重置进度条、内距收紧（对应 body.wgt .qcard）。
    var compact: Bool = false
    /// 等高拉伸：两张额度卡并排时撑到同高（对应 v1 CSS grid stretch）。
    var fillHeight: Bool = false

    private var name: String { brand == .claude ? "Claude" : "Codex" }
    private var radius: CGFloat { compact ? 16 : Theme.rLg }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(compact ? EdgeInsets(top: 10, leading: 11, bottom: 8, trailing: 11)
                         : EdgeInsets(top: 13, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading)
        .background(alignment: .topTrailing) {   // qcard::before 品牌辉光（右上角径向）
            RadialGradient(colors: [brand.tint, .clear], center: .topTrailing,
                           startRadius: 0, endRadius: 170)
                .allowsHitTesting(false)
        }
        .glassCard(radius: radius)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    @ViewBuilder private var content: some View {
        if let node, node.ok {
            let windows = node.displayWindows
            let main = windows.first
            // 小组件(compact)只显示有用量的副窗口；主面板还显示有重置时间的（对应 v1 wgt ? >0% : >0%||resets_at）
            let rest = windows.dropFirst().filter { compact ? $0.usedPercent > 0 : ($0.usedPercent > 0 || $0.resetsAt?.date != nil) }
            head(main: main)
            HStack(spacing: 11) {                 // .qbody
                RingView(percent: main?.usedPercent ?? 0, brand: brand)
                VStack(alignment: .leading, spacing: 9) {   // .qmeta
                    if rest.isEmpty {
                        Text(L("quota.noOther")).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                    } else {
                        ForEach(rest) { WindowRow(window: $0, brand: brand) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 9)   // .qhead margin-bottom:9
            if !compact, let foot = footer(node) {   // .qfoot：限流警示 / 烧录速率 / 额外用量 / Credits / 新鲜度
                Divider().overlay(Color.white.opacity(0.07)).padding(.top, 9)
                Text(foot.text).font(.system(size: 9.5))
                    .foregroundStyle(foot.stale ? Color(hex: 0xffb38a) : Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        } else {
            // 错误/无额度态
            head(main: nil)
            Text(node?.noQuota == true ? L("quota.noQuota") : L("quota.fetchFailed"))
                .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                .padding(.vertical, 6)
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

    // .qhead：徽章 + 名称 + 账号 tag + 右侧副信息（主窗口名 + 倒计时 + 重置进度条）
    // v1 align-items:center → 徽章与名称垂直居中对齐。
    @ViewBuilder private func head(main: QuotaWindow?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            BrandBadge(brand: brand)
            Text(name).font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 名称不被右侧挤换行
            if let acct = accountLabel, !acct.isEmpty {
                Text(acct).font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
            }
            Spacer(minLength: 6)
            if let main {
                // 小组件窄卡：副信息缩到 8.5px 防截断（对应 body.wgt .qsub）。
                let subSize: CGFloat = compact ? 8.5 : 10.5
                VStack(alignment: .trailing, spacing: 2) {
                    Text(main.displayLabel).font(.system(size: subSize)).foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                    let cd = Fmt.countdown(main.resetsAt?.date, compact: compact)
                    if !cd.isEmpty {
                        Text(cd).font(.system(size: subSize)).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                    if !compact, let elapsed = main.resetElapsed() {   // .qreset 重置进度微条（widget 隐藏）
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.10))
                            Capsule().fill(Color.white.opacity(0.32))
                                .frame(width: 84 * elapsed)
                        }
                        .frame(width: 84, height: 3)
                    }
                }
            }
        }
    }
}
