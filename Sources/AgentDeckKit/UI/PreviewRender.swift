// AgentDeck v2 — 无头预览渲染。用 SwiftUI ImageRenderer 把视图离屏渲染成 PNG，
// 供命令行 PreviewGen 调用（绕开 Xcode 可执行目标 Preview 限制；也便于自动核对）。
import SwiftUI
import AppKit

@MainActor
public enum PreviewRender {
    /// 开发期切换预览语言（zh-CN / en / ja），验证三语布局。
    public static func setLocale(_ l: String) { I18N.locale = l }

    /// 渲染概览页（额度卡）到 PNG 数据。scale=2 出 @2x 清晰图。
    public static func overviewPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 1080) {
            OverviewView(quota: PreviewSamples.response, usage: PreviewSamples.usage,
                         today: PreviewSamples.today, active: PreviewSamples.active, done: PreviewSamples.done)
        }, scale: scale)
    }

    /// 三种用量图各自渲染（验证 tab 切换后的视图，静态渲染拿不到 @State）。
    public static func chartsPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 620) {
            VStack(spacing: 10) {
                Curve24h(usage: PreviewSamples.usage).frame(height: 160).padding(12).glassCard()
                Week7Bars(usage: PreviewSamples.usage).frame(height: 160).padding(12).glassCard()
                ProjectTop(usage: PreviewSamples.usage).frame(height: 140).padding(12).glassCard()
            }
        }, scale: scale)
    }

    /// 会话页（含一行展开预览 + 操作可见）。
    public static func sessionsPNG(scale: CGFloat = 2) -> Data? {
        let firstKey = PreviewSamples.sessions.first!.rowKey
        return png(PanelChrome(height: 560) {
            SessionsView(sessions: PreviewSamples.sessions, scrollable: false,
                         initialExpanded: firstKey, seededPreviews: [firstKey: PreviewSamples.previewMsgs])
        }, scale: scale)
    }

    /// 设置页（全展开，不滚动以便整图自检）。
    public static func settingsPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome(height: 1480) {
            SettingsView(values: PreviewSamples.settingsValues, scrollable: false, version: "1.26.0")
        }, scale: scale)
    }

    /// 桌面小组件紧凑视图。
    public static func widgetPNG(scale: CGFloat = 2) -> Data? {
        png(WidgetChrome {
            WidgetView(quota: PreviewSamples.response, today: PreviewSamples.today,
                       active: PreviewSamples.active)
        }, scale: scale)
    }

    /// 整壳（顶栏 + 更新横幅 + 双 tab + 概览）。验证 #4+#10 组装。
    public static func rootPNG(scale: CGFloat = 2) -> Data? {
        png(AgentDeckRootView(previewStore: mockStore(), version: "1.26.0")
            .frame(width: 420, height: 1040), scale: scale)
    }

    /// 小组件整壳（store 驱动）。
    public static func widgetRootPNG(scale: CGFloat = 2) -> Data? {
        png(WidgetChrome {
            AgentDeckWidgetRootView(store: mockStore())
        }, scale: scale)
    }

    /// 预览用 mock store（同模块可直接塞 @Published）。
    static func mockStore() -> AppStore {
        let s = AppStore()
        s.quota = PreviewSamples.response
        s.usage = PreviewSamples.usage
        s.active = PreviewSamples.active
        s.done = PreviewSamples.done
        s.sessions = PreviewSamples.sessions
        s.settings = PreviewSamples.settingsValues
        s.update = UpdateInfo(current: "1.25.17", latest: "1.26.0", available: true,
                              url: "https://github.com/Spacebody/AgentDeck/releases",
                              dmg: nil, notesUrl: nil)
        return s
    }

    static func png<V: View>(_ view: V, scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
