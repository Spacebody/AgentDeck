<p align="center">
  <img src="docs/icon.png" width="96" alt="AgentDeck 图标">
</p>

<h1 align="center">AgentDeck</h1>

<p align="center">
  macOS 菜单栏应用：统一监控 <b>Claude Code</b> 与 <b>Codex</b> 的额度、会话与用量。
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="Dependencies">
  <img src="https://img.shields.io/badge/i18n-中%20%C2%B7%20EN%20%C2%B7%20日-8a7cff" alt="i18n">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

<p align="center">
  <a href="https://agentdeck.yilin.dev">官网</a> ·
  <b>简体中文</b> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="docs/screenshots/i18n-demo.gif" width="300" alt="概览与会话面板（中 / 英 / 日）">
  &nbsp;
  <img src="docs/screenshots/settings-zh.png" width="300" alt="设置面板">
</p>
<p align="center"><sub>左：概览 / 会话面板（三语轮播，默认跟随系统语言）· 右：设置</sub></p>

AgentDeck 将 Claude Code 与 Codex 的额度监控、会话管理与用量统计集成在一个菜单栏面板中。后端为纯标准库 Python daemon，macOS 客户端为 SwiftPM 工程中的原生 AppKit + SwiftUI 应用，仍保持零第三方运行时依赖、无 Node / Electron / 打包器、无运行时下载。

## 设计原则

- **零第三方依赖** — 标准库 Python + SwiftPM 原生 AppKit / SwiftUI；不引入 Node、Electron 或任何打包器
- **本地优先** — 数据全程本机处理，零遥测；仅有两条出站请求（额度查询、版本检查），语义透明、后者可关闭
- **原生体验** — 连续曲率圆角、玻璃材质、桌面小组件，对齐系统组件的视觉标准
- **多语言** — 简体中文 / English / 日本語三层（面板 / 通知 / 菜单）统一，默认跟随系统

## 功能

**额度监控**
- 实时聚合 Claude 官方额度（5 小时 / 7 天窗口）与 Codex rate limits
- 多账号并行：自动发现多个 Claude 配置目录（`CLAUDE_CONFIG_DIR` / `~/.claude-*` / shell 启动文件），逐账号查询额度，面板轮播切换、菜单栏可按间隔轮显各账号
- 菜单栏常显用量百分比（可配置显示单端 / 双端 / 隐藏；数字与变色各自可选 5h / 周 / 最吃紧窗口）
- 额度查询间隔可调（默认 10 分钟，可至 6 小时），按需降低官方接口调用频率以缓解多账号限流
- 窗口重置进度条；额度临界与回满的系统通知（阈值可配置）

**会话管理**
- 识别双端活跃会话，覆盖终端内 CLI 会话与 Codex 桌面端会话
- 点击活跃会话聚焦其所在终端：沿进程链自动识别宿主 `.app`，兼容任意终端，无需维护终端清单；iTerm2 / Terminal 精确至标签页；Codex 桌面端经 `codex://` 深链直达线程
- 会话完成弹窗提醒，点击跳转回会话；事件去重，仅提醒一次
- 历史会话一键恢复：iTerm2 / Terminal / Ghostty / kitty / WezTerm / Alacritty 直接注入命令启动；Warp / VS Code / Cursor / Windsurf / Hyper / Tabby / Rio / Wave 走「打开应用 + 复制命令」
- 会话列表支持搜索、按端筛选、置顶与对话预览

**用量统计**
- 近 7 / 30 天 token 用量与成本估算（口径见下文）
- 今日摘要、24 小时环比曲线、模型分布、项目维度排行
- 支持导出 CSV

**界面与系统**
- 主题配色：用取色器自定义 Claude / Codex 主色，额度环、进度条、用量曲线、Logo 渐变全部同步换色，一键恢复内置橙 / 青
- 展示 Agent 开关：只用 Claude 或仅用 Codex 的用户可隐藏另一端，隐藏后不再为其拉取额度（省钥匙串读取与官方接口调用）
- 字体大小 80–160% 整体缩放（面板与小组件同步）；暗化强度、精简模式等外观配置
- 活跃会话期间保持系统唤醒，防止长任务因休眠断流（默认开，可关）
- 兼容企业代理环境：App 访问本机 daemon 的流量绕过系统级 PAC 代理，避免回环被改道导致面板空白
- 版本更新发现：自动检查（仅查询版本号，可关闭）与设置内手动检查；有新版时面板顶部横幅提示
- 桌面小组件：常驻桌面层的玻璃信息卡，支持拖动、缩放与位置记忆

## 安装

```bash
git clone https://github.com/Spacebody/AgentDeck.git && cd AgentDeck
./build.sh install
```

编译、安装至 `/Applications` 并启动，首次启动注册登录项实现自启。

