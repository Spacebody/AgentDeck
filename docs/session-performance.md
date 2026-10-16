# 会话输出速度

当前实现展示输出 token 的**轮次平均吞吐量**，不将日志分批写入误称为逐 token 实时生成速度。

## 数据口径

- Codex：优先使用 `token_usage_record.turn_token_usage.output_tokens`；旧格式使用有基线的 `total_token_usage.output_tokens` 增量。两种来源不相加。完整轮次优先使用 `task_complete.duration_ms`。
- Claude / Qoder CLI：用户消息确定轮次开始，assistant usage 按消息 ID 去重，`system/turn_duration` 确认轮次结束。工具结果、侧链和元消息不作为新用户轮次。
- Qoder App：当前元数据接口没有可靠的输出 token 与计时信息，显示不可用，不按字数估算。
- 输出分量沿用来源定义，推理 token 不额外叠加。耗时包含思考、工具执行、等待，因此不能用于比较纯模型解码性能。
- 进行中显示本轮平均值；15 秒没有新样本后隐藏数字，显示暂无新样本。完成后保留最近轮均。缺少起点、计数基线、损坏或超长日志时宁可不显示数字。

## 实现

`session_performance.py` 是独立、有界增量采集器，`agentdeckd.py` 只提供已索引路径与轻量接口 `/api/session-performance`。接口不接受客户端文件路径；账号不明确且匹配多个会话时拒绝猜测归属。

后台每 5 秒发现近期变动会话；单工作线程每轮最多处理 32 个文件，每文件最多读取 512 KiB，单行上限 256 KiB。首次从有界文件尾开始，不扫描多年历史；没有可靠边界的旧轮次不会伪造指标。后续按 inode、文件偏移增量读取，截断或替换时重新建立基线。

独立 SQLite `session_performance.sqlite3` 保存数值解析状态和每会话最近 32 个完整轮次，不保存消息正文。最多保留 10,000 个会话，清理 30 天未访问状态；运行时缓存最多 512 条。不会修改会话索引 revision 或分页游标。

Swift `SessionPerformanceStore` 独立发布指标，面板或小组件可见时每秒获取一次，按 32 个会话分批；没有可见窗口时取消请求。列表仅请求当前页，概览只请求活跃会话。数字使用等宽字符，不加刷新动画。

## 验证

`tests/test_session_performance.py` 覆盖计数去重、重置、取消、缺少基线、持久化恢复、日志截断/半行/超长行、历史重放、侧链隔离及接口边界。Swift 测试覆盖指标口径、身份键、三语标签和可见性生命周期。

`swift run PreviewGen sessionspeed /tmp/agentdeck-session-speed.png` 可渲染窄/宽界面；`AD_LOCALE=en` / `ja` 切换语言。无头 ImageRenderer 不支持原生搜索框与菜单控件，最终安装验证仍需在应用里确认这些控件。
