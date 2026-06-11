// AgentDeck — 菜单栏壳：状态栏 icon + 自定义 HUD 玻璃面板(WKWebView) + 后端守护
import Cocoa
import ServiceManagement
import WebKit

let kPort = 7777
let kBase = "http://127.0.0.1:\(kPort)"          // Swift 原生请求 / 浏览器打开用
let kWebBase = "agentdeck://app"                 // WebView 经自定义 scheme 走，绕系统代理

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

/// WKWebView 自定义 scheme handler：页面与 /api 全走 agentdeck://，由本 handler 经
/// 禁代理 session 转发到 http://127.0.0.1:kPort。WebView 自身不再直发 HTTP 到回环，
/// 从根上绕开系统 PAC 把回环改道到 SOCKS 的问题。
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = LocalSchemeHandler()
    private var active = Set<ObjectIdentifier>()
    private let lock = NSLock()

    private func isActive(_ t: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active.contains(ObjectIdentifier(t))
    }
    private func drop(_ t: WKURLSchemeTask) {
        lock.lock(); active.remove(ObjectIdentifier(t)); lock.unlock()
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        lock.lock(); active.insert(ObjectIdentifier(task)); lock.unlock()
        let req = task.request
        guard let u = req.url,
              let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
              comps.host == "app" else {   // 只服务自身 origin，拒绝 agentdeck://其他host
            fail(task, URLError(.badURL)); return
        }
        var dst = URLComponents()
        dst.scheme = "http"; dst.host = "127.0.0.1"; dst.port = kPort
        let p = comps.percentEncodedPath
        dst.percentEncodedPath = p.isEmpty ? "/" : p
        dst.percentEncodedQuery = comps.percentEncodedQuery
        guard let durl = dst.url else { fail(task, URLError(.badURL)); return }

        var out = URLRequest(url: durl)
        out.httpMethod = req.httpMethod ?? "GET"
        var headers = req.allHTTPHeaderFields ?? [:]
        // WKURLSchemeTask 的 POST httpBody 常为空 → 前端 fetch 已把 body 经 X-AD-Body(base64) 头透传
        if let b64 = headers.removeValue(forKey: "X-AD-Body"),
           let d = Data(base64Encoded: b64) {
            out.httpBody = d
        } else if let b = req.httpBody {
            out.httpBody = b
        }
        // Origin=agentdeck://app 会被 daemon CSRF 拒；Host 让 URLSession 自设为 127.0.0.1
        headers.removeValue(forKey: "Origin")
        headers.removeValue(forKey: "Host")
        for (k, v) in headers { out.setValue(v, forHTTPHeaderField: k) }

        kDirectSession.dataTask(with: out) { [weak self] data, resp, err in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.isActive(task) else { return }   // 已 stop（页面切走）→ 禁止回调，防崩
                if let err = err { self.fail(task, err); return }
                let http = resp as? HTTPURLResponse
                let r = HTTPURLResponse(url: u, statusCode: http?.statusCode ?? 200,
                                        httpVersion: "HTTP/1.1",
                                        headerFields: http?.allHeaderFields as? [String: String])
                    ?? URLResponse(url: u, mimeType: http?.mimeType,
                                   expectedContentLength: data?.count ?? -1, textEncodingName: nil)
                task.didReceive(r)
                if let data { task.didReceive(data) }
                task.didFinish()
                self.drop(task)
            }
        }.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { drop(task) }

    private func fail(_ task: WKURLSchemeTask, _ error: Error) {
        guard isActive(task) else { return }
        task.didFailWithError(error); drop(task)
    }
}

/// 注入到 WebView 的 fetch 包装：把字符串 body 经 X-AD-Body(base64) 头透传，
/// 规避 WKURLSchemeTask 拿不到 POST httpBody 的限制。
let kBodyWrapJS = """
(function(){
  if (window.__adWrap) return; window.__adWrap = 1;
  const _f = window.fetch.bind(window);
  window.fetch = function(input, init){
    try {
      if (init && typeof init.body === 'string') {
        const h = Object.assign({}, init.headers);
        h['X-AD-Body'] = btoa(unescape(encodeURIComponent(init.body)));
        init = Object.assign({}, init, {headers: h});
      }
    } catch (e) {}
    return _f(input, init);
  };
})();
"""
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
        guard l || r || b || t else { return }   // 非边带不干预，光标交还 WKWebView
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

