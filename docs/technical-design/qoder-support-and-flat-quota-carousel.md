# AgentDeck 2.7.0：Qoder 支持与拍平额度轮播技术方案

状态：已实现并完成本地验证  
目标版本：2.7.0  
交付方式：本机构建并安装，不提交、不推送

## 1. 背景与目标

AgentDeck 当前以 Claude 和 Codex 为固定对象，额度概览按 Agent 分栏，并在单个 Agent 内通过账号下拉或子轮播切换。该结构不能自然扩展到更多 Agent，也会在“多个 Agent × 多个账号”时形成两层导航。

本次改造包含两个目标：

1. 增加 Qoder 的会话、运行态、恢复入口和额度展示支持。
2. 将概览额度改造成单层自动轮播：无论是同类 Agent 的多个账号，还是不同 Agent 的账号，全部拍平成同级页面。

## 2. 设计原则

- 页面唯一单位为 `agentId::accountId`，不再存在 Agent 内账号下拉或二级轮播。
- 后端优先返回通用 Agent 数据，同时保留 Claude/Codex 旧字段，降低升级风险。
- Agent 不支持额度、未登录或采集失败时仍保留明确状态页，不静默消失。
- 不引入常驻第三方运行时依赖；Qoder 数据由本机 `qodercli` 和本地会话文件提供。
- 主面板概览和状态栏使用彼此独立的轮播设置；桌面小组件不自动轮播。

## 3. 用户体验方案

### 3.1 页面拍平

后端按已启用 Agent 顺序返回账号，前端生成：

```text
Claude / 默认账号
Claude / 工作账号
Codex / 默认账号
Qoder / 默认账号
```

排序规则：

1. Agent 按设置中的启用顺序排列；本版本内置顺序为 Claude、Codex、Qoder。
2. 同一 Agent 内默认账号优先，其余账号保持后端稳定顺序。
3. 页面 ID 使用 `agentId::accountId`。刷新后若当前页面仍存在，则保持当前页面；否则回退到首项。

### 3.2 轮播交互

- 只有一个页面时不启动定时器，也不显示冗余控制。
- 多个页面时默认每 6 秒自动切换；设置中可关闭，间隔可选 4、6、8、10 秒。
- 支持左右按钮、触控板横向拖动、键盘左右方向键和页码指示。
- 手动切页后重新开始当前轮播周期，避免立即再次跳页。
- 鼠标悬停、拖动中或用户点击暂停时停止自动切换；离开或恢复播放后重新计时。
- 面板不可见、切到非概览页、打开设置时停止计时。
- 开启“减少动态效果”时使用淡入淡出，不做横向位移动画。
- 页面超过 6 个时使用 `当前页 / 总页数`，不绘制一长串圆点。
- 告警只更新对应页面状态，不强制抢占当前页面。
- 轮播容器使用稳定高度，避免下方最近会话随页面内容上下跳动。

### 3.3 单页内容

单页占满原额度区域，展示：

- Agent 标识和账号名称；
- 一个或多个额度窗口；
- 额度更新时间、陈旧状态；
- 未登录、不支持、采集失败等明确空态。

Qoder 首期将 `UsageInfo` 映射为综合、套餐、加油包和组织资源包等可用额度窗口；不存在的窗口不渲染。

## 4. 后端方案

### 4.1 通用 Agent 注册表

本次先引入轻量注册表 `AGENT_IDS = ("claude", "codex", "qoder")`，统一会话校验、筛选、游标、收藏和 API 枚举；额度采集、配置发现、会话解析与恢复仍由各 Agent 的独立函数承担。这样可以在不一次性重写 Claude/Codex 稳定链路的前提下建立通用数据契约，后续新增 Agent 时再逐步收敛为完整适配器对象。

### 4.2 Qoder 本地数据

- CLI：优先使用 `PATH` 中的 `qodercli`，并兼容 `~/.local/bin/qodercli`。
- 配置目录：默认读取 `QODER_CONFIG_DIR` 或 `~/.qoder`，同时支持设置中的额外目录。
- 会话：扫描 `<config>/projects/**/*.jsonl`，排除 `subagents`、日志和其他非主会话文件。
- 恢复：使用 `qodercli --resume <sessionId>`，多账号时通过 `QODER_CONFIG_DIR` 绑定对应配置目录。
- 活跃状态：识别 `qodercli` 及其会话工作目录，复用现有进程采样与防抖逻辑。

### 4.3 Qoder 额度采集

Qoder CLI SDK 暴露 `getUsageInfo()` 语义。本实现通过已安装 `qodercli` 的流式控制协议请求 `get_usage_info`，只解析对应响应，不记录初始化响应中的账号和模型信息。

采集约束：

- 使用 `--no-session-persistence`，不得生成额度探测会话。
- 禁用工具并设置超时，失败后终止子进程。
- 只保留额度数值、到期时间和套餐类型，不回传用户 ID、邮箱、头像或升级链接。
- 采用短期缓存，避免概览轮询频繁拉起 CLI。
- CLI 不存在、版本不兼容、未登录或超时时返回稳定错误状态，并由前端显示状态页。

