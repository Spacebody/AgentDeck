// AgentDeck — 菜单栏壳：状态栏 icon + 自定义 HUD 玻璃面板(WKWebView) + 后端守护
import Cocoa
import ServiceManagement
import WebKit

let kPort = 7777
let kBase = "http://127.0.0.1:\(kPort)"
// 默认高取概览页全显 + 设置页大半的折中值，展示时钳制到屏幕可视高度
let kPanelW: CGFloat = 420, kPanelH: CGFloat = 780

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
    ],
    "en": [
        "menu.openBrowser": "Open in browser", "menu.restartBackend": "Restart backend",
        "menu.loginItem": "Launch at login", "menu.widget": "Desktop widget", "menu.quit": "Quit AgentDeck",
        "island.done": "Session done", "island.taskDone": "Task complete",
    ],
    "ja": [
        "menu.openBrowser": "ブラウザで開く", "menu.restartBackend": "バックエンドを再起動",
        "menu.loginItem": "ログイン時に起動", "menu.widget": "デスクトップウィジェット", "menu.quit": "AgentDeck を終了",
        "island.done": "セッション完了", "island.taskDone": "タスク完了",
    ],
]
func L(_ key: String) -> String {
    return kStrings[appLocale]?[key] ?? kStrings["en"]?[key] ?? key
}

/// 无边框面板：允许成为 key window（搜索框输入需要）
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// 小组件顶部拖拽把手：WKWebView 吞掉鼠标事件，isMovableByWindowBackground 失效，
/// 用原生透明条 + performDrag 实现拖动
final class DragHandle: NSView {
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
        var pos: NSCursor.FrameResizePosition?
        if l && b { pos = .bottomLeft } else if r && b { pos = .bottomRight }
        else if l && t { pos = .topLeft } else if r && t { pos = .topRight }
        else if l { pos = .left } else if r { pos = .right }
        else if b { pos = .bottom } else if t { pos = .top }
        guard let pos else { return }   // 非边带不干预，光标交还 WKWebView
        if #available(macOS 15.0, *) {
            NSCursor.frameResize(position: pos, directions: .all).set()
        } else {
            switch pos {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
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

// JS → 原生桥：面板内「退出」按钮经此通道终止 App
final class ControlBridge: NSObject, WKScriptMessageHandler {
    static let shared = ControlBridge()
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let delegate = NSApp.delegate as? AppDelegate
        guard let body = message.body as? String else { return }
        if body.hasPrefix("open:") {   // 打开外部链接（更新下载页等）→ 默认浏览器
            if let url = URL(string: String(body.dropFirst(5))),
               url.scheme == "https" || url.scheme == "http" {
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            }
            return
        }
        if body.hasPrefix("scale:") {   // 字体缩放 → 面板/小组件窗口同步放大，保持布局有效宽度
            if let z = Double(body.dropFirst(6)) {
                DispatchQueue.main.async { delegate?.applyUIScale(CGFloat(z)) }
            }
            return
        }
        switch body {
        case "quit":
            DispatchQueue.main.async { NSApp.terminate(nil) }
        case "panel":   // 桌面小组件点击 → 打开主面板
            DispatchQueue.main.async { delegate?.showPanel() }
        case "hide":    // 跳转会话成功 → 收起主面板，让目标终端独占前台
            DispatchQueue.main.async { delegate?.hidePanel() }
        case "sync":    // 设置变更 → 刷新菜单栏 + 桌面小组件（语言 / 外观跟随主面板）
            DispatchQueue.main.async {
                delegate?.updateIconState()
                delegate?.widgetVC.refresh()
            }
        default:
            break
        }
    }
}

final class WebViewController: NSViewController {
    var webView: WKWebView!
    var path = "/"

    override func loadView() {
        let conf = WKWebViewConfiguration()
        conf.userContentController.add(ControlBridge.shared, name: "control")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 640),
                            configuration: conf)
        webView.setValue(false, forKey: "drawsBackground") // 透明背景与玻璃 UI 融合
        webView.underPageBackgroundColor = .clear          // 让系统液态玻璃材质透出
        view = webView
    }

    func load() {
        _ = view   // 确保 loadView 已执行（无 NSPopover 提前触发后必须显式拉起）
        webView.load(URLRequest(url: URL(string: "\(kBase)\(path)")!))
    }

    func refresh() {
        guard isViewLoaded else { return }
        webView.evaluateJavaScript("window.refresh && window.refresh()", completionHandler: nil)
    }
}

// MARK: - 灵动岛式完成提醒
final class IslandController {
    static let shared = IslandController()
    typealias Event = (tool: String, title: String, project: String,
                       session: String, cwd: String)
    private var queue: [Event] = []
    private var showing = false
    private var window: KeyPanel?
    private var current: Event?
    var onTap: ((Event?) -> Void)?
    var dwellSecs: Double = 5   // 停留时长，由设置经 /api/events 下发

