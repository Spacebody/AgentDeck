// AgentDeck v2 — 额度卡。忠实复刻 index.html quotaCardInner()（行 1189）：
// 头部(徽章+名+账号+副信息) · 主体(进度环 + 窗口条) · 脚注 · 品牌辉光 · 玻璃卡。
import SwiftUI
import AppKit

private extension View {
    /// The carousel needs focus for arrow-key paging, but the default macOS focus
    /// effect draws a persistent blue frame around the whole quota card.
    @ViewBuilder
    func quotaCarouselKeyboardFocus() -> some View {
        if #available(macOS 14.0, *) {
            focusable()
                .focusEffectDisabled()
        } else {
            // macOS 13 has no public API for suppressing a custom view's focus
            // effect. Keep the card unfocused instead of showing a stuck ring.
            self
        }
    }
}

/// 百分比文字：整数不带小数，否则保留 1 位（对应窗口条 ${used_percent}% 的原值，已 round 1）。
private func pctText(_ v: Double) -> String {
    v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}

struct QuotaStatusInfo {
    let text: String
    let stale: Bool
}

/// 额度卡右上角只展示数据新鲜度/降级状态，不混入余额、额外用量等额度内容。
func quotaStatusInfo(node: QuotaNode, now: Date = Date()) -> QuotaStatusInfo? {
    if node.stale == true {
        return QuotaStatusInfo(text: L("quota.stale"), stale: true)
    }
    guard let sampledAt = node.sampledAt, let date = Fmt.parseISO(sampledAt) else {
        return nil
    }
    let age = now.timeIntervalSince(date)
    if age > 2 * 3600 {
        return QuotaStatusInfo(
            text: L("quota.dataStale", ["h": "\(Int((age / 3600).rounded()))"]),
            stale: true)
    }
    return QuotaStatusInfo(
        text: L("quota.sampledAt", ["time": Fmt.relative(date, now: now)]),
        stale: false)
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
                Image(systemName: brand == .claude ? "sparkle"
                      : brand == .codex ? "apple.terminal" : "q.square")
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
            .frame(height: dense ? 2.5 : (presentation.isWidget ? 3
                           : (presentation.isDualPanel ? 4 : 5)))
        }
    }
}

/// 上游窗口 id 理论上应唯一，但展示层不能依赖该约束；用原始数组位置保持行身份稳定。
private struct IndexedQuotaWindow: Identifiable {
    let id: Int
    let window: QuotaWindow
}

/// 宽面板额度主体的稳定比例布局。右栏整体中心与左栏指定的视觉锚点对齐。
private struct QuotaColumnsLayout: Layout {
    let leadingFraction: CGFloat
    let spacing: CGFloat
    let leadingCenterY: CGFloat

    private func widths(totalWidth: CGFloat) -> (leading: CGFloat, trailing: CGFloat) {
        let available = max(0, totalWidth - spacing)
        let leading = available * leadingFraction
        return (leading, available - leading)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        let fallback = subviews.prefix(2).reduce(CGFloat.zero) {
            $0 + $1.sizeThatFits(.unspecified).width
        } + spacing
        let width = proposal.width ?? fallback
        let columns = widths(totalWidth: width)
        let leading = subviews[0].sizeThatFits(
            ProposedViewSize(width: columns.leading, height: proposal.height))
        let trailing = subviews[1].sizeThatFits(
            ProposedViewSize(width: columns.trailing, height: proposal.height))
        let commonCenterY = max(leadingCenterY, trailing.height / 2)
        let leadingBottom = commonCenterY - leadingCenterY + leading.height
        let trailingBottom = commonCenterY + trailing.height / 2
        return CGSize(width: width, height: max(leadingBottom, trailingBottom))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let columns = widths(totalWidth: bounds.width)
        let leadingProposal = ProposedViewSize(width: columns.leading, height: nil)
        let trailingProposal = ProposedViewSize(width: columns.trailing, height: nil)
        let trailingSize = subviews[1].sizeThatFits(trailingProposal)
        let commonCenterY = max(leadingCenterY, trailingSize.height / 2)

        subviews[0].place(
            at: CGPoint(x: bounds.minX,
                        y: bounds.minY + commonCenterY - leadingCenterY),
            anchor: .topLeading, proposal: leadingProposal)
        subviews[1].place(
            at: CGPoint(x: bounds.minX + columns.leading + spacing,
                        y: bounds.minY + commonCenterY - trailingSize.height / 2),
            anchor: .topLeading, proposal: trailingProposal)
    }
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

// MARK: - 多 Agent × 多账号拍平轮播
struct FlatQuotaCarousel: View {
    let pages: [QuotaPage]
    var autoRotate = true
    var interval = 6
    var isActive = true
    var selectionID: String? = nil
    var onSelectionChange: (String) -> Void = { _ in }
    var onRotationPauseChange: (Bool) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedID: String?
    @State private var width: CGFloat = 0
    @State private var hovering = false
    @State private var paused = false
    @State private var dragging = false
    @State private var movingForward = true
    @State private var lastAdvance = Date()
    @GestureState private var dragX: CGFloat = 0
    private var page: Int {
        guard !pages.isEmpty else { return 0 }
        return pages.firstIndex(where: { $0.id == selectedID }) ?? 0
    }
    private var canAutoRotate: Bool {
        pages.count > 1 && autoRotate && isActive && !hovering && !paused && dragX == 0
            && NSApplication.shared.keyWindow?.isVisible == true
    }
    private var normalizedInterval: TimeInterval {
        TimeInterval(normalizedQuotaRotationInterval(interval))
    }
    private var autoRotationTaskID: String {
        "\(autoRotate)-\(isActive)-\(interval)-\(pages.map(\.id).joined(separator: "|"))"
    }