### 4.4 API 兼容

`GET /api/quota` 新增通用结构：

```json
{
  "agents": [
    {
      "id": "qoder",
      "name": "Qoder",
      "hidden": false,
      "accounts": [
        {"account_id": "default", "ok": false, "no_quota": true}
      ]
    }
  ],
  "accounts": {
    "claude": [],
    "codex": [],
    "qoder": []
  }
}
```

兼容期继续返回顶层 `claude`、`codex` 和既有 `accounts` 字段。Swift 客户端优先消费 `agents`，缺失时从旧字段回退。

额度窗口补充可选字段 `used`、`total`、`remaining`、`unit`、`bucket_kind`；旧客户端可忽略，当前客户端以 `used_percent` 为主展示并保留这些字段供后续额度语义扩展。

## 5. 客户端方案

### 5.1 品牌与设置

- `Brand` 增加 `qoder`，提供独立颜色和系统图标降级。
- 界面设置增加 Qoder 显示和菜单栏显示；后端设置契约增加 `qoder_dirs`，与现有多账号目录发现机制一致。
- 设置增加“自动轮播”和“轮播间隔”。非法间隔由后端归一为 6 秒。
- 会话筛选、运行态岛、恢复按钮和菜单栏状态项加入 Qoder。

### 5.2 拍平轮播组件

新增 `FlatQuotaCarousel`：

1. 把 `agents[].accounts[]` 映射为 `[QuotaPage]`。
2. `QuotaPage.id = agentId + "::" + accountId`。
3. 组件只维护一个 `selection`，不维护 Agent 选择和账号选择两套状态。
4. 定时器由页面数量、面板可见性、当前导航、悬停、拖动、播放状态和系统动态效果设置共同控制。
5. 数据刷新时按稳定 ID 对齐当前页，并夹紧索引。

### 5.3 菜单栏与小组件

- 菜单栏状态项按 Claude、Codex、Qoder 顺序创建，沿用各 Agent 的严重等级颜色。
- 2.7.1 起状态栏固定为单槽位，整组滚动 `Agent/账号图标 + 对应额度`；关闭轮播时固定当前页，不再横向平铺。
- 小组件保持静态，不自动轮播；空间允许时展示排序最靠前的两个同级额度页及精简告警摘要。

## 6. 验证方案

### 6.1 后端测试

- Qoder 配置目录、会话发现、主会话排除规则。
- Qoder 会话解析与恢复命令。
- Qoder UsageInfo 到额度窗口的映射。
- CLI 缺失、未登录、超时、畸形响应和缓存行为。
- `/api/quota` 新旧结构兼容、多 Agent 顺序与隐藏状态。

### 6.2 Swift 测试

- 新旧额度 JSON 均可解码。
- 多 Agent、多账号拍平顺序和稳定 ID。
- 当前页面在刷新后的保持与回退。
- 自动轮播开关、间隔归一、暂停和单页不轮播。
- Qoder 会话筛选、品牌颜色和设置项。

### 6.3 手工验收

1. 仅一个账号：无轮播控制，无自动切换。
2. 同 Agent 多账号：单层轮播，不出现账号下拉。
3. 多 Agent 多账号：全部同级，顺序稳定。
4. 悬停、拖动、手动切页、暂停/播放、键盘操作符合规则。
5. Qoder 未安装、未登录、额度不可用时显示明确状态。
6. Qoder 会话可见、活跃状态可识别、恢复命令能启动。
7. 版本显示为 2.7.0；本机安装后 GUI 与 `agentdeckd.py` 均来自新包。

## 7. 风险与降级

- Qoder 本地 JSONL 和 CLI 控制协议可能随版本变化：解析器采用宽松字段识别，额度能力失败时降级为状态页，不影响 Claude/Codex。
- 额度 CLI 首次启动可能较慢：通过缓存、超时和后台刷新避免阻塞主 API。
- 页面内容高度不同：用测量后的最大高度或固定最小高度抑制布局跳动。
- 旧 daemon 与新客户端短暂混用：客户端保留旧额度结构回退，后端保留旧字段。

## 8. 交付边界

- 本次交付包含方案文件、代码、测试、版本号 2.7.0 和本机安装验证。
- 不提交 Git commit，不推送远端，不发布更新清单。
- 不采集或展示 Qoder 消息正文、用户 ID、邮箱、头像等隐私数据。

## 9. 参考资料

