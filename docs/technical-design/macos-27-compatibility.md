# macOS 27 兼容性适配

## 范围

2026-09-14：使用 Xcode 27.0 (27A266a)、macOS 27.0 SDK 编译，保持
macOS 13.0 最低部署目标、Apple Silicon + Intel 通用二进制和 Swift 5 语言模式。
首次验证系统为 macOS 26.6.2。2026-09-15 本机升级至 macOS 27.0 (26A428)，
重新完成编译、测试、签名和覆盖安装；以下分别记录已覆盖项目与待验范围。

## 修复与保护

- 实测 SwiftPM 27 默认 Swift Build 引擎生成的两个架构均记录 `minos 13.0 / sdk 13.0`，
  虽然编译使用 SDK 27。构建脚本显式选择 SDK，并通过链接器 `-platform_version`
  分别传入最低系统版本和实际 SDK 版本；修复后两个架构均为 `minos 13.0 / sdk 27.0`。
- 不再在通用构建失败时静默回退为 arm64-only，避免 Intel 用户下载不能运行的安装包。
- `scripts/verify-macos-build.py` 在安装前校验两个架构、各自的 macOS 平台/最低版本/SDK、
  Info.plist 和必需资源。缺项或不一致立即终止，不替换已安装的应用。
- 本地 ad-hoc 签名不再吞掉错误；所有构建签名后执行严格验证。DMG 公证流程不变。
- AppKit/SwiftUI 检查未发现必须更换的 macOS 27 API：保留 macOS 15 光标 API 可用性守卫、
  原生材质背板，以及隐藏时移除 NSHostingView 的生命周期处理。不为适配而迁移应用框架。

## 系统权限边界

依据 [Apple macOS 27 发布说明](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)，
新系统进一步限制跨开发者应用数据访问。现有 CLI 配置、日志以及 Qoder App 数据能否读取，
仍需在目标系统的实际安装环境测试，编译无法证明权限可用。
禁止读取 TCC 数据库、关闭 SIP、移除系统保护或自动扩大权限。
若升级后出现拒绝访问，应先核实被拒绝路径和系统隐私设置，而不是将空数据认定为没有会话。

应用后端仍依赖本机可用的 Python 3；安装包没有内嵌解释器，不保证全新系统自带 Python。
这属于既有运行环境要求，并非本次引入的依赖。

## 验证与复测

```bash
swift test
python3 -m unittest discover -s tests -p 'test_*.py'
./build.sh install
python3 scripts/verify-runtime.py
```

- Xcode 27 编译和 103 项 Swift 测试通过（含剪贴板写入失败、写入期间替换、交接后替换的回归）。
- Python 回归与新增构建校验共 219 项通过。
- 已签名安装至 `/Applications/AgentDeck.app`；macOS 26.6.2 上连续 30 次健康检查期间
  后端实例稳定，平均响应 3.4ms，最大 22.3ms；831 个会话可读取，额度/用量接口正常。
- 原生 UI 自动化访问已安装应用时超时，未完成本轮菜单栏和面板交互验收。
- 2026-09-14 时待验项目：登录项启动；菜单栏/面板/小组件开关和动画；额度切换；会话搜索与分页；
  Claude/Codex/Qoder 数据权限；单次完成通知；辅助功能授权后的跳转；退出/重启与应用内更新。
- macOS 13 和 Intel 本次只验证产物架构/部署元数据，没有相应机器进行运行测试。
- 自动粘贴交接竞态已修复：由 clearContents 返回的代次确定剪贴板所有权，确认写入成功且
  代次未变后，原样传递至主壳；不再重新采样并接受可能已被替换的内容。写入失败时提示
  复制失败并停止自动粘贴，普通复制和路径回退分支也不再误报成功。
- 粘贴按键创建失败时立即停止，避免仍发送回车。测试使用独立命名剪贴板，不改动用户剪贴板。
- 剪贴板修复经独立 CR 无发现；真实终端按键投递未做端到端自动化验收。

## macOS 27 发布复测（2026-09-15）

- Swift 100 项 XCTest + 3 项 Swift Testing、Python 220 项通过。
- 双架构构建通过；最低系统版本为 13.0，SDK 为 27.0；覆盖安装及严格签名校验通过。
- 安装后只有一个 App 和一个由其启动的 daemon，没有残留旧实例。
- 原生 UI 自动化服务启动失败，界面交互转为用户人工确认；不将服务故障视为应用异常。
- 用户已授权验证通过后发布 2.8.5，版本号按兼容性和安全修复采用 PATCH 递增。
- 实机发现 Python HTTPServer 在开始监听前等待反向 DNS，采样栈为
  `socket_gethostbyaddr -> mDNS -> kevent`。新增 LoopbackHTTPServer 仅执行 TCP 绑定并记录
  数字地址，不再调用 getfqdn；没有修改系统 DNS 或安全设置。修复后健康接口恢复，新增测试
  在禁止调用 getfqdn 的条件下验证服务成功绑定，原有 HTTP 测试也使用实际生产服务类。
- 修复后 2.8.5 连续 30 次健康检查保持同一后端实例，平均 4.7ms、最大 22.5ms；
  会话总数 831，用量 5.0ms、会话分页 30.6ms、缓存额度 21.0ms。独立 CR 无新增发现。
- DMG 制作完成，但公证凭证检查返回 `No Keychain password item found for profile: AgentDeck`；
  公证和公开发布尚未完成，需恢复凭证后继续。错误提示中的变量已用花括号明确边界，避免
  新系统 shell 将紧邻的中文标点误解析为变量名的一部分。不会推送更新清单来宣传未公证的产物。
