# AgentDeck

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![Dependencies](https://img.shields.io/badge/dependencies-none-brightgreen)

macOS 菜单栏应用，为 **Claude Code** 与 **Codex** 提供统一的额度监控、会话管理与用量分析。液态玻璃视觉风格，对标系统原生小组件的观感标准。

整个项目零第三方依赖：后端为纯标准库 Python daemon，应用壳为单文件 Swift（`swiftc` 直接编译），界面为单文件 HTML——无包管理器、无构建链、无运行时下载。

## 功能特性

**额度监控**
- Claude 官方额度（5 小时 / 7 天窗口）与 Codex rate limits 实时聚合
- 菜单栏常显用量百分比，支持单个 / 多个 / 隐藏的展示配置
- 窗口重置时间进度条；额度临界 / 回满的系统通知告警（阈值可配置）

**会话管理**
- 识别双端活跃会话，包括终端内运行的 CLI 会话与 Codex 桌面端会话
- 点击活跃会话直接聚焦其所在终端标签页（tty 级精确匹配），Codex 桌面端会话经 `codex://` 深链直达对应线程
- 会话完成弹窗提醒（灵动岛风格），点击跳转回会话；事件去重，仅提醒一次
- 历史会话一键在终端中恢复，支持 iTerm2、Terminal、Ghostty、kitty、WezTerm、Alacritty

**用量分析**
- 近 7 / 30 天 token 用量与成本估算，统计口径经独立工具交叉校准（详见下文）
- 今日摘要、24 小时环比曲线、模型分布、项目维度 Top 榜
- 数据可导出 CSV

**桌面小组件**
- 常驻桌面层的玻璃信息卡，支持拖动、缩放与位置记忆

## 系统要求

- macOS 13 及以上
- 本机已安装 [Claude Code](https://claude.com/claude-code) 或 [Codex](https://openai.com/codex)（任一即可）
- Xcode Command Line Tools（编译需要 `swiftc`）

## 安装

```bash
git clone <repo-url> && cd agentdeck
./build.sh install
```

该命令完成编译、安装至 `/Applications` 并启动，首次启动自动注册系统登录项实现开机自启。

其余构建目标：

```bash
./build.sh           # 仅构建 dist/AgentDeck.app
./build.sh dmg       # 产出可分发 DMG（含拖装窗口布局）
./build.sh uninstall # 卸载应用（数据目录默认保留）
```

首次使用「跳转会话」功能时，系统会请求**自动化（Apple Events）**权限，用于聚焦目标终端窗口，请予以允许。

## 可选配置：会话完成提醒

完成提醒依赖 Claude / Codex 的事件回调。AgentDeck 不会自动修改你的配置文件，需手动接线（均为单行改动）：

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

**Codex** — 在 `~/.codex/config.toml` 中将 notify 指向仓库内的包装脚本：

```toml
notify = ["/path/to/agentdeck/scripts/codex-notify.sh"]
```

若原 notify 已被其他工具占用，可在脚本末尾以 `exec` 链式转发原命令（脚本内有说明）。

## 架构

```
agentdeckd.py        后端 daemon：数据采集 / 解析 / 聚合 / HTTP API（纯标准库）
app/main.swift       应用壳：菜单栏、玻璃面板、桌面小组件、完成提醒弹窗
static/index.html    面板界面：单文件，无构建步骤
build.sh             构建 / 安装 / DMG 打包 / 卸载
scripts/             图标与 DMG 背景生成、Codex notify 包装、CSRF 回归测试
```

应用壳启动时拉起后端 daemon（监听 `127.0.0.1:7777`），面板与小组件均为 WKWebView 加载同一份本地页面，数据经 HTTP API 交互。

## 数据来源与隐私

所有数据**仅在本机处理**，不含任何遥测或数据上报：

| 数据 | 来源 | 说明 |
|------|------|------|
| Claude 额度 | 钥匙串中 Claude Code 的 OAuth 凭据 → `api.anthropic.com/api/oauth/usage` | 全应用唯一一条出站请求，使用用户本人凭据查询本人额度 |
| Claude 用量 / 会话 | 解析本地 `~/.claude/projects/**/*.jsonl` | token 统计、成本估算、会话列表 |
| Codex 额度 / 用量 / 会话 | 解析本地 `~/.codex/sessions` rollout 文件 | 同上 |
| 完成事件 | Claude Stop hook / Codex notify 回调（见可选配置） | 完成提醒与事件流 |

运行时产物：数据目录 `~/Library/Application Support/AgentDeck/`，日志 `~/Library/Logs/AgentDeck.log`。

## 安全设计

- daemon 仅绑定回环地址 `127.0.0.1`，不对局域网暴露
- 全部 POST 接口设有 CSRF 屏障：Content-Type 精确匹配 + Origin 结构化校验 + Host 白名单（防 DNS rebinding），随仓库附带回归测试 `scripts/test-csrf.sh`
- 涉及「按请求参数读取文件」的路径统一收口至 `~/.claude` 目录内（realpath 校验）
- 健康检查带身份校验，避免端口被其他进程占用时误判

## 成本估算口径

- **Claude**：usage 记录按 `(message.id, requestId)` 去重；cache 写入区分 ephemeral 5m / 1h 两档分别计价；单价表按模型版本前缀匹配
- **Codex**：采用 `total_token_usage.total_tokens`（cached 为 input 子集、reasoning 为 output 子集，避免重复累加）；订阅制下给出 API 等值参考价
- 整体口径与 [ccusage](https://github.com/ryoppippi/ccusage) 交叉校准，偏差约 ±4%（差额来自 cache 分档精度）
- 面板中各 ⓘ 入口提供对应视图的逐项口径说明

## 致谢

- 菜单栏品牌字形取自 Claude / Codex 官方应用内置的菜单栏模板图，版权归 Anthropic / OpenAI 所有，仅作来源标识用途
- Ghostty 按工作目录精确聚焦的实现思路参考了 MioIsland
- 用量统计以 [ccusage](https://github.com/ryoppippi/ccusage) 为独立基准交叉校准

## 更新日志

见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

[MIT](LICENSE)
