// AgentDeck v2 — 无头预览渲染。用 SwiftUI ImageRenderer 把视图离屏渲染成 PNG，
// 供命令行 PreviewGen 调用（绕开 Xcode 可执行目标 Preview 限制；也便于自动核对）。
import SwiftUI
import AppKit

@MainActor
public enum PreviewRender {
    /// 渲染概览页（额度卡）到 PNG 数据。scale=2 出 @2x 清晰图。
    public static func overviewPNG(scale: CGFloat = 2) -> Data? {
        png(PanelChrome {
            OverviewView(quota: PreviewSamples.response, today: PreviewSamples.today,
                         active: PreviewSamples.active, done: PreviewSamples.done)
        }, scale: scale)
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
