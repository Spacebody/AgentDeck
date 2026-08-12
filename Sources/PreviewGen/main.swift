// AgentDeck v2 — 开发用无头预览生成器。`swift run PreviewGen [输出路径]` 把概览页
// 渲染成 PNG。仅开发期看效果用，不入 .app（build.sh 只打包 AgentDeck 产物）。
import Foundation
import AgentDeckKit

// 用法：PreviewGen [overview|codexonly|visibilityoff|visibilityon|quotacases|quotadual|quotaclaude|quotaduplicate|quotaharmony|charts|chartsfiltered|sessions|settings|agentsettings|widget|widgetsizes|widgetfour|widgetstress|root|widgetroot] [outPath]
var args = Array(CommandLine.arguments.dropFirst())
let mode = ["overview", "codexonly", "visibilityoff", "visibilityon", "quotacases", "quotadual", "quotaclaude", "quotaduplicate", "quotaharmony", "charts", "chartsfiltered",
            "sessions", "settings", "agentsettings", "widget", "widgetsizes", "widgetfour", "widgetstress", "root", "widgetroot", "carousel"].contains(args.first)
    ? args.removeFirst() : "overview"
let outPath = args.first ?? "/tmp/agentdeck-\(mode).png"

let data = MainActor.assumeIsolated { () -> Data? in
    PreviewRender.useMaterialGlass()   // 无头：玻璃回退 SwiftUI 材质（ImageRenderer 渲不出 NSView）
    // 可经 AD_LOCALE=en|ja 切换预览语言，验证三语布局。
    if let loc = ProcessInfo.processInfo.environment["AD_LOCALE"] { PreviewRender.setLocale(loc) }
    if let raw = ProcessInfo.processInfo.environment["AD_FONT_SCALE"], let value = Int(raw) {
        PreviewRender.setFontScalePercent(value)
    }
    switch mode {
    case "codexonly":  return PreviewRender.codexOnlyOverviewPNG()
    case "visibilityoff": return PreviewRender.agentVisibilityOffPNG()
    case "visibilityon": return PreviewRender.agentVisibilityOnPNG()
    case "quotacases": return PreviewRender.quotaCasesPNG()
    case "quotadual":  return PreviewRender.quotaDualCasesPNG()
    case "quotaclaude": return PreviewRender.quotaClaudeCasesPNG()
    case "quotaduplicate": return PreviewRender.quotaDuplicatePNG()
    case "quotaharmony": return PreviewRender.quotaHarmonyPNG()
    case "charts":     return PreviewRender.chartsPNG()
    case "chartsfiltered": return PreviewRender.filteredChartsPNG()
    case "sessions":   return PreviewRender.sessionsPNG()
    case "settings":   return PreviewRender.settingsPNG()
    case "agentsettings": return PreviewRender.agentSettingsPNG()
    case "widget":     return PreviewRender.widgetPNG()
    case "widgetsizes": return PreviewRender.widgetSizesPNG()
    case "widgetfour": return PreviewRender.widgetFourWindowPNG()
    case "widgetstress": return PreviewRender.widgetStressPNG()
    case "root":       return PreviewRender.rootPNG()
    case "widgetroot": return PreviewRender.widgetRootPNG()
    case "carousel":   return PreviewRender.carouselPNG()
    default:           return PreviewRender.overviewPNG()
    }
}
guard let data else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(data.count) bytes)")
