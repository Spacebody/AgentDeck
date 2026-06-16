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
                Text("\(Int(percent.rounded()))").font(.rounded(15, weight: .heavy))
                Text("%").font(.rounded(9, weight: .bold)).foregroundStyle(Theme.ink2)
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

    private static func image(_ brand: Brand) -> NSImage? {
        guard let url = Bundle.module.url(forResource: brand.rawValue, withExtension: "png",
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
                    .font(.system(size: glyph, weight: .medium))
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
                        Text(cd).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Text("\(pctText(window.usedPercent))%")
                    .font(.rounded(11, weight: .bold)).foregroundStyle(Theme.ink)
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

// MARK: - 额度卡
struct QuotaCardView: View {
    let brand: Brand
    let node: QuotaNode?
    /// 多账号时显示的账号名（carousel 页）。
    var accountLabel: String? = nil
    /// 小组件紧凑模式：圆角 16、去重置进度条、内距收紧（对应 body.wgt .qcard）。
    var compact: Bool = false

    private var name: String { brand == .claude ? "Claude" : "Codex" }
    private var radius: CGFloat { compact ? 16 : Theme.rLg }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(compact ? EdgeInsets(top: 10, leading: 11, bottom: 8, trailing: 11)
                         : EdgeInsets(top: 13, leading: 13, bottom: 11, trailing: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
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
            let rest = windows.dropFirst().filter { $0.usedPercent > 0 || $0.resetsAt?.date != nil }
            head(main: main)
            HStack(spacing: 11) {                 // .qbody
                RingView(percent: main?.usedPercent ?? 0, brand: brand)
                VStack(alignment: .leading, spacing: 9) {   // .qmeta
                    if rest.isEmpty {
                        Text("无其他窗口").font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                    } else {
                        ForEach(rest) { WindowRow(window: $0, brand: brand) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 9)   // .qhead margin-bottom:9
        } else {
            // 错误/无额度态
            head(main: nil)
            Text(node?.noQuota == true ? "暂无额度信息" : "额度获取失败")
                .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                .padding(.vertical, 6)
        }
    }

    // .qhead：徽章 + 名称 + 账号 tag + 右侧副信息（主窗口名 + 倒计时 + 重置进度条）
    // v1 align-items:center → 徽章与名称垂直居中对齐。
    @ViewBuilder private func head(main: QuotaWindow?) -> some View {
        HStack(alignment: .center, spacing: 6) {
            BrandBadge(brand: brand)
            Text(name).font(.system(size: 12.5, weight: .bold))
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 名称不被右侧挤换行
            if let acct = accountLabel, !acct.isEmpty {
                Text(acct).font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.09)))
            }
            Spacer(minLength: 6)
            if let main {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(main.displayLabel).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                    let cd = Fmt.countdown(main.resetsAt?.date)
                    if !cd.isEmpty {
                        Text(cd).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
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
