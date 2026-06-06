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

AgentDeck 将 Claude Code 与 Codex 的额度监控、会话管理与用量统计集成在一个菜单栏面板中。后端为纯标准库 Python daemon，应用壳为单文件 Swift（`swiftc` 直接编译），界面为单文件 HTML——无包管理器、无构建链、无运行时下载。

## 设计原则

- **零第三方依赖** — 标准库 Python + 原生编译 Swift + WKWebView；不引入 Node、Electron 或任何打包器
- **本地优先** — 数据全程本机处理，零遥测；仅有两条出站请求（额度查询、版本检查），语义透明、后者可关闭
- **原生体验** — 连续曲率圆角、玻璃材质、桌面小组件，对齐系统组件的视觉标准
- **多语言** — 简体中文 / English / 日本語三层（面板 / 通知 / 菜单）统一，默认跟随系统

## 功能

**额度监控**
- 实时聚合 Claude 官方额度（5 小时 / 7 天窗口）与 Codex rate limits
- 菜单栏常显用量百分比（可配置显示单端 / 双端 / 隐藏）
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
- 字体大小 80–160% 整体缩放（面板与小组件同步）；暗化强度、精简模式等外观配置
- 活跃会话期间保持系统唤醒，防止长任务因休眠断流（默认开，可关）
- 版本更新发现：自动检查（仅查询版本号，可关闭）与设置内手动检查；有新版时面板顶部横幅提示
- 桌面小组件：常驻桌面层的玻璃信息卡，支持拖动、缩放与位置记忆

## 安装

```bash
git clone https://github.com/Spacebody/AgentDeck.git && cd AgentDeck
./build.sh install
```

编译、安装至 `/Applications` 并启动，首次启动注册登录项实现自启。

**环境要求**：macOS 13+；已安装 [Claude Code](https://claude.com/claude-code) 或 [Codex](https://openai.com/codex)（任一）；Xcode Command Line Tools（提供 `swiftc`，可经 `xcode-select --install` 安装）。

其余构建目标：

```bash
./build.sh           # 仅构建 dist/AgentDeck.app
./build.sh dmg       # 产出可分发 DMG
./build.sh uninstall # 卸载（默认保留数据目录）
```

首次使用「跳转会话」时，系统将请求**自动化（Apple Events）**权限用于聚焦终端窗口。

## 可选配置：会话完成提醒

完成提醒依赖 Claude / Codex 的事件回调。AgentDeck 不修改任何外部配置文件，需手动接入（均为单行改动）：

**Claude Code** — 在 `~/.claude/settings.json` 的 `hooks.Stop` 中追加：

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

**Codex** — 在 `~/.codex/config.toml` 中将 `notify` 指向仓库内的包装脚本：

```toml
notify = ["/path/to/agentdeck/scripts/codex-notify.sh"]
```

若 `notify` 已被其他工具占用，可在脚本末尾以 `exec` 链式转发原命令（脚本内有说明）。

## 架构

```
agentdeckd.py        后端 daemon：采集 / 解析 / 聚合 / HTTP API（纯标准库）
app/main.swift       应用壳：菜单栏、面板、桌面小组件、完成提醒
static/index.html    面板界面：单文件，无构建步骤
site/                官网与更新清单（Cloudflare Pages，零依赖静态页）
build.sh             构建 / 安装 / DMG / 卸载
scripts/             图标与 DMG 背景生成、Codex notify 包装、CSRF 回归测试
```

应用壳启动时拉起 daemon（监听 `127.0.0.1:7777`）；面板与小组件为 WKWebView 加载同一份本地页面，经 HTTP API 取数。

## 数据来源与隐私

所有数据**仅在本机处理**，无遥测、无上报：

| 数据 | 来源 | 说明 |
|------|------|------|
| Claude 额度 | 钥匙串中 Claude Code 的 OAuth 凭据 → `api.anthropic.com/api/oauth/usage` | 以用户本人凭据查询本人额度 |
| 版本检查 | `agentdeck.yilin.dev/version.json`（静态清单，6 小时缓存） | 仅比对版本号，不携带凭据或本机信息；可在设置中关闭 |
| Claude 用量 / 会话 | 解析本地 `~/.claude/projects/**/*.jsonl` | token 统计、成本估算、会话列表 |
| Codex 额度 / 用量 / 会话 | 解析本地 `~/.codex/sessions` rollout 文件 | 同上 |
| 完成事件 | Claude Stop hook / Codex notify 回调（见可选配置） | 完成提醒与事件流 |

运行时产物：数据目录 `~/Library/Application Support/AgentDeck/`，日志 `~/Library/Logs/AgentDeck.log`。

## 安全设计

- daemon 仅绑定回环地址 `127.0.0.1`，不对局域网暴露
- 全部 POST 接口设有 CSRF 屏障：Content-Type 精确匹配、Origin 结构化校验、Host 白名单（防 DNS rebinding）；附回归测试 `scripts/test-csrf.sh`
- 「按请求参数读取文件」的路径统一收口至 `~/.claude` 目录内（realpath 校验）
- 健康检查带身份校验，避免端口被其他进程占用时误判

## 统计口径

- **Claude**：usage 记录按 `(message.id, requestId)` 去重；cache 写入按 ephemeral 5m / 1h 两档分别计价；单价表按模型版本前缀匹配
- **Codex**：采用 `total_token_usage.total_tokens`（cached 为 input 子集、reasoning 为 output 子集，避免重复累加）；订阅制下提供 API 等值参考
- 与 [ccusage](https://github.com/ryoppippi/ccusage) 交叉校准，偏差约 ±4%（差额来自 cache 分档精度）
- 面板内各 ⓘ 入口提供对应视图的逐项口径说明

## 致谢

- 菜单栏品牌字形取自 Claude / Codex 官方应用内置的菜单栏模板图，版权归 Anthropic / OpenAI 所有，仅作来源标识
- 会话跳转的终端聚焦思路最初借鉴 MioIsland（Ghostty 按 cwd 精确聚焦），现已演进为沿进程链自动识别任意终端宿主
- 用量统计以 [ccusage](https://github.com/ryoppippi/ccusage) 为独立基准交叉校准

## 更新日志

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
