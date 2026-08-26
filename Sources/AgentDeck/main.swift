// AgentDeck — 菜单栏壳：状态栏 icon + 自定义 HUD 玻璃面板(原生 SwiftUI) + 后端守护
import Cocoa
import Darwin
import ServiceManagement
import SwiftUI
import AgentDeckKit

let kPort = 7777
let kBase = "http://127.0.0.1:\(kPort)"          // 原生请求 / 浏览器打开用

struct BackendHealth {
    let alive: Bool
    let version: String?
    let pid: pid_t?
    let parentPID: pid_t?
    let instanceID: String?
    let updateTransaction: String?
    let ownerToken: String?
    let scriptPath: String?

    func belongs(
        to appPID: pid_t, version expected: String,
        updateTransaction expectedTransaction: String?, ownerToken expectedOwner: String
    ) -> Bool {
        BackendOwnerPolicy.belongsToCurrentApp(
            alive: alive,
            remoteVersion: version,
            remoteParentPID: parentPID,
            remoteUpdateTransaction: updateTransaction,
            remoteOwnerToken: ownerToken,
            currentPID: appPID,
            currentVersion: expected,
            expectedUpdateTransaction: expectedTransaction,
            expectedOwnerToken: expectedOwner)
    }
}

typealias BackendReadyCallback = @MainActor @Sendable () -> Void

// App→自身 daemon 的连接必须绕过系统代理：某些企业安全软件装的是系统级 PAC，会把
// 127.0.0.1 也改道到 SOCKS（代理到不了回环）→ WebView/URLSession 连不上本机后端。
// 显式禁用所有代理后直连回环。
let kDirectSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.connectionProxyDictionary = [
        kCFNetworkProxiesHTTPEnable as String: false,
        kCFNetworkProxiesHTTPSEnable as String: false,
        kCFNetworkProxiesSOCKSEnable as String: false,
        kCFNetworkProxiesProxyAutoConfigEnable as String: false,
    ]
    cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    cfg.timeoutIntervalForRequest = 20
    return URLSession(configuration: cfg)
}()

// 默认高取概览页全显 + 设置页大半的折中值，展示时钳制到屏幕可视高度
let kPanelW: CGFloat = 420, kPanelH: CGFloat = 780
let kWidgetMinW: CGFloat = 360, kWidgetMinH: CGFloat = 300

func quotaAlertColor(_ level: String) -> NSColor {
    switch level {
    case "crit":  return NSColor(calibratedRed: 1.00, green: 0.32, blue: 0.41, alpha: 1)
    case "reset": return NSColor(calibratedRed: 0.45, green: 0.89, blue: 0.63, alpha: 1)
    default:      return NSColor(calibratedRed: 1.00, green: 0.82, blue: 0.28, alpha: 1)
    }
}

func quotaWarnColor() -> NSColor { quotaAlertColor("warn") }

// ----------------------------------------------------------------- 多语言 i18n
// 应用壳的菜单 / 灵动岛 / 通知文案。有效 locale 由 daemon 经 /api/events 下发，
// 与面板、后端三层一致；首次轮询前回退到系统语言。
func systemLocale() -> String {
    let pref = (Locale.preferredLanguages.first ?? "en").lowercased()
    if pref.hasPrefix("zh") { return "zh-CN" }
    if pref.hasPrefix("ja") { return "ja" }
    return "en"
}
var appLocale = systemLocale()
let kStrings: [String: [String: String]] = [
    "zh-CN": [
        "menu.openBrowser": "在浏览器中打开", "menu.restartBackend": "重启后端",
        "menu.loginItem": "开机自启", "menu.widget": "桌面小组件", "menu.quit": "退出 AgentDeck",
        "island.done": "会话完成", "island.taskDone": "任务完成",
        "alert.warn": "额度提醒", "alert.crit": "额度严重", "alert.reset": "额度恢复",
    ],
    "en": [
        "menu.openBrowser": "Open in browser", "menu.restartBackend": "Restart backend",
        "menu.loginItem": "Launch at login", "menu.widget": "Desktop widget", "menu.quit": "Quit AgentDeck",
        "island.done": "Session done", "island.taskDone": "Task complete",
        "alert.warn": "Quota warning", "alert.crit": "Quota critical", "alert.reset": "Quota recovered",
    ],
    "ja": [
        "menu.openBrowser": "ブラウザで開く", "menu.restartBackend": "バックエンドを再起動",
        "menu.loginItem": "ログイン時に起動", "menu.widget": "デスクトップウィジェット", "menu.quit": "AgentDeck を終了",
        "island.done": "セッション完了", "island.taskDone": "タスク完了",
        "alert.warn": "残量警告", "alert.crit": "残量重大", "alert.reset": "残量回復",
    ],
]
@MainActor func L(_ key: String) -> String {
    return kStrings[appLocale]?[key] ?? kStrings["en"]?[key] ?? key
}

/// 无边框面板：允许成为 key window（搜索框输入需要）
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 小组件顶部拖拽把手：NSHostingView 吞掉鼠标事件，isMovableByWindowBackground 失效，
/// 用原生透明条 + performDrag 实现拖动
final class DragHandle: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 全幅透明层：按住 ⌘ 时任意位置都能拖走小组件（解决顶部把手被遮挡/找不到时无法拖动）。
/// 不按 ⌘ 时 hitTest 返回 nil → 事件穿透给底下的 webview，点击开面板 / 多账号 carousel 滑动照常。
final class CmdDragView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        NSEvent.modifierFlags.contains(.command) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 顶亮底暗的渐变描边（rim light）：系统桌面小组件的边缘语言——
/// 顶部受光更亮、向下渐隐，比均匀白边更有体积感。点击穿透，不挡交互
final class RimView: NSView {
    var radius: CGFloat = 28
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2),
                          cornerHeight: min(radius, r.height / 2), transform: nil)
        ctx.addPath(path.copy(strokingWithWidth: 1, lineCap: .round,
                              lineJoin: .round, miterLimit: 10))
        ctx.clip()
        let colors = [NSColor.white.withAlphaComponent(0.04).cgColor,   // 底
                      NSColor.white.withAlphaComponent(0.10).cgColor,
                      NSColor.white.withAlphaComponent(0.34).cgColor]   // 顶
        guard let grad = CGGradient(colorsSpace: nil, colors: colors as CFArray,
                                    locations: [0, 0.55, 1]) else { return }
        ctx.drawLinearGradient(grad,
                               start: CGPoint(x: bounds.midX, y: 0),
                               end: CGPoint(x: bounds.midX, y: bounds.height),
                               options: [])
    }
}

/// 边缘缩放光标提示：borderless 窗口没有系统光标反馈，用户不知道可拉伸。
/// hitTest 穿透不拦事件；NSTrackingArea 按几何触发，照常收 mouseMoved
final class EdgeCursorView: NSView {
    var allowTop = true   // 小组件顶部是拖动把手，不提示缩放
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let m: CGFloat = 7
        let l = p.x < m, r = p.x > bounds.width - m
        let b = p.y < m, t = allowTop && p.y > bounds.height - m
        guard l || r || b || t else { return }   // 非边带不干预，光标交还内容视图
        // NSCursor.FrameResizePosition 是 macOS 15+ 类型，整段引用须收进可用性守卫内，
        // 否则部署目标 13.0 编译报错（14.4.1 等旧系统支持的前提）
        if #available(macOS 15.0, *) {
            var pos: NSCursor.FrameResizePosition
            if l && b { pos = .bottomLeft } else if r && b { pos = .bottomRight }
            else if l && t { pos = .topLeft } else if r && t { pos = .topRight }
            else if l { pos = .left } else if r { pos = .right }
            else if b { pos = .bottom } else { pos = .top }
            NSCursor.frameResize(position: pos, directions: .all).set()
        } else {
            if l || r { NSCursor.resizeLeftRight.set() } else { NSCursor.resizeUpDown.set() }
        }
    }
}

func addEdgeCursor(to view: NSView, allowTop: Bool = true) {
    let edge = EdgeCursorView(frame: view.bounds)
    edge.allowTop = allowTop
    edge.autoresizingMask = [.width, .height]
    view.addSubview(edge, positioned: .above, relativeTo: nil)
}

func addRim(to view: NSView, radius: CGFloat) {
    let rim = RimView(frame: view.bounds)
    rim.radius = radius
    rim.autoresizingMask = [.width, .height]
    view.addSubview(rim, positioned: .above, relativeTo: nil)
}

/// behindWindow 模糊的圆角必须用 maskImage 裁，layer.cornerRadius 裁不到材质本体。
/// 用 CALayer cornerCurve=.continuous 渲染连续曲率角（squircle）——
/// 与系统桌面小组件同款，弧线与直边 G2 平滑过渡，普通圆弧角对比下显生硬
func roundedMask(radius: CGFloat) -> NSImage {
    let inset = ceil(radius * 1.6)   // 连续曲率角的影响范围 ≈ 1.528r
    let edge = inset * 2 + 1
    let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let layer = CALayer()
        layer.frame = rect
        layer.backgroundColor = NSColor.black.cgColor
        layer.cornerRadius = radius
        layer.cornerCurve = .continuous
        layer.render(in: ctx)
        return true
    }
    img.capInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
    img.resizingMode = .stretch
    return img
}