    var body: some View {
        if pages.isEmpty {
            EmptyView()
        } else if pages.count == 1, let only = pages.first {
            QuotaCardView(brand: only.brand, node: only.account,
                          accountLabel: only.account.account)
        } else {
            VStack(spacing: 8) {
                ZStack(alignment: .topLeading) {
                    // Invisible copies participate in layout so the carousel height is the
                    // maximum page height and content below never jumps during rotation.
                    ForEach(pages) { item in
                        QuotaCardView(brand: item.brand, node: item.account,
                                      accountLabel: item.account.account)
                            .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    let current = pages[page]
                    QuotaCardView(brand: current.brand, node: current.account,
                                  accountLabel: current.account.account)
                        .id(current.id)
                        .offset(x: dragX)
                        .transition(cardTransition)
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.18)
                           : .spring(response: 0.34, dampingFraction: 0.86), value: page)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .updating($dragX) { value, state, _ in state = value.translation.width }
                        .onChanged { _ in
                            guard !dragging else { return }
                            dragging = true
                            publishPauseState()
                        }
                        .onEnded { value in
                            let threshold = max(40, width * 0.18)
                            if value.translation.width <= -threshold { select(page + 1) }
                            else if value.translation.width >= threshold { select(page - 1) }
                            else { lastAdvance = Date() }
                            dragging = false
                            publishPauseState()
                        })
                controls
            }
            .background(GeometryReader { proxy in
                Color.clear.preference(key: CarouselWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(CarouselWidthKey.self) { width = $0 }
            .onHover {
                hovering = $0
                publishPauseState()
                if !$0 { lastAdvance = Date() }
            }
            .onAppear { reconcileSelection(); lastAdvance = Date() }
            .onDisappear {
                hovering = false
                dragging = false
                publishPauseState()
            }
            .onChange(of: pages.map(\.id)) { _ in reconcileSelection() }
            .onChange(of: selectionID) { id in
                guard let id, pages.contains(where: { $0.id == id }), selectedID != id else { return }
                movingForward = direction(to: id)
                selectedID = id
                lastAdvance = Date()
            }
            .onChange(of: isActive) { _ in lastAdvance = Date() }
            .task(id: autoRotationTaskID) {
                guard autoRotate && isActive && pages.count > 1 else { return }
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    let now = Date()
                    guard canAutoRotate,
                          now.timeIntervalSince(lastAdvance) >= normalizedInterval else { continue }
                    // 状态栏轮播关闭时，概览仍可按自己的设置自动切换，但不能让已固定的
                    // 状态栏跟着滚动；用户手动切换仍通过下面的默认参数双向同步。
                    select(page + 1, notifySharedSelection: false)
                }
            }
            .quotaCarouselKeyboardFocus()
            .onMoveCommand { direction in
                if direction == .left { select(page - 1) }
                if direction == .right { select(page + 1) }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            carouselButton("chevron.left", label: L("quota.previous")) { select(page - 1) }
            Spacer(minLength: 0)
            if pages.count <= 6 {
                HStack(spacing: 5) {
                    ForEach(pages.indices, id: \.self) { index in
                        Button { select(index) } label: {
                            Capsule()
                                .fill(index == page ? pages[page].brand.accent : Color.white.opacity(0.22))
                                .frame(width: index == page ? 15 : 6, height: 6)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(index + 1) / \(pages.count)")
                    }
                }
            } else {
                Text("\(page + 1) / \(pages.count)")
                    .font(.rounded(10, weight: .semibold)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
            carouselButton(paused ? "play.fill" : "pause.fill",
                           label: paused ? L("quota.play") : L("quota.pause")) {
                paused.toggle()
                publishPauseState()
                lastAdvance = Date()
            }
            carouselButton("chevron.right", label: L("quota.next")) { select(page + 1) }
        }
        .padding(.horizontal, 4)
    }

    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: movingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: movingForward ? .leading : .trailing).combined(with: .opacity))
    }

    private func carouselButton(_ system: String, label: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink2)
                .frame(width: 22, height: 18)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func reconcileSelection() {
        let preferred = selectedID.flatMap { id in
            pages.contains(where: { $0.id == id }) ? id : nil
        } ?? selectionID.flatMap { id in
            pages.contains(where: { $0.id == id }) ? id : nil
        }
        selectedID = reconciledQuotaSelection(currentID: preferred, pages: pages)
        lastAdvance = Date()
    }

    private func direction(to id: String) -> Bool {
        guard let target = pages.firstIndex(where: { $0.id == id }) else { return true }
        return target > page || (page == pages.count - 1 && target == 0)
    }

    private func publishPauseState() {
        onRotationPauseChange(paused || hovering || dragging)
    }

    private func select(_ requested: Int, notifySharedSelection: Bool = true) {
        guard !pages.isEmpty else { return }
        let target = (requested % pages.count + pages.count) % pages.count
        movingForward = requested > page || (page == pages.count - 1 && target == 0)
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.18)) { selectedID = pages[target].id }
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                selectedID = pages[target].id
            }
        }
        if notifySharedSelection { onSelectionChange(pages[target].id) }
        lastAdvance = Date()
    }
}