**环境要求**：macOS 13+（产出 Apple Silicon + Intel 通用二进制）；已安装 [Claude Code](https://claude.com/claude-code) 或 [Codex](https://openai.com/codex)（任一）；Xcode Command Line Tools（提供 SwiftPM / Swift toolchain，可经 `xcode-select --install` 安装）。

其余构建目标：

```bash
./build.sh           # 仅构建 dist/AgentDeck.app
./build.sh dmg       # 产出可分发 DMG
./build.sh uninstall # 卸载（默认保留数据目录）
```

首次使用「跳转会话」时，系统将请求**自动化（Apple Events）**权限用于聚焦终端窗口。

## 会话完成提醒集成

完成提醒依赖 Claude / Codex 的事件回调。当前版本在 daemon 启动时会**幂等自动接入**，并只合并 / 移除带 AgentDeck 标记的配置：

- Claude Code：向 `~/.claude/settings.json` 的 `hooks.Stop` 合并一个指向 `~/Library/Application Support/AgentDeck/claude-stop-hook.sh` 的 Stop hook。
- Codex：默认由 `~/Library/Application Support/AgentDeck/codex-notify.sh` 占用根 `notify` 并顺序转发原命令；若 Computer Use 等外部工具已持有根槽并通过 `--previous-notify` 链入 AgentDeck，则保留外部 owner，AgentDeck 不再反向转发，避免形成通知环。
- 集成状态记录在 `~/Library/Application Support/AgentDeck/integration.json`；`./build.sh uninstall` 会调用 daemon 的 `--remove-integration` 仅还原 AgentDeck 自己安装的条目。

仓库内仍保留手动调试用脚本 `scripts/codex-notify.sh`，但正常安装使用 App Support 中自动生成的 wrapper。

手动转发 Claude Stop 事件的最小命令形态如下：

```json
{
  "hooks": [{
    "type": "command",
    "command": "curl -sf -m 3 -X POST http://127.0.0.1:7777/api/event -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 || true",
    "timeout": 5,
    "async": true
  }]
}
```

## 架构

```
Package.swift        SwiftPM 包定义：AgentDeck 可执行目标、AgentDeckKit 库、PreviewGen 预览工具
Sources/AgentDeck/   AppKit 壳：菜单栏、NSPanel、桌面小组件、灵动岛、daemon 守护
Sources/AgentDeckKit/SwiftUI UI、API 客户端、数据模型、三语 i18n、预览渲染
Sources/PreviewGen/  无头渲染 UI 预览图，用于开发检查
agentdeckd.py        后端 daemon：采集 / 解析 / 聚合 / HTTP API / hook 集成（纯标准库）
static/index.html    旧 Web UI / 浏览器 fallback；daemon 仍在 / 和 /index.html 提供
site/                官网与更新清单（Cloudflare Pages，零依赖静态页）
build.sh             构建 / 安装 / DMG / 卸载
scripts/             图标与 DMG 背景生成、Codex notify 包装、CSRF 回归测试
```

应用壳启动时拉起 daemon（监听 `127.0.0.1:7777`）；面板与小组件由 `NSHostingView` 承载 SwiftUI 根视图，经 HTTP API 取数。`static/index.html` 不再是主 App UI。

## 数据来源与隐私

所有数据**仅在本机处理**，无遥测、无上报：

| 数据 | 来源 | 说明 |
|------|------|------|
| Claude 额度 | 钥匙串中 Claude Code 的 OAuth 凭据 → `api.anthropic.com/api/oauth/usage` | 以用户本人凭据查询本人额度；多账号时按配置目录各自精确取对应凭据 |
| 版本检查 | `agentdeck.yilin.dev/version.json`（静态清单，6 小时缓存） | 仅比对版本号，不携带凭据或本机信息；可在设置中关闭 |
| Claude 用量 / 会话 | 解析已发现的各 Claude 配置目录下 `projects/**/*.jsonl` | token 统计、成本估算、会话列表 |
| Codex 额度 / 用量 / 会话 | 解析本地 `~/.codex/sessions` rollout 文件 | 同上 |
| 完成事件 | AgentDeck 自动安装的 Claude Stop hook / Codex notify wrapper 回调（见会话完成提醒集成） | 完成提醒与事件流 |

运行时产物：数据目录 `~/Library/Application Support/AgentDeck/`，日志 `~/Library/Logs/AgentDeck.log`。其中 `claude_usage_cache.json` 与 `codex_usage_cache.json` 是按文件 inode/大小校验的可重建增量缓存，删除后只会触发下一次全量统计。

## 安全设计

- daemon 仅绑定回环地址 `127.0.0.1`，不对局域网暴露
- 全部 `/api/*` GET 及 POST 接口校验本机 Host；POST 额外要求 Content-Type 精确匹配及 Origin 结构化同源校验，封锁 DNS rebinding / 浏览器 CSRF；附回归测试 `scripts/test-csrf.sh`
- 「按请求参数读取文件」的路径统一收口至已发现的 Claude 配置目录内（realpath 校验）
- 账号诊断接口 `/api/diag` 输出全程脱敏（token 仅留末 4 位）
- 自动更新仅接受固定 GitHub Release 路径，安装前核对 bundle ID、清单版本、完整代码签名、Team ID 与 Gatekeeper assessment；复制或复验失败会原子恢复旧 App
- 健康检查带身份校验，避免端口被其他进程占用时误判

## 统计口径

- **Claude**：usage 记录按 `(message.id, requestId)` 去重；cache 写入按 ephemeral 5m / 1h 两档分别计价；单价表按模型版本前缀匹配
- **Codex**：按每条 `total_token_usage` 累计快照的正增量归入事件发生小时；跳过会完整重放父历史的 subagent rollout，只统计顶层累计流，cached input 不重复计入 input
- 金额为静态模型单价表换算的 API 等值估算，不代表订阅实际账单；未知 Codex 模型按当前默认档估算
- 面板内各 ⓘ 入口提供对应视图的逐项口径说明

## 致谢

- 菜单栏品牌字形取自 Claude / Codex 官方应用内置的菜单栏模板图，版权归 Anthropic / OpenAI 所有，仅作来源标识
- 会话跳转的终端聚焦思路最初借鉴 MioIsland（Ghostty 按 cwd 精确聚焦），现已演进为沿进程链自动识别任意终端宿主
- 用量统计以 [ccusage](https://github.com/ryoppippi/ccusage) 为独立基准交叉校准

## 更新日志

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