// 反馈邮件：先探 mailto 处理器，缺失或 open 失败则把邮箱复制到剪贴板 + 弹框告知。
// 默认 NSWorkspace.open 在没有默认邮件客户端时静默 no-op，用户点了按钮没反应不知道为啥。
func openMailto(_ url: URL) {
    let probe = URL(string: "mailto:test@example.com")!
    let hasHandler = NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    if hasHandler && NSWorkspace.shared.open(url) { return }
    let raw = String(url.absoluteString.dropFirst("mailto:".count))
    let email = raw.components(separatedBy: "?").first ?? raw
    if !email.isEmpty {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(email, forType: .string)
    }
    let alert = NSAlert()
    alert.alertStyle = .informational
    let lang = Locale.preferredLanguages.first ?? "en"
    if lang.hasPrefix("zh") {
        alert.messageText = "未检测到默认邮件客户端"
        alert.informativeText = "已将反馈邮箱 \(email) 复制到剪贴板，可粘贴到任意邮件服务发送，或直接到 GitHub Issues 反馈。"
        alert.addButton(withTitle: "好的")
    } else if lang.hasPrefix("ja") {
        alert.messageText = "メールクライアントが見つかりません"
        alert.informativeText = "メールアドレス \(email) をクリップボードにコピーしました。任意のメールサービスに貼り付けるか、GitHub Issues からご報告ください。"
        alert.addButton(withTitle: "OK")
    } else {
        alert.messageText = "No default mail client"
        alert.informativeText = "Copied feedback email \(email) to clipboard. Paste it into any mail service, or report via GitHub Issues."
        alert.addButton(withTitle: "OK")
    }
    alert.runModal()
}

// 自动粘贴：合成 ⌘V + 回车，让无 CLI 注入的终端（Warp / VS Code / Cursor…）一键直达会话。
// 首次未授权时 kAXTrustedCheckOptionPrompt=true 会拉起系统授权框，我们再补一个引导 NSAlert
// 兜底（提示用户去系统设置授权 + 当次仍可手动粘贴）。
func autoPasteEnter() {
    let opt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trusted = AXIsProcessTrustedWithOptions([opt: true] as CFDictionary)
    if !trusted {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let lang = Locale.preferredLanguages.first ?? "en"
        if lang.hasPrefix("zh") {
            alert.messageText = "需要「辅助功能」权限"
            alert.informativeText = "AgentDeck 需要辅助功能权限才能自动粘贴并回车。请去 系统设置 → 隐私与安全性 → 辅助功能 勾选 AgentDeck，然后重新点击恢复按钮。本次命令已复制到剪贴板，可手动 ⌘V 回车。"
            alert.addButton(withTitle: "好的")
        } else if lang.hasPrefix("ja") {
            alert.messageText = "アクセシビリティ権限が必要"
            alert.informativeText = "自動ペースト+Enter には、システム設定 → プライバシーとセキュリティ → アクセシビリティ で AgentDeck を許可してください。コマンドはクリップボードにコピー済み、今回は手動で ⌘V + Enter を実行できます。"
            alert.addButton(withTitle: "OK")
        } else {
            alert.messageText = "Accessibility permission required"
            alert.informativeText = "Grant AgentDeck under System Settings → Privacy & Security → Accessibility to enable auto paste & return. The command is on the clipboard; you can ⌘V + Return manually this time."
            alert.addButton(withTitle: "OK")
        }
        alert.runModal()
        return
    }
    // 已授权：等 ~800ms 让目标终端拿到焦点（open -a 异步前台），再合成按键
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
        let src = CGEventSource(stateID: .hidSystemState)
        let kV: CGKeyCode = 0x09, kReturn: CGKeyCode = 0x24
        if let d = CGEvent(keyboardEventSource: src, virtualKey: kV, keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: kV, keyDown: false) {
            d.flags = .maskCommand; u.flags = .maskCommand
            d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        }
        Thread.sleep(forTimeInterval: 0.08)   // 让目标 App 消化完 paste 再发回车
        if let d = CGEvent(keyboardEventSource: src, virtualKey: kReturn, keyDown: true),
           let u = CGEvent(keyboardEventSource: src, virtualKey: kReturn, keyDown: false) {
            d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        }
    }
}

/// SwiftUI 承载层：把 AgentDeckKit 的根视图装进 NSHostingView，背景透明以透出系统玻璃。
final class HostController: NSViewController {
    private let host: NSView
    init(_ root: some View) {
        let h = NSHostingView(rootView: root)
        h.layer?.backgroundColor = .clear
        // 关键：不让 NSHostingView 用 SwiftUI 内容尺寸去驱动/约束窗口大小，
        // 否则用户手动拉伸会被内容尺寸顶回（表现为「重开仍是原始大小」）。
        // 窗口尺寸完全由 AppDelegate（保存/恢复 panelW/H）说了算，内容随窗口自适应。
        h.sizingOptions = []
        host = h
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = host }
}

// MARK: - 灵动岛式完成提醒
@MainActor
final class IslandController {
    static let shared = IslandController()
    typealias Event = IslandEvent
    private var queue = IslandEventQueue()
    private var showing = false
    private var window: KeyPanel?
    private var current: Event?
    private var shownAt: Date?
    private var scheduledDismissAt: Date?
    private var dismissWorkItem: DispatchWorkItem?
    var onTap: ((Event?) -> Void)?
    var dwellSecs: Double = 5   // 停留时长，由设置经 /api/events 下发

    func push(_ event: Event) {
        queue.enqueue(event)
        accelerateCurrentIfNeeded()
        maybeShow()
    }

    private func accelerateCurrentIfNeeded() {
        guard showing, !queue.isEmpty, let window, let shownAt else { return }
        scheduleDismiss(window, at: IslandQueueTiming.deadline(
            shownAt: shownAt, configuredDwell: dwellSecs, hasPending: true))
    }

    private func scheduleDismiss(_ target: KeyPanel, at deadline: Date) {
        if let scheduledDismissAt, scheduledDismissAt <= deadline { return }
        dismissWorkItem?.cancel()
        self.scheduledDismissAt = deadline
        let work = DispatchWorkItem { [weak self, weak target] in
            guard let self, let target, self.window === target else { return }
            self.dismiss()
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: work)
    }

    private func maybeShow() {
        guard !showing, let event = queue.popFirst() else { return }
        showing = true
        display(event)
    }

    private func brandIcon(for tool: String) -> NSImage {
        let key = ["claude", "codex", "qoder", "qoder_cn"].contains(tool.lowercased())
            ? tool.lowercased() : "claude"
        let bundleName = "AgentDeck_AgentDeckKit.bundle"
        let bases = [Bundle.main.resourceURL,
                     Bundle.main.bundleURL,
                     Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")]
        for base in bases.compactMap({ $0 }) {
            if let b = Bundle(url: base.appendingPathComponent(bundleName)),
               let url = b.url(forResource: key, withExtension: "png", subdirectory: "Brand"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 26, height: 26)
                return img
            }
        }
        let conf = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        let symbol = key == "claude" ? "sparkle" : key == "codex" ? "apple.terminal" : "q.square"
        let img = NSImage(systemSymbolName: symbol,
                          accessibilityDescription: key)?
            .withSymbolConfiguration(conf) ?? NSImage(size: NSSize(width: 26, height: 26))
        img.isTemplate = true
        img.size = NSSize(width: 26, height: 26)
        return img
    }

