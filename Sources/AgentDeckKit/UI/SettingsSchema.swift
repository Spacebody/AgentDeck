// AgentDeck v2 — 设置 schema（镜像 index.html SET_SCHEMA，行 1857）。
// label/hint/section/option-name 一律存 i18n 键；渲染期 L() 解析（L() 对非键原样返回，
// 故 "Claude"/"中文" 等字面量也能直接过）。值类型用 SettingValue 承载混合类型。
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
        case .minutesFromSecs: return L("set.minUnit", ["n": "\(v / 60)"])
        case .plain: return "\(v)"
        case .rotate: return v == 0 ? L("set.rotateOff") : "\(v)s"
        }
    }
}

enum SetRow {
    case section(String)
    case toggle(key: String, label: String, hint: String?)
    case chips(key: String, label: String, hint: String?, opts: [Int], fmt: ChipFmt, custom: ClosedRange<Int>?)
    case select(key: String, label: String, hint: String?, opts: [(String, String)])   // (值, 显示名/键)
    case multi(label: String, hint: String?, opts: [(String, String)])                  // (key, 名/键)
    case colors(label: String, hint: String?, opts: [(String, String, String)])         // (key, 名, 默认hex)
    case agentManager(label: String, hint: String?)
    case btns(label: String, hint: String?, btns: [(String, String)])                   // (act, 名/键)
}

enum SettingValueKind { case bool, int, string }

enum SettingsSchema {
    /// 键 → 值类型（解析 /api/settings 时按此映射，避开 JSON Bool/Int 歧义）。
    static var valueKinds: [String: SettingValueKind] {
        var m: [String: SettingValueKind] = [:]
        for agent in AgentSettingsCatalog.all {
            m[agent.showKey] = .bool
            m[agent.menubarKey] = .bool
            m[agent.colorKey] = .string
        }
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
        .section("set.secPanel"),
        .select(key: "language", label: "set.language", hint: nil,
                opts: [("auto", "set.langAuto"), ("zh-CN", "中文"), ("en", "English"), ("ja", "日本語")]),
        .chips(key: "font_scale", label: "set.fontScale", hint: "set.fontScaleHint",
               opts: [100, 110, 120, 135], fmt: .percent, custom: 80...160),
        .chips(key: "glass_dim", label: "set.glassDim", hint: "set.glassDimHint",
               opts: [40, 55, 68, 80], fmt: .percent, custom: 20...90),
        .toggle(key: "minimal_mode", label: "set.minimal", hint: "set.minimalHint"),
        .toggle(key: "show_active", label: "set.showActive", hint: nil),
        .agentManager(label: "set.agentManager", hint: "set.agentManagerHint"),
        .chips(key: "sessions_limit", label: "set.sessionsLimit", hint: "set.sessionsLimitHint",
               opts: [10, 15, 20, 30], fmt: .plain, custom: 5...100),
        .chips(key: "refresh_interval", label: "set.refreshInterval", hint: "set.refreshIntervalHint",
               opts: [15, 30, 60], fmt: .seconds, custom: 5...600),
        .chips(key: "sample_interval", label: "set.sampleInterval", hint: "set.sampleIntervalHint",
               opts: [60, 180, 300, 600], fmt: .minutesFromSecs, custom: 60...3600),
        .chips(key: "quota_interval", label: "set.quotaInterval", hint: "set.quotaIntervalHint",
               opts: [300, 600, 1800, 3600], fmt: .minutesFromSecs, custom: 300...21600),
        .toggle(key: "quota_auto_rotate", label: "set.quotaAutoRotate", hint: "set.quotaAutoRotateHint"),
        .chips(key: "quota_rotate_secs", label: "set.quotaRotateSecs", hint: "set.quotaRotateSecsHint",
               opts: [4, 6, 8, 10], fmt: .seconds, custom: 4...10),
        .section("set.secMenubar"),
        .select(key: "menubar_value_dim", label: "set.mbValueDim", hint: "set.mbValueDimHint",
                opts: [("shortest", "set.dimShortest"), ("weekly", "set.dimWeekly"), ("max", "set.dimMax")]),
        .toggle(key: "menubar_alert_color", label: "set.menubarAlert", hint: "set.menubarAlertHint"),
        .select(key: "menubar_color_dim", label: "set.mbColorDim", hint: "set.mbColorDimHint",
                opts: [("shortest", "set.dimShortest"), ("weekly", "set.dimWeekly"), ("max", "set.dimMax")]),
        .chips(key: "menubar_rotate_secs", label: "set.menubarRotate", hint: "set.menubarRotateHint",
               opts: [0, 4, 6, 10], fmt: .rotate, custom: 0...60),
        .section("set.secNotify"),
        .toggle(key: "notify_enabled", label: "set.notifyEnabled", hint: nil),
        .chips(key: "notify_warn", label: "set.notifyWarn", hint: "set.notifyWarnHint",
               opts: [70, 80, 90], fmt: .percent, custom: 50...99),
        .chips(key: "notify_crit", label: "set.notifyCrit", hint: "set.notifyCritHint",
               opts: [90, 95, 98], fmt: .percent, custom: 60...100),
        .toggle(key: "notify_reset", label: "set.notifyReset", hint: nil),
        .toggle(key: "notify_session_done", label: "set.sessionDone", hint: "set.sessionDoneHint"),
        .chips(key: "notify_done_min_secs", label: "set.shortFilter", hint: "set.shortFilterHint",
               opts: [15, 30, 60, 120], fmt: .seconds, custom: 5...3600),
        .chips(key: "island_dwell_secs", label: "set.dwell", hint: nil,
               opts: [3, 5, 8, 10], fmt: .seconds, custom: 2...30),
        .toggle(key: "notify_sound", label: "set.sound", hint: nil),
        .section("set.secResume"),
        .select(key: "terminal", label: "set.resumeMethod", hint: "set.resumeMethodHint",
                opts: [("auto", "set.termAuto"), ("copy", "set.termCopy")]),
        .toggle(key: "auto_paste_resume", label: "set.autoPasteResume", hint: "set.autoPasteResumeHint"),
        .section("set.secSystem"),
        .toggle(key: "keep_awake", label: "set.keepAwake", hint: "set.keepAwakeHint"),
        .toggle(key: "update_check", label: "set.updateCheck", hint: "set.updateCheckHint"),
        .btns(label: "set.checkNow", hint: "set.checkNowHint", btns: [("check_update", "set.checkNowBtn")]),
        .section("set.secData"),
        .btns(label: "set.dataManage", hint: "set.dataManageHint",
              btns: [("open", "set.openData"), ("export", "set.exportCsv"), ("clear_events", "set.clearEvents")]),
        .section("set.secFeedback"),
        .btns(label: "set.feedback", hint: "set.feedbackHint",
              btns: [("feedback_github", "set.feedbackGithub"), ("feedback_email", "set.feedbackEmail")]),
    ]
}