// JS → 原生桥：面板内「退出」按钮经此通道终止 App
final class ControlBridge: NSObject, WKScriptMessageHandler {
    static let shared = ControlBridge()
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        let delegate = NSApp.delegate as? AppDelegate
        guard let body = message.body as? String else { return }
        if body.hasPrefix("open:") {   // 打开外部链接（更新下载页 / GitHub issue / mailto 反馈）
            if let url = URL(string: String(body.dropFirst(5))),
               url.scheme == "https" || url.scheme == "http" || url.scheme == "mailto" {
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
        // 自定义 scheme + fetch body 包装：所有页面/接口请求绕系统代理直连 daemon
        conf.setURLSchemeHandler(LocalSchemeHandler.shared, forURLScheme: "agentdeck")
        conf.userContentController.addUserScript(
            WKUserScript(source: kBodyWrapJS, injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 640),
                            configuration: conf)
        webView.setValue(false, forKey: "drawsBackground") // 透明背景与玻璃 UI 融合
        webView.underPageBackgroundColor = .clear          // 让系统液态玻璃材质透出
        view = webView
    }

    func load() {
        _ = view   // 确保 loadView 已执行（无 NSPopover 提前触发后必须显式拉起）
        webView.load(URLRequest(url: URL(string: "\(kWebBase)\(path)")!))
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
    var appearanceObs: NSKeyValueObservation?   // 菜单栏明暗变化 → 重绘混色图标
    // 多账号菜单栏轮转
    typealias MBItem = (tool: String, text: String, alert: NSColor?)
    var rotateTimer: Timer?
    var mbFull: [MBItem] = []      // 全部 (tool×账号) 项，轮转用
    var mbPrimary: [MBItem] = []   // 每 tool 仅主账号一段，不轮转时显示（=今天行为）
    var rotateSecs = 0
    var rotateIdx = 0

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
            // 混色图标的常规段颜色取决于菜单栏明暗，外观变化时重绘
            appearanceObs = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                DispatchQueue.main.async { self?.updateIconState() }
            }
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
        kDirectSession.dataTask(with: req) { [weak self] data, _, _ in
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
        kDirectSession.dataTask(with: url) { [weak self] data, _, _ in
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

    /// 多段「图标+百分比」合成单张状态栏图：垂直居中自己掌控；各段按自身额度独立着色。
    /// 全段常规 → 模板图（随菜单栏自适应黑白）；任一段告警 → 混色非模板图，
    /// 常规段按菜单栏明暗自行取黑/白，告警段烘入告警色
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
            // 顶部 28px 原生拖拽把手（盖在 webview 之上）
            let handle = DragHandle(frame: NSRect(x: 0, y: H - 28, width: W, height: 28))
            handle.autoresizingMask = [.width, .minYMargin]
            effect.addSubview(handle)
            // 最上层：按住 ⌘ 任意位置可拖（顶部把手够不到时的兜底），平时事件穿透不挡交互
            let cmdDrag = CmdDragView(frame: effect.bounds)
            cmdDrag.autoresizingMask = [.width, .height]
            effect.addSubview(cmdDrag)
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
        let mine = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        healthCheck { [weak self] alive, version in
            guard let self = self else { return }
            // 端口上跑着同版本 daemon 才复用；版本不符（装了新版仍占着旧后端）则清掉换新——
            // daemon 是常驻进程，磁盘换了 .py 也不会自动重载，必须强制重起才跑新代码。
            if alive, version == mine { done(); return }
            if alive { self.killStaleBackend() }
            self.spawnBackend()
            // 等后端起来再加载页面，最多重试 10 次
            self.waitHealthy(retries: 10, then: done)
        }
    }

    func waitHealthy(retries: Int, then done: @escaping () -> Void) {
        healthCheck { [weak self] alive, _ in
            if alive || retries <= 0 { done(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self?.waitHealthy(retries: retries - 1, then: done)
            }
        }
    }

    func healthCheck(_ cb: @escaping (Bool, String?) -> Void) {
        var req = URLRequest(url: URL(string: "\(kBase)/api/health")!)
        req.timeoutInterval = 2
        kDirectSession.dataTask(with: req) { data, _, _ in
            // 校验响应身份：端口被其他进程占用时不能误当作后端
            let obj = data.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            cb(obj?["ok"] as? Bool ?? false, obj?["version"] as? String)
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
        kDirectSession.dataTask(with: url) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            let mb = json["menubar"] as? [String: Any]
            let alertEnabled = mb?["alert_color"] as? Bool ?? true   // 设置开关：菜单栏告警变色
            let rotateSecs = mb?["rotate_secs"] as? Int ?? 0
            let accounts = json["accounts"] as? [String: Any]
            // 单段（pct）/ 标注账号段（label pct）按需着色
            let valueDim = mb?["value_dim"] as? String ?? "shortest"
            let colorDim = mb?["color_dim"] as? String ?? "shortest"
            func alertFor(_ pct: Double) -> NSColor? {
                !alertEnabled ? nil : pct >= 95 ? .systemRed
                              : pct >= 80 ? .systemOrange : nil
            }
            // 抽象维度 → 各 agent 自己的窗口（对 Claude/Codex 都成立）
            //   shortest=首窗口(5h)  weekly=seven_day(缺则次窗口/末窗口)  max=所有窗口最大值
            func dimPct(_ windows: [[String: Any]], _ dim: String) -> Double? {
                let pcts = windows.map { $0["used_percent"] as? Double }
                switch dim {
                case "max":
                    return pcts.compactMap { $0 }.max()
                case "weekly":
                    if let w = windows.first(where: { ($0["id"] as? String) == "seven_day" }),
                       let p = w["used_percent"] as? Double { return p }
                    return (windows.count > 1 ? windows.last : windows.first)?["used_percent"] as? Double
                default:   // shortest
                    return windows.first?["used_percent"] as? Double
                }
            }
            var full: [MBItem] = []      // 全部 tool×账号，轮转用
            var primaryList: [MBItem] = []   // 每 tool 主账号一段
            for tool in ["claude", "codex"] {
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
                    full.append((tool, text, alert))
                    if i == 0 { primaryList.append((tool, pctStr, alert)) }  // 主账号
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem.isVisible = true   // 兜底：被系统/误操作隐藏后自动恢复
                self.statusItem.button?.contentTintColor = nil
                self.mbFull = full
                self.mbPrimary = primaryList
                self.rotateSecs = rotateSecs
                self.configureMenubar()
            }
        }.resume()
    }

    /// 决定菜单栏是「轮转」还是「主账号常显」，并立即重绘。
    /// rotate_secs>0 且有多于一项（tool×账号）→ 起轮转定时器逐项显示；否则停轮转、显示主账号段。
    func configureMenubar() {
        let shouldRotate = rotateSecs > 0 && mbFull.count > 1
        if shouldRotate {
            if rotateTimer == nil || rotateTimer?.timeInterval != Double(rotateSecs) {
                rotateTimer?.invalidate()
                rotateTimer = Timer.scheduledTimer(withTimeInterval: Double(rotateSecs),
                                                   repeats: true) { [weak self] _ in
                    self?.advanceRotation()
                }
            }
            if rotateIdx >= mbFull.count { rotateIdx = 0 }
            drawMenubar([mbFull[rotateIdx]])   // 立即显示当前项，不等首次 tick
        } else {
            rotateTimer?.invalidate()
            rotateTimer = nil
            drawMenubar(mbPrimary)
        }
    }

    func advanceRotation() {
        guard !mbFull.isEmpty else { return }
        rotateIdx = (rotateIdx + 1) % mbFull.count
        drawMenubar([mbFull[rotateIdx]])
    }

    func drawMenubar(_ items: [MBItem]) {
        guard let button = statusItem.button else { return }
        button.contentTintColor = nil
        if let img = composedIcon(items: items) { button.image = img }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 菜单栏常驻，不出现在 Dock
app.run()
