// swift-tools-version: 6.0
// AgentDeck v2 工程定义。Swift 工具链自带，非第三方依赖 → 不破「零依赖」红线。
// 用 Xcode 打开本 package，AgentDeckKit 库目标的 SwiftUI Preview 即可工作。
// .app bundle 仍由 build.sh 组装（拷 daemon / UI / 图标 + Info.plist + 签名/公证）。
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v13)],   // 部署目标与 v1 一致（旧系统仍可启动）
    targets: [
        // 可执行壳：AppKit 入口（main.swift）。依赖 AgentDeckKit 取 SwiftUI/数据层。
        // SwiftUI 视图放库目标而非此处——可执行目标受 ENABLE_DEBUG_DYLIB 限制无法预览。
        .executableTarget(
            name: "AgentDeck",
            dependencies: ["AgentDeckKit"],
            path: "Sources/AgentDeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 库目标：SwiftUI 视图 + API 客户端 + 数据模型。Preview 在此可正常渲染。
        .target(
            name: "AgentDeckKit",
            path: "Sources/AgentDeckKit",
            resources: [
                .copy("Brand"),   // 官方品牌字形（claude/codex tray 模板图），经 Bundle.module 取
            ],
            swiftSettings: [
                // 现有 AppKit 壳与迁移期代码沿用 Swift 5 语言模式，回避 Swift 6 严格并发。
                .swiftLanguageMode(.v5),
            ]
        ),
        // 开发用无头预览生成器：`swift run PreviewGen` 把视图渲染成 PNG 看效果。
        // 不进 .app（build.sh 用 --product AgentDeck 只打包壳）。
        .executableTarget(
            name: "PreviewGen",
            dependencies: ["AgentDeckKit"],
            path: "Sources/PreviewGen",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AgentDeckKitTests",
            dependencies: ["AgentDeckKit"],
            path: "tests/AgentDeckKitTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