- [Qoder SDK References：UsageInfo / getUsageInfo](https://docs.qoder.com/en/cli/sdk/references)
- [Qoder Hooks：配置位置、Stop 事件与 Transcript 格式](https://docs.qoder.com/extensions/hooks)

## 10. 落地验证记录

- Swift 测试：32 项通过。
- Python 后端测试：117 项通过。
- 静态 fallback 内联脚本完成语法解析，Python 后端完成字节码编译检查。
- Release 包版本与构建号均为 2.7.0，主程序为 `arm64 + x86_64` 通用二进制，代码签名校验通过。
- 安装后的 GUI 与 daemon 均来自 `/Applications/AgentDeck.app`；daemon 健康接口报告 2.7.0。
- 安装环境中 Qoder 额度、会话索引与单条 AgentDeck Stop hook 均验证可用，既有用户 Stop hook 未被覆盖。
- Git 工作区保留未提交改动，未修改公开更新清单。

## 11. 2.7.1 状态栏单槽位补充

- 状态栏页面与概览一致使用 `agentId::accountId` 稳定身份，额度刷新后优先保持当前页。
- 图标、简短账号标识与额度百分比合成为一张状态栏图，作为整体竖向滚动。
- 所有页面按最宽单项生成固定视口，因此占用宽度从“所有 Agent 相加”降为“最宽单项”，且切换时不会挤动相邻图标。
- 默认间隔为 6 秒，设置为关闭时固定当前页面；减少动态效果开启时不执行位移动画。

## 12. 2.7.2 轮播焦点外观修复

- 多 Agent 轮播原先直接对整组 `VStack` 使用 `.focusable()`，获得焦点后 macOS 会持续绘制包围整张额度卡的蓝色 Focus Ring。
- macOS 14+ 使用 `.focusEffectDisabled()` 只关闭系统焦点外观，继续保留左右方向键翻页。
- macOS 13 没有对应公开 API，外层轮播容器不参与键盘焦点；鼠标、触控板、按钮与自动轮播保持不变。

## 13. 2.7.3 Qoder 概览用量统计

- 后端扫描已发现 Qoder 配置目录下的 `projects/**/*.jsonl`，复用 Claude-compatible assistant usage 结构，按 `(message.id, requestId)` 去重并按小时、本地自然日、项目目录聚合。
- `/api/usage` 新增 `qoder_daily`，小时桶新增 `q`，项目项新增 `agents` token 分项；这些字段均向后兼容，旧 daemon 缺字段时客户端按 0 处理。
- 原生 SwiftUI 与 Web fallback 的今日摘要、24 小时曲线、近 7 天堆叠柱和项目 Top 均展示 Qoder，并遵循 `show_qoder` 可见性设置。
- Qoder 没有稳定的公开模型计价接口，本版本只展示真实 token，不推断或计入 API 等值金额。
- 独立 `qoder_usage_cache.json` 只持久化小时聚合、去重摘要和文件指纹，不保存消息正文、账号身份或本机运行样本；测试数据使用合成路径与保留测试域名。
- 回归验证：Swift 39 项、Python 后端 118 项全部通过，静态 fallback 内联脚本通过语法解析。

## 14. 2.7.4 正在运行列表按最后活跃排序

- `/api/active` 为每条运行中会话计算 `last_active_at`，最终按该字段倒序排列；时间相同时再按 Agent 与 PID 排序，避免刷新时随机跳动。
- Claude 以 session transcript mtime 为准；Codex 以进程实际打开的 rollout mtime 为准，并保留同工程 rollout 回退；Codex Desktop 直接使用被识别 rollout 的 mtime。
- Qoder 优先从进程打开的、且位于已发现配置目录内的主 transcript 获取会话身份与 mtime；取不到时查询本地 SQLite 会话索引，不读取消息正文。
- 所有 Agent 在缺少可观测 transcript/rollout 时间时，以进程启动时间作为最后兜底。原生 SwiftUI 与 Web fallback 只过滤可见 Agent，均不做二次排序。
- 回归验证：Python 后端 120 项通过；Swift 代码未改变行为，完整 39 项继续执行。

## 15. 2.7.5 可扩展 Agent 设置管理

- 主设置页移除按属性横向平铺的“主题配色”“展示 Agent”和状态栏 Agent 多选，合并为一个“Agent 管理”入口；入口只显示已启用数量、最多三个主题色圆点和进入箭头。
- Agent 管理页把 Claude、Codex、Qoder 拍平成同级纵向列表。每行同时提供面板显示、状态栏参与和主题色控件，颜色归属不再依赖色块顺序；支持单 Agent 恢复默认色与全部恢复默认色。
- 原生端新增 `AgentSettingsCatalog`，统一描述 Agent 标识、品牌、`show_*`、`menubar_*`、`color_*` 与默认颜色；设置 schema、AppStore 配色应用和管理页均由注册表派生。Web fallback 使用等价的单一 `AGENT_SETTINGS` 注册表生成入口、详情页和颜色应用逻辑。
- 继续使用既有设置键和值类型，后端 API 与持久化文件无需迁移；面板显示和状态栏参与保持相互独立，允许用户全部关闭。
- 设置页返回按钮在 Agent 管理页先返回设置首页，再次返回才关闭设置；Web fallback 同步支持 `?settings=agents` 直达调试。
- 回归验证：Swift 39 项 XCTest 与 3 项 Swift Testing、Python 后端 120 项全部通过；静态 fallback 内联脚本通过语法解析，并生成 Agent 管理页无头预览检查布局。
