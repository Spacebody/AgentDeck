// AgentDeck v2 — 开发用无头预览生成器。`swift run PreviewGen [输出路径]` 把概览页
// 渲染成 PNG。仅开发期看效果用，不入 .app（build.sh 只打包 AgentDeck 产物）。
import Foundation
import AgentDeckKit

// 用法：PreviewGen [overview|charts|sessions] [outPath]
var args = Array(CommandLine.arguments.dropFirst())
let mode = ["charts", "sessions", "settings"].contains(args.first) ? args.removeFirst() : "overview"
let outPath = args.first ?? "/tmp/agentdeck-\(mode).png"

let data = MainActor.assumeIsolated { () -> Data? in
    switch mode {
    case "charts":   return PreviewRender.chartsPNG()
    case "sessions": return PreviewRender.sessionsPNG()
    case "settings": return PreviewRender.settingsPNG()
    default:         return PreviewRender.overviewPNG()
    }
}
guard let data else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(data.count) bytes)")