    func push(_ event: Event) {
        queue.append(event)
        maybeShow()
    }

    private func maybeShow() {
        guard !showing, !queue.isEmpty else { return }
        showing = true
        display(queue.removeFirst())
    }

    private func appIcon(for tool: String) -> NSImage {
        let path = tool == "claude" ? "/Applications/Claude.app" : "/Applications/Codex.app"
        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 26, height: 26)
        return img
    }

    private func display(_ e: Event) {
        current = e
        guard let screen = NSScreen.main else { showing = false; return }
        let H: CGFloat = 46

        // 文案
        let head = NSTextField(labelWithString:
            "\(e.project.isEmpty ? (e.tool == "claude" ? "Claude" : "Codex") : e.project) · \(L("island.done"))")
        head.font = .systemFont(ofSize: 12.5, weight: .semibold)
        head.textColor = .labelColor
        let sub = NSTextField(labelWithString: e.title.isEmpty ? L("island.taskDone") : e.title)
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
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let iconView = NSImageView(frame: NSRect(x: 14, y: (H - 26) / 2, width: 26, height: 26))
        iconView.image = appIcon(for: e.tool)
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
        let shownAt = Date()
        let myWindow = p
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellSecs) { [weak self] in
            // 防止 dwell 期间面板已被点击关闭后误关下一条
            guard let self, self.window === myWindow,
                  Date().timeIntervalSince(shownAt) >= self.dwellSecs - 0.1 else { return }
            self.dismiss()
        }
    }

    @objc private func tapped() {
        onTap?(current)
        dismiss(fast: true)
    }

    private func dismiss(fast: Bool = false) {
        guard let p = window else { showing = false; maybeShow(); return }
        window = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fast ? 0.15 : 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            var f = p.frame
            f = NSRect(x: f.midX - 23, y: f.minY + 8, width: 46, height: f.height - 16)
            p.animator().setFrame(f, display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            p.orderOut(nil)
            self?.showing = false
            self?.maybeShow()
        })
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
        // 尺寸切换用交叉淡变：WKWebView 渲染异步，任何「边框动画 + 内容追赶」的同步
        // 方案都可能出现玻璃先到、内容后到的脱节。淡出 → 不可见时一步切到新尺寸并等
        // 内容绘制提交（双 rAF）→ 淡入，中间状态不可见，绝无撕裂。
        let animate: (NSWindow, NSRect) -> Void = { w, target in
            guard w.frame.size != target.size else { w.setFrame(target, display: true); return }
            func findWeb(_ v: NSView) -> WKWebView? {
                if let wk = v as? WKWebView { return wk }
                for sub in v.subviews { if let hit = findWeb(sub) { return hit } }
                return nil
            }
            let wk = w.contentView.flatMap(findWeb)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                w.animator().alphaValue = 0
            }, completionHandler: { [weak w, weak wk] in
                guard let w else { return }
                w.setFrame(target, display: true)
                w.invalidateShadow()
                let fadeIn = { [weak w] in
                    guard let w else { return }
                    NSAnimationContext.runAnimationGroup({ ctx in
                        ctx.duration = 0.18
                        ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                        w.animator().alphaValue = 1
                    }, completionHandler: { [weak w] in w?.invalidateShadow() })
                }
                if let wk {   // 等新布局绘制提交后再淡入
                    wk.callAsyncJavaScript(
                        "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 16))))",
                        arguments: [:], in: nil, in: .page) { _ in fadeIn() }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fadeIn() }
                }
            })
        }
        if let p = panel, p.isVisible {          // 面板：锚定顶边中心重排
            let d = UserDefaults.standard
            let w = max(kPanelW, CGFloat(d.double(forKey: "panelW"))) * s
            let h = max(kPanelH, CGFloat(d.double(forKey: "panelH"))) * s
            let f = p.frame
            animate(p, NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h))
        }
        if let wp = widgetPanel, wp.isVisible {  // 小组件：锚定左上角
            let d = UserDefaults.standard
            let bw = CGFloat(d.double(forKey: "widgetW")) > 0 ? CGFloat(d.double(forKey: "widgetW")) : 360
            let bh = CGFloat(d.double(forKey: "widgetH")) > 0 ? CGFloat(d.double(forKey: "widgetH")) : 300
            wp.minSize = NSSize(width: 280 * s, height: 180 * s)
            wp.maxSize = NSSize(width: 720 * s, height: 560 * s)
            let f = wp.frame
            animate(wp, NSRect(x: f.minX, y: f.maxY - max(180, bh) * s,
                               width: max(280, bw) * s, height: max(180, bh) * s))
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        let d = UserDefaults.standard
        if w === panel {
            d.set(Double(w.frame.width / uiScale), forKey: "panelW")
            d.set(Double(w.frame.height / uiScale), forKey: "panelH")
        } else if w === widgetPanel {
            d.set(Double(w.frame.width / uiScale), forKey: "widgetW")
            d.set(Double(w.frame.height / uiScale), forKey: "widgetH")
        }
        w.invalidateShadow()
    }

    var statusItem: NSStatusItem!
    var panel: KeyPanel?
    var clickMonitor: Any?
    var keyMonitor: Any?
    let webVC = WebViewController()
    var backend: Process?
    var pollTimer: Timer?
    var eventTimer: Timer?
    var lastEventId = 0
    var eventsPrimed = false
    var loaded = false

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
        }

        ensureBackend { [weak self] in
            DispatchQueue.main.async {
                self?.webVC.load()
                self?.loaded = true
                if self?.widgetEnabled == true { self?.showWidget() }
            }
        }

        // 首次启动自动注册开机自启（可在右键菜单或系统设置·登录项关闭）
        if !UserDefaults.standard.bool(forKey: "loginItemSetup") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSetup")
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.updateIconState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.updateIconState()
        }

        // 会话完成事件 → 灵动岛；点击 → 跳转会话所在终端，失败则打开面板
        IslandController.shared.onTap = { [weak self] event in
            self?.focusSession(event)
        }
        eventTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.pollEvents()
        }
    }

    func focusSession(_ event: IslandController.Event?) {
        guard let event else { showPanel(); return }
        var req = URLRequest(url: URL(string: "\(kBase)/api/focus")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "tool": event.tool, "session": event.session, "cwd": event.cwd])
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            let ok = (data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            })?["ok"] as? Bool ?? false
            if !ok {   // 找不到终端 → 兜底打开面板
                DispatchQueue.main.async { self?.showPanel() }
            }
        }.resume()
    }

    func pollEvents() {
        guard let url = URL(string: "\(kBase)/api/events?since=\(lastEventId)") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = json["events"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                if let secs = json["island_secs"] as? Double {
                    IslandController.shared.dwellSecs = secs
                } else if let secs = json["island_secs"] as? Int {
                    IslandController.shared.dwellSecs = Double(secs)
                }
                if let loc = json["locale"] as? String { appLocale = loc }   // 三层语言一致
                if let last = json["last"] as? Int { self.lastEventId = max(self.lastEventId, last) }
                // 首次轮询只对齐游标不弹窗：壳重启而 daemon 存活时，避免重放历史事件
                if !self.eventsPrimed { self.eventsPrimed = true; return }
                for ev in events {
                    IslandController.shared.push((
                        tool: ev["tool"] as? String ?? "claude",
                        title: ev["title"] as? String ?? "",
                        project: ev["project"] as? String ?? "",
                        session: ev["session"] as? String ?? "",
                        cwd: ev["cwd"] as? String ?? ""))
                }
            }
        }.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        let file = tool == "codex" ? "codex-tray@2x" : "claude-tray@2x"
        if let path = Bundle.main.path(forResource: file, ofType: "png", inDirectory: "static/brand"),
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
        let img = NSImage(systemSymbolName: tool == "codex" ? "apple.terminal" : "sparkle",
                          accessibilityDescription: tool)?
            .withSymbolConfiguration(conf)
        img?.isTemplate = true
        return img
    }

    /// 多段「图标+百分比」合成单张模板图：垂直居中自己掌控；告警色统一走 contentTintColor
    /// items 为空 → 仅显示 AgentDeck 仪表图标
    func composedIcon(items: [(tool: String, pct: Double)]) -> NSImage? {
        let barH: CGFloat = 22, gap: CGFloat = 3, groupGap: CGFloat = 8
        var parts: [(NSImage, NSAttributedString)] = []
        for it in items {
            guard let g = agentGlyph(it.tool) else { continue }
            parts.append((g, NSAttributedString(
                string: String(format: "%.0f%%", it.pct),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.black,   // 模板图只取 alpha 通道
                ])))
        }
        var symbols: [(NSImage, NSAttributedString?)] = parts.map { ($0.0, $0.1) }
        if symbols.isEmpty {
            symbols = [(deckGlyph(), nil)]   // 全不选 → 自身双环字形
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
        img.isTemplate = true
        return img
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
        p.minSize = NSSize(width: 420, height: 600)   // 最小尺寸限制，只许放大
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

        webVC.view.frame = effect.bounds
        webVC.view.autoresizingMask = [.width, .height]
        effect.addSubview(webVC.view)
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
        if !loaded { webVC.load(); loaded = true } else { webVC.refresh() }

        // 尺寸：恢复用户上次拖拽的大小（不小于默认），高度不超过屏幕可视范围
        let d = UserDefaults.standard
        let bFrame = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let vis = (bw.screen ?? NSScreen.main!).visibleFrame
        let w = max(kPanelW, CGFloat(d.double(forKey: "panelW"))) * uiScale
        let maxH = bFrame.minY - 6 - (vis.minY + 8)   // 图标下沿到屏幕底的可用高度
        let h = min(max(kPanelH, CGFloat(d.double(forKey: "panelH"))) * uiScale, maxH)
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
        panel?.orderOut(nil)
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    // MARK: - 桌面小组件（驻留桌面层的玻璃小窗）
    var widgetPanel: NSPanel?
    let widgetVC = WebViewController()

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
            let W = max(280, CGFloat(d0.double(forKey: "widgetW")) > 0
                        ? CGFloat(d0.double(forKey: "widgetW")) : 360) * uiScale
            let H = max(180, CGFloat(d0.double(forKey: "widgetH")) > 0
                        ? CGFloat(d0.double(forKey: "widgetH")) : 300) * uiScale
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: W, height: H),
                            styleMask: [.borderless, .nonactivatingPanel,
                                        .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
            p.minSize = NSSize(width: 280 * uiScale, height: 180 * uiScale)
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

            widgetVC.path = "/?widget=1"
            widgetVC.view.frame = effect.bounds
            widgetVC.view.autoresizingMask = [.width, .height]
            effect.addSubview(widgetVC.view)
            addRim(to: effect, radius: 28)   // 顶亮底暗渐变描边
            addEdgeCursor(to: effect, allowTop: false)   // 顶部是拖动把手
            // 顶部 22px 原生拖拽把手（盖在 webview 之上）
            let handle = DragHandle(frame: NSRect(x: 0, y: H - 22, width: W, height: 22))
            handle.autoresizingMask = [.width, .minYMargin]
            effect.addSubview(handle)
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
            p.setFrame(NSRect(x: x, y: y, width: W, height: H), display: true)
            widgetVC.load()
            for delay in [0.3, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak p] in
                    p?.invalidateShadow()
                }
            }
        }
        widgetPanel?.orderFront(nil)
    }

    func hideWidget() {
        widgetPanel?.orderOut(nil)
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
        backend?.terminate()
        backend = nil
        killStaleBackend()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.spawnBackend()
        }
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

    func ensureBackend(then done: @escaping () -> Void) {
        healthCheck { [weak self] alive in
            if alive { done(); return }
            self?.spawnBackend()
            // 等后端起来再加载页面，最多重试 10 次
            self?.waitHealthy(retries: 10, then: done)
        }
    }

    func waitHealthy(retries: Int, then done: @escaping () -> Void) {
        healthCheck { [weak self] alive in
            if alive || retries <= 0 { done(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self?.waitHealthy(retries: retries - 1, then: done)
            }
        }
    }

    func healthCheck(_ cb: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "\(kBase)/api/health")!)
        req.timeoutInterval = 2
        URLSession.shared.dataTask(with: req) { data, _, _ in
            // 校验响应身份：端口被其他进程占用时不能误当作后端
            let ok = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }?["ok"] as? Bool ?? false
            cb(ok)
        }.resume()
    }

    func killStaleBackend() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "agentdeckd.py"]
        try? p.run(); p.waitUntilExit()
    }

    func spawnBackend() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", backendScript()]
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
        guard let url = URL(string: "\(kBase)/api/quota") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let mb = json["menubar"] as? [String: Any]
            var maxPct = 0.0                          // 全窗口最大值 → 决定告警色
            var items: [(tool: String, pct: Double)] = []   // 勾选的 agent → 常显段
            for tool in ["claude", "codex"] {
                guard let node = json[tool] as? [String: Any],
                      let windows = node["windows"] as? [[String: Any]] else { continue }
                for (i, w) in windows.enumerated() {
                    if let p = w["used_percent"] as? Double {
                        maxPct = max(maxPct, p)
                        if i == 0 && (mb?[tool] as? Bool ?? false) {
                            items.append((tool, p))
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                guard let button = self?.statusItem.button else { return }
                self?.statusItem.isVisible = true   // 兜底：被系统/误操作隐藏后自动恢复
                if maxPct >= 95 {
                    button.contentTintColor = .systemRed
                } else if maxPct >= 80 {
                    button.contentTintColor = .systemOrange
                } else {
                    button.contentTintColor = nil
                }
                if let img = self?.composedIcon(items: items) {
                    button.image = img
                }
            }
        }.resume()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏常驻，不出现在 Dock
app.run()
