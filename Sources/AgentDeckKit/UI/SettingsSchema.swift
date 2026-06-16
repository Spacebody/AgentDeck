// AgentDeck v2 — 设置 schema（镜像 index.html SET_SCHEMA，行 1857）。
// 标签暂用中文字面量（#3 接管三语）。值类型用 SettingValue 承载混合类型。
import Foundation

enum SettingValue: Equatable {
    case bool(Bool), int(Int), double(Double), string(String)
    var boolVal: Bool { if case .bool(let b) = self { return b }; return false }
    var intVal: Int {
        switch self { case .int(let i): return i; case .double(let d): return Int(d)
        case .string(let s): return Int(s) ?? 0; default: return 0 }
    }
    var stringVal: String { if case .string(let s) = self { return s }; return "" }
}

/// chips 数值格式（对应 SET_SCHEMA 各 fmt 闭包）。
enum ChipFmt { case percent, seconds, minutesFromSecs, plain, rotate
    func text(_ v: Int) -> String {
        switch self {
        case .percent: return "\(v)%"
        case .seconds: return "\(v)s"
        case .minutesFromSecs: return "\(v / 60) 分钟"
        case .plain: return "\(v)"
        case .rotate: return v == 0 ? "关闭" : "\(v)s"
        }
    }
}

enum SetRow {
    case section(String)
    case toggle(key: String, label: String, hint: String?)
    case chips(key: String, label: String, hint: String?, opts: [Int], fmt: ChipFmt, custom: ClosedRange<Int>?)
    case select(key: String, label: String, hint: String?, opts: [(String, String)])   // (值, 显示名)
    case multi(label: String, hint: String?, opts: [(String, String)])                  // (key, 名)
    case colors(label: String, hint: String?, opts: [(String, String, String)])         // (key, 名, 默认hex)
    case btns(label: String, hint: String?, btns: [(String, String)])                   // (act, 名)
}

enum SettingValueKind { case bool, int, string }

enum SettingsSchema {
    /// 键 → 值类型（解析 /api/settings 时按此映射，避开 JSON Bool/Int 歧义）。
    static var valueKinds: [String: SettingValueKind] {
        var m: [String: SettingValueKind] = [:]
        for r in rows {
            switch r {
            case let .toggle(key, _, _): m[key] = .bool
            case let .chips(key, _, _, _, _, _): m[key] = .int
            case let .select(key, _, _, _): m[key] = .string
            case let .multi(_, _, opts): for o in opts { m[o.0] = .bool }
            case let .colors(_, _, opts): for o in opts { m[o.0] = .string }
            default: break
            }
        }
        return m
    }

