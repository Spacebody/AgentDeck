// AgentDeck v2 — 开发用无头预览生成器。`swift run PreviewGen [输出路径]` 把概览页
// 渲染成 PNG。仅开发期看效果用，不入 .app（build.sh 只打包 AgentDeck 产物）。
import Foundation
import AgentDeckKit

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "/tmp/agentdeck-preview.png"

let data = MainActor.assumeIsolated { PreviewRender.overviewPNG() }
guard let data else {
    FileHandle.standardError.write(Data("render failed\n".utf8))
    exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(data.count) bytes)")