// MARK: - 额度卡
struct QuotaCardView: View {
    let brand: Brand
    let node: QuotaNode?
    /// 多账号时显示的账号名（carousel 页）。
    var accountLabel: String? = nil
    var presentation: QuotaCardPresentation = .panelWide

    private var name: String {
        switch brand {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .qoder: return "Qoder"
        }
    }
    private var compact: Bool { presentation.isWidget }
    private var narrow: Bool { presentation.isDualPanel }
    private var radius: CGFloat { compact ? 16 : Theme.rLg }
    private var dualBodyMinHeight: CGFloat { 104 }

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
            } else if let mainIndex = QuotaWindowPolicy.preferredPrimaryIndex(
                ids: windows.map(\.id)) {
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
        } else {
            // 错误/无额度态
            head
            VStack(alignment: .leading, spacing: 3) {
                Text(node?.hidden == true ? L("quota.loading")
                     : (node?.noQuota == true ? L("quota.noQuota") : L("quota.fetchFailed")))
                if node?.hidden != true, let detail = node?.error, !detail.isEmpty {
                    Text(detail).font(.system(size: 9.5)).foregroundStyle(Theme.ink3.opacity(0.8))
                        .lineLimit(2)
                }
            }
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
        return VStack(alignment: .leading,
                      spacing: compact ? 5 : (narrow ? 0 : 7)) {
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
            if narrow { Spacer(minLength: 8) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(Theme.gradient(for: window.level, brand: brand))
                        .frame(width: geo.size.width * min(max(window.usedPercent, 0), 100) / 100)
                        .animation(.easeOut(duration: 1), value: window.usedPercent)
                }
            }
            .frame(height: compact ? 4 : (narrow ? 4 : 5))
            if narrow { Spacer(minLength: 8) }
            HStack(spacing: 8) {
                Text(L("quota.remainingPercent", ["pct": remaining]))
                Spacer(minLength: 6)
                if !countdown.isEmpty { Text(countdown) }
            }
            .font(.system(size: detailSize, weight: .medium))
            .foregroundStyle(Theme.ink2).lineLimit(1)
        }
        .padding(.top, compact ? 7 : (narrow ? 8 : 9))
        .padding(.bottom, narrow ? 2 : 0)
        .frame(height: narrow ? dualBodyMinHeight : nil, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("quota.windowSummary", [
            "window": window.displayLabel, "used": used,
            "remaining": remaining, "reset": countdown,
        ]))
    }

    /// 两个及以上窗口固定为“左环右条”：2 个窗口右侧 1 条，3 个窗口右侧 2 条，以此类推。
    @ViewBuilder
    private func multiWindowBody(main: QuotaWindow, rest: [IndexedQuotaWindow]) -> some View {
        switch presentation {
        case .panelWide:
            centeredMultiWindowBody(
                main: main, rest: rest,
                ringSize: rest.count == 1 ? 98 : 88,
                leadingFraction: 1 / 3, spacing: 14)
        case .panelDual:
            centeredMultiWindowBody(
                main: main, rest: rest,
                ringSize: rest.count == 1 ? 70 : 58,
                leadingFraction: 0.42, spacing: 8)
        case .widget:
            widgetMultiWindowBody(main: main, rest: rest)
        }
    }

    /// 面板卡统一以圆心为视觉锚点：右侧单行或多行组的整体中心始终对齐圆心。
    private func centeredMultiWindowBody(main: QuotaWindow,
                                         rest: [IndexedQuotaWindow],
                                         ringSize: CGFloat,
                                         leadingFraction: CGFloat,
                                         spacing: CGFloat) -> some View {
        QuotaColumnsLayout(leadingFraction: leadingFraction, spacing: spacing,
                           leadingCenterY: ringSize / 2) {
            VStack(spacing: 4) {
                RingView(percent: main.usedPercent, brand: brand,
                         size: ringSize, lineWidth: 6)
                primaryRingCaption(main, singleLine: rest.count == 1)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 9) {
                ForEach(rest) {
                    WindowRow(window: $0.window, brand: brand,
                              presentation: presentation)
                }
            }
        }
        .padding(.top, 9)
        .frame(minHeight: narrow ? dualBodyMinHeight : nil, alignment: .center)
    }

    private func widgetMultiWindowBody(main: QuotaWindow,
                                       rest: [IndexedQuotaWindow]) -> some View {
        let dense = rest.count >= 3
        let ringSize: CGFloat = dense ? 44 : 48
        let ringWidth: CGFloat = dense ? 54 : 58
        return HStack(alignment: .top, spacing: 6) {
            primaryRing(main, size: ringSize, columnWidth: ringWidth)
            VStack(alignment: .leading, spacing: dense ? 3 : 6) {
                ForEach(rest) {
                    WindowRow(window: $0.window, brand: brand,
                              presentation: presentation, dense: dense)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, dense ? 5 : 7)
    }

    @ViewBuilder
    private func primaryRingCaption(_ window: QuotaWindow,
                                    singleLine: Bool) -> some View {
        let countdown = Fmt.countdown(window.resetsAt?.date, compact: true)
        if singleLine {
            // 半宽双栏优先保住完整单行，圆环本身已表达“已用”，这里省略重复词。
            let primary = narrow
                ? window.displayLabel
                : L("quota.primaryUsed", ["window": window.displayLabel])
            let visibleCountdown = narrow
                ? Fmt.countdownToken(window.resetsAt?.date)
                : countdown
            let parts = [primary, visibleCountdown]
                .filter { !$0.isEmpty }
            Text(parts.joined(separator: " · "))
                .font(.system(size: narrow ? 8.5 : 9.5, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(narrow ? 0.78 : 0.75)
                .accessibilityLabel(primaryRingAccessibility(window, countdown: countdown))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("quota.primaryUsed", ["window": window.displayLabel]))
                    .foregroundStyle(Theme.ink2)
                if !countdown.isEmpty {
                    Text(countdown).foregroundStyle(Theme.ink3)
                }
            }
            .font(.system(size: narrow ? 8.5 : 9.5, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(narrow ? 0.68 : 0.75)
            .accessibilityLabel(primaryRingAccessibility(window, countdown: countdown))
        }
    }

    private func primaryRingAccessibility(_ window: QuotaWindow,
                                          countdown: String) -> String {
        L("quota.windowSummary", [
            "window": window.displayLabel,
            "used": pctText(window.usedPercent),
            "remaining": pctText(max(0, 100 - min(window.usedPercent, 100))),
            "reset": countdown,
        ])
    }

    private func primaryRing(_ window: QuotaWindow, size: CGFloat,
                             columnWidth: CGFloat) -> some View {
        VStack(spacing: 3) {
            RingView(percent: window.usedPercent, brand: brand,
                     size: size, lineWidth: compact ? 5 : 6)
            Text(L("quota.primaryUsed", ["window": window.displayLabel]))
                .font(.system(size: compact ? 7.5 : (narrow ? 8.5 : 9.5), weight: .medium))
                .foregroundStyle(Theme.ink2).lineLimit(1).minimumScaleFactor(0.68)
            let countdown = Fmt.countdown(window.resetsAt?.date, compact: true)
            if !countdown.isEmpty {
                Text(countdown).font(.system(size: compact ? 7.5 : (narrow ? 8.5 : 9.5)))
                    .foregroundStyle(Theme.ink3).lineLimit(1).minimumScaleFactor(0.68)
            }
        }
        .frame(width: columnWidth)
        .accessibilityElement(children: .combine)
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
            if let headerStatus {
                Text(headerStatus.text)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(headerStatus.stale
                        ? Color(hex: 0xffb38a) : Theme.ink3)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(narrow ? 2 : 1)
                    .minimumScaleFactor(narrow ? 0.72 : 0.78)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: narrow ? 105 : 220, alignment: .trailing)
            }
        }
    }

    private var headerStatus: QuotaStatusInfo? {
        guard let node else { return nil }
        return quotaStatusInfo(node: node)
    }
}