    static let rows: [SetRow] = [
        .section("面板"),
        .select(key: "language", label: "语言", hint: nil,
                opts: [("auto", "跟随系统"), ("zh-CN", "中文"), ("en", "English"), ("ja", "日本語")]),
        .chips(key: "font_scale", label: "字体大小", hint: "面板与小组件整体缩放",
               opts: [100, 110, 120, 135], fmt: .percent, custom: 80...160),
        .chips(key: "glass_dim", label: "面板暗化强度", hint: "越低越透明",
               opts: [40, 55, 68, 80], fmt: .percent, custom: 20...90),
        .colors(label: "主题配色", hint: "自定义 Claude / Codex 主色（额度环、进度条、用量图同步）",
                opts: [("color_claude", "Claude", "#ff9d7a"), ("color_codex", "Codex", "#4fd1c5")]),
        .toggle(key: "minimal_mode", label: "精简模式", hint: "降低视觉噪声，更耐看"),
        .toggle(key: "show_active", label: "活跃会话卡片", hint: nil),
        .multi(label: "展示 Agent", hint: "只用其中一个时，可隐藏不需要的板块与会话",
               opts: [("show_claude", "Claude"), ("show_codex", "Codex")]),
        .chips(key: "sessions_limit", label: "会话列表数量", hint: "每端各取 N 条",
               opts: [10, 15, 20, 30], fmt: .plain, custom: 5...100),
        .chips(key: "refresh_interval", label: "自动刷新间隔", hint: "面板自动刷新显示的间隔",
               opts: [15, 30, 60], fmt: .seconds, custom: 5...600),
        .chips(key: "sample_interval", label: "曲线采样间隔", hint: "额度历史曲线的记点间隔，与接口频率无关",
               opts: [60, 180, 300, 600], fmt: .minutesFromSecs, custom: 60...3600),
        .chips(key: "quota_interval", label: "额度查询间隔", hint: "调大可避免触发官方接口限流",
               opts: [300, 600, 1800, 3600], fmt: .minutesFromSecs, custom: 300...21600),
        .section("菜单栏"),
        .multi(label: "常显用量", hint: "可多选，全不选只留图标",
               opts: [("menubar_claude", "Claude"), ("menubar_codex", "Codex")]),
        .select(key: "menubar_value_dim", label: "百分比窗口", hint: "菜单栏数字取自该额度窗口",
                opts: [("shortest", "5 小时"), ("weekly", "周限额"), ("max", "用量最高")]),
        .toggle(key: "menubar_alert_color", label: "额度告警变色", hint: "对应段 ≥80% 变橙、≥95% 变红"),
        .select(key: "menubar_color_dim", label: "告警依据窗口", hint: "图标按该窗口用量变色",
                opts: [("shortest", "5 小时"), ("weekly", "周限额"), ("max", "用量最高")]),
        .chips(key: "menubar_rotate_secs", label: "多账号轮转", hint: "多个账号时菜单栏按间隔轮流显示各账号额度",
               opts: [0, 4, 6, 10], fmt: .rotate, custom: 0...60),
        .section("通知"),
        .toggle(key: "notify_enabled", label: "额度告警通知", hint: nil),
        .chips(key: "notify_warn", label: "一级提醒阈值", hint: "用量达此发出提醒",
               opts: [70, 80, 90], fmt: .percent, custom: 50...99),
        .chips(key: "notify_crit", label: "二级严重阈值", hint: "用量更高时发严重告警（带提示音）",
               opts: [90, 95, 98], fmt: .percent, custom: 60...100),
        .toggle(key: "notify_reset", label: "重置回满提醒", hint: nil),
        .toggle(key: "notify_session_done", label: "会话完成提醒", hint: "灵动岛弹出，点击跳会话"),
        .chips(key: "notify_done_min_secs", label: "短任务过滤", hint: "低于该时长不提醒",
               opts: [15, 30, 60, 120], fmt: .seconds, custom: 5...3600),
        .chips(key: "island_dwell_secs", label: "提醒停留时长", hint: nil,
               opts: [3, 5, 8, 10], fmt: .seconds, custom: 2...30),
        .toggle(key: "notify_sound", label: "提示音", hint: nil),
        .section("会话恢复"),
        .select(key: "terminal", label: "恢复方式", hint: "仅列已安装终端",
                opts: [("auto", "自动（按优先级）"), ("copy", "仅复制命令")]),
        .toggle(key: "auto_paste_resume", label: "唤起后自动粘贴",
                hint: "对 Warp / VS Code / Cursor 等无 CLI 注入的终端，唤起后模拟 ⌘V + 回车直达会话；首次会弹「辅助功能」系统授权"),
        .section("系统"),
        .toggle(key: "keep_awake", label: "保持唤醒", hint: "有活跃会话时阻止系统休眠，避免会话断网中断"),
        .toggle(key: "update_check", label: "自动检查更新", hint: "仅向项目主页查询版本号，不发送任何数据"),
        .btns(label: "手动检查", hint: "立即查询一次最新版本", btns: [("check_update", "立即检查")]),
        .section("数据"),
        .btns(label: "数据管理", hint: "数据仅存本机",
              btns: [("open", "打开数据目录"), ("export", "导出用量 CSV"), ("clear_events", "清空完成记录")]),
        .section("反馈"),
        .btns(label: "问题反馈", hint: "版本号自动预填，不含任何账号 / 路径信息",
              btns: [("feedback_github", "GitHub Issue"), ("feedback_email", "邮件反馈")]),
    ]
}