    private func brandColor(for tool: String) -> NSColor {
        switch tool.lowercased() {
        case "codex": return NSColor(calibratedRed: 0.55, green: 0.91, blue: 0.89, alpha: 1)
        case "qoder": return NSColor(calibratedRed: 0.65, green: 0.55, blue: 0.98, alpha: 1)
        case "qoder_cn": return NSColor(calibratedRed: 0.51, green: 0.55, blue: 0.97, alpha: 1)
        default: return NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.48, alpha: 1)
        }
    }

    private func display(_ e: Event) {
        current = e
        guard let screen = NSScreen.main else { showing = false; return }
        let H: CGFloat = 46

        // 文案（kind=alert：额度告警，标题用级别本地化词 + 级别配色；否则会话完成）
        let isAlert = e.kind == "alert"
        let headText = isAlert
            ? L("alert.\(["warn", "crit", "reset"].contains(e.level) ? e.level : "warn")")
            : "\(e.project.isEmpty ? e.tool.capitalized : e.project) · \(L("island.done"))"
        let head = NSTextField(labelWithString: headText)
        head.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let accent = quotaAlertColor(e.level)
        head.textColor = isAlert ? accent : .labelColor
        let sub = NSTextField(labelWithString: isAlert ? e.title
                                                       : (e.title.isEmpty ? L("island.taskDone") : e.title))
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        head.sizeToFit(); sub.sizeToFit()
        let textW = min(max(head.frame.width, sub.frame.width), 250)
        let W: CGFloat = 16 + 26 + 10 + textW + 18

        // 玻璃胶囊
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = roundedMask(radius: H / 2)
        effect.layer?.cornerRadius = H / 2
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = (isAlert ? accent.withAlphaComponent(0.42)
                                             : NSColor.white.withAlphaComponent(0.15)).cgColor
        if isAlert {
            effect.layer?.backgroundColor = accent.withAlphaComponent(0.08).cgColor
        }

        let iconView = NSImageView(frame: NSRect(x: 14, y: (H - 26) / 2, width: 26, height: 26))
        iconView.image = brandIcon(for: e.tool)
        iconView.contentTintColor = brandColor(for: e.tool)
        head.frame = NSRect(x: 50, y: H / 2 + 1, width: textW, height: 15)
        sub.frame = NSRect(x: 50, y: H / 2 - 15, width: textW, height: 13)
        effect.addSubview(iconView); effect.addSubview(head); effect.addSubview(sub)
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        effect.addGestureRecognizer(click)

        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = effect
        window = p

        // 动画：菜单栏下方小胶囊弹性展开 → 停留 → 收缩淡出
        let topY = screen.visibleFrame.maxY - H - 6
        let midX = screen.frame.midX
        let small = NSRect(x: midX - 23, y: topY + 8, width: 46, height: H - 16)
        let full = NSRect(x: midX - W / 2, y: topY, width: W, height: H)
        p.setFrame(small, display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.38
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.08)
            p.animator().setFrame(full, display: true)
            p.animator().alphaValue = 1
        }, completionHandler: { [weak p] in
            p?.invalidateShadow()
        })
        let startedAt = Date()
        shownAt = startedAt
        // 用户设置用于正常展示；有待播事件时缩短停留以追赶，但不跳过任何完成通知。
        scheduleDismiss(p, at: IslandQueueTiming.deadline(
            shownAt: startedAt, configuredDwell: dwellSecs, hasPending: !queue.isEmpty))
    }

    @objc private func tapped() {
        onTap?(current)
        dismiss(fast: true)
    }

    private func dismiss(fast: Bool = false) {
        guard let p = window else { showing = false; maybeShow(); return }
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        scheduledDismissAt = nil
        shownAt = nil
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fast ? 0.15 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var f = p.frame
            f = NSRect(x: f.midX - 23, y: f.minY + 8, width: 46, height: f.height - 16)
            p.animator().setFrame(f, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                p.orderOut(nil)
                self?.showing = false
                self?.maybeShow()
            }
        })
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private struct StoredEventCursor: Codable {
        let bootId: String
        let lastEventId: Int
    }

    /// 界面缩放系数（随「字体大小」设置）。UserDefaults 持久化保证启动即生效；
    /// 窗口尺寸的存取均以「未缩放基准值」为准（存÷取×），避免缩放系数复利叠加。
    var uiScale: CGFloat = {
        let v = UserDefaults.standard.double(forKey: "fontScale")
        return v > 0 ? min(max(CGFloat(v), 0.8), 1.6) : 1
    }()

    func applyUIScale(_ z: CGFloat) {
        let s = min(max(z, 0.8), 1.6)
        guard abs(s - uiScale) > 0.001 else { return }
        uiScale = s
        UserDefaults.standard.set(Double(s), forKey: "fontScale")
        // 尺寸切换交叉淡变：原生 SwiftUI 内容随 fontScale 同步整体缩放（见 ScaledContainer），
        // 这里只负责把承载窗口按同一系数放大/缩小，并用淡出→换尺寸→淡入掩盖布局突变。
        let animate: (NSWindow, NSRect) -> Void = { w, target in
            guard w.frame.size != target.size else { w.setFrame(target, display: true); return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                w.animator().alphaValue = 0
            }, completionHandler: { [weak w] in
                guard let w else { return }
                w.setFrame(target, display: true)
                w.invalidateShadow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak w] in
                    guard let w else { return }
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.18
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        w.animator().alphaValue = 1
                    }, completionHandler: { [weak w] in w?.invalidateShadow() })
                }
            })
        }
        if let p = panel, p.isVisible {          // 面板：锚定顶边中心重排
            let w = savedPanelW() * s
            let h = savedPanelH() * s
            let f = p.frame
            animate(p, NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h))
        }
        if let wp = widgetPanel {                // 小组件：锚定左上角
            let d = UserDefaults.standard
            let bw = CGFloat(d.double(forKey: "widgetW")) > 0
                ? CGFloat(d.double(forKey: "widgetW")) : kWidgetMinW
            let bh = CGFloat(d.double(forKey: "widgetH")) > 0
                ? CGFloat(d.double(forKey: "widgetH")) : kWidgetMinH
            wp.minSize = NSSize(width: kWidgetMinW * s, height: kWidgetMinH * s)
            wp.maxSize = NSSize(width: 720 * s, height: 560 * s)
            let f = wp.frame
            let target = NSRect(x: f.minX, y: f.maxY - max(kWidgetMinH, bh) * s,
                                width: max(kWidgetMinW, bw) * s,
                                height: max(kWidgetMinH, bh) * s)
            if wp.isVisible { animate(wp, target) } else { wp.setFrame(target, display: false) }
        }
    }

    /// 拖拽过程中持续落盘尺寸（inLiveResize 守卫 → 只在用户实时拖动时存，
    /// 程序化 setFrame（恢复/缩放）不会触发，避免把恢复值/钳制值反写覆盖）。
    /// 这样即便 resize 后立刻退出 app（没走 hidePanel/didEndLiveResize），尺寸也已保存。
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w.inLiveResize else { return }
        savePanelSize(w)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        savePanelSize(w)
        w.invalidateShadow()
    }

    /// 恢复用的面板基准尺寸（未缩放）。自动测高可能在数据尚未加载时得到很小的值，
    /// 因此已保存高度只用于记住更高的内容，不能把下次打开压到默认高度以下。
    func savedPanelW() -> CGFloat { let v = UserDefaults.standard.double(forKey: "panelW"); return v > 0 ? CGFloat(v) : kPanelW }
    func savedPanelH() -> CGFloat {
        let v = CGFloat(UserDefaults.standard.double(forKey: "panelH"))
        return max(kPanelH, v)
    }

    private func savePanelSize(_ w: NSWindow) {
        let d = UserDefaults.standard
        if w === panel {
            // 面板高度已自适应内容（fitPanelHeight 管），用户拖拽只持久化宽度
            d.set(Double(w.frame.width / uiScale), forKey: "panelW")
        } else if w === widgetPanel {
            d.set(Double(w.frame.width / uiScale), forKey: "widgetW")
            d.set(Double(w.frame.height / uiScale), forKey: "widgetH")
        }
    }

    var statusItem: NSStatusItem!
    var panel: KeyPanel?
    var clickMonitor: Any?
    var keyMonitor: Any?
    // 单一数据 store：面板与桌面小组件共用一份轮询（@MainActor）。
    let store = AppStore()
    var panelHost: HostController?
    var widgetHost: HostController?
    var backend: Process?
    var backendTransitioning = false
    var backendReadyWaiters: [BackendReadyCallback] = []
    var restartStoreAfterBackendTransition = false
    var storeStarted = false
    let backendOwnerToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var pollTimer: Timer?
    var eventTask: Task<Void, Never>?
    var lastEventId = 0
    var eventBootId: String?
    var loaded = false
    // 菜单栏明暗变化 → 重绘混色图标，改用系统主题分布式通知（见 didFinishLaunching），不再 KVO 自激

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// The detached installer injects this one-shot token into the replacement App.
    /// Its daemon must echo the same token before the update can be committed.
    var updateTransaction: String? {
        let value = ProcessInfo.processInfo.environment["AGENTDECK_UPDATE_TRANSACTION"] ?? ""
        guard value.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    /// 主面板根视图（接 store + 动作闭包）。
    func makeRootView() -> AgentDeckRootView {
        AgentDeckRootView(
            store: store, version: appVersion,
            onQuit: { NSApp.terminate(nil) },
            onOpenExternal: { [weak self] in self?.openExternal($0) },
            onPasteEnter: { autoPasteEnter() },
            onHidePanel: { [weak self] in self?.hidePanel() },
            onScale: { [weak self] z in self?.applyUIScale(z) },
            onContentHeight: { [weak self] h in self?.fitPanelHeight(h) })
    }

    /// 面板高度自适应内容：窗口高 = 内容自然高×缩放，钳到 [最小, 屏幕可用]，锚定顶边（菜单栏下）。
    /// 消除内容不足时底部的空隙；内容超屏则封顶到屏幕高、由内部 ScrollView 滚动。
    private var lastFitH: CGFloat = 0
    func fitPanelHeight(_ contentH: CGFloat) {
        guard let p = panel, p.isVisible, contentH > 1,
              let screen = p.screen ?? NSScreen.main else { return }
        let target = (contentH * uiScale).rounded()
        let vis = screen.visibleFrame
        let f = p.frame
        let maxH = f.maxY - (vis.minY + 8)            // 顶边到屏幕底的可用高
        // 数据加载前的短暂空态不能把主面板压矮并持久化；正常屏幕至少维持默认高度，
        // 小屏幕仍由 maxH 封顶，超出内容继续交给内部 ScrollView。
        let h = min(max(target, kPanelH * uiScale), maxH)
        guard abs(h - f.height) > 2 else { return }    // 抖动抑制
        lastFitH = h
        p.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true)
        p.invalidateShadow()
        UserDefaults.standard.set(Double(h / uiScale), forKey: "panelH")  // 记住，下次开就近、少闪
    }

    /// 桌面小组件根视图（点击开主面板）。
    func makeWidgetView() -> AgentDeckWidgetRootView {
        AgentDeckWidgetRootView(store: store, onTapPanel: { [weak self] in self?.showPanel() })
    }

    /// 打开外部链接（更新下载 / GitHub issue / mailto 反馈）；mailto 走兜底。
    func openExternal(_ s: String) {
        guard let url = URL(string: s), let scheme = url.scheme,
              ["http", "https", "mailto"].contains(scheme) else { return }
        if scheme == "mailto" { openMailto(url) } else { NSWorkspace.shared.open(url) }
    }
    // 状态栏单槽位轮播：Agent 图标、账号标识与额度作为一个不可拆分的页面。
    struct MBItem {
        let id: String
        let tool: String
        let text: String
        let alert: NSColor?
    }
    var rotateTimer: Timer?
    var menubarAnimationTimer: Timer?
    var currentMenubarImage: NSImage?
    var menubarRequestID = 0
    var menubarAppliedRequestID = 0
    var menubarSlotWidth: CGFloat = 17
    var mbFull: [MBItem] = []      // 全部 (tool×账号) 同级页面
    var rotateSecs = 0
    var rotateIdx = 0
    var quotaRotationPaused = false
    var overviewSelectionOutsideMenubar = false

    override init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "eventCursor"),
           let cursor = try? JSONDecoder().decode(StoredEventCursor.self, from: data),
           !cursor.bootId.isEmpty, cursor.lastEventId >= 0 {
            eventBootId = cursor.bootId
            lastEventId = cursor.lastEventId
        } else if let legacyBoot = defaults.string(forKey: "eventBootId"),
                  !legacyBoot.isEmpty,
                  defaults.object(forKey: "eventLastId") != nil {
            // 旧版使用两个 key；仅在两者同时存在时迁移，避免异常退出留下高位孤立 ID。
            eventBootId = legacyBoot
            lastEventId = max(0, defaults.integer(forKey: "eventLastId"))
        }
        super.init()
        if eventBootId != nil { persistEventCursor() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 菜单栏是唯一入口：禁止 ⌘拖拽移除（isVisible=false 会被系统持久化，导致入口永久消失）
        statusItem.behavior = []
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = deckGlyph()
            button.imagePosition = .imageLeft
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // 混色图标的常规段颜色随系统明暗变。⚠️不用 KVO 观察 effectiveAppearance——
            // updateIconState 改 button.image/tintColor 会让 AppKit 重算 effectiveAppearance → KVO 再触发
            // → 自激死循环，菜单栏图标持续重绘吃满一核（v2 一直耗电的真凶）。
            // 改听系统主题切换分布式通知：只在用户真正切浅/深色时发，绝不被自身绘制触发。
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.updateIconState() }
                }
        }

        // 设置变更 → 即时重绘菜单栏（语言/常显用量/告警阈值等，等价 v1 "sync" 桥消息）
        store.onSettingsChanged = { [weak self] in self?.updateIconState() }
        store.onQuotaChanged = { [weak self] in self?.updateIconState() }
        store.onQuotaSelectionChanged = { [weak self] id in
            self?.selectMenubarPage(id: id, animated: true)
        }
        store.onQuotaRotationPauseChanged = { [weak self] paused in
            guard let self, self.quotaRotationPaused != paused else { return }
            self.quotaRotationPaused = paused
            self.configureMenubar()
        }

        ensureBackend { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.store.start(forceInitialRefresh: self.updateTransaction != nil)
                self.storeStarted = true
                self.loaded = true
                if self.widgetEnabled { self.showWidget() }
            }
        }

        // 首次启动自动注册开机自启（可在右键菜单或系统设置·登录项关闭）
        if !UserDefaults.standard.bool(forKey: "loginItemSetup") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSetup")
        }

        // 省电：菜单栏图标刷新 15→20s + 大 tolerance，让系统合并唤醒（避免进「能耗显著」列表）。
        pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.ensureBackend {}
                self?.updateIconState()
            }
        }
        pollTimer?.tolerance = 8
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.updateIconState()
        }

        // 会话完成事件 → 灵动岛；点击 → 跳转会话所在终端，失败则打开面板
        IslandController.shared.onTap = { [weak self] event in
            self?.focusSession(event)
        }
        // daemon 事件长轮询：事件入队即唤醒，不依赖隐藏菜单栏 App 可能被 App Nap
        // 延迟的 Timer；同一时刻只有一个请求，事件 id 仍负责端到端去重。
        eventTask = Task { [weak self] in
            await self?.watchEvents()
        }
    }

    func focusSession(_ event: IslandController.Event?) {
        // 额度告警弹丸无会话可跳转 → 直接打开面板看额度
        guard let event, event.kind != "alert" else { showPanel(); return }
        var req = URLRequest(url: URL(string: "\(kBase)/api/focus")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "tool": event.tool, "session": event.session, "cwd": event.cwd])
        kDirectSession.dataTask(with: req) { [weak self] data, _, _ in
            let ok = (data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })?["ok"] as? Bool ?? false
            if !ok {   // 找不到终端 → 兜底打开面板
                DispatchQueue.main.async { self?.showPanel() }
            }
        }.resume()
    }

    func watchEvents() async {
        var retryNanos: UInt64 = 300_000_000
        while !Task.isCancelled {
            var components = URLComponents(string: "\(kBase)/api/events")
            var items = [
                URLQueryItem(name: "since", value: "\(lastEventId)"),
                URLQueryItem(name: "wait", value: "25"),
            ]
            if let eventBootId {
                items.append(URLQueryItem(name: "boot", value: eventBootId))
            }
            components?.queryItems = items
            guard let url = components?.url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 35
            do {
                let (data, response) = try await kDirectSession.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let events = json["events"] as? [[String: Any]] else {
                    throw URLError(.badServerResponse)
                }
                _ = applyEventResponse(json, events: events)
                retryNanos = 300_000_000
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: retryNanos)
                retryNanos = min(retryNanos * 2, 5_000_000_000)
            }
        }
    }

    private func applyEventResponse(
        _ json: [String: Any], events: [[String: Any]]
    ) -> Bool {
        if let boot = json["boot_id"] as? String {
            if let previous = eventBootId, previous != boot {
                eventBootId = boot
                lastEventId = 0
                persistEventCursor()
                return false
            }
            eventBootId = boot
        }
        if let secs = json["island_secs"] as? Double {
            IslandController.shared.dwellSecs = secs
        } else if let secs = json["island_secs"] as? Int {
            IslandController.shared.dwellSecs = Double(secs)
        }
        if let loc = json["locale"] as? String { appLocale = loc }
        for ev in events {
            guard let id = ev["id"] as? Int, id > lastEventId else { continue }
            lastEventId = id
            let kind = ev["kind"] as? String ?? ""
            if kind == "alert", ev["sound"] as? Bool ?? false {
                NSSound(named: "Glass")?.play()
            }
            IslandController.shared.push(IslandEvent(
                tool: ev["tool"] as? String ?? "claude",
                title: ev["title"] as? String ?? "",
                project: ev["project"] as? String ?? "",
                session: ev["session"] as? String ?? "",
                cwd: ev["cwd"] as? String ?? "",
                kind: kind,
                level: ev["level"] as? String ?? "",
                dedupeKey: ev["dedupe_key"] as? String ?? ""))
        }
        if let last = json["last"] as? Int { lastEventId = max(lastEventId, last) }
        persistEventCursor()
        return true
    }

    private func persistEventCursor() {
        let defaults = UserDefaults.standard
        guard let eventBootId,
              let data = try? JSONEncoder().encode(StoredEventCursor(
                bootId: eventBootId, lastEventId: lastEventId
              )) else {
            defaults.removeObject(forKey: "eventCursor")
            return
        }
        // boot + id 必须作为同一份 Data 原子落盘；分开写会在异常退出时形成高位孤立 ID。
        defaults.set(data, forKey: "eventCursor")
        defaults.removeObject(forKey: "eventLastId")
        defaults.removeObject(forKey: "eventBootId")
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTask?.cancel()
        backend?.terminate()
    }

    func icon(named: String) -> NSImage? {
        // 默认符号在状态栏偏小，统一放大到 16pt
        let conf = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let img = NSImage(systemSymbolName: named, accessibilityDescription: "AgentDeck")?
            .withSymbolConfiguration(conf)
        img?.isTemplate = true
        return img
    }

    /// AgentDeck 自身字形：双 agent 活动环的单色线稿（与 App 图标同构）
    func deckGlyph() -> NSImage {
        let s: CGFloat = 17
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let c = NSPoint(x: s / 2, y: s / 2)
            NSColor.black.setStroke()
            func arc(_ r: CGFloat, _ from: CGFloat, _ to: CGFloat) {
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: r,
                            startAngle: from, endAngle: to, clockwise: true)
                p.lineWidth = 2.0
                p.lineCapStyle = .round
                p.stroke()
            }
            arc(6.6, 90, -160)    // 外环 70%
            arc(3.1, -150, 12)    // 内环，缺口错位
            return true
        }
        img.isTemplate = true
        return img
    }

    /// agent 单色模板字形：直接用官方 App 自带的菜单栏模板图（assets/brand 随包分发）
    /// Claude.app TrayIconTemplate / Codex.app codexTemplate，形状与官方完全一致
    func agentGlyph(_ tool: String) -> NSImage? {
        let file = tool == "codex" ? "codex-tray@2x" : tool == "claude" ? "claude-tray@2x" : nil
        if let file,
           let path = Bundle.main.path(forResource: file, ofType: "png", inDirectory: "static/brand"),
           let img = NSImage(contentsOfFile: path) {
            // 按字形实际占比对齐视觉大小：两家字形均 34px，但 Claude 画布 48(留白 29%)、
            // Codex 画布 36 —— 等字形高 ~14.2pt 反推画布高
            let h: CGFloat = tool == "codex" ? 15 : 20
            img.size = NSSize(width: img.size.width / img.size.height * h, height: h)
            img.isTemplate = true
            return img
        }
        // 兜底：品牌资源缺失时退回 SF Symbol
        let conf = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
        let symbol = tool == "codex" ? "apple.terminal"
            : ["qoder", "qoder_cn"].contains(tool) ? "q.square" : "sparkle"
        let img = NSImage(systemSymbolName: symbol,
                          accessibilityDescription: tool)?
            .withSymbolConfiguration(conf)
        img?.isTemplate = true
        return img
    }

    /// 把「Agent 图标+账号标识+百分比」合成单张状态栏图；常规态使用模板图，
    /// 告警态把颜色直接烘入图像，规避 macOS 26 对模板图 tint 的兼容问题。
    /// （macOS 26 起对模板图设 contentTintColor 会整体渲染成黑色，故颜色一律画进图里）。
    /// items 为空 → 仅显示 AgentDeck 仪表图标
    func composedIcon(items: [MBItem]) -> NSImage? {
        let barH: CGFloat = 22, gap: CGFloat = 3, groupGap: CGFloat = 8
        let anyAlert = items.contains { $0.alert != nil }
        let isDark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            .map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
        // 模板模式只取 alpha，黑色即可；混色模式常规段需匹配菜单栏明暗
        let normalInk: NSColor = anyAlert ? (isDark ? .white : .black) : .black
        var parts: [(NSImage, NSAttributedString)] = []
        for it in items {
            guard let g = agentGlyph(it.tool) else { continue }
            let ink = it.alert ?? normalInk
            parts.append((tinted(g, ink), NSAttributedString(
                string: it.text,
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: ink,
                ])))
        }
        var symbols: [(NSImage, NSAttributedString?)] = parts.map { ($0.0, $0.1) }
        if symbols.isEmpty {
            symbols = [(tinted(deckGlyph(), normalInk), nil)]   // 全不选 → 自身双环字形
        }
        var width: CGFloat = 0
        for (i, s) in symbols.enumerated() {
            width += s.0.size.width + (s.1.map { gap + $0.size().width } ?? 0)
            if i < symbols.count - 1 { width += groupGap }
        }
        // 宽度异常（NaN/0）会让 variableLength 状态项缩成不可见
        guard width.isFinite, width >= 1 else { return nil }
        let img = NSImage(size: NSSize(width: width, height: barH), flipped: false) { _ in
            var x: CGFloat = 0
            for s in symbols {
                s.0.draw(in: NSRect(x: x, y: (barH - s.0.size.height) / 2,
                                    width: s.0.size.width, height: s.0.size.height))
                x += s.0.size.width
                if let t = s.1 {
                    t.draw(at: NSPoint(x: x + gap, y: (barH - t.size().height) / 2))
                    x += gap + t.size().width
                }
                x += groupGap
            }
            return true
        }
        img.isTemplate = !anyAlert
        return img
    }

    /// 用指定颜色给字形上色（sourceAtop 保留 alpha 形状）；黑色即原样返回
    func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        if color == .black { return img }
        let out = NSImage(size: img.size, flipped: false) { rect in
            img.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return out
    }

    /// 所有页面使用最宽单项作为固定视口，切换时不会推动旁边的状态栏图标。
    func updateMenubarSlotWidth() {
        let images = mbFull.isEmpty
            ? [composedIcon(items: [])].compactMap { $0 }
            : mbFull.compactMap { composedIcon(items: [$0]) }
        menubarSlotWidth = max(17, ceil(images.map(\.size.width).max() ?? 17))
    }

    func paddedMenubarImage(_ image: NSImage) -> NSImage {
        let width = max(menubarSlotWidth, image.size.width)
        guard abs(width - image.size.width) > 0.25 else { return image }
        let out = NSImage(size: NSSize(width: width, height: image.size.height), flipped: false) { rect in
            image.draw(in: NSRect(x: (rect.width - image.size.width) / 2, y: 0,
                                  width: image.size.width, height: image.size.height))
            return true
        }
        out.isTemplate = image.isTemplate
        return out
    }

    func resolvedAnimationImage(_ image: NSImage) -> NSImage {
        guard image.isTemplate else { return image }
        let isDark = statusItem.button?.effectiveAppearance
            .bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            .map { $0 == .darkAqua || $0 == .vibrantDark } ?? true
        let ink: NSColor = isDark ? .white : .black
        let out = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            ink.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        out.isTemplate = false
        return out
    }

    func drumMenubarImage(from outgoing: NSImage, to incoming: NSImage,
                          progress: CGFloat) -> NSImage {
        let size = NSSize(width: max(outgoing.size.width, incoming.size.width),
                          height: max(outgoing.size.height, incoming.size.height))
        let angle = progress * .pi / 2
        let incomingAngle = (.pi / 2) - angle
        let image = NSImage(size: size, flipped: false) { bounds in
            NSGraphicsContext.current?.cgContext.clip(to: bounds)
            func drawFace(_ source: NSImage, angle: CGFloat, direction: CGFloat) {
                let scale = max(0.02, cos(angle))
                let height = max(0.5, source.size.height * scale)
                let center = bounds.midY + direction * sin(angle) * bounds.height / 2
                let rect = NSRect(x: (bounds.width - source.size.width) / 2,
                                  y: center - height / 2,
                                  width: source.size.width, height: height)
                source.draw(in: rect, from: .zero, operation: .sourceOver,
                            fraction: 0.32 + 0.68 * scale)
            }
            drawFace(outgoing, angle: angle, direction: 1)
            drawFace(incoming, angle: incomingAngle, direction: -1)
            return true
        }
        image.isTemplate = false
        return image
    }

    func setMenubarImage(_ image: NSImage) {
        menubarAnimationTimer?.invalidate()
        menubarAnimationTimer = nil
        statusItem.button?.image = image
        currentMenubarImage = image
    }

    func animateMenubar(to next: NSImage) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let previous = currentMenubarImage,
              previous.size == next.size else {
            setMenubarImage(next)
            return
        }
        menubarAnimationTimer?.invalidate()
        let outgoing = resolvedAnimationImage(previous)
        let incoming = resolvedAnimationImage(next)
        guard let button = statusItem.button else {
            setMenubarImage(next)
            return
        }
        let duration: TimeInterval = 0.62
        let started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, self.menubarAnimationTimer === timer else {
                    timer.invalidate()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let linear = min(1, max(0, elapsed / duration))
                let progress = CGFloat(linear * linear * (3 - 2 * linear))
                button.image = self.drumMenubarImage(
                    from: outgoing, to: incoming, progress: progress)
                button.needsDisplay = true
                button.displayIfNeeded()
                if linear >= 1 {
                    timer.invalidate()
                    self.menubarAnimationTimer = nil
                    self.currentMenubarImage = next
                    // A quota refresh may have changed or removed the current item mid-roll.
                    let current = MenubarRotationPolicy.currentItem(
                        items: self.mbFull, currentIndex: self.rotateIdx).map { [$0] } ?? []
                    self.drawMenubar(current, animated: false)
                }
            }
        }
        menubarAnimationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: - 点击处理
    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - HUD 玻璃面板
    func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: kPanelW, height: kPanelH),
                         styleMask: [.borderless, .nonactivatingPanel,
                                     .fullSizeContentView, .resizable],
                         backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.minSize = NSSize(width: 420, height: 200)   // 宽度下限 420；高度自适应内容，下限放小
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        p.delegate = self

        // 系统玻璃：hudWindow 材质 + behindWindow 混合，透明度高于 NSPopover 默认材质
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: kPanelW, height: kPanelH))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = roundedMask(radius: 28)
        effect.layer?.cornerRadius = 28
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        if panelHost == nil { panelHost = HostController(makeRootView()) }
        let hv = panelHost!.view
        hv.frame = effect.bounds
        hv.autoresizingMask = [.width, .height]
        effect.addSubview(hv)
        addRim(to: effect, radius: 28)   // 顶亮底暗渐变描边
        addEdgeCursor(to: effect)        // 边缘缩放光标提示
        p.contentView = effect
        return p
    }

    func togglePanel() {
        if let p = panel, p.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        if panel == nil { panel = makePanel() }
        guard let p = panel, let button = statusItem.button,
              let bw = button.window else { return }
        // hidePanel 时把承载视图摘下了（停离屏 display link 省电）；重开先 reattach 回玻璃层底部
        // （rim/边缘光标是后加的覆盖层，须在其下），保持 @State 与原始 z 序。
        if let host = panelHost, host.view.superview == nil,
           let effect = p.contentView {
            host.view.frame = effect.bounds
            host.view.autoresizingMask = [.width, .height]
            effect.addSubview(host.view, positioned: .below, relativeTo: nil)
        }
        loaded = true
        Task { await store.refreshOnOpen() }   // 开面板即刻按缓存快刷，与菜单栏对齐；实时最新值由🔄(force)触发

        // 尺寸：恢复用户上次拖拽的大小，高度不超过屏幕可视范围
        let bFrame = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let vis = (bw.screen ?? NSScreen.main!).visibleFrame
        // 宽度恢复用户上次拖拽值；高度恢复最近内容高度，但 savedPanelH 会以默认高度
        // 为下限，避免启动空态把下次打开永久压矮。小屏幕仍按可用屏高封顶。
        let w = savedPanelW() * uiScale
        let maxH = bFrame.minY - 6 - (vis.minY + 8)   // 图标下沿到屏幕底的可用高度
        let h = min(savedPanelH() * uiScale, maxH)
        // 定位：状态栏图标正下方，水平钳制在屏幕内
        let x = min(max(bFrame.midX - w / 2, vis.minX + 8), vis.maxX - w - 8)
        let y = bFrame.minY - 6 - h
        p.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        button.highlight(true)
        // 内容(webview)异步渲染完成后重算窗口阴影，消除圆角外的矩形残角
        for delay in [0.15, 0.6, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak p] in
                p?.invalidateShadow()
            }
        }

        // transient 行为：点击面板外（其他 App 区域）或按 ESC 关闭
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.hidePanel(); return nil }   // ESC
            return ev
        }
    }

    func hidePanel() {
        // 尺寸已在拖拽时由 windowDidResize(inLiveResize) 持续落盘，这里不再保存——
        // 否则会把 showPanel 恢复时的「按屏高钳制后的值」反写覆盖，导致高度逐次缩水。
        panel?.orderOut(nil)
        // ⚡️省电关键：orderOut 只是隐藏窗口，承载的 NSHostingView 仍在窗口里，其内
        // .repeatForever 呼吸/极光动画会让 SwiftUI 的 display link 继续每帧重绘 → 隐藏后
        // 仍持续吃 CPU（额度可取时 live 点呼吸尤甚）。把承载视图从窗口摘下：无窗口可渲染，
        // AppKit 即停掉它的 display link；@State 仍存活在 panelHost 上，重开 reattach 即恢复。
        panelHost?.view.removeFromSuperview()
        if overviewSelectionOutsideMenubar {
            overviewSelectionOutsideMenubar = false
            publishMenubarSelection()
            configureMenubar()
        }
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: - 桌面小组件（驻留桌面层的玻璃小窗）
    var widgetPanel: NSPanel?

    var widgetEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "widgetEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "widgetEnabled") }
    }

    @objc func toggleWidget() {
        widgetEnabled.toggle()
        widgetEnabled ? showWidget() : hideWidget()
    }

    func showWidget() {
        if widgetPanel == nil {
            let d0 = UserDefaults.standard
            // 默认高按内容实高取值：额度卡+今日条+活跃卡头部 ≈ 285
            let W = max(kWidgetMinW, CGFloat(d0.double(forKey: "widgetW")) > 0
                        ? CGFloat(d0.double(forKey: "widgetW")) : kWidgetMinW) * uiScale
            let H = max(kWidgetMinH, CGFloat(d0.double(forKey: "widgetH")) > 0
                        ? CGFloat(d0.double(forKey: "widgetH")) : kWidgetMinH) * uiScale
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.borderless, .nonactivatingPanel,
                                        .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
            p.minSize = NSSize(width: kWidgetMinW * uiScale, height: kWidgetMinH * uiScale)
            p.maxSize = NSSize(width: 720 * uiScale, height: 560 * uiScale)
            // 桌面图标之上、所有应用窗口之下 —— 小组件层
            p.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.isMovableByWindowBackground = true   // 按住任意处拖动
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            p.appearance = NSAppearance(named: .darkAqua)
            p.delegate = self

            let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: W, height: H))
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.maskImage = roundedMask(radius: 28)
            effect.layer?.cornerRadius = 28
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]

            if widgetHost == nil { widgetHost = HostController(makeWidgetView()) }
            let wv = widgetHost!.view
            wv.frame = effect.bounds
            wv.autoresizingMask = [.width, .height]
            effect.addSubview(wv)
            addRim(to: effect, radius: 28)   // 顶亮底暗渐变描边
            // 顶部 28px 原生拖拽把手（盖在内容之上）
            let handle = DragHandle(frame: NSRect(x: 0, y: H - 28, width: W, height: 28))
            handle.autoresizingMask = [.width, .minYMargin]
            effect.addSubview(handle)
            // 按住 ⌘ 任意位置可拖（顶部把手够不到时的兜底），平时事件穿透不挡交互
            let cmdDrag = CmdDragView(frame: effect.bounds)
            cmdDrag.autoresizingMask = [.width, .height]
            effect.addSubview(cmdDrag)
            // 边缘缩放光标提示放最上层（hitTest 返回 nil 不挡点击；之前被 handle/cmdDrag 压在底下
            // 拿不到 mouseMoved → 边缘不显示缩放光标）。allowTop:false：顶部是拖拽把手不提示缩放。
            addEdgeCursor(to: effect, allowTop: false)
            p.acceptsMouseMovedEvents = true   // 非 key 桌面窗：确保边缘 tracking area 收到 mouseMoved
            p.contentView = effect
            widgetPanel = p

            // 位置：恢复上次拖放点，否则主屏右上角
            let d = UserDefaults.standard
            let vis = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            var x = CGFloat(d.double(forKey: "widgetX"))
            var y = CGFloat(d.double(forKey: "widgetY"))
            if x == 0 && y == 0 {
                x = vis.maxX - W - 24
                y = vis.maxY - H - 24
            }
            // 夹回可视范围：保证顶部拖拽条始终在屏内、不被菜单栏/屏幕边缘盖住
            // （历史保存的位置可能来自已断开的外接屏或贴边到把手够不着处）
            x = min(max(x, vis.minX + 8), vis.maxX - W - 8)
            y = min(max(y, vis.minY + 8), vis.maxY - H - 8)
            p.setFrame(NSRect(x: x, y: y, width: W, height: H), display: true)
            for delay in [0.3, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak p] in
                    p?.invalidateShadow()
                }
            }
        }
        // 复用既有小组件窗：hideWidget 摘下了承载视图，重新启用时 reattach 回玻璃层底部
        // （rim/把手/⌘拖层/边缘光标都是覆盖层，须在其下）。
        if let host = widgetHost, host.view.superview == nil,
           let effect = widgetPanel?.contentView {
            host.view.frame = effect.bounds
            host.view.autoresizingMask = [.width, .height]
            effect.addSubview(host.view, positioned: .below, relativeTo: nil)
        }
        widgetPanel?.orderFront(nil)
    }

    func hideWidget() {
        widgetPanel?.orderOut(nil)
        widgetHost?.view.removeFromSuperview()   // 同面板：摘下承载视图停离屏 display link，关掉小组件后不再耗电
    }

    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === widgetPanel else { return }
        UserDefaults.standard.set(Double(w.frame.minX), forKey: "widgetX")
        UserDefaults.standard.set(Double(w.frame.minY), forKey: "widgetY")
    }

    func showMenu() {
        let menu = NSMenu()
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let title = NSMenuItem(title: "AgentDeck v\(ver)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("menu.openBrowser"), action: #selector(openBrowser), keyEquivalent: "o")
        menu.addItem(withTitle: L("menu.restartBackend"), action: #selector(restartBackend), keyEquivalent: "r")
        let login = NSMenuItem(title: L("menu.loginItem"), action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let widget = NSMenuItem(title: L("menu.widget"), action: #selector(toggleWidget), keyEquivalent: "w")
        widget.state = widgetEnabled ? .on : .off
        menu.addItem(widget)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 用完即弃，保留左键 action
    }

    @objc func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            NSLog("AgentDeck: login item toggle failed: \(error)")
        }
    }

    @objc func openBrowser() { NSWorkspace.shared.open(URL(string: kBase)!) }

    @objc func restartBackend() {
        guard !backendTransitioning else { return }
        ensureBackend(forceRestart: true) {}
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: - 后端守护
    func backendScript() -> String {
        // 打包模式：脚本在 Contents/Resources；开发模式：与 .app 同级
        if let bundled = Bundle.main.path(forResource: "agentdeckd", ofType: "py"),
           FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("agentdeckd.py").path
    }

    var logPath: String {
        let dir = NSHomeDirectory() + "/Library/Logs"
        return dir + "/AgentDeck.log"
    }

    func ensureBackend(
        forceRestart: Bool = false, then done: @escaping BackendReadyCallback
    ) {
        backendReadyWaiters.append(done)
        guard !backendTransitioning else { return }
        backendTransitioning = true
        let mine = appVersion
        let appPID = ProcessInfo.processInfo.processIdentifier
        healthCheck { [weak self] health in
            guard let self else { return }
            // 同版本不等于同实例：快速重开时旧 daemon 仍会短暂健康，随后因旧父
            // App 消失而退出。只有 parent_pid 明确指向当前 App 才允许复用。
            if !forceRestart, health.belongs(
                to: appPID, version: mine,
                updateTransaction: self.updateTransaction,
                ownerToken: self.backendOwnerToken
            ) {
                self.finishBackendTransition()
                return
            }
            if BackendOwnerPolicy.shouldWaitForOwnedBackend(
                forceRestart: forceRestart,
                healthAlive: health.alive,
                ownedProcessRunning: self.backend?.isRunning == true
            ) {
                // A large first session scan can briefly hold Python's GIL after
                // startup. The daemon still belongs to this App, so tolerate the
                // transient health miss instead of creating a terminate/spawn loop.
                self.waitHealthy(retries: 20, transitionPrepared: false)
                return
            }
            self.replaceBackend(health)
        }
    }

    private func prepareForBackendReplacement() {
        menubarRequestID += 1
        menubarAppliedRequestID = menubarRequestID
        eventTask?.cancel()
        eventTask = nil
        if storeStarted && !restartStoreAfterBackendTransition {
            store.stop()
            store.markBackendUnavailable()
            restartStoreAfterBackendTransition = true
        }
    }

    private func replaceBackend(_ health: BackendHealth) {
        prepareForBackendReplacement()
        if let owned = backend, owned.isRunning {
            stopOwnedBackend(owned) { [weak self] in self?.spawnAndWait() }
            return
        }
        backend = nil
        if health.alive, let instanceID = health.instanceID {
            handleForeignBackend(health, instanceID: instanceID)
        } else if health.alive {
            // 兼容还没有 instance_id 的旧 daemon：不依据健康响应中的纯数值 PID
            // 发信号，等待其父进程 watchdog 自行退出，避免 PID 复用误伤。
            waitForForeignBackendExit(instanceID: nil, retries: 20)
        } else {
            spawnAndWait()
        }
    }

    private func spawnAndWait() {
        spawnBackend()
        waitHealthy(retries: 20, transitionPrepared: true)
    }

    private func waitHealthy(retries: Int, transitionPrepared: Bool) {
        let mine = appVersion
        let appPID = ProcessInfo.processInfo.processIdentifier
        healthCheck { [weak self] health in
            guard let self else { return }
            if health.belongs(
                to: appPID, version: mine,
                updateTransaction: self.updateTransaction,
                ownerToken: self.backendOwnerToken
            ) {
                self.finishBackendTransition()
                return
            }
            if health.alive, let instanceID = health.instanceID {
                if !transitionPrepared {
                    self.prepareForBackendReplacement()
                }
                self.handleForeignBackend(health, instanceID: instanceID)
                return
            }
            if retries <= 0 {
                NSLog("AgentDeck: backend did not become healthy")
                if transitionPrepared {
                    self.store.markBackendUnavailable()
                } else {
                    // The optimistic wait started outside a replacement
                    // transition. Prepare the store/event lifecycle before the
                    // timeout path actually terminates and respawns the daemon.
                    self.prepareForBackendReplacement()
                }
                // The update installer treats this App as healthy only after its
                // transaction-bound daemon owns the port. Keep recovering instead
                // of allowing the UI to consume a stale or unrelated service.
                if let process = self.backend, process.isRunning {
                    self.stopOwnedBackend(process) { [weak self] in
                        self?.spawnAndWait()
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        self.spawnAndWait()
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitHealthy(retries: retries - 1,
                                 transitionPrepared: transitionPrepared)
            }
        }
    }

    private func finishBackendTransition() {
        backendTransitioning = false
        if restartStoreAfterBackendTransition {
            restartStoreAfterBackendTransition = false
            store.start(forceInitialRefresh: true)
        }
        if eventTask == nil {
            eventTask = Task { [weak self] in
                await self?.watchEvents()
            }
        }
        let waiters = backendReadyWaiters
        backendReadyWaiters.removeAll()
        waiters.forEach { $0() }
    }

    func healthCheck(_ cb: @escaping (BackendHealth) -> Void) {
        var req = URLRequest(url: URL(string: "\(kBase)/api/health")!)
        req.timeoutInterval = 2
        kDirectSession.dataTask(with: req) { data, _, _ in
            // 校验响应身份：端口被其他进程占用时不能误当作后端
            let obj = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            DispatchQueue.main.async {
                cb(BackendHealth(
                    alive: obj?["ok"] as? Bool ?? false,
                    version: obj?["version"] as? String,
                    pid: (obj?["pid"] as? NSNumber)?.int32Value,
                    parentPID: (obj?["parent_pid"] as? NSNumber)?.int32Value,
                    instanceID: obj?["instance_id"] as? String,
                    updateTransaction: obj?["update_transaction"] as? String,
                    ownerToken: obj?["owner_token"] as? String,
                    scriptPath: obj?["script_path"] as? String))
            }
        }.resume()
    }

    private func handleForeignBackend(_ health: BackendHealth, instanceID: String) {
        let ownerIsAlive = health.parentPID.map { Darwin.kill($0, 0) == 0 } ?? false
        let transactionMatches = updateTransaction == nil
            || health.updateTransaction == updateTransaction
        // 所有 App 对 owner 使用同一排序：高版本优先；同版本优先 /Applications，
        // 其余路径稳定排序。这样旧 App 会共享新版 daemon，跨 bundle 也不会互相抢占。
        if transactionMatches && BackendOwnerPolicy.shouldShare(
            currentVersion: appVersion,
            currentScript: backendScript(),
            remoteVersion: health.version,
            remoteScript: health.scriptPath,
            remoteOwnerIsAlive: ownerIsAlive
        ) {
            finishBackendTransition()
            return
        }
        requestBackendShutdown(instanceID: instanceID) { [weak self] in
            self?.waitForForeignBackendExit(instanceID: instanceID, retries: 20)
        }
    }

    private func requestBackendShutdown(
        instanceID: String, then done: @escaping BackendReadyCallback
    ) {
        var req = URLRequest(url: URL(string: "\(kBase)/api/shutdown")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "instance_id": instanceID
        ])
        kDirectSession.dataTask(with: req) { _, _, _ in
            DispatchQueue.main.async(execute: done)
        }.resume()
    }

    private func waitForForeignBackendExit(instanceID: String?, retries: Int) {
        healthCheck { [weak self] health in
            guard let self else { return }
            if !health.alive {
                self.spawnAndWait()
                return
            }
            if health.belongs(
                to: ProcessInfo.processInfo.processIdentifier,
                version: self.appVersion,
                updateTransaction: self.updateTransaction,
                ownerToken: self.backendOwnerToken
            ) {
                self.finishBackendTransition()
                return
            }
            if let currentInstanceID = health.instanceID,
               currentInstanceID != instanceID {
                // 原目标已退出但端口被另一个实例抢占：对新实例重新做 bundle/owner
                // 判定和令牌交接，不能继续等待旧令牌直至超时后误用 foreign daemon。
                self.handleForeignBackend(health, instanceID: currentInstanceID)
                return
            }
            if retries <= 0 {
                NSLog("AgentDeck: foreign backend did not exit (instance \(instanceID ?? "legacy"))")
                self.store.markBackendUnavailable()
                // Never mark a foreign daemon ready: the replacement UI would keep
                // reading old code and cache. Keep retrying with the instance token.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if let instanceID {
                        self.requestBackendShutdown(instanceID: instanceID) {
                            self.waitForForeignBackendExit(
                                instanceID: instanceID, retries: 20)
                        }
                    } else {
                        self.waitForForeignBackendExit(instanceID: nil, retries: 20)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.waitForForeignBackendExit(instanceID: instanceID,
                                               retries: retries - 1)
            }
        }
    }

    private func stopOwnedBackend(
        _ process: Process, then done: @escaping BackendReadyCallback
    ) {
        backend = nil
        if process.isRunning { process.terminate() }
        waitForOwnedProcessExit(process, retries: 50, then: done)
    }

    private func waitForOwnedProcessExit(
        _ process: Process, retries: Int, then done: @escaping BackendReadyCallback
    ) {
        if !process.isRunning {
            done()
            return
        }
        if retries <= 0 {
            // 不对纯数值 PID 强杀；daemon 的 TERM handler 正常应在此窗口内收尾，
            // 若未退出则留给后续轮询继续恢复，避免 PID 复用误伤。
            NSLog("AgentDeck: owned backend did not exit after terminate")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: done)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForOwnedProcessExit(process, retries: retries - 1, then: done)
        }
    }

    func spawnBackend() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", backendScript()]
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTDECK_BACKEND_OWNER_TOKEN"] = backendOwnerToken
        if let updateTransaction {
            environment["AGENTDECK_UPDATE_TRANSACTION"] = updateTransaction
        }
        p.environment = environment
        p.standardOutput = FileHandle.nullDevice
        FileManager.default.createFile(atPath: logPath, contents: nil)
        p.standardError = (try? FileHandle(forWritingTo:
            URL(fileURLWithPath: logPath))) ?? FileHandle.nullDevice
        do { try p.run(); backend = p } catch {
            NSLog("AgentDeck: failed to spawn backend: \(error)")
        }
    }

    // MARK: - 额度状态映射到 icon 颜色
    func updateIconState() {
        // 菜单栏只读 daemon 已有快照，绝不因 Codex 实时更新顺带触发慢速 Claude 出站。
        guard let url = URL(string: "\(kBase)/api/quota?cached=1") else { return }
        menubarRequestID += 1
        let requestID = menubarRequestID
        kDirectSession.dataTask(with: url) { [weak self] data, response, _ in
            guard let http = response as? HTTPURLResponse,
                  MenubarRotationPolicy.isSuccessfulHTTPStatus(http.statusCode),
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let mb = json["menubar"] as? [String: Any]
            guard mb != nil, json["accounts"] != nil || json["agents"] != nil else { return }
            let alertEnabled = mb?["alert_color"] as? Bool ?? true   // 设置开关：菜单栏告警变色
            let rotateSecs = mb?["rotate_secs"] as? Int ?? 0
            let accounts = json["accounts"] as? [String: Any]
            // 单段（pct）/ 标注账号段（label pct）按需着色
            let valueDim = mb?["value_dim"] as? String ?? "shortest"
            let colorDim = mb?["color_dim"] as? String ?? "shortest"
            func alertFor(_ pct: Double) -> NSColor? {
                !alertEnabled ? nil : pct >= 95 ? .systemRed
                              : pct >= 80 ? quotaWarnColor() : nil
            }
            // 默认维度优先通用额度；仅当通用额度缺失时才回退模型专项额度。
            // max 是用户显式选择的“用量最高”，仍覆盖全部独立窗口。
            func dimPct(_ windows: [[String: Any]], _ dim: String) -> Double? {
                let ids = windows.map { $0["id"] as? String ?? "" }
                let pcts = windows.map { $0["used_percent"] as? Double }
                guard let index = QuotaWindowPolicy.preferredIndex(
                    ids: ids, usedPercents: pcts, dimension: dim) else { return nil }
                return pcts[index]
            }
            var full: [MBItem] = []      // 全部 tool×账号，统一进入单槽位
            for tool in ["claude", "codex", "qoder", "qoder_cn"] {
                guard mb?[tool] as? Bool ?? false else { continue }
                // accounts 列表（新后端）；缺失则回退到顶层单账号对象
                let list = (accounts?[tool] as? [[String: Any]])
                    ?? (json[tool] as? [String: Any]).map { [$0] } ?? []
                let multi = list.filter { ($0["windows"] as? [[String: Any]])?.isEmpty == false }.count > 1
                for (i, node) in list.enumerated() {
                    guard let windows = node["windows"] as? [[String: Any]],
                          let p = dimPct(windows, valueDim) else { continue }
                    let alert = alertFor(dimPct(windows, colorDim) ?? p)   // 颜色由所选维度独立驱动
                    let pctStr = String(format: "%.0f%%", p)
                    let raw = node["account"] as? String ?? ""
                    let label = raw.count > 10 ? String(raw.prefix(10)) + "…" : raw  // 防长名撑宽菜单栏
                    // 轮转项：同 tool 多账号时带账号名区分；否则仅百分比
                    let text = (multi && !label.isEmpty) ? "\(label) \(pctStr)" : pctStr
                    let pageID = stableQuotaPageID(
                        agentID: tool, accountID: node["account_id"] as? String,
                        isDefault: node["is_default"] as? Bool ?? false,
                        fallbackIndex: i)
                    full.append(MBItem(id: pageID, tool: tool,
                                       text: text, alert: alert))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard MenubarRotationPolicy.shouldAcceptResponse(
                    requestID: requestID,
                    lastAppliedRequestID: self.menubarAppliedRequestID) else { return }
                self.menubarAppliedRequestID = requestID
                self.statusItem.isVisible = true   // 兜底：被系统/误操作隐藏后自动恢复
                self.statusItem.button?.contentTintColor = nil
                let sharedID = self.store.quotaSelectionID
                let sharedTool = sharedID?.split(separator: ":", maxSplits: 1)
                    .first.map(String.init)
                let sharedToolEnabled = sharedTool.flatMap { mb?[$0] as? Bool } ?? false
                self.overviewSelectionOutsideMenubar =
                    MenubarRotationPolicy.selectionIsOutsideMenubar(
                        sharedID: sharedID, sharedToolEnabled: sharedToolEnabled,
                        itemIDs: full.map(\.id), panelVisible: self.panel?.isVisible == true)
                let currentID = sharedID.flatMap { id in
                    full.contains(where: { $0.id == id }) ? id : nil
                } ?? (self.mbFull.indices.contains(self.rotateIdx)
                    ? self.mbFull[self.rotateIdx].id : nil)
                self.mbFull = full
                self.rotateIdx = MenubarRotationPolicy.reconciledIndex(
                    currentID: currentID, itemIDs: full.map(\.id))
                self.rotateSecs = rotateSecs
                self.configureMenubar()
            }
        }.resume()
    }

    /// 状态栏始终只显示一个同级页面；rotate_secs=0 时固定当前页，大于 0 时自动滚动。
    func configureMenubar() {
        updateMenubarSlotWidth()
        let interval = MenubarRotationPolicy.interval(
            configuredSeconds: rotateSecs, itemCount: mbFull.count)
        store.setMenubarRotationActive(interval != nil)
        if let interval, !quotaRotationPaused && !overviewSelectionOutsideMenubar {
            if rotateTimer == nil || rotateTimer?.timeInterval != interval {
                rotateTimer?.invalidate()
                rotateTimer = Timer.scheduledTimer(withTimeInterval: interval,
                                                   repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.advanceRotation() }
                }
            }
        } else {
            rotateTimer?.invalidate()
            rotateTimer = nil
        }
        if rotateIdx >= mbFull.count { rotateIdx = 0 }
        // A quota poll may land during the short rolling transition. Do not cancel that
        // transition with a non-animated redraw; its final frame already owns the slot.
        if !MenubarRotationPolicy.shouldDeferPassiveRefresh(
                isAnimating: menubarAnimationTimer != nil) {
            drawMenubar(mbFull.isEmpty ? [] : [mbFull[rotateIdx]], animated: false)
        }
        if !overviewSelectionOutsideMenubar { publishMenubarSelection() }
    }

    func advanceRotation() {
        guard mbFull.count > 1 else { return }
        rotateIdx = MenubarRotationPolicy.nextIndex(current: rotateIdx, itemCount: mbFull.count)
        publishMenubarSelection()
        drawMenubar([mbFull[rotateIdx]], animated: true)
    }

    func selectMenubarPage(id: String, animated: Bool) {
        guard let index = mbFull.firstIndex(where: { $0.id == id }) else {
            let tool = id.split(separator: ":", maxSplits: 1).first.map(String.init)
            let toolEnabled = tool.map { menubarAgentEnabled($0) } ?? false
            overviewSelectionOutsideMenubar =
                MenubarRotationPolicy.selectionIsOutsideMenubar(
                    sharedID: id, sharedToolEnabled: toolEnabled,
                    itemIDs: mbFull.map(\.id), panelVisible: panel?.isVisible == true)
            configureMenubar()
            return
        }
        overviewSelectionOutsideMenubar = false
        let changed = index != rotateIdx
        rotateIdx = index
        if let timer = rotateTimer {
            timer.fireDate = Date().addingTimeInterval(timer.timeInterval)
        }
        publishMenubarSelection()
        if changed || currentMenubarImage == nil {
            drawMenubar([mbFull[index]], animated: animated)
        }
    }

    func publishMenubarSelection() {
        let id = MenubarRotationPolicy.currentItem(items: mbFull, currentIndex: rotateIdx)?.id
        store.selectQuotaPage(id, notifyMenubar: false)
    }

    private func menubarAgentEnabled(_ tool: String) -> Bool {
        switch tool {
        case "claude", "codex", "qoder", "qoder_cn": return store.menubarAgentEnabled(tool)
        default: return false
        }
    }

    func drawMenubar(_ items: [MBItem], animated: Bool) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil
        guard let raw = composedIcon(items: items) else { return }
        let image = paddedMenubarImage(raw)
        if animated { animateMenubar(to: image) }
        else { setMenubarImage(image) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // 菜单栏常驻，不出现在 Dock
    app.run()
}
