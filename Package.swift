// swift-tools-version: 6.0
// AgentDeck v2 工程定义。Swift 工具链自带，非第三方依赖 → 不破「零依赖」红线。
// 用 Xcode 打开本 package 即得 SwiftUI Preview；命令行 `swift build` 亦可构建。
// .app bundle 仍由 build.sh 组装（拷 daemon / UI / 图标 + Info.plist + 签名/公证）。
import PackageDescription

let package = Package(
    name: "AgentDeck",
    platforms: [.macOS(.v13)],   // 部署目标与 v1 一致（旧系统仍可启动）
    targets: [
        .executableTarget(
            name: "AgentDeck",
            path: "Sources/AgentDeck",
            swiftSettings: [
                // 沿用 Swift 5 语言模式：现有 AppKit 壳（NSObject 委托 / 全局可变状态 /
                // 大量主线程闭包）不适配 Swift 6 严格并发检查，迁移期先稳住编译，
                // 后续按视图逐步收敛到 @MainActor 再考虑切 6。
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
