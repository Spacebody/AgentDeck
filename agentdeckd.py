#!/usr/bin/env python3
"""AgentDeck daemon — Claude Code / Codex 额度与会话监控后端（纯标准库，零依赖）。

API:
  GET  /api/health    存活探测
  GET  /api/quota     Claude 官方额度(OAuth) + Codex rate_limits(本地解析)
  GET  /api/sessions  双端最近会话合并列表
  GET  /api/usage     近 7/30 天 token 用量 + 成本估算
  POST /api/resume    在终端中恢复指定会话
"""

import base64
import binascii
import concurrent.futures
import hashlib
import json
import os
import plistlib
import re
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import urllib.parse
import uuid
from collections import deque
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path.home()
CLAUDE_PROJECTS = HOME / ".claude" / "projects"
CODEX_SESSIONS = HOME / ".codex" / "sessions"
CLAUDE_PIDFILES = HOME / ".claude" / "sessions"
STATIC_DIR = Path(__file__).resolve().parent / "static"
# 数据统一放标准位置（App Support），老版本 repo 内 data/ 自动迁移一次
DATA_DIR = HOME / "Library" / "Application Support" / "AgentDeck"
_LEGACY_DATA = Path(__file__).resolve().parent / "data"
if not DATA_DIR.exists() and _LEGACY_DATA.is_dir():
    import shutil
    shutil.copytree(_LEGACY_DATA, DATA_DIR)
DATA_DIR.mkdir(parents=True, exist_ok=True)
HISTORY_FILE = DATA_DIR / "quota_history.jsonl"
PINS_FILE = DATA_DIR / "pins.json"
PATH_MAPPINGS_FILE = DATA_DIR / "path_mappings.json"
SESSION_INDEX_FILE = DATA_DIR / "session_index.sqlite3"
CODEX_USAGE_CACHE_FILE = DATA_DIR / "codex_usage_cache.json"
CLAUDE_USAGE_CACHE_FILE = DATA_DIR / "claude_usage_cache.json"
PORT = 7777
try:
    VERSION = (Path(__file__).resolve().parent / "VERSION").read_text().strip()
except OSError:
    VERSION = "dev"
SAMPLE_INTERVAL = 180          # 额度采样周期（秒）
HISTORY_KEEP = 7 * 86400       # 历史保留 7 天
# Claude 官方 usage 端点限流偏严：缓存 5 分钟（额度窗口是 5h/7d，无需更勤）。
# 多账号时每账号各拉一次，本 TTL 直接决定每个账号的真实外部调用频率。
CLAUDE_QUOTA_TTL = 300
CODEX_QUOTA_TTL = 30           # Codex 是本地 jsonl 解析，无外部限流，可勤

# 更新检测：向自托管的 Cloudflare Pages 清单查最新版本号（不带任何凭据；可在设置中关闭）。
# 部署后把域名改成你的 Pages 项目地址即可。
UPDATE_MANIFEST_URL = "https://agentdeck.yilin.dev/version.json"
# GitHub Releases 基址：清单未显式给 dmg 直链时，按固定命名（tag=v{ver}、资产=AgentDeck-{ver}.dmg，
# 由 build.sh 强制）从版本号推导最新 DMG 直链，发版无需额外维护字段。
GITHUB_RELEASES = "https://github.com/Spacebody/AgentDeck/releases"
_UPDATE_VERSION_RE = r"[0-9]+[.][0-9]+[.][0-9]+(?:[-+][A-Za-z0-9.-]+)?"
_MAX_UPDATE_DMG_BYTES = 1_500_000_000

# 模型单价 (USD / MTok): (input, output, cache_read, cache_write)
MODEL_PRICES = {   # $/Mtok: input, output, cache_read, cache_write_5m, cache_write_1h
    # Opus 4.5 起官方降价 3 倍；按版本前缀优先匹配（dict 有序）
    "opus-4-5": (5.0, 25.0, 0.50, 6.25, 10.0),
    "opus-4-6": (5.0, 25.0, 0.50, 6.25, 10.0),
    "opus-4-7": (5.0, 25.0, 0.50, 6.25, 10.0),
    "opus-4-8": (5.0, 25.0, 0.50, 6.25, 10.0),
    "opus": (15.0, 75.0, 1.50, 18.75, 30.0),   # 4.1 及更早
    "sonnet": (3.0, 15.0, 0.30, 3.75, 6.0),
    "haiku": (1.0, 5.0, 0.10, 1.25, 2.0),
}

CODEX_PRICES = {   # $/Mtok: input, output, cached_input（缓存读 -90%）
    "gpt-5.5": (5.0, 30.0, 0.50),
    "gpt-5": (1.25, 10.0, 0.125),
}


def _atomic_write_text(path, text, mode=None):
    """Write text without exposing a truncated destination to concurrent readers."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if mode is None:
        try:
            mode = path.stat().st_mode & 0o777
        except OSError:
            mode = 0o600
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_name, mode)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def _codex_price(model):
    for key, p in CODEX_PRICES.items():
        if model.startswith(key):
            return p
    return CODEX_PRICES["gpt-5.5"]   # 未知模型按当前默认模型计

# ----------------------------------------------------------------- 设置

SETTINGS_FILE = DATA_DIR / "settings.json"
DEFAULT_SETTINGS = {
    "notify_enabled": True,    # 额度告警通知
    "notify_session_done": True,    # 会话完成灵动岛提醒
    "notify_done_min_secs": 30,     # 任务时长阈值（短对话不提醒）
    "island_dwell_secs": 5,         # 灵动岛停留时长
    "glass_dim": 68,                # 面板暗化强度 %（越低越透明）
    "minimal_mode": False,          # 精简模式：去弥散光斑/噪点/镜面线，日用耐看
    "notify_warn": 80,         # 提醒阈值 %
    "notify_crit": 95,         # 严重阈值 %
    "notify_reset": True,      # 重置回满提醒
    "notify_sound": True,      # 提示音
    "menubar_claude": True,    # 菜单栏常显 Claude 图标+百分比
    "menubar_codex": True,     # 菜单栏常显 Codex 图标+百分比（可多选/全不选）
    "menubar_alert_color": True,   # 菜单栏图标按额度变色（≥80% 橙 / ≥95% 红，分段独立）
    "menubar_value_dim": "shortest",  # 菜单栏显示哪个窗口的百分比：shortest/weekly/max
    "menubar_color_dim": "shortest",  # 菜单栏颜色由哪个窗口驱动：shortest/weekly/max
    "menubar_rotate_secs": 0,  # 多账号菜单栏轮转间隔（秒）；0=不轮转，只显主账号
    "claude_dirs": [],         # 手动添加的额外 Claude 配置目录（多账号并行）
    "codex_dirs": [],          # 手动添加的额外 Codex 配置目录
    "show_active": True,       # 活跃会话卡片
    "show_claude": True,       # 面板展示 Claude 板块（只用 Codex 的用户可关）
    "show_codex": True,        # 面板展示 Codex 板块（只用 Claude 的用户可关）
    "sessions_limit": 15,      # 每端会话列表数量
    "refresh_interval": 30,    # 前端自动刷新（秒）
    "sample_interval": 180,    # 历史曲线采样间隔（秒）——只影响记录密度，不决定查询频率
    "quota_interval": 600,     # 额度查询间隔（秒）——Claude 直接决定外部 API 频率（调大可避限流），Codex 为本地读取节流
    "terminal": "auto",        # auto | iterm | terminal | copy
    "auto_paste_resume": False,    # 唤起 Warp/VS Code 等无 CLI 注入终端后，自动模拟 ⌘V + 回车（需辅助功能授权）
    "font_scale": 100,         # 面板/小组件字体缩放 %（整体 zoom）
    "color_claude": "",        # 自定义 Claude 主色（#rrggbb）；空=内置橙
    "color_codex": "",         # 自定义 Codex 主色（#rrggbb）；空=内置青
    "language": "auto",        # 界面语言：auto（跟随系统）| zh-CN | en | ja
    "keep_awake": True,        # 有活跃会话时阻止系统休眠（避免会话因休眠/断网中断）
    "update_check": True,      # 检查新版本（向自托管 Pages 清单查版本号，不带凭据）
}
# 数值项合法范围（自定义输入钳制）
SETTING_RANGES = {
    "notify_warn": (50, 99),
    "notify_crit": (60, 100),
    "notify_done_min_secs": (5, 3600),
    "island_dwell_secs": (2, 30),
    "glass_dim": (20, 90),
    "font_scale": (80, 160),
    "sessions_limit": (5, 100),
    "refresh_interval": (5, 600),
    "sample_interval": (60, 3600),
    "quota_interval": (300, 21600),   # 5 分钟 ~ 6 小时
    "menubar_rotate_secs": (0, 60),
}
_settings_lock = threading.Lock()
_settings_cache = None   # (mtime, 解析后的 saved dict)——按 mtime 命中，免每次读盘+解析


def get_settings():
    global _settings_cache
    s = dict(DEFAULT_SETTINGS)
    with _settings_lock:
        try:
            mt = SETTINGS_FILE.stat().st_mtime
            if _settings_cache and _settings_cache[0] == mt:
                saved = _settings_cache[1]
            else:
                saved = json.loads(SETTINGS_FILE.read_text())
                _settings_cache = (mt, saved)
            s.update({k: v for k, v in saved.items() if k in DEFAULT_SETTINGS})
        except (OSError, ValueError):
            pass
    return s


def api_settings_save(body):
    clean = {}
    for k, default in DEFAULT_SETTINGS.items():
        if k not in body:
            continue
        v = body[k]
        if isinstance(default, bool):
            if not isinstance(v, bool):
                continue
        elif isinstance(default, list):
            if not isinstance(v, list):
                continue
            # 目录列表：仅留字符串、去空白、去重、限长，防注入与膨胀
            seen, clean_list = set(), []
            for item in v:
                if not isinstance(item, str):
                    continue
                p = item.strip()
                if p and p not in seen:
                    seen.add(p)
                    clean_list.append(p[:512])
                if len(clean_list) >= 16:
                    break
            v = clean_list
            clean[k] = v
            with _cache_lock:        # 目录变更立即重扫数据源
                _ttl_cache.pop("sources_claude", None)
                _ttl_cache.pop("sources_codex", None)
            continue
        elif isinstance(default, int):
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                continue
            v = int(v)
            if k in SETTING_RANGES:
                lo, hi = SETTING_RANGES[k]
                v = max(lo, min(hi, v))
        elif not isinstance(v, type(default)):
            continue
        elif k == "language" and v != "auto" and v not in LOCALES:
            continue
        elif k in ("color_claude", "color_codex"):
            # 仅接受 #rrggbb 或空串（清除）——防 CSS 注入
            if v != "" and not re.fullmatch(r"#[0-9a-fA-F]{6}", v):
                continue
        elif k in ("menubar_value_dim", "menubar_color_dim"):
            if v not in ("shortest", "weekly", "max"):
                continue
        clean[k] = v
    global _settings_cache
    with _settings_lock:
        try:
            cur = json.loads(SETTINGS_FILE.read_text())
        except (OSError, ValueError):
            cur = {}
        cur.update(clean)
        # 即使旧文件被手工写入越界值，也先恢复各自范围，再保持严格有序；
        # 否则 warn=100/crit=100 这类损坏状态无法靠 min/max 分支自愈。
        try:
            warn = int(cur.get("notify_warn", DEFAULT_SETTINGS["notify_warn"]))
        except (TypeError, ValueError):
            warn = DEFAULT_SETTINGS["notify_warn"]
        try:
            crit = int(cur.get("notify_crit", DEFAULT_SETTINGS["notify_crit"]))
        except (TypeError, ValueError):
            crit = DEFAULT_SETTINGS["notify_crit"]
        warn = max(50, min(99, warn))
        crit = max(60, min(100, crit))
        if warn >= crit:
            if "notify_crit" in clean and "notify_warn" not in clean:
                warn = max(50, crit - 1)
            else:
                crit = min(100, warn + 1)
        cur["notify_warn"], cur["notify_crit"] = warn, crit
        _atomic_write_text(SETTINGS_FILE,
                           json.dumps(cur, ensure_ascii=False, indent=1))
        _settings_cache = None   # 失效设置缓存，下次 get_settings 重读
    with _cache_lock:
        if "quota_interval" in clean:
            # 间隔变更立即生效：把现有「成功」额度缓存的到期改为 now+新间隔（调大即刻
            # 延长静默、不强制立刻重拉）。退避/降级条目(stale/error)不动，让其跑完退避，
            # 否则缩短到期会在限流中提前重试又被打。
            now = time.time()
            for key, (_exp, val) in list(_ttl_cache.items()):
                if (key.startswith(("claude_quota", "codex_quota"))
                        and isinstance(val, dict) and val.get("ok") and not val.get("stale")):
                    _ttl_cache[key] = (now + clean["quota_interval"], val)
    if "keep_awake" in clean:   # 立即生效，不阻塞响应
        threading.Thread(target=_update_keepawake, daemon=True).start()
    if "claude_dirs" in clean or "codex_dirs" in clean:
        _request_session_index_scan()
    return {"ok": True, "settings": _settings_response()}


_cache_lock = threading.Lock()
_ttl_cache = {}        # key -> (expire_ts, value)，接口级 TTL 缓存
_compute_locks = {}    # key -> Lock，防缓存击穿：同 key 到期时只放一个线程算 fn


def cached(key, ttl, fn):
    now = time.time()
    with _cache_lock:
        hit = _ttl_cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
        lock = _compute_locks.get(key)
        if lock is None:
            lock = _compute_locks[key] = threading.Lock()
    # 同 key 串行：缓存到期时若多请求并发（Swift 15s + 前端 30s + 采样器），
    # 只第一个真打外部接口，其余在锁上等它的结果——杜绝缓存击穿打爆限流
    with lock:
        now = time.time()
        with _cache_lock:
            hit = _ttl_cache.get(key)
            if hit and hit[0] > now:
                return hit[1]
        val = fn()
        with _cache_lock:
            _ttl_cache[key] = (now + ttl, val)
        return val


# -------------------------------------------------- 数据源发现（多账号并行）
# 用户可能用 CLAUDE_CONFIG_DIR 把不同账号隔离到独立目录（如 ~/.claude-personal /
# ~/.claude-work）。守护进程看不到终端别名注入的 env，故综合多条线索发现目录：
#   ① 守护进程自身的 CLAUDE_CONFIG_DIR ② 默认 ~/.claude
#   ③ ~/.claude-* 通配 ④ 反查 shell 启动文件里的 CLAUDE_CONFIG_DIR=
#   ⑤ 设置里手动添加。每个候选都校验「确为 Claude 配置目录」以排除 .claude-mem 等同名异类目录。

def _slug(text):
    return re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-") or "x"


def _is_claude_dir(p):
    """判定是否为真实 Claude Code 配置目录。
    强标志：projects/(用过) | .credentials.json(登录过) | history.jsonl(命令历史)。
    不用 settings.json——太通用，会误纳 .claude-mem 等同名异类工具目录。"""
    try:
        return p.is_dir() and (
            (p / "projects").is_dir() or (p / ".credentials.json").exists()
            or (p / "history.jsonl").exists())
    except OSError:
        return False


def _is_codex_dir(p):
    try:
        return p.is_dir() and (
            (p / "sessions").is_dir() or (p / "config.toml").exists()
            or (p / "auth.json").exists())
    except OSError:
        return False


def _expand(raw):
    s = str(raw).strip().strip('"').strip("'")
    s = s.replace("${HOME}", str(HOME)).replace("$HOME", str(HOME))
    return Path(os.path.expanduser(s))


def _shell_rc_dirs(var):
    """从 shell 启动文件里反查 <var>=...（值含 $HOME/~ 时展开）。"""
    found = []
    pat = re.compile(re.escape(var) + r'=(?:"([^"]*)"|\'([^\']*)\'|([^\s;]+))')
    for name in (".zshrc", ".zprofile", ".zshenv", ".bashrc",
                 ".bash_profile", ".profile"):
        try:
            txt = (HOME / name).read_text(errors="replace")
        except OSError:
            continue
        for m in pat.finditer(txt):
            raw = m.group(1) or m.group(2) or m.group(3) or ""
            if raw:
                found.append(raw)
    return found


def _proc_env_dirs(var, tools):
    """从在跑的目标进程环境里反查 <var>=...。IDE/扩展（如 Xcode 自带 claude、
    各类编辑器插件）常把 CLAUDE_CONFIG_DIR / CODEX_HOME 只注入所拉起子进程的环境，
    既不写 shell 配置、也不在守护进程自身环境里——只能从进程环境直接取。"""
    if not tools:
        return []
    head = re.compile(r'^(?:\S+/)?(?:' + '|'.join(map(re.escape, tools)) + r')(?:\s|$)')
    try:
        ps = subprocess.run(["ps", "-axo", "pid=,command="],
                            capture_output=True, text=True, timeout=10)
    except Exception:
        return []
    pids = []
    for line in ps.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and head.match(parts[1]) and "app-server" not in parts[1]:
            pids.append(parts[0])
    if not pids:
        return []
    pat, found = re.compile(re.escape(var) + r'=(\S+)'), []
    try:
        env = subprocess.run(["ps", "eww", "-o", "command=", "-p", ",".join(pids[:40])],
                             capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return []
    for line in env.splitlines():
        m = pat.search(line)
        if m:
            found.append(m.group(1))
    return found


def _label_for_dir(p, default_label):
    name = p.name
    if name in (".claude", ".codex"):
        return default_label
    for pre in (".claude-", ".codex-"):
        if name.startswith(pre):
            return name[len(pre):] or default_label
    return name.lstrip(".") or default_label


def _discover(env_var, default_dir, glob_pat, settings_key,
              is_dir_fn, default_label, proc_tools=()):
    seen, order = {}, []

    def add(raw, session_only=False):
        p = _expand(raw)
        if not is_dir_fn(p):
            return
        try:
            rp = os.path.realpath(p)
        except OSError:
            return
        if rp in seen:
            return
        src = {
            "id": _slug(p.name) if p != default_dir else "default",
            "label": _label_for_dir(p, default_label),
            "path": p,
            "is_default": (p == default_dir),
            # 仅供会话/活跃/用量读取，不当作独立计费账号去拉额度（IDE 注入的配置目录
            # 如 Xcode ClaudeAgentConfig：和用户是同一订阅，多拉一次 usage 只会撞 429）
            "session_only": session_only,
        }
        seen[rp] = src
        order.append(src)

    env = os.environ.get(env_var)
    if env:
        add(env)
    add(default_dir)                              # 默认目录恒在
    for p in sorted(HOME.glob(glob_pat)):         # ~/.claude-* / ~/.codex-*
        add(p)
    for raw in _shell_rc_dirs(env_var):           # 反查 shell 配置
        add(raw)
    # 在跑进程环境（IDE 注入，如 Xcode 自带 claude）——仅作会话源，不计额度账号。
    # 若同一目录已被上面任一路发现（用户自己设的 CLAUDE_CONFIG_DIR 等），先到先得保留为账号。
    for raw in _proc_env_dirs(env_var, proc_tools):
        add(raw, session_only=True)
    for raw in get_settings().get(settings_key, []):   # 手动添加
        add(raw)
    # id 去重：同名 slug 追加序号，保证前端/Swift key 唯一
    used = set()
    for src in order:
        base = src["id"]
        i, sid = 1, base
        while sid in used:
            i += 1
            sid = f"{base}-{i}"
        src["id"] = sid
        used.add(sid)
    return order


def claude_sources():
    """发现所有 Claude 配置目录，默认目录排首位。结果短缓存（30s）。"""
    return cached("sources_claude", 30, lambda: _discover(
        "CLAUDE_CONFIG_DIR", HOME / ".claude", ".claude-*",
        "claude_dirs", _is_claude_dir, "默认", proc_tools=("claude",)))


def codex_sources():
    return cached("sources_codex", 30, lambda: _discover(
        "CODEX_HOME", HOME / ".codex", ".codex-*",
        "codex_dirs", _is_codex_dir, "默认", proc_tools=("codex",)))


# ----------------------------------------------------------------- 多语言 i18n
# 有效 locale 由 daemon 统一解析，前端与 Swift 壳都消费 daemon 给的值，三层一致。
LOCALES = ("zh-CN", "en", "ja")

# daemon 直接产出的用户可见串（系统通知）；面板文案在前端本地化。
NOTIFY_STRINGS = {
    "zh-CN": {"crit": "🔴 {tool} {label} 已用 {pct}%，即将触顶",
              "warn": "⚠️ {tool} {label} 已用 {pct}%",
              "reset": "✅ {tool} {label} 已重置，额度回满"},
    "en": {"crit": "🔴 {tool} {label} at {pct}% — almost capped",
           "warn": "⚠️ {tool} {label} at {pct}%",
           "reset": "✅ {tool} {label} reset — quota restored"},
    "ja": {"crit": "🔴 {tool} {label} {pct}% 使用 — 上限間近",
           "warn": "⚠️ {tool} {label} {pct}% 使用",
           "reset": "✅ {tool} {label} リセット — 上限回復"},
}
# 窗口标签（按稳定 id），仅供通知本地化；面板同样按 id 本地化。
WINDOW_LABELS = {
    "zh-CN": {"five_hour": "5 小时窗口", "seven_day": "周限额",
              "seven_day_sonnet": "周限额 · Sonnet", "seven_day_opus": "周限额 · Opus",
              "seven_day_oauth_apps": "周限额 · OAuth Apps"},
    "en": {"five_hour": "5-hour", "seven_day": "Weekly",
           "seven_day_sonnet": "Weekly · Sonnet", "seven_day_opus": "Weekly · Opus",
           "seven_day_oauth_apps": "Weekly · OAuth Apps"},
    "ja": {"five_hour": "5時間枠", "seven_day": "週間上限",
           "seven_day_sonnet": "週間 · Sonnet", "seven_day_opus": "週間 · Opus",
           "seven_day_oauth_apps": "週間 · OAuth Apps"},
}


def _system_locale():
    """系统首选语言 → zh-CN / en / ja；探测失败/无法识别返回 None。
    失败不返回 en，是为了让上层区分『确实是英文』与『这次没探到』，后者不进缓存。"""
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"],
                             capture_output=True, text=True, timeout=5)
        if out.returncode != 0:
            return None
        for line in out.stdout.splitlines():
            tok = line.strip().strip('(),"').lower()
            if not tok:
                continue
            if tok.startswith("zh"):
                return "zh-CN"
            if tok.startswith("ja"):
                return "ja"
            return "en"   # 首个非空语言码：英文或其它语种，均按 en
    except Exception:
        pass
    return None


def _effective_locale():
    """设置为 auto 时跟随系统；否则用设置值。
    系统探测成功才写 5 分钟缓存——探测失败本次回退 en 但不缓存，
    否则启动期一次 defaults 抖动会把界面锁成英文 5 分钟（且 auto 下切不回来）。"""
    lang = get_settings().get("language", "auto")
    if lang in LOCALES:
        return lang
    now = time.time()
    with _cache_lock:
        hit = _ttl_cache.get("syslang")
        if hit and hit[0] > now:
            return hit[1]
    loc = _system_locale()
    if loc is None:
        return "en"   # 不写缓存，下个刷新周期立即重探
    with _cache_lock:
        _ttl_cache["syslang"] = (now + 300, loc)
    return loc


def _settings_response():
    """对外的设置响应：持久化设置 + 计算出的有效 locale（不持久化）。"""
    return {**get_settings(), "locale": _effective_locale()}


# ----------------------------------------------------------------- 更新检测
def _ver_key(v):
    """版本串 → 可比较元组（取前三段数字；解析不出按 0）。"""
    nums = re.findall(r"\d+", str(v))[:3]
    return tuple(int(n) for n in (nums or ["0"]))


def api_update(force=False):
    """查自托管清单的最新版本（6 小时缓存；设置关闭时不发任何请求）。
    force=True（设置页「立即检查」）时绕过缓存强制拉取，失败标记 error。"""
    if not get_settings().get("update_check", True):
        return {"current": VERSION, "available": False, "disabled": True}

    def fetch():
        req = urllib.request.Request(UPDATE_MANIFEST_URL, headers={
            "User-Agent": f"agentdeck/{VERSION}"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            return json.loads(resp.read().decode())
    try:
        if force:
            with _cache_lock:
                _ttl_cache.pop("update_manifest", None)
        m = cached("update_manifest", 6 * 3600, fetch)
    except Exception:
        return {"current": VERSION, "available": False, "error": True}
    latest = str(m.get("version") or "")
    # dmg 直链：清单显式给则用之，否则按命名规律从版本号推导（面板「下载新版」直接下 DMG，不跳页）
    dmg = str(m.get("dmg") or "")
    if not dmg and latest:
        dmg = f"{GITHUB_RELEASES}/download/v{latest}/AgentDeck-{latest}.dmg"
    return {"current": VERSION, "latest": latest,
            "available": bool(latest) and _ver_key(latest) > _ver_key(VERSION),
            "url": str(m.get("url") or ""),
            "dmg": dmg,
            "notes_url": str(m.get("notes_url") or "")}


_update_job = {}
_update_job_lock = threading.Lock()


def _set_update_job(**kw):
    with _update_job_lock:
        _update_job.update(kw)


def _update_status():
    with _update_job_lock:
        return dict(_update_job) if _update_job else {"running": False}


def _safe_update_url(url):
    p = urllib.parse.urlparse(url)
    if p.scheme != "https":
        return False
    host = (p.hostname or "").lower()
    if host != "github.com":
        return False
    m = re.fullmatch(
        rf"/Spacebody/AgentDeck/releases/download/v({_UPDATE_VERSION_RE})/"
        rf"AgentDeck-({_UPDATE_VERSION_RE})[.]dmg", p.path)
    return bool(m and m.group(1) == m.group(2))


def _codesign_team(app_path):
    r = _run_checked(["codesign", "-dv", str(app_path)], timeout=30)
    blob = (r.stderr or "") + (r.stdout or "")
    m = re.search(r"^TeamIdentifier=(.+)$", blob, re.M)
    return (m.group(1).strip() if m else "")


def _verify_update_app(app_path, version):
    """Verify bundle identity, version and the complete sealed code signature."""
    try:
        info = plistlib.loads((Path(app_path) / "Contents" / "Info.plist").read_bytes())
    except Exception as exc:
        raise RuntimeError(f"invalid app bundle: {exc}")
    if info.get("CFBundleIdentifier") != "com.agentdeck.app":
        raise RuntimeError("DMG does not contain AgentDeck")
    short_version = str(info.get("CFBundleShortVersionString") or "")
    bundle_version = str(info.get("CFBundleVersion") or "")
    if short_version != version or bundle_version != version:
        raise RuntimeError("AgentDeck version does not match update manifest")
    _run_checked(["codesign", "--verify", "--deep", "--strict", str(app_path)], timeout=60)
    _run_checked(["spctl", "--assess", "--type", "execute", "--verbose=2",
                  str(app_path)], timeout=60)
    if _codesign_team(app_path) != "2E56T94S33":
        raise RuntimeError("AgentDeck signature team mismatch")


def _run_checked(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=kw.pop("timeout", 120), **kw)
    if r.returncode != 0:
        raise RuntimeError((r.stderr or r.stdout or "command failed").strip()[:500])
    return r


def _update_install_worker(job_id, dmg_url, version):
    tmp = Path(tempfile.mkdtemp(prefix="agentdeck-update-"))
    dmg_path = tmp / f"AgentDeck-{version or 'latest'}.dmg"
    mount = tmp / "mnt"
    stage = tmp / "stage"
    mounted = False
    try:
        _set_update_job(stage="downloading", progress=0.02, message="downloading")
        req = urllib.request.Request(dmg_url, headers={"User-Agent": f"agentdeck/{VERSION}"})
        with urllib.request.urlopen(req, timeout=30) as resp, open(dmg_path, "wb") as f:
            total = int(resp.headers.get("Content-Length") or 0)
            if total > _MAX_UPDATE_DMG_BYTES:
                raise RuntimeError("update DMG is too large")
            got = 0
            while True:
                chunk = resp.read(1024 * 256)
                if not chunk:
                    break
                f.write(chunk)
                got += len(chunk)
                if got > _MAX_UPDATE_DMG_BYTES:
                    raise RuntimeError("update DMG is too large")
                if total:
                    _set_update_job(progress=min(0.72, 0.02 + 0.70 * got / total))
                else:
                    _set_update_job(progress=min(0.70, (_update_status().get("progress") or 0.02) + 0.01))
        if dmg_path.stat().st_size < 1024 * 1024:
            raise RuntimeError("downloaded DMG is too small")

        _set_update_job(stage="mounting", progress=0.76, message="mounting")
        mount.mkdir()
        _run_checked(["hdiutil", "attach", str(dmg_path), "-nobrowse", "-noautoopen",
                      "-mountpoint", str(mount)], timeout=90)
        mounted = True
        app = mount / "AgentDeck.app"
        if not app.is_dir():
            matches = list(mount.glob("*.app"))
            if not matches:
                raise RuntimeError("AgentDeck.app not found in DMG")
            app = matches[0]
        _verify_update_app(app, version)

        _set_update_job(stage="staging", progress=0.86, message="staging")
        stage.mkdir()
        _run_checked(["cp", "-R", str(app), str(stage / "AgentDeck.app")], timeout=120)

        helper = tmp / "install-agentdeck.sh"
        _atomic_write_text(helper, f'''#!/bin/sh
set -eu
APP="/Applications/AgentDeck.app"
NEW={shlex.quote(str(stage / "AgentDeck.app"))}
MOUNT={shlex.quote(str(mount))}
TMP={shlex.quote(str(tmp))}
DAEMON_PID={os.getpid()}
OLD="$TMP/AgentDeck.old.app"
cleanup() {{
  /usr/bin/hdiutil detach "$MOUNT" >/dev/null 2>&1 || true
  /bin/rm -rf "$TMP"
}}
restore() {{
  if [ -d "$OLD" ]; then
    /bin/rm -rf "$APP"
    /bin/mv "$OLD" "$APP"
  fi
  cleanup
  [ -d "$APP" ] && /usr/bin/open "$APP" || true
}}
trap restore ERR INT TERM
/usr/bin/osascript -e 'tell application "AgentDeck" to quit' >/dev/null 2>&1 || true
sleep 1
/bin/kill "$DAEMON_PID" >/dev/null 2>&1 || true
if [ -d "$APP" ]; then /bin/mv "$APP" "$OLD"; fi
/bin/cp -R "$NEW" "$APP"
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/sbin/spctl --assess --type execute "$APP"
/bin/rm -rf "$OLD"
/usr/bin/xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
trap - ERR INT TERM
cleanup
/usr/bin/open "$APP"
''', mode=0o755)
        _set_update_job(stage="installing", progress=0.95, message="installing")
        subprocess.Popen(["/bin/sh", str(helper)], stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
    except Exception as exc:
        if mounted:
            subprocess.run(["hdiutil", "detach", str(mount)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=20)
        try:
            import shutil
            shutil.rmtree(tmp)
        except OSError:
            pass
        _set_update_job(running=False, stage="error", progress=0.0,
                        error=str(exc)[:500], message="error")


def api_update_install(body):
    with _update_job_lock:
        if _update_job.get("running"):
            return {"ok": True, **_update_job}
    version = str(body.get("version") or "")
    info = api_update(force=True)
    latest = str(info.get("latest") or "")
    if not version:
        version = latest
    if (not re.fullmatch(_UPDATE_VERSION_RE, version)
            or version != latest or not info.get("available")):
        return {"ok": False, "error": "no matching update available"}
    dmg = info.get("dmg") or ""
    if not dmg or not _safe_update_url(dmg):
        return {"ok": False, "error": "invalid update url"}
    job_id = str(uuid.uuid4())
    with _update_job_lock:
        _update_job.clear()
        _update_job.update({"ok": True, "running": True, "id": job_id,
                            "stage": "queued", "progress": 0.0,
                            "version": version, "error": ""})
    threading.Thread(target=_update_install_worker,
                     args=(job_id, dmg, version), daemon=True).start()
    return _update_status()


# ---------------------------------------------------------------- Claude 额度

def _keychain_item(service="Claude Code-credentials", account=None):
    """读某条 generic-password 的 JSON；不存在/解析失败返回 None（不抛）。"""
    cmd = ["security", "find-generic-password", "-s", service]
    if account is not None:
        cmd += ["-a", account]
    cmd += ["-w"]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            return None
        return json.loads(out.stdout.strip())
    except (ValueError, OSError, subprocess.SubprocessError):
        # SubprocessError 含 TimeoutExpired：security 卡住时跳过该候选、继续探测下一项
        return None


def _keychain_token():
    """共享项（无 -a）的订阅 token；取不到则抛——保留给 api_diag / 兜底用。"""
    data = _keychain_item()
    tok = (data or {}).get("claudeAiOauth", {}).get("accessToken") if data else None
    if not tok:
        raise RuntimeError("keychain: no claudeAiOauth")
    return tok


def _keychain_token_for(path, is_default=False):
    """按 config dir 取对应钥匙串项里的订阅 token。
    实测 macOS 新版 Claude Code 多账号会按 sha256(目录路径) 后缀把凭据「分项」存
    （单账号 / 默认目录则是无后缀的共享项，account=$USER）。确切命名规则无法在
    单账号机器上验证，故逐候选探测、命中即用。

    关键：共享项（无后缀）只属于默认目录——只有 is_default 才回落它；非默认源若没
    命中自己的 sha256 分项就返回 None（老实显示『无额度』），绝不误取主账号 token
    造成额度错配、也不对同一 token 重复打 usage 接口。"""
    abspath = os.path.realpath(str(path))
    h = hashlib.sha256(abspath.encode()).hexdigest()[:8]
    user = os.environ.get("USER") or ""
    base = "Claude Code-credentials"
    # 该目录专属的 sha256 分项（覆盖『后缀加在 service / account』两种可能）
    candidates = [
        (f"{base}-{h}", None),
        (base, f"{user}-{h}" if user else None),
        (base, h),
    ]
    if is_default:   # 共享项仅归默认目录
        candidates += [(base, user or None), (base, None)]
    for svc, acct in candidates:
        data = _keychain_item(svc, acct)
        tok = (data or {}).get("claudeAiOauth", {}).get("accessToken") if data else None
        if tok:
            return tok
    return None


def _gateway_settings(path):
    """该源是否为网关/自建 API 账号：settings(.local).json 的 env 里声明了
    ANTHROPIC_BASE_URL 或 ANTHROPIC_AUTH_TOKEN（中转网关 / 非官方 API，无 usage 端点）。"""
    for name in ("settings.json", "settings.local.json"):
        try:
            s = json.loads((path / name).read_text())
        except (OSError, ValueError):
            continue
        env = (s.get("env") or {}) if isinstance(s, dict) else {}
        if env.get("ANTHROPIC_BASE_URL") or env.get("ANTHROPIC_AUTH_TOKEN"):
            return True
    return False


def _source_token(src):
    """解析某 Claude 源的额度 token 与账号类型 → (token, kind)。
      "oauth"    → 可拉官方额度
      "gateway"  → 中转网关 / 自建 API 账号，官方 usage 不可用
      "no_login" → 该源未做订阅 OAuth 登录、也无可用凭据

    取 token 顺序：目录自带文件凭据 → 网关源（settings 有 base_url）显式排除 →
    按 config dir 解析钥匙串项（多账号 sha256 分项；单账号即共享 $USER 项）。
    网关账号用 env 注入的 AUTH_TOKEN、从不写钥匙串，故排除以免误取订阅 token。"""
    path = src["path"]
    # 1. 目录内文件凭据（Linux / 部分 CLAUDE_CONFIG_DIR 配置直接落文件）
    try:
        data = json.loads((path / ".credentials.json").read_text())
        tok = (data.get("claudeAiOauth") or {}).get("accessToken")
        if tok:
            return tok, "oauth"
    except (OSError, ValueError):
        pass
    # 2. 网关 / 自建 API 账号：无官方额度端点，且不应误取钥匙串里的订阅 token
    if _gateway_settings(path):
        return None, "gateway"
    # 3. 钥匙串：按目录取对应项（多账号 sha256 分项 / 单账号共享项，仅默认源回落共享项）
    tok = _keychain_token_for(path, is_default=src.get("is_default", False))
    return (tok, "oauth") if tok else (None, "no_login")


def _claude_quota_for(src):
    token, kind = _source_token(src)
    if not token:
        # 官方额度端点不可用，按账号类型给出可读原因（面板自动展示）
        reason = {
            "gateway": "中转网关 / 自建 API 账号，无官方额度（仅按会话用量统计）",
            "no_login": "该目录未做订阅登录，钥匙串无 OAuth 凭据",
        }.get(kind, "无可用额度凭据")
        return {"ok": False, "kind": kind, "no_quota": True, "error": reason}
    req = urllib.request.Request(
        "https://api.anthropic.com/api/oauth/usage",
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Content-Type": "application/json",
            "User-Agent": "agentdeck/1.0",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = json.loads(resp.read().decode())

    # 防御式解析：official 接口字段可能演进，未识别时透传 raw 由前端兜底
    windows = []
    for key, label in (
        ("five_hour", "5 小时窗口"),
        ("seven_day", "周限额"),
        ("seven_day_sonnet", "周限额 · Sonnet"),
        ("seven_day_opus", "周限额 · Opus"),
        ("seven_day_oauth_apps", "周限额 · OAuth Apps"),
    ):
        node = raw.get(key)
        if isinstance(node, dict) and node.get("utilization") is not None:
            windows.append({
                "id": key,
                "label": label,
                "used_percent": round(float(node["utilization"]), 1),
                "resets_at": node.get("resets_at"),
            })
    return {"ok": True, "kind": "oauth", "windows": windows, "raw": raw}


def _claude_quota():
    """主账号（首个计费源）额度——保持原返回形状，向后兼容旧前端/Swift。"""
    srcs = [s for s in claude_sources() if not s.get("session_only")]
    if not srcs:
        return {"ok": False, "error": "未发现 Claude 配置目录"}
    return _claude_quota_for(srcs[0])


def _claude_quota_accounts(ttl=CLAUDE_QUOTA_TTL):
    """每个 Claude 账号各拉一次额度（各自缓存 + 失败降级）。ttl 即真实外部调用间隔。"""
    out = []
    for src in claude_sources():
        if src.get("session_only"):
            continue          # IDE 注入的会话源（如 Xcode），非计费账号，不拉额度
        # 默认账号用回稳定键 claude_quota，复用历史降级数据（不因多账号化丢失兜底）
        key = "claude_quota" if src["is_default"] else f"claude_quota_{src['id']}"
        q = _resilient(key, ttl, lambda s=src: _claude_quota_for(s))
        out.append({"account_id": src["id"], "account": src["label"],
                    "is_default": src["is_default"], **q})
    return out


# ----------------------------------------------------------------- Codex 额度

def _codex_file_index(base):
    # 单账号 rollout 文件列表（按文件名倒排≈新→旧），短 TTL 缓存。
    # 搜索时扫描窗口放大到 240、连续按键反复进来，缓存 5s 免去重复 glob 枚举。
    return cached(f"fidx:codex:{base}", 5, lambda: sorted(
        (base / "sessions").glob("*/*/*/rollout-*.jsonl"), reverse=True))


def _iter_codex_files(limit=60, base=None):
    """rollout 文件列表（文件名按时间戳，词序倒排≈新→旧）。
    base=None 聚合所有 Codex 源；指定 base（codex home 目录）则只扫该账号。"""
    bases = [base] if base is not None else [s["path"] for s in codex_sources()]
    if len(bases) == 1:
        files = _codex_file_index(bases[0])
        return files if limit is None else files[:limit]
    files = []
    for b in bases:
        files.extend(_codex_file_index(b))
    files.sort(reverse=True)
    return files if limit is None else files[:limit]


def _tail_lines(path, size=262144):
    with open(path, "rb") as f:
        f.seek(0, 2)
        end = f.tell()
        f.seek(max(0, end - size))
        data = f.read()
    return data.decode("utf-8", "replace").splitlines()


def _codex_quota(base=None):
    primary = secondary = credits = stamp = None
    for path in _iter_codex_files(30, base=base):
        for line in reversed(_tail_lines(path)):
            if '"rate_limits"' not in line:
                continue
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            rl = (evt.get("payload") or {}).get("rate_limits") or {}
            if credits is None and isinstance(rl.get("credits"), dict):
                credits = rl["credits"]
            if rl.get("primary"):
                primary = rl["primary"]
                secondary = rl.get("secondary")
                stamp = evt.get("timestamp")
                break
        if primary:
            break

    windows = []
    now = time.time()
    for node, fb_label, fb_id in ((primary, "主窗口", "primary"),
                                  (secondary, "次窗口", "secondary")):
        if not node:
            continue
        mins = node.get("window_minutes") or 0
        # 稳定 id 供前端/通知本地化；label 作为回退
        wid = ("five_hour" if mins == 300 else
               "seven_day" if mins >= 10000 else
               f"win_{mins}" if mins else fb_id)
        label = ("5 小时窗口" if mins == 300 else
                 "周限额" if mins >= 10000 else
                 f"{mins} 分钟窗口" if mins else fb_label)
        resets = node.get("resets_at")
        pct = float(node.get("used_percent") or 0)
        if resets and resets < now:   # 窗口已重置，历史百分比作废
            pct = 0.0
        windows.append({
            "id": wid,
            "label": label,
            "used_percent": round(pct, 1),
            "resets_at": resets,
        })
    return {"ok": True, "windows": windows, "credits": credits,
            "sampled_at": stamp}


def _codex_quota_accounts(ttl=CODEX_QUOTA_TTL):
    """每个 Codex 账号各自解析 rate_limits（各自缓存）。"""
    out = []
    for src in codex_sources():
        if src.get("session_only"):
            continue          # IDE 注入的会话源，非计费账号，不拉额度
        key = "codex_quota" if src["is_default"] else f"codex_quota_{src['id']}"
        q = _resilient(key, ttl, lambda s=src: _codex_quota(base=s["path"]))
        out.append({"account_id": src["id"], "account": src["label"],
                    "is_default": src["is_default"], **q})
    return out


_last_good = {}        # key -> 最近一次成功结果（失败时降级返回）
_last_good_lock = threading.Lock()
LAST_GOOD_FILE = None  # 延迟初始化，DATA_DIR 定义在前文


def _resilient(key, ttl, fn):
    """失败时回退到最近一次成功值；429 限流额外退避 10 分钟。"""
    global LAST_GOOD_FILE
    with _last_good_lock:
        if LAST_GOOD_FILE is None:
            LAST_GOOD_FILE = DATA_DIR / "last_good.json"
            try:  # 进程重启后恢复降级数据，避免重启风暴打爆接口
                _last_good.update(json.loads(LAST_GOOD_FILE.read_text()))
            except (OSError, ValueError):
                pass
    try:
        val = cached(key, ttl, fn)
        # 只把「真正成功」的结果存为降级值：ok=False（如网关无额度 / 钥匙串抖动）
        # 不得污染兜底，否则真额度 429 时拿不回上一次的好数据
        if val.get("ok") and not val.get("stale"):
            with _last_good_lock:
                if _last_good.get(key) != val:
                    _last_good[key] = val
                    try:
                        _atomic_write_text(
                            LAST_GOOD_FILE,
                            json.dumps(_last_good, ensure_ascii=False))
                    except OSError:
                        pass
        return val
    except Exception as exc:
        err = str(exc)
        with _last_good_lock:
            stale = _last_good.get(key)
        out = dict(stale, stale=True, error=err) if stale \
            else {"ok": False, "error": err}
        backoff = 600 if "429" in err else 60
        with _cache_lock:                       # 失败结果也缓存，防止重试风暴
            _ttl_cache[key] = (time.time() + backoff, out)
        return out


_last_force_quota = 0.0


def api_quota(force=False):
    s = get_settings()
    # 面板隐藏的 agent 不再拉额度（省钥匙串读取 / Anthropic usage 调用 / 限流消耗）
    ttl = s.get("quota_interval", CLAUDE_QUOTA_TTL)   # 用户可调的额度查询间隔（Claude/Codex 共用）
    # 手动刷新（🔄）：清掉额度缓存键，逼一次真实重拉，不再只回读上次缓存——否则把查询
    # 间隔调大（如 1 小时）后点刷新也拿不到新数据。带 10s 防连点闸，避免狂点把接口打到 429。
    if force:
        global _last_force_quota
        now = time.time()
        with _cache_lock:
            if now - _last_force_quota >= 10:
                _last_force_quota = now
                for k in [k for k in _ttl_cache
                          if k.startswith("claude_quota") or k.startswith("codex_quota")]:
                    _ttl_cache.pop(k, None)
    claude_accts = _claude_quota_accounts(ttl) if s.get("show_claude", True) else []
    codex_accts = _codex_quota_accounts(ttl) if s.get("show_codex", True) else []
    # 向后兼容：claude/codex 仍为「主账号」单对象；新增 accounts 列表供 carousel/轮转
    if claude_accts:
        primary_claude = claude_accts[0]
    elif not s.get("show_claude", True):
        primary_claude = {"ok": False, "hidden": True}   # 隐藏 → 不拉取
    else:
        primary_claude = _resilient("claude_quota", ttl, _claude_quota)
    if codex_accts:
        primary_codex = codex_accts[0]
    elif not s.get("show_codex", True):
        primary_codex = {"ok": False, "hidden": True}
    else:
        primary_codex = _resilient("codex_quota", ttl, _codex_quota)
    return {"claude": primary_claude,
            "codex": primary_codex,
            "accounts": {"claude": claude_accts, "codex": codex_accts},
            "menubar": {"claude": s["menubar_claude"],
                        "codex": s["menubar_codex"],
                        "alert_color": s.get("menubar_alert_color", True),
                        "value_dim": s.get("menubar_value_dim", "shortest"),
                        "color_dim": s.get("menubar_color_dim", "shortest"),
                        "rotate_secs": s.get("menubar_rotate_secs", 0)},
            "ts": time.time()}


def api_diag():
    """账号/额度自动诊断（脱敏，不含任何 token 明文）。
    面板可在打开时自动拉取，把『为什么这个账号没额度』讲清楚。"""
    def redact(t):
        return f"len={len(t)}·…{t[-4:]}" if t else None

    keychain = {}
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
            capture_output=True, text=True, timeout=15)
        if out.returncode != 0:
            keychain = {"found": False, "error": (out.stderr or "denied").strip()[:80]}
        else:
            kc = json.loads(out.stdout.strip() or "{}")
            oa = kc.get("claudeAiOauth") or {}
            keychain = {"found": True,
                        "has_claudeAiOauth": bool(oa.get("accessToken")),
                        "subscriptionType": oa.get("subscriptionType"),
                        "accessToken": redact(oa.get("accessToken")),
                        "has_mcpOAuth": "mcpOAuth" in kc}
    except Exception as exc:
        keychain = {"found": False, "error": str(exc)[:80]}

    sources = []
    for src in claude_sources():
        path = src["path"]
        cf = path / ".credentials.json"
        file_oauth = None
        try:
            d = json.loads(cf.read_text())
            file_oauth = bool((d.get("claudeAiOauth") or {}).get("accessToken"))
        except (OSError, ValueError):
            pass
        tok, kind = _source_token(src)
        sources.append({
            "id": src["id"], "label": src["label"], "path": str(path),
            "is_default": src["is_default"],
            "has_credentials_file": cf.exists(),
            "file_has_claudeAiOauth": file_oauth,
            "is_gateway": _gateway_settings(path),
            "resolved_kind": kind,
            "resolved_token": redact(tok),
        })
    return {"sources": sources, "keychain": keychain,
            "codex_sources": [s["label"] for s in codex_sources()],
            "ts": time.time()}


# ----------------------------------------------------------------- 会话列表

_SKIP_PREFIXES = ("<command-name>", "<local-command", "<user_instructions",
                  "<environment_context", "<ENVIRONMENT_CONTEXT", "Caveat:",
                  "<system-reminder>", "<task-notification>",
                  "# AGENTS.md", "<permissions",
                  # Claude Code 内部 housekeeping 会话（摘要 / compact），非用户交互，
                  # 跳过其首条消息后该会话取不到有效标题即被丢弃，避免白占最近列表名额
                  "You are summarizing a Claude Code session",
                  "Apply maximum non-destructive compression")


def _msg_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for item in content:
            if isinstance(item, dict) and item.get("type") in ("text", "input_text", "output_text"):
                return item.get("text", "")
    return ""


def _clean_title(text):
    # 图片/附件标记的源路径串没有可读性，折叠为占位符
    text = re.sub(r"\[Image[^\]]*\]", "[图片]", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:120] if text else ""


_SESSION_INDEX_SCHEMA = 2
_SESSION_INDEX_INTERVAL = 30
_SESSION_PAGE_MAX = 200
_session_schema_lock = threading.Lock()
_session_schema_paths = set()
_session_index_write_lock = threading.Lock()
_session_index_start_lock = threading.Lock()
_session_index_state_lock = threading.Lock()
_session_index_wake = threading.Event()
_session_index_started = False
_session_index_state = {
    "indexing": False, "indexed_at": 0.0, "total_files": 0,
    "processed_files": 0, "error": "",
}


def _session_db_connect_once():
    """每个 HTTP 线程使用独立连接；WAL 允许后台单写与前台并发读。"""
    path = Path(SESSION_INDEX_FILE)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(path), timeout=5)
    try:
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout=5000")
        conn.execute("PRAGMA synchronous=NORMAL")
        key = os.path.realpath(path)
        with _session_schema_lock:
            if key not in _session_schema_paths:
                conn.execute("PRAGMA journal_mode=WAL")
                version = conn.execute("PRAGMA user_version").fetchone()[0]
                if version not in (0, _SESSION_INDEX_SCHEMA):
                    conn.executescript(
                        "DROP TABLE IF EXISTS session_file_state; "
                        "DROP TABLE IF EXISTS session_index; DROP TABLE IF EXISTS session_meta;")
                conn.executescript("""
                    CREATE TABLE IF NOT EXISTS session_file_state (
                        path TEXT PRIMARY KEY,
                        tool TEXT NOT NULL,
                        account_id TEXT NOT NULL,
                        account TEXT NOT NULL DEFAULT '',
                        inode INTEGER NOT NULL DEFAULT 0,
                        size INTEGER NOT NULL DEFAULT 0,
                        mtime REAL NOT NULL DEFAULT 0,
                        status TEXT NOT NULL,
                        session_id TEXT NOT NULL DEFAULT '',
                        title TEXT NOT NULL DEFAULT '',
                        cwd TEXT NOT NULL DEFAULT '',
                        project TEXT NOT NULL DEFAULT '',
                        branch TEXT NOT NULL DEFAULT '',
                        title_folded TEXT NOT NULL DEFAULT '',
                        project_folded TEXT NOT NULL DEFAULT '',
                        search_text TEXT NOT NULL DEFAULT ''
                    );
                    CREATE INDEX IF NOT EXISTS idx_session_file_identity
                        ON session_file_state (tool, account_id, session_id, mtime DESC);
                    CREATE TABLE IF NOT EXISTS session_index (
                        tool TEXT NOT NULL,
                        account_id TEXT NOT NULL,
                        account TEXT NOT NULL DEFAULT '',
                        session_id TEXT NOT NULL,
                        path TEXT NOT NULL UNIQUE,
                        inode INTEGER NOT NULL DEFAULT 0,
                        size INTEGER NOT NULL DEFAULT 0,
                        mtime REAL NOT NULL DEFAULT 0,
                        title TEXT NOT NULL DEFAULT '',
                        cwd TEXT NOT NULL DEFAULT '',
                        project TEXT NOT NULL DEFAULT '',
                        branch TEXT NOT NULL DEFAULT '',
                        title_folded TEXT NOT NULL DEFAULT '',
                        project_folded TEXT NOT NULL DEFAULT '',
                        search_text TEXT NOT NULL DEFAULT '',
                        pinned INTEGER NOT NULL DEFAULT 0,
                        source_present INTEGER NOT NULL DEFAULT 1,
                        PRIMARY KEY (tool, account_id, session_id)
                    );
                    CREATE INDEX IF NOT EXISTS idx_session_recent
                        ON session_index (pinned DESC, mtime DESC);
                    CREATE INDEX IF NOT EXISTS idx_session_tool_recent
                        ON session_index (tool, pinned DESC, mtime DESC);
                    CREATE TABLE IF NOT EXISTS session_meta (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    );
                """)
                conn.execute(f"PRAGMA user_version={_SESSION_INDEX_SCHEMA}")
                conn.commit()
                try:
                    os.chmod(path, 0o600)
                except OSError:
                    pass
                _session_schema_paths.add(key)
        return conn
    except Exception:
        conn.close()
        raise


def _session_db_connect():
    conn = None
    try:
        conn = _session_db_connect_once()
        conn.execute("SELECT 1 FROM sqlite_master LIMIT 1").fetchone()
        return conn
    except sqlite3.DatabaseError as exc:
        if conn:
            conn.close()
        message = str(exc).lower()
        if not any(marker in message for marker in
                   ("malformed", "not a database", "file is encrypted")):
            raise
        path = Path(SESSION_INDEX_FILE)
        key = os.path.realpath(path)
        with _session_schema_lock:
            _session_schema_paths.discard(key)
            for candidate in (path, Path(str(path) + "-wal"), Path(str(path) + "-shm")):
                try:
                    candidate.unlink()
                except FileNotFoundError:
                    pass
        _session_state(indexing=True, indexed_at=0.0,
                       error="session index rebuilt after corruption")
        fresh = _session_db_connect_once()
        _request_session_index_scan()
        return fresh


def _session_state(**updates):
    with _session_index_state_lock:
        _session_index_state.update(updates)


def _session_status():
    with _session_index_state_lock:
        return dict(_session_index_state)


def _fold_session_text(*parts):
    return " ".join(str(p or "") for p in parts).casefold()


_SESSION_IGNORED = object()


def _claude_session_info(path):
    title, cwd, branch = "", "", ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for _ in range(80):
                line = f.readline()
                if not line:
                    break
                try:
                    evt = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(evt, dict):
                    continue
                if evt.get("isSidechain"):
                    return _SESSION_IGNORED
                cwd = evt.get("cwd") or cwd
                branch = evt.get("gitBranch") or branch
                if evt.get("type") == "user":
                    message = evt.get("message")
                    text = _msg_text(message.get("content")) \
                        if isinstance(message, dict) else ""
                    if text and not text.lstrip().startswith(_SKIP_PREFIXES):
                        title = _clean_title(text)
                        break
    except OSError:
        return None
    if not title:
        return None
    return path.stem, cwd, title, branch


def _codex_session_info(path):
    sid, cwd, title = None, "", ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for _ in range(120):
                line = f.readline()
                if not line:
                    break
                try:
                    evt = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(evt, dict):
                    continue
                payload = evt.get("payload")
                payload = payload if isinstance(payload, dict) else {}
                if evt.get("type") == "session_meta":
                    sid = payload.get("id")
                    cwd = payload.get("cwd") or ""
                text = ""
                if payload.get("type") == "user_message":
                    text = _msg_text(payload.get("message"))
                elif payload.get("role") == "user":
                    text = _msg_text(payload.get("content"))
                if text and not text.lstrip().startswith(_SKIP_PREFIXES):
                    title = _clean_title(text)
                    break
    except OSError:
        return None
    if not (sid and title):
        return None
    return sid, cwd, title


def _session_file_info(tool, path):
    if tool == "claude":
        info = _claude_session_info(path)
        if info is _SESSION_IGNORED:
            return "ignored", None
        if not info:
            return "incomplete", None
        sid, cwd, title, branch = info
    else:
        _rollout_meta_cache.pop(str(path), None)
        if _rollout_meta(path).get("subagent"):
            return "ignored", None
        info = _codex_session_info(path)
        if not info:
            return "incomplete", None
        sid, cwd, title = info
        branch = ""
    project = Path(cwd).name if cwd else (path.parent.name if tool == "claude" else "")
    return "indexed", {
        "session_id": sid, "cwd": cwd or "", "title": title,
        "project": project, "branch": branch or "",
    }


def _session_source_files():
    entries = []
    specs = (
        ("claude", claude_sources(), "projects", "*/*.jsonl"),
        ("codex", codex_sources(), "sessions", "*/*/*/rollout-*.jsonl"),
    )
    for tool, sources, folder, pattern in specs:
        for src in sources:
            for path in (src["path"] / folder).glob(pattern):
                if tool == "claude" and path.name.startswith("agent-"):
                    continue
                try:
                    st = path.stat()
                except OSError:
                    continue
                entries.append({
                    "tool": tool, "account_id": src["id"], "account": src["label"],
                    "path": path, "inode": int(getattr(st, "st_ino", 0)),
                    "size": st.st_size, "mtime": st.st_mtime,
                })
    # 首次建库先产出最近会话，前端可在后台索引未完成时逐步得到可用结果。
    entries.sort(key=lambda e: e["mtime"], reverse=True)
    return entries


def _session_file_state_upsert(conn, entry, status, info):
    info = info or {}
    title = info.get("title", "")
    project = info.get("project", "")
    conn.execute("""
        INSERT INTO session_file_state (
            path, tool, account_id, account, inode, size, mtime, status,
            session_id, title, cwd, project, branch, title_folded,
            project_folded, search_text
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            tool=excluded.tool, account_id=excluded.account_id,
            account=excluded.account, inode=excluded.inode, size=excluded.size,
            mtime=excluded.mtime, status=excluded.status,
            session_id=excluded.session_id, title=excluded.title,
            cwd=excluded.cwd, project=excluded.project, branch=excluded.branch,
            title_folded=excluded.title_folded,
            project_folded=excluded.project_folded,
            search_text=excluded.search_text
    """, (str(entry["path"]), entry["tool"], entry["account_id"], entry["account"],
          entry["inode"], entry["size"], entry["mtime"], status,
          info.get("session_id", ""), title, info.get("cwd", ""), project,
          info.get("branch", ""), title.casefold(), project.casefold(),
          _fold_session_text(title, info.get("cwd", ""), project,
                             info.get("branch", ""))))


def _rebuild_session_rows(conn):
    """每个复合身份只展示 mtime 最新的文件；旧副本仍留在 file_state 供回退。"""
    conn.execute("DELETE FROM session_index WHERE source_present=1")
    conn.execute("""
        INSERT INTO session_index (
            tool, account_id, account, session_id, path, inode, size, mtime,
            title, cwd, project, branch, title_folded, project_folded,
            search_text, source_present
        )
        SELECT tool, account_id, account, session_id, path, inode, size, mtime,
               title, cwd, project, branch, title_folded, project_folded,
               search_text, 1
        FROM (
            SELECT *, ROW_NUMBER() OVER (
                PARTITION BY tool, account_id, session_id
                ORDER BY mtime DESC, path DESC
            ) AS row_num
            FROM session_file_state
            WHERE status='indexed' AND session_id<>''
        )
        WHERE row_num=1
        ON CONFLICT(tool, account_id, session_id) DO UPDATE SET
            account=excluded.account, path=excluded.path, inode=excluded.inode,
            size=excluded.size, mtime=excluded.mtime, title=excluded.title,
            cwd=excluded.cwd, project=excluded.project, branch=excluded.branch,
            title_folded=excluded.title_folded,
            project_folded=excluded.project_folded,
            search_text=excluded.search_text, source_present=1
    """)


def _pin_key(tool, account_id, sid):
    return f"{tool}|{account_id or 'default'}|{sid}"


# ----------------------------------------------------------------- 收藏置顶

_pins_lock = threading.Lock()


def _load_pins():
    try:
        data = json.loads(PINS_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_pins(pins):
    _atomic_write_text(PINS_FILE, json.dumps(pins, ensure_ascii=False, indent=1))


def _sync_pins_to_db(conn):
    """pins.json 是用户状态真源；SQLite 只镜像，删库重建也不会丢收藏。"""
    with _pins_lock:
        raw = _load_pins()
        canonical = {}
        for old_key, value in raw.items():
            if not isinstance(value, dict):
                continue
            snap = dict(value)
            tool = str(snap.get("tool") or "")
            sid = str(snap.get("id") or old_key)
            if tool not in ("claude", "codex") or not _ID_RE.match(sid):
                continue
            parts = old_key.split("|", 2)
            account_id = str(snap.get("account_id") or "")
            if len(parts) == 3 and parts[0] == tool and parts[2] == sid:
                account_id = parts[1] or account_id
            if not account_id:
                row = conn.execute(
                    "SELECT account_id, account FROM session_index "
                    "WHERE tool=? AND session_id=? AND source_present=1 "
                    "ORDER BY mtime DESC LIMIT 1", (tool, sid)).fetchone()
                account_id = row["account_id"] if row else "default"
                if row and not snap.get("account"):
                    snap["account"] = row["account"]
            if not re.fullmatch(r"[a-z0-9-]{1,120}", account_id):
                account_id = "default"
            snap.update(tool=tool, id=sid, account_id=account_id)
            canonical[_pin_key(tool, account_id, sid)] = snap
        if canonical != raw:
            _save_pins(canonical)

    conn.execute("UPDATE session_index SET pinned=0 WHERE pinned<>0")
    for snap in canonical.values():
        tool, account_id, sid = snap["tool"], snap["account_id"], snap["id"]
        found = conn.execute(
            "SELECT 1 FROM session_index WHERE tool=? AND account_id=? AND session_id=?",
            (tool, account_id, sid)).fetchone()
        if found:
            conn.execute(
                "UPDATE session_index SET pinned=1 WHERE tool=? AND account_id=? AND session_id=?",
                (tool, account_id, sid))
            continue
        title = str(snap.get("title") or "")
        cwd = str(snap.get("cwd") or "")
        project = str(snap.get("project") or (Path(cwd).name if cwd else ""))
        branch = str(snap.get("branch") or "")
        account = str(snap.get("account") or "")
        try:
            mtime = float(snap.get("mtime") or 0)
        except (TypeError, ValueError):
            mtime = 0
        synthetic = "pin://" + hashlib.sha256(
            _pin_key(tool, account_id, sid).encode()).hexdigest()
        conn.execute("""
            INSERT OR REPLACE INTO session_index (
                tool, account_id, account, session_id, path, mtime, title, cwd,
                project, branch, title_folded, project_folded, search_text,
                pinned, source_present
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0)
        """, (tool, account_id, account, sid, synthetic, mtime, title, cwd,
              project, branch, title.casefold(), project.casefold(),
              _fold_session_text(title, cwd, project, branch)))
    conn.execute("DELETE FROM session_index WHERE source_present=0 AND pinned=0")


def _session_index_scan():
    """枚举文件只在后台发生；已完成元数据的增长文件仅更新 stat，不重复读 JSONL。"""
    with _session_index_write_lock:
        _session_state(indexing=True, error="", processed_files=0)
        conn = None
        try:
            conn = _session_db_connect()
            entries = _session_source_files()
            _session_state(total_files=len(entries))
            existing = {row["path"]: row for row in conn.execute(
                "SELECT path, tool, account_id, account, inode, size, mtime, status "
                "FROM session_file_state")}
            seen, writes, committed_writes, fast_processed = set(), 0, 0, 0
            parse_jobs = []
            for entry in entries:
                path = str(entry["path"])
                seen.add(path)
                old = existing.get(path)
                same_identity = old and old["tool"] == entry["tool"] \
                    and old["account_id"] == entry["account_id"]
                stable_file = same_identity and old["inode"] == entry["inode"]
                complete = old and old["status"] in ("indexed", "ignored")
                unchanged_incomplete = old and old["status"] == "incomplete" \
                    and entry["size"] == old["size"] and entry["mtime"] == old["mtime"]
                # 已解析/忽略的文件追加增长不改变会话头；不完整文件有变化则重试。
                if stable_file and ((complete and entry["size"] >= old["size"])
                                    or unchanged_incomplete):
                    if (old["size"] != entry["size"] or old["mtime"] != entry["mtime"]
                            or old["account"] != entry["account"]):
                        conn.execute(
                            "UPDATE session_file_state SET size=?, mtime=?, account=? "
                            "WHERE path=?",
                            (entry["size"], entry["mtime"], entry["account"], path))
                        writes += 1
                    fast_processed += 1
                else:
                    parse_jobs.append((entry, old))
                if writes and writes % 50 == 0 and writes != committed_writes:
                    conn.commit()
                    committed_writes = writes
                if fast_processed and fast_processed % 25 == 0:
                    _session_state(processed_files=fast_processed)

            def parse(job):
                entry, old = job
                status, info = _session_file_info(entry["tool"], entry["path"])
                return entry, old, status, info

            if parse_jobs:
                workers = min(4, len(parse_jobs))
                with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
                    for offset, (entry, old, status, info) in enumerate(
                            pool.map(parse, parse_jobs), 1):
                        _session_file_state_upsert(conn, entry, status, info)
                        writes += 1
                        if writes % 50 == 0 and writes != committed_writes:
                            _rebuild_session_rows(conn)
                            conn.commit()
                            committed_writes = writes
                        if offset % 25 == 0:
                            _session_state(processed_files=fast_processed + offset)

            for path in existing.keys() - seen:
                conn.execute("DELETE FROM session_file_state WHERE path=?", (path,))
            _rebuild_session_rows(conn)
            _sync_pins_to_db(conn)
            now = time.time()
            conn.execute(
                "INSERT OR REPLACE INTO session_meta(key, value) VALUES('indexed_at', ?)",
                (str(now),))
            conn.commit()
            _session_state(indexing=False, indexed_at=now,
                           processed_files=len(entries), error="")
        except Exception as exc:
            if conn:
                conn.rollback()
            _session_state(indexing=False, error=str(exc)[:240])
        finally:
            if conn:
                conn.close()


def _session_index_loop():
    while True:
        _session_index_scan()
        _session_index_wake.wait(_SESSION_INDEX_INTERVAL)
        _session_index_wake.clear()


def _ensure_session_index_started():
    global _session_index_started
    conn = _session_db_connect()
    if not _session_status()["indexed_at"]:
        row = conn.execute(
            "SELECT value FROM session_meta WHERE key='indexed_at'").fetchone()
        if row:
            try:
                _session_state(indexed_at=float(row["value"]))
            except ValueError:
                pass
    conn.close()
    with _session_index_start_lock:
        if _session_index_started:
            return
        _session_index_started = True
        _session_state(indexing=True, error="")
        threading.Thread(target=_session_index_loop, daemon=True,
                         name="AgentDeckSessionIndex").start()


def _request_session_index_scan():
    if _session_index_started:
        _session_index_wake.set()


def _cursor_scope(query, tool):
    return hashlib.sha256(f"{query}\0{tool}".encode()).hexdigest()[:16]


def _encode_session_cursor(row, scope):
    payload = {"v": 1, "scope": scope, "p": int(row["pinned"]),
               "r": int(row["rank"]), "m": float(row["mtime"]),
               "t": row["tool"], "a": row["account_id"], "s": row["session_id"]}
    raw = json.dumps(payload, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_session_cursor(raw, scope):
    if not raw or len(raw) > 512:
        return None
    try:
        padded = raw + "=" * (-len(raw) % 4)
        value = json.loads(base64.urlsafe_b64decode(padded).decode())
        if not isinstance(value, dict) or value.get("v") != 1 or value.get("scope") != scope:
            return None
        normalized = {
            "p": int(value["p"]), "r": int(value["r"]), "m": float(value["m"]),
            "t": str(value["t"]), "a": str(value["a"]), "s": str(value["s"]),
        }
        if normalized["p"] not in (0, 1) or not 0 <= normalized["r"] <= 3:
            return None
        if normalized["t"] not in ("claude", "codex"):
            return None
        if (not re.fullmatch(r"[a-z0-9-]{1,120}", normalized["a"])
                or not _ID_RE.match(normalized["s"])):
            return None
        return normalized
    except (ValueError, TypeError, KeyError, UnicodeDecodeError,
            json.JSONDecodeError, binascii.Error):
        return None


def _session_cursor_where(cursor):
    values = [cursor["p"], cursor["r"], cursor["m"],
              cursor["t"], cursor["a"], cursor["s"]]
    specs = [("pinned", "<"), ("rank", ">"), ("mtime", "<"),
             ("tool", ">"), ("account_id", ">"), ("session_id", ">")]
    clauses, params = [], []
    for i, (field, op) in enumerate(specs):
        equal = " AND ".join(f"{specs[j][0]}=?" for j in range(i))
        clauses.append(f"({equal + ' AND ' if equal else ''}{field}{op}?)")
        params.extend(values[:i])
        params.append(values[i])
    return "WHERE " + " OR ".join(clauses), params


def _query_session_index(query="", tool="all", limit=None, cursor=""):
    q = (query or "").strip().casefold()[:80]
    tool = tool if tool in ("claude", "codex") else "all"
    if limit is None:
        # 未升级的静态客户端搜索没有分页参数：保留尽可能完整的首批结果；
        # 原生 Swift 客户端始终显式传页大小。
        if q:
            limit = _SESSION_PAGE_MAX
        else:
            per_tool = get_settings()["sessions_limit"]
            limit = per_tool if tool != "all" else per_tool * 2
    try:
        limit = min(_SESSION_PAGE_MAX, max(1, int(limit)))
    except (TypeError, ValueError):
        limit = 30

    where, where_params = ["(source_present=1 OR pinned=1)", "title<>''"], []
    if tool != "all":
        where.append("tool=?")
        where_params.append(tool)
    terms = [part for part in q.split() if part]
    for term in terms:
        where.append("instr(search_text, ?) > 0")
        where_params.append(term)
    where_sql = " AND ".join(where)
    if q:
        rank_sql = ("CASE WHEN title_folded=? THEN 0 "
                    "WHEN instr(title_folded, ?)>0 THEN 1 "
                    "WHEN instr(project_folded, ?)>0 THEN 2 ELSE 3 END")
        rank_params = [q, q, q]
    else:
        rank_sql, rank_params = "0", []

    scope = _cursor_scope(q, tool)
    decoded = _decode_session_cursor(cursor, scope)
    cursor_sql, cursor_params = _session_cursor_where(decoded) if decoded else ("", [])
    conn = _session_db_connect()
    try:
        total = conn.execute(
            f"SELECT COUNT(*) FROM session_index WHERE {where_sql}",
            where_params).fetchone()[0]
        rows = conn.execute(f"""
            WITH matches AS (
                SELECT *, {rank_sql} AS rank
                FROM session_index WHERE {where_sql}
            )
            SELECT * FROM matches
            {cursor_sql}
            ORDER BY pinned DESC, rank ASC, mtime DESC,
                     tool ASC, account_id ASC, session_id ASC
            LIMIT ?
        """, rank_params + where_params + cursor_params + [limit + 1]).fetchall()
    finally:
        conn.close()
    has_more = len(rows) > limit
    page = rows[:limit]
    sessions = [{
        "tool": row["tool"], "id": row["session_id"], "title": row["title"],
        "cwd": row["cwd"], "project": row["project"], "branch": row["branch"],
        "mtime": row["mtime"], "size": row["size"], "account": row["account"],
        "account_id": row["account_id"], "pinned": bool(row["pinned"]),
    } for row in page]
    status = _session_status()
    return {
        "sessions": sessions, "ts": time.time(), "query": q, "tool": tool,
        "total": total, "has_more": has_more,
        "next_cursor": _encode_session_cursor(page[-1], scope) if has_more and page else None,
        # 仅首次无可用索引时要求前端轮询进度；已有快照的后台增量扫描不打扰 UI。
        "indexing": bool(status["indexing"] and not status["indexed_at"]),
        "indexed_at": status["indexed_at"],
        "index_progress": {
            "processed": status["processed_files"], "total": status["total_files"]},
        "index_error": status["error"] or None,
    }


def api_pin(body):
    sess = body.get("session") or {}
    tool = str(sess.get("tool") or "")
    sid = str(sess.get("id") or "")
    account_id = str(sess.get("account_id") or "default")[:120]
    if (tool not in ("claude", "codex") or not _ID_RE.match(sid)
            or not re.fullmatch(r"[a-z0-9-]{1,120}", account_id)):
        return {"ok": False, "error": "invalid id"}
    key = _pin_key(tool, account_id, sid)
    with _pins_lock:
        pins = _load_pins()
        if body.get("pinned"):
            pins[key] = {k: sess.get(k, "") for k in
                         ("tool", "id", "title", "cwd", "project", "branch",
                          "mtime", "account", "account_id")}
        else:
            pins.pop(key, None)
            # 兼容尚未迁移的 v2.1.3 以前单 id 键。
            pins.pop(sid, None)
        _save_pins(pins)
    with _session_index_write_lock:
        conn = _session_db_connect()
        try:
            _sync_pins_to_db(conn)
            conn.commit()
        finally:
            conn.close()
    return {"ok": True, "pinned": bool(body.get("pinned"))}


def api_sessions(query=None, tool="all", limit=None, cursor=""):
    _ensure_session_index_started()
    return _query_session_index(query, tool, limit, cursor)


# ----------------------------------------------------------------- 活跃会话

def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def _fmt_secs(s):
    """秒数 → 人话（与 _fmt_etime 同口径）"""
    s = max(0, int(s))
    if s >= 86400:
        return f"{s // 86400} 天 {s % 86400 // 3600}h"
    if s >= 3600:
        return f"{s // 3600}h {s % 3600 // 60}m"
    return f"{s // 60} 分钟"


def _fmt_etime(etime):
    """ps etime: [[dd-]hh:]mm:ss → 人话（旧版回退；前端按 runtime_secs 本地化）"""
    m = re.match(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$", etime.strip())
    if not m:
        return etime
    d, h, mi = int(m.group(1) or 0), int(m.group(2) or 0), int(m.group(3))
    if d:
        return f"{d} 天 {h}h"
    if h:
        return f"{h}h {mi}m"
    return f"{mi} 分钟"


def _etime_secs(etime):
    """ps etime → 总秒数（供前端按 locale 自行格式化运行时长）"""
    m = re.match(r"(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$", etime.strip())
    if not m:
        return 0
    d, h, mi, s = (int(m.group(1) or 0), int(m.group(2) or 0),
                   int(m.group(3)), int(m.group(4)))
    return ((d * 24 + h) * 60 + mi) * 60 + s


def _pid_cwd(pid):
    out = subprocess.run(["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
                         capture_output=True, text=True, timeout=8)
    for line in out.stdout.splitlines():
        if line.startswith("n"):
            return line[1:]
    return ""


def _pid_codex_rollout_info(pid):
    """Codex CLI 会长时间 resume 旧 rollout 文件；仅按文件名扫描最近 N 个会漏掉。
    直接读取该 pid 当前打开的 rollout-*.jsonl，并返回该会话的稳定身份。"""
    try:
        out = subprocess.run(["lsof", "-p", str(pid), "-Fn"],
                             capture_output=True, text=True, timeout=8).stdout
    except Exception:
        return None
    try:
        roots = [os.path.realpath(src["path"] / "sessions") + os.sep
                 for src in codex_sources()]
    except Exception:
        roots = []
    best = None
    for line in out.splitlines():
        if not line.startswith("n"):
            continue
        raw = line[1:]
        name = os.path.basename(raw)
        if not (name.startswith("rollout-") and name.endswith(".jsonl")):
            continue
        try:
            rp = os.path.realpath(raw)
        except (OSError, ValueError):
            continue
        if roots and not any(rp.startswith(r) for r in roots):
            continue
        try:
            mt = os.path.getmtime(rp)
        except OSError:
            continue
        meta = _rollout_meta(Path(rp))
        if meta.get("subagent"):
            continue
        if best is None or mt > best["mtime"]:
            fm = re.search(r"-([0-9a-f-]{36})[.]jsonl$", name)
            best = {"mtime": mt, "id": meta.get("id") or (fm.group(1) if fm else ""),
                    "cwd": meta.get("cwd") or ""}
    return best


def _iter_claude_pidfiles():
    """所有 Claude 源的 per-PID 索引文件（多账号合并）。"""
    for src in claude_sources():
        yield from (src["path"] / "sessions").glob("*.json")


def _norm_claude_status(s):
    """Claude pidfile 的 status 词表不止 busy/idle（实测还有 shell「正在跑命令」，
    可能有 tool 等其它工作子态）。除明确 idle 外，一切非空工作态一律归 busy——
    否则 shell 等会被当成「空闲」误显且 chip 失样。空值保持空，交给 transcript/CPU 兜底。"""
    if not s:
        return ""
    return "idle" if s == "idle" else "busy"


def _claude_tx_mtime(session_id):
    """该 claude 会话 transcript（projects/*/<sid>.jsonl）最近写入时间；缺失返回 0。
    用于 pidfile 不带 status 的 claude（如 Xcode 自带旧版）按写入活跃度判忙闲。"""
    if not session_id:
        return 0.0
    best = 0.0
    for src in claude_sources():
        for f in (src["path"] / "projects").glob(f"*/{session_id}.jsonl"):
            try:
                best = max(best, f.stat().st_mtime)
            except OSError:
                pass
    return best


def api_active():
    def build():
        active, claude_pids = [], {}
        # Claude: 官方 per-PID 索引文件，含 sessionId/cwd/status
        for f in _iter_claude_pidfiles():
            try:
                info = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            pid = info.get("pid")
            if not (pid and _pid_alive(pid) and info.get("kind") == "interactive"):
                continue
            claude_pids[int(pid)] = info

        ps = subprocess.run(["ps", "-axo", "pid=,ppid=,etime=,args="],
                            capture_output=True, text=True, timeout=10)
        ppid_of, rows, tool_pids = {}, [], set()
        for line in ps.stdout.splitlines():
            parts = line.strip().split(None, 3)
            if len(parts) < 4:
                continue
            pid, ppid, etime, args = parts
            try:
                pid_i, ppid_i = int(pid), int(ppid)
            except ValueError:
                continue
            ppid_of[pid_i] = ppid_i
            m = re.match(r"^(?:\S+/)?(claude|codex)(?:\s+(.*))?$", args)
            if not m or "app-server" in (m.group(2) or ""):
                continue
            rows.append((pid_i, m.group(1), etime))
            tool_pids.add(pid_i)

        def _spawned_by_agent(pid):
            # 沿父进程链上溯：祖先里有另一个 claude/codex ⇒ 这是 agent 自己拉起的子进程
            # （后台标题生成 `claude -p`、子代理等一闪而过的 headless 助手），非用户会话。
            seen, p = set(), ppid_of.get(pid)
            while p and p > 1 and p not in seen:
                seen.add(p)
                if p in tool_pids:
                    return True
                p = ppid_of.get(p)
            return False

        for pid_i, tool, etime in rows:
            if _spawned_by_agent(pid_i):
                continue
            entry = {"tool": tool, "pid": pid_i, "runtime": _fmt_etime(etime),
                     "runtime_secs": _etime_secs(etime),
                     "status": "", "id": "", "cwd": "", "project": ""}
            if tool == "claude":
                info = claude_pids.get(pid_i)
                if info:
                    entry.update(id=info.get("sessionId", ""),
                                 cwd=info.get("cwd", ""),
                                 status=_norm_claude_status(info.get("status", "")))
            if not entry["cwd"]:
                try:
                    entry["cwd"] = _pid_cwd(pid_i)
                except Exception:
                    pass
            entry["project"] = Path(entry["cwd"]).name if entry["cwd"] else "—"
            active.append(entry)

        # Codex 无官方状态索引：按其 rollout 文件最近写入时间推断 忙碌/空闲
        codex_entries = [e for e in active if e["tool"] == "codex" and not e["status"]]
        if codex_entries:
            now = time.time()
            cwd_mtime = {}
            for f in _iter_codex_files(15):
                c = _rollout_cwd(f)
                if c:
                    try:
                        cwd_mtime[c] = max(cwd_mtime.get(c, 0), f.stat().st_mtime)
                    except OSError:
                        pass
            for e in codex_entries:
                info = _pid_codex_rollout_info(e["pid"])
                if info:
                    e["id"] = info["id"] or e["id"]
                    e["cwd"] = e["cwd"] or info["cwd"]
                    e["project"] = Path(e["cwd"]).name if e["cwd"] else "—"
                    # 当前进程已明确打开某个 rollout 后，该文件的新旧就是该会话的
                    # 结论；不得再按 cwd 回退到同项目另一会话的最近写入时间。
                    e["status"] = "busy" if now - info["mtime"] < 30 else "idle"
                    continue
                # Codex 桌面端 rollout cwd 可能是进程 cwd 的子目录，前缀匹配
                cands = [mt for c, mt in cwd_mtime.items()
                         if c == e["cwd"] or c.startswith(e["cwd"] + "/")
                         or e["cwd"].startswith(c + "/")]
                if cands:
                    e["status"] = "busy" if now - max(cands) < 30 else "idle"

        # Claude 会话的 pidfile 未必带 status（Xcode 自带的旧版 claude 即如此）：
        # 按 transcript 最近写入活跃度判忙闲，与 Codex 同口径，远比 CPU 占用可靠。
        tnow = time.time()
        for e in active:
            if e["tool"] == "claude" and not e["status"] and e["id"]:
                mt = _claude_tx_mtime(e["id"])
                if mt:
                    e["status"] = "busy" if tnow - mt < 30 else "idle"

        # 仍无任何状态来源的会话（无 sessionId、也无 transcript）：末路兜底，按进程
        # CPU 占用粗判（对网络 I/O 密集的流式生成不准，仅作最后手段）
        unknown = [e for e in active if not e["status"]]
        if unknown:
            try:
                out = subprocess.run(
                    ["ps", "-o", "pid=,%cpu=",
                     "-p", ",".join(str(e["pid"]) for e in unknown)],
                    capture_output=True, text=True, timeout=5).stdout
                cpu = {}
                for ln in out.splitlines():
                    p = ln.split()
                    if len(p) == 2:
                        try:
                            cpu[int(p[0])] = float(p[1].replace(",", "."))
                        except ValueError:
                            pass
                for e in unknown:
                    if e["pid"] in cpu:
                        e["status"] = "busy" if cpu[e["pid"]] >= 5 else "idle"
            except Exception:
                pass

        # Codex 桌面端会话：宿主是常驻 app-server（被进程扫描排除），
        # 改按 rollout 近期写入 + originator == "Codex Desktop" 识别
        now = time.time()
        term_ids = {e["id"] for e in active if e["tool"] == "codex" and e["id"]}
        for f in _iter_codex_files(20):
            try:
                mt = f.stat().st_mtime
            except OSError:
                continue
            if now - mt > 600:        # 10 分钟内有写入才算「正在运行」
                continue
            meta = _rollout_meta(f)
            cwd = meta["cwd"]
            if meta.get("subagent") or meta["originator"] != "Codex Desktop":
                continue
            fm = re.match(r"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})"
                          r"-([0-9a-f-]{36})\.jsonl$", f.name)
            if not fm:
                continue
            sid = meta.get("id") or fm.group(2)
            if sid in term_ids:
                continue              # 同一 session 已由终端进程行覆盖
            try:
                start = time.mktime(time.strptime(fm.group(1), "%Y-%m-%dT%H-%M-%S"))
            except ValueError:
                start = mt
            active.append({"tool": "codex", "pid": 0, "host": "app",
                           "runtime": _fmt_secs(now - start),
                           "status": "busy" if now - mt < 30 else "idle",
                           "id": sid, "cwd": cwd,
                           "project": Path(cwd).name if cwd else "—"})

        active.sort(key=lambda a: (a["tool"], a["pid"]))
        return {"active": active, "ts": time.time()}
    return cached("active", 3, build)


_rollout_meta_cache = {}


def _rollout_meta(path):
    """rollout 文件 → 首个 session_meta（每文件恒定，永久缓存）。"""
    key = str(path)
    if key in _rollout_meta_cache:
        return _rollout_meta_cache[key]
    meta = {"cwd": "", "originator": "", "id": "", "subagent": False,
            "subagent_kind": "", "started_at": None}
    found = False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for _ in range(5):
                line = f.readline()
                if not line:
                    break
                try:
                    evt = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(evt, dict):
                    continue
                if evt.get("type") == "session_meta":
                    found = True
                    payload = evt.get("payload")
                    p = payload if isinstance(payload, dict) else {}
                    meta["cwd"] = p.get("cwd") or ""
                    meta["originator"] = p.get("originator") or ""
                    meta["id"] = p.get("id") or ""
                    source = p.get("source")
                    child = source.get("subagent") if isinstance(source, dict) else None
                    meta["subagent"] = isinstance(child, dict)
                    if isinstance(child, dict):
                        meta["subagent_kind"] = next(iter(child), "")
                    stamp = p.get("timestamp") or evt.get("timestamp")
                    if isinstance(stamp, str):
                        try:
                            meta["started_at"] = datetime.fromisoformat(
                                stamp.replace("Z", "+00:00")).timestamp()
                        except ValueError:
                            pass
                    break
    except OSError:
        pass
    # An active writer may not have completed the first JSON line yet. Empty
    # metadata must be retried instead of becoming a permanent false top-level hit.
    if found:
        _rollout_meta_cache[key] = meta
    return meta


def _rollout_cwd(path):
    return _rollout_meta(path)["cwd"]


# ----------------------------------------------------------------- 会话预览

def _collect_preview(path, codex=False):
    msgs = []
    # 截图等 base64 内容单行可达数百 KB，窗口给足 2MB 才能覆盖到文本消息
    for line in _tail_lines(path, 2_000_000):
        try:
            evt = json.loads(line)
        except ValueError:
            continue
        if not isinstance(evt, dict):
            continue
        role, text = "", ""
        if codex:
            payload = evt.get("payload")
            payload = payload if isinstance(payload, dict) else {}
            if payload.get("type") == "user_message":
                role, text = "user", _msg_text(payload.get("message"))
            elif payload.get("type") == "agent_message":
                role, text = "assistant", _msg_text(payload.get("message"))
            elif payload.get("role") in ("user", "assistant"):
                role, text = payload["role"], _msg_text(payload.get("content"))
        else:
            if evt.get("type") in ("user", "assistant") and not evt.get("isSidechain"):
                role = evt["type"]
                message = evt.get("message")
                text = _msg_text(message.get("content")) \
                    if isinstance(message, dict) else ""
        text = _clean_title(text or "")
        if role and text and not text.startswith(_SKIP_PREFIXES):
            msgs.append({"role": role, "text": text[:220]})
    return msgs[-4:]


def _session_index_path(tool, sid, account_id=""):
    conn = _session_db_connect()
    try:
        if account_id:
            row = conn.execute(
                "SELECT path FROM session_index WHERE tool=? AND account_id=? "
                "AND session_id=? AND source_present=1",
                (tool, account_id, sid)).fetchone()
        else:
            row = conn.execute(
                "SELECT path FROM session_index WHERE tool=? AND session_id=? "
                "AND source_present=1 ORDER BY mtime DESC LIMIT 1",
                (tool, sid)).fetchone()
        return Path(row["path"]) if row else None
    finally:
        conn.close()


def api_preview(query):
    tool = query.get("tool", [""])[0]
    sid = query.get("id", [""])[0]
    account_id = query.get("account_id", [""])[0][:120]
    if tool not in ("claude", "codex") or not _ID_RE.match(sid):
        return {"ok": False, "error": "invalid args"}
    indexed = _session_index_path(tool, sid, account_id)
    files = [indexed] if indexed and indexed.is_file() else []
    if not files:   # 索引初建/旧客户端兜底；正常路径不再全目录 glob
        sources = claude_sources() if tool == "claude" else codex_sources()
        pattern = f"*/{sid}.jsonl" if tool == "claude" else f"*/*/*/rollout-*{sid}.jsonl"
        folder = "projects" if tool == "claude" else "sessions"
        for src in sources:
            if account_id and src["id"] != account_id:
                continue
            files += list((src["path"] / folder).glob(pattern))
    if not files:
        return {"ok": False, "error": "transcript not found"}
    path = max(files, key=lambda p: p.stat().st_mtime)
    return {"ok": True, "messages": _collect_preview(path, codex=(tool == "codex"))}


# ------------------------------------------------- 会话完成事件（灵动岛提醒）

_events = deque(maxlen=50)
_events_lock = threading.Lock()
_events_file_lock = threading.Lock()
_event_seq = 0
_event_boot_id = uuid.uuid4().hex
EVENTS_FILE = DATA_DIR / "events.jsonl"
_event_keys = deque()
_event_key_set = set()
_EVENT_DEDUPE_MAX = 200


def _event_key(evt):
    """同一次会话完成的稳定身份。

    Claude Stop / Codex notify 在异常重试、旧 wrapper 链式转发或重复 hook 配置下，
    可能把同一完成事件 POST 多次。ts/duration 每次都会变，不能参与去重。
    """
    if evt.get("kind") == "alert":
        return None
    tool = evt.get("tool") or ""
    sid = evt.get("session") or ""
    cwd = evt.get("cwd") or ""
    title = evt.get("title") or ""
    if sid:
        return f"{tool}\0{sid}\0{cwd}\0{title}"
    if cwd or title:
        return f"{tool}\0{cwd}\0{title}"
    return None


def _remember_event_key(key):
    if not key or key in _event_key_set:
        return False
    _event_key_set.add(key)
    _event_keys.append(key)
    while len(_event_keys) > _EVENT_DEDUPE_MAX:
        old = _event_keys.popleft()
        _event_key_set.discard(old)
    return True


# ------------------------------------------------- 完成事件钩子：自动配置 / 干净移除
# 目标：装上即用、卸载即净。只「合并」不覆盖用户已有配置；只删「我们打了标记的那条」。
# 改动记录在 INTEGRATION_FILE，供 --remove-integration（build.sh uninstall 调）或关开关时还原。
INTEGRATION_FILE = DATA_DIR / "integration.json"
_integration_lock = threading.Lock()
_CLAUDE_SETTINGS = Path.home() / ".claude" / "settings.json"
_HOOK_WRAPPER = DATA_DIR / "claude-stop-hook.sh"   # 放 app-support：App 删了也在 → 可自清理
# 识别「我们装的」Stop 钩子：新版指向 wrapper；旧版是裸 curl（兼容迁移，一并清掉）
_HOOK_MARKS = ("claude-stop-hook.sh", "127.0.0.1:7777/api/event")
_HOOK_CMD = f'sh {json.dumps(str(_HOOK_WRAPPER))}'   # json.dumps 给路径加引号（含空格安全）

# 自清理 wrapper：转发完成事件给 daemon；若 App 已被拖进废纸篓（bundle 不在且 daemon 不在），
# 则自动从 ~/.claude/settings.json 摘掉本钩子并自删——drag-to-trash 卸载也能净。
_HOOK_WRAPPER_SH = '''#!/bin/sh
# AgentDeck Claude Stop hook（自动安装/自清理，勿手改）
APP="/Applications/AgentDeck.app"
SELF="__SELFDIR__"
BODY="$(cat)"
printf '%s' "$BODY" | curl -sf -m 3 -X POST http://127.0.0.1:7777/api/event \\
  -H 'Content-Type: application/json' --data-binary @- >/dev/null 2>&1 && exit 0
# POST 失败=daemon 没跑。仅当 App 也不在了（=已卸载，区别于「临时退出」）才自清理。
[ -d "$APP" ] && exit 0
python3 - "$HOME/.claude/settings.json" >/dev/null 2>&1 <<'PY'
import json,sys,os,tempfile
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: raise SystemExit
h=d.get("hooks") or {}; st=h.get("Stop")
if isinstance(st,list):
    kept=[g for g in st if not (isinstance(g,dict) and any(
        "claude-stop-hook.sh" in (x.get("command") or "") for x in (g.get("hooks") or [])))]
    if kept: h["Stop"]=kept
    else:
        h.pop("Stop",None)
        if not h: d.pop("hooks",None)
    fd,tmp=tempfile.mkstemp(prefix='.settings.json.',dir=os.path.dirname(p))
    with os.fdopen(fd,'w') as f:
        json.dump(d,f,ensure_ascii=False,indent=2); f.flush(); os.fsync(f.fileno())
    os.replace(tmp,p)
PY
rm -f "$SELF/claude-stop-hook.sh" "$SELF/integration.json" 2>/dev/null
exit 0
'''


def _integration_state():
    try:
        return json.loads(INTEGRATION_FILE.read_text())
    except (OSError, ValueError):
        return {}


def _integration_state_save(st):
    try:
        _atomic_write_text(INTEGRATION_FILE,
                           json.dumps(st, ensure_ascii=False, indent=2))
    except OSError:
        pass


def _hook_is_ours(grp):
    if not isinstance(grp, dict):
        return False
    return any(any(m in (h.get("command") or "") for m in _HOOK_MARKS)
               for h in (grp.get("hooks") or []))


def _write_hook_wrapper():
    try:
        _atomic_write_text(_HOOK_WRAPPER,
                           _HOOK_WRAPPER_SH.replace("__SELFDIR__", str(DATA_DIR)),
                           mode=0o755)
        return True
    except OSError:
        return False


def _hook_wrapper_is_current():
    try:
        expected = _HOOK_WRAPPER_SH.replace("__SELFDIR__", str(DATA_DIR))
        return _HOOK_WRAPPER.read_text() == expected
    except OSError:
        return False


def _install_claude_hook():
    """幂等：写自清理 wrapper + 把指向它的 Stop 钩子合并进 settings.json（不覆盖用户其它钩子）。
    已配置正确则完全跳过（不重写 settings.json）。返回是否发生了改动。"""
    try:
        d = json.loads(_CLAUDE_SETTINGS.read_text()) if _CLAUDE_SETTINGS.exists() else {}
    except (OSError, ValueError):
        return False
    if not isinstance(d, dict):
        return False
    hooks = d.get("hooks")
    stop = hooks.get("Stop") if isinstance(hooks, dict) else None
    ours = [g for g in stop if _hook_is_ours(g)] if isinstance(stop, list) else []
    already = (len(ours) == 1 and _hook_wrapper_is_current()
               and (ours[0].get("hooks") or [{}])[0].get("command") == _HOOK_CMD)
    if already:
        return False
    if not _write_hook_wrapper():
        return False
    hooks = d.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        return False
    stop = hooks.setdefault("Stop", [])
    if not isinstance(stop, list):
        return False
    # 先剔除我们的旧条目（裸 curl 旧版 / 重复），再装当前 wrapper 版——保证幂等且单条
    stop[:] = [g for g in stop if not _hook_is_ours(g)]
    stop.append({"hooks": [{"type": "command", "command": _HOOK_CMD, "timeout": 5}]})
    try:
        _atomic_write_text(_CLAUDE_SETTINGS,
                           json.dumps(d, ensure_ascii=False, indent=2))
        return True
    except OSError:
        return False


def _remove_claude_hook():
    """只移除我们打了标记的 Stop 钩子（新/旧版都认）；用户自己的钩子原样保留。"""
    try:
        d = json.loads(_CLAUDE_SETTINGS.read_text())
    except (OSError, ValueError):
        return
    hooks = d.get("hooks") if isinstance(d, dict) else None
    stop = hooks.get("Stop") if isinstance(hooks, dict) else None
    if not isinstance(stop, list):
        return
    kept = [g for g in stop if not _hook_is_ours(g)]
    if len(kept) == len(stop):
        return
    if kept:
        hooks["Stop"] = kept
    else:
        hooks.pop("Stop", None)
        if not hooks:
            d.pop("hooks", None)
    try:
        _atomic_write_text(_CLAUDE_SETTINGS,
                           json.dumps(d, ensure_ascii=False, indent=2))
    except OSError:
        pass


# ---- Codex notify（单槽，可能被 Computer Use 等占用 → 链式转发，不破坏原工具）----
_CODEX_CONFIG = Path.home() / ".codex" / "config.toml"
_CODEX_HOOKS = Path.home() / ".codex" / "hooks.json"
_CODEX_WRAPPER = DATA_DIR / "codex-notify.sh"
_CODEX_LEGACY_STOP_WRAPPER = DATA_DIR / "codex-stop-hook.sh"
_CODEX_LEGACY_REPO_STOP_WRAPPER = Path(__file__).resolve().parent / "scripts" / "codex-stop-hook.sh"
_CODEX_MARK = "codex-notify.sh"
_CODEX_OUR_MARKS = (_CODEX_MARK, "127.0.0.1:7777/api/event")
_CODEX_LEGACY_STOP_MARK = str(_CODEX_LEGACY_STOP_WRAPPER)


def _codex_read_notify(text):
    """从 config.toml 文本里取 notify 数组（优先 tomllib，回退正则单行）。"""
    try:
        import tomllib
        v = tomllib.loads(text).get("notify")
        return v if isinstance(v, list) else None
    except Exception:
        # notify 是根键；只检查首个 TOML table 之前，避免误改 [profiles.*].notify。
        table = re.search(r'^[ \t]*\[', text, re.M)
        root = text[:table.start()] if table else text
        m = re.search(r'^[ \t]*notify[ \t]*=[ \t]*(\[.*\])[ \t]*$', root, re.M)
        if not m:
            return None
        try:
            return json.loads(m.group(1))   # TOML 单行数组与 JSON 数组语法兼容（双引号字符串）
        except ValueError:
            return None


def _codex_set_notify(text, arr):
    """把 config.toml 文本里的 notify 行替换/插入为 arr（仅动 notify 单行，其余原样）。
    arr=None 表示删除 notify 行。返回新文本。用 [ \t]* 避免误吃上一空行。"""
    line = None if arr is None else "notify = " + json.dumps(arr, ensure_ascii=False)
    table = re.search(r'^[ \t]*\[', text, re.M)
    cut = table.start() if table else len(text)
    root, rest = text[:cut], text[cut:]
    if re.search(r'^[ \t]*notify[ \t]*=', root, re.M):
        if line is None:
            root = re.sub(r'^[ \t]*notify[ \t]*=.*\n?', '', root, count=1, flags=re.M)
        else:
            root = re.sub(r'^[ \t]*notify[ \t]*=.*$', line, root, count=1, flags=re.M)
        return root + rest
    if not line:
        return text
    separator = "" if not root or root.endswith("\n") else "\n"
    return root + separator + line + "\n" + rest


def _codex_notify_is_ours(arr):
    """识别 AgentDeck 自己的 Codex notify（新版 App Support wrapper 或旧仓库脚本）。

    旧版用户可能已手动把 notify 指到 scripts/codex-notify.sh。自动安装新版 wrapper
    时若把旧脚本当成“原 notify”链式转发，会造成同一完成事件 POST 两次。
    """
    if not isinstance(arr, list):
        return False
    joined = " ".join(str(x) for x in arr)
    return any(mark in joined for mark in _CODEX_OUR_MARKS)


def _codex_notify_direct_is_ours(arr):
    if not isinstance(arr, list) or not arr:
        return False
    command = str(arr[0])
    return any(mark in command for mark in _CODEX_OUR_MARKS)


def _codex_notify_without_ours(arr):
    """Remove AgentDeck from an external --previous-notify chain."""
    if not isinstance(arr, list):
        return arr
    if _codex_notify_direct_is_ours(arr):
        return None
    out, i = list(arr), 0
    while i < len(out):
        if out[i] != "--previous-notify" or i + 1 >= len(out):
            i += 1
            continue
        try:
            nested = json.loads(out[i + 1])
        except (TypeError, ValueError):
            i += 2
            continue
        cleaned = _codex_notify_without_ours(nested)
        if cleaned is None:
            del out[i:i + 2]
        else:
            out[i + 1] = json.dumps(cleaned, ensure_ascii=False)
            i += 2
    return out


def _write_codex_wrapper(restore_notify, forward_notify=None):
    """Generate wrapper with separate forwarding and uninstall restoration targets."""
    fwd = (" ".join(shlex.quote(x) for x in forward_notify) + ' "$@"') \
        if forward_notify else 'true'
    restore = json.dumps(restore_notify, ensure_ascii=False) \
        if restore_notify is not None else "null"
    sh = f'''#!/bin/sh
# AgentDeck Codex notify wrapper（自动安装/链式转发/自清理，勿手改）
APP="/Applications/AgentDeck.app"
SELF={shlex.quote(str(DATA_DIR))}
curl -sf -m 3 -X POST http://127.0.0.1:7777/api/event \\
  -H 'Content-Type: application/json' --data-binary "$1" >/dev/null 2>&1
{fwd}   # 链式转发回原 notify（如 Computer Use）
[ -d "$APP" ] && exit 0
# App 已卸载 → 还原 config.toml 的 notify、删 wrapper（drag-trash 也能净；不破坏原工具）
python3 - "$HOME/.codex/config.toml" >/dev/null 2>&1 <<'PY'
import re,sys,json,os,tempfile
p=sys.argv[1]
try: t=open(p).read()
except Exception: raise SystemExit
orig={restore}
line=None if orig is None else "notify = "+json.dumps(orig,ensure_ascii=False)
table=re.search(r'^[ \\t]*\\[',t,re.M); cut=table.start() if table else len(t)
root,rest=t[:cut],t[cut:]
if re.search(r'^[ \\t]*notify[ \\t]*=',root,re.M):
    root=re.sub(r'^[ \\t]*notify[ \\t]*=.*\\n?','',root,count=1,flags=re.M) if line is None else re.sub(r'^[ \\t]*notify[ \\t]*=.*$',line,root,count=1,flags=re.M)
t=root+rest
fd,tmp=tempfile.mkstemp(prefix='.config.toml.',dir=os.path.dirname(p))
with os.fdopen(fd,'w') as f: f.write(t); f.flush(); os.fsync(f.fileno())
os.replace(tmp,p)
PY
rm -f "$SELF/codex-notify.sh"
exit 0
'''
    try:
        _atomic_write_text(_CODEX_WRAPPER, sh, mode=0o755)
        return True
    except OSError:
        return False


def _install_codex_notify():
    """幂等：备份原 notify → 写转发 wrapper → 把 notify 指向 wrapper（不破坏原工具）。返回是否改动。"""
    if not _CODEX_CONFIG.exists():
        return False   # 没装 Codex 就不动
    try:
        text = _CODEX_CONFIG.read_text()
    except OSError:
        return False
    cur = _codex_read_notify(text)
    wrapper = str(_CODEX_WRAPPER)
    st = _integration_state()
    prev = st.get("codex_prev_notify")

    if _codex_notify_is_ours(prev):
        prev = _codex_notify_without_ours(prev)
        st["codex_prev_notify"] = prev
        _integration_state_save(st)

    # Computer Use 等外部 owner 可能已把 AgentDeck 放进自己的 previous-notify。
    # 此时保留外部 owner 为根，AgentDeck wrapper 不再反向调用 owner，彻底断开环。
    if (_codex_notify_is_ours(cur) and not _codex_notify_direct_is_ours(cur)):
        cleaned = _codex_notify_without_ours(cur)
        st["codex_prev_notify"] = cleaned
        _integration_state_save(st)
        return _write_codex_wrapper(cleaned, forward_notify=None)

    # AgentDeck 自己持有根槽时，wrapper 在 POST 后顺序调用原外部 notify。
    if not _codex_notify_direct_is_ours(cur):
        st["codex_prev_notify"] = cur
        _integration_state_save(st)
    prev = st.get("codex_prev_notify")
    if not _write_codex_wrapper(prev, forward_notify=prev):
        return False
    try:
        updated = _codex_set_notify(text, [wrapper])
        if updated == text:
            return False
        _atomic_write_text(_CODEX_CONFIG, updated)
        return True
    except OSError:
        return False


def _remove_codex_notify():
    """还原 config.toml 的 notify 为原值（备份里取），删 wrapper。"""
    st = _integration_state()
    if _CODEX_CONFIG.exists():
        try:
            text = _CODEX_CONFIG.read_text()
            cur = _codex_read_notify(text)
            if _codex_notify_direct_is_ours(cur):
                updated = _codex_set_notify(text, st.get("codex_prev_notify"))
                _atomic_write_text(_CODEX_CONFIG, updated)
            elif _codex_notify_is_ours(cur):
                # 外部 owner 的链中只摘掉 AgentDeck，保留 owner 及其它 previous notify。
                updated = _codex_set_notify(text, _codex_notify_without_ours(cur))
                _atomic_write_text(_CODEX_CONFIG, updated)
        except OSError:
            pass
    try:
        _CODEX_WRAPPER.unlink()
    except OSError:
        pass


def _codex_legacy_stop_entry_is_ours(entry):
    if not isinstance(entry, dict):
        return False
    cmd = entry.get("command") or ""
    expanded = os.path.expandvars(os.path.expanduser(cmd))
    marks = (
        _CODEX_LEGACY_STOP_MARK,
        shlex.quote(_CODEX_LEGACY_STOP_MARK),
        str(_CODEX_LEGACY_REPO_STOP_WRAPPER),
        shlex.quote(str(_CODEX_LEGACY_REPO_STOP_WRAPPER)),
    )
    return any(mark in expanded for mark in marks)


def _remove_legacy_codex_stop_hook():
    """清理旧版迁移留下的 Codex Stop hook。

    Codex 完成事件的正式入口是 notify wrapper；Stop hook 输入和 Claude Stop 形似，
    同时启用会让同一 Codex turn 先被误归属成 Claude，再由 notify 归属成 Codex。
    """
    try:
        d = json.loads(_CODEX_HOOKS.read_text())
    except (OSError, ValueError):
        d = None
    if isinstance(d, dict):
        hooks = d.get("hooks") if isinstance(d.get("hooks"), dict) else None
        stop = hooks.get("Stop") if isinstance(hooks, dict) else None
        if isinstance(stop, list):
            kept = []
            changed = False
            for grp in stop:
                if not isinstance(grp, dict) or not isinstance(grp.get("hooks"), list):
                    kept.append(grp)
                    continue
                entries = [h for h in grp["hooks"] if not _codex_legacy_stop_entry_is_ours(h)]
                if len(entries) == len(grp["hooks"]):
                    kept.append(grp)
                    continue
                changed = True
                if entries:
                    new_grp = dict(grp)
                    new_grp["hooks"] = entries
                    kept.append(new_grp)
            if changed:
                if kept:
                    hooks["Stop"] = kept
                else:
                    hooks.pop("Stop", None)
                    if not hooks:
                        d.pop("hooks", None)
                try:
                    _atomic_write_text(_CODEX_HOOKS,
                                       json.dumps(d, ensure_ascii=False, indent=2) + "\n")
                except OSError:
                    pass
    try:
        _CODEX_LEGACY_STOP_WRAPPER.unlink()
    except OSError:
        pass


def install_integration():
    """启动时调用（幂等）：自动接好完成事件钩子（Claude Stop + Codex notify 链式转发）。
    每步各自重读 state 再加标记，避免覆盖 _install_codex_notify 写入的原值备份。"""
    with _integration_lock:
        _remove_legacy_codex_stop_hook()
        if _install_claude_hook():
            st = _integration_state(); st["claude_hook"] = True; _integration_state_save(st)
        if _install_codex_notify():
            st = _integration_state(); st["codex_notify"] = True; _integration_state_save(st)


def remove_integration():
    """卸载 / 关开关时调用：还原我们的所有改动。"""
    with _integration_lock:
        _remove_claude_hook()
        _remove_codex_notify()
        _remove_legacy_codex_stop_hook()
        for f in (_HOOK_WRAPPER, INTEGRATION_FILE):
            try:
                f.unlink()
            except OSError:
                pass


def _events_load():
    """启动时回灌最近事件（重启后「最近完成」不清零）。"""
    global _event_seq
    try:
        lines = EVENTS_FILE.read_text().splitlines()[-50:]
    except OSError:
        return
    with _events_lock:
        for line in lines:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            _event_seq += 1
            e["id"] = _event_seq
            e["replayed"] = True   # 回灌仅供「最近完成」卡；不得再次触发灵动岛
            _remember_event_key(_event_key(e))
            _events.append(e)


def _events_persist(evt):
    with _events_file_lock:
        try:
            EVENTS_FILE.parent.mkdir(exist_ok=True)
            with open(EVENTS_FILE, "a", encoding="utf-8") as f:
                f.write(json.dumps(evt, ensure_ascii=False) + "\n")
            if EVENTS_FILE.stat().st_size > 256 * 1024:    # 防膨胀：超限保尾部
                tail = EVENTS_FILE.read_text().splitlines()[-100:]
                _atomic_write_text(EVENTS_FILE, "\n".join(tail) + "\n")
        except OSError:
            pass


def _last_user_msg(transcript_path, sid="", cwd=""):
    """返回 (时间戳, 文本)——最后一条真实用户消息，用于算任务时长和提醒文案。"""
    want_cwd = None
    if cwd:
        try:
            want_cwd = os.path.realpath(os.path.expanduser(cwd))
        except (OSError, ValueError):
            want_cwd = None
    try:
        for line in reversed(_tail_lines(Path(transcript_path), 2_000_000)):
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            if sid and evt.get("sessionId") != sid:
                continue
            if evt.get("type") != "user" or evt.get("isSidechain"):
                continue
            got_cwd = evt.get("cwd")
            if want_cwd:
                if not got_cwd:
                    continue
                try:
                    if os.path.realpath(os.path.expanduser(got_cwd)) != want_cwd:
                        continue
                except (OSError, ValueError):
                    continue
            text = _msg_text((evt.get("message") or {}).get("content"))
            if not text or text.lstrip().startswith(_SKIP_PREFIXES):
                continue
            ts = evt.get("timestamp", "")
            try:
                t = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
            except ValueError:
                t = None
            return t, _clean_title(text)
    except OSError:
        pass
    return None, ""


def _claude_transcript_matches(tp, sid, cwd):
    if not sid:
        return False
    try:
        want_cwd = os.path.realpath(os.path.expanduser(cwd))
    except (OSError, ValueError):
        return False
    try:
        with open(tp, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    evt = json.loads(line)
                except ValueError:
                    continue
                if evt.get("sessionId") != sid:
                    continue
                if evt.get("type") != "user" or evt.get("isSidechain"):
                    continue
                got_cwd = evt.get("cwd")
                if not got_cwd:
                    continue
                try:
                    if os.path.realpath(os.path.expanduser(got_cwd)) == want_cwd:
                        return True
                except (OSError, ValueError):
                    continue
    except OSError:
        pass
    return False


def _valid_claude_transcript_path(raw_path, sid="", cwd=""):
    """只接受真实 Claude transcript，避免 Codex Stop hook 形似输入串成 Claude 事件。"""
    if not raw_path or not sid or not cwd:
        return None
    try:
        tp = os.path.realpath(os.path.expanduser(raw_path))
    except (OSError, ValueError):
        return None
    roots = [os.path.realpath(src["path"]) + os.sep for src in claude_sources()]
    if any(tp.startswith(r) for r in roots) and os.path.isfile(tp) and Path(tp).stem == sid:
        return tp if _claude_transcript_matches(tp, sid, cwd) else None
    return None


_TEMP_ROOTS = tuple(sorted({
    os.path.realpath(b) for b in (tempfile.gettempdir(), "/tmp", "/private/tmp", "/var/folders")
}))


def _is_temp_cwd(cwd):
    """cwd 落在系统临时目录（$TMPDIR=/var/folders/.../T、/tmp …）→ 非交互的一次性子调用
    （headless / 子 agent），其完成提醒是噪音：项目名被解析成 'T'、标题为空。一律跳过。"""
    if not cwd:
        return False
    try:
        rp = os.path.realpath(os.path.expanduser(cwd))
    except (OSError, ValueError):
        return False
    return any(rp == r or rp.startswith(r + os.sep) for r in _TEMP_ROOTS)


def api_event(body):
    """接收 Claude Stop hook / Codex notify 包装脚本推来的完成事件。"""
    s = get_settings()
    if not s["notify_session_done"]:
        return {"ok": True, "skipped": "disabled"}
    tool, title, project, duration = None, "", "", None

    sid = ""
    cwd = ""
    if body.get("hook_event_name") == "Stop":
        if body.get("stop_hook_active"):       # hook 续跑回环，忽略
            return {"ok": True, "skipped": "loop"}
        tool = "claude"
        sid = body.get("session_id") or ""
        cwd = body.get("cwd") or ""
        project = Path(cwd).name if cwd else ""
        # 外部输入→文件读取的唯一路径：限定在已发现的 Claude 配置目录内，防任意文件读取
        tp = _valid_claude_transcript_path(body.get("transcript_path") or "", sid, cwd)
        if not tp:
            return {"ok": True, "skipped": "invalid_claude_transcript"}
        t, text = _last_user_msg(tp, sid, cwd)
        title = _clean_title(text)[:60]
        if t:
            duration = time.time() - t
        if duration is not None and duration < s["notify_done_min_secs"]:
            return {"ok": True, "skipped": "short"}
    elif body.get("type") == "agent-turn-complete":
        tool = "codex"
        sid = body.get("thread-id") or body.get("thread_id") or ""
        cwd = body.get("cwd") or ""
        project = Path(cwd).name if cwd else ""
        msgs = body.get("input_messages") or body.get("input-messages") or []
        if isinstance(msgs, list):
            msgs = " ".join(str(m) for m in msgs)
        title = _clean_title(str(msgs))[:60]
    else:
        return {"ok": False, "error": "unknown event"}

    # 临时目录里的会话（cwd=/var/folders/.../T 等）是 headless/子 agent 一次性调用，
    # 完成提醒纯噪音（弹丸头显示成 'T'、标题空），直接丢弃不入队。
    if _is_temp_cwd(cwd):
        return {"ok": True, "skipped": "temp_cwd"}

    global _event_seq
    # 空标题存为 ""，由前端 / Swift 壳按当前语言本地化「任务完成」回退
    evt = {"tool": tool, "session": sid, "cwd": cwd,
           "title": title or "", "project": project,
           "duration": round(duration or 0), "ts": time.time()}
    with _events_lock:
        if not _remember_event_key(_event_key(evt)):
            return {"ok": True, "skipped": "duplicate"}
        _event_seq += 1
        _events.append({"id": _event_seq, **evt})
    _events_persist(evt)
    _request_session_index_scan()   # 完成事件意味着对应 transcript 刚更新，尽快刷新索引 mtime
    return {"ok": True, "queued": _event_seq}


def api_events(query):
    with _events_lock:
        recent = int(query.get("recent", ["0"])[0])
        if recent:        # 「最近完成」卡：取末尾 N 条（新→旧）；排除额度告警事件（kind=alert）
            done = [e for e in _events if e.get("kind") != "alert"]
            return {"events": done[-recent:][::-1], "last": _event_seq,
                    "boot_id": _event_boot_id}
        since = int(query.get("since", ["0"])[0])
        # 灵动岛通道：排除重启回灌的历史事件，只推真正新发生的
        evs = [e for e in _events if e["id"] > since and not e.get("replayed")]
        # locale 随该通道下发给 Swift 壳（菜单 / 灵动岛 / 通知本地化）
        return {"events": evs, "last": _event_seq, "boot_id": _event_boot_id,
                "island_secs": get_settings()["island_dwell_secs"],
                "locale": _effective_locale()}


# ------------------------------------------------- 跳转会话所在终端

_TERM_APPS = {   # 兜底清单：仅用于个别非 .app 启动 / 进程名无法定位 bundle 的终端
    "iTerm2": "iTerm", "Terminal": "Terminal", "WezTerm": "WezTerm",
    "wezterm-gui": "WezTerm", "kitty": "kitty", "alacritty": "Alacritty",
    "Ghostty": "Ghostty", "Warp": "Warp", "cmux": "cmux",
    "Tabby": "Tabby", "Hyper": "Hyper", "rio": "Rio",
    "Code Helper": "Visual Studio Code", "Electron": "Visual Studio Code",
    "Cursor Helper": "Cursor",
    "node_repl": "Codex", "Codex": "Codex",   # Codex 桌面端内置会话
}


def _find_claude_pid(sid):
    for f in _iter_claude_pidfiles():
        try:
            info = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        if info.get("sessionId") == sid and _pid_alive(info.get("pid", 0)):
            return int(info["pid"])
    return None


def _find_codex_pid(cwd):
    ps = subprocess.run(["ps", "-axo", "pid=,args="],
                        capture_output=True, text=True, timeout=10)
    for line in ps.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, args = parts
        if re.match(r"^(?:\S+/)?codex(?:\s|$)", args) and "app-server" not in args:
            try:
                if not cwd or _pid_cwd(int(pid)) == cwd:
                    return int(pid)
            except Exception:
                continue
    return None


def _pid_tty(pid):
    out = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)],
                         capture_output=True, text=True, timeout=8)
    t = out.stdout.strip()
    return f"/dev/{t}" if t and t != "??" else None


def _osa(script):
    r = subprocess.run(["osascript", "-e", script],
                       capture_output=True, text=True, timeout=12)
    return r.stdout.strip()


def _app_running(app):
    """App 是否在运行（不会启动它）——用于按 tty 兜底前的存在性检查。"""
    return _osa('tell application "System Events" to '
                f'(name of processes) contains "{app}"') == "true"


def _focus_iterm(tty):
    ok = _osa(f'''
tell application "iTerm"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if tty of s is "{tty}" then
          select s
          select t
          set index of w to 1
          activate
          return "ok"
        end if
      end repeat
    end repeat
  end repeat
end tell
return "miss"''')
    return ok == "ok"


def _focus_terminal(tty):
    ok = _osa(f'''
tell application "Terminal"
  repeat with w in windows
    repeat with t in tabs of w
      if tty of t is "{tty}" then
        set selected of t to true
        set index of w to 1
        activate
        return "ok"
      end if
    end repeat
  end repeat
end tell
return "miss"''')
    return ok == "ok"


def _focus_ghostty(cwd):
    """Ghostty 有 AppleScript 字典：按 working directory 聚焦具体 terminal。"""
    if not (cwd and Path("/Applications/Ghostty.app").exists()):
        return False
    out = _osa(f'''
tell application "Ghostty"
  set matches to every terminal whose working directory contains "{_osa_escape(cwd)}"
  if (count of matches) > 0 then
    focus (item 1 of matches)
    activate
    return "ok"
  end if
end tell
return "miss"''')
    return out == "ok"


# 不是宿主终端的 .app：框架内置解释器壳、AgentDeck 自身等，识别到则继续向上找
_APP_SKIP = {"Python", "python3", "AgentDeck"}


def _ancestor_app(pid):
    """沿父进程链向上自动识别宿主终端，返回 (App 名, bundle 路径)；找不到 → (None, None)。

    macOS 上 `ps -o comm=` 给出可执行文件完整路径；GUI 终端的可执行文件必落在某个
    .app bundle 内，取最外层的 .app 即宿主（VS Code 集成终端的 Code Helper 仍归到
    Visual Studio Code）。关键防线：**跳过 .framework 内置的 .app**——macOS 的
    Python.framework 内含 Python.app，不跳过会把解释器误判成宿主、再 activate 挂起；
    同理跳过 AgentDeck 自身。少数非 .app 启动的终端按 _TERM_APPS 进程名前缀兜底。"""
    for _ in range(20):
        out = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=8)
        parts = out.stdout.strip().split(None, 1)
        if len(parts) < 2:
            return None, None
        ppid, comm = parts
        # 框架内置二进制（Python.framework 等）不是 GUI 宿主，整跳过该进程往上找
        if ".framework/" not in comm:
            m = re.search(r"/([^/]+)\.app/", comm)
            if m and m.group(1) not in _APP_SKIP:
                bundle = comm[:comm.index("/" + m.group(1) + ".app/")
                               + len(m.group(1)) + 5]   # …/<Name>.app
                return m.group(1), bundle
        # 兜底：极少数非 .app 启动的终端，按进程名前缀匹配已知清单
        base = os.path.basename(comm).lower()
        for key, app in _TERM_APPS.items():
            if base.startswith(key.lower()):
                return app, None
        try:
            pid = int(ppid)
        except ValueError:
            return None, None
        if pid <= 1:
            return None, None
    return None, None


def _codex_thread_for_cwd(cwd):
    """进程 cwd → 最近写入的 rollout 线程 id（文件名末尾 UUID）。"""
    if not cwd:
        return ""
    best, best_mt = "", 0
    for f in _iter_codex_files(30):
        c = _rollout_cwd(f)
        if not (c and (c == cwd or c.startswith(cwd + "/")
                       or cwd.startswith(c + "/"))):
            continue
        try:
            mt = f.stat().st_mtime
        except OSError:
            continue
        if mt > best_mt:
            m = re.search(r"-([0-9a-f-]{36})\.jsonl$", f.name)
            if m:
                best, best_mt = m.group(1), mt
    return best


def api_focus(body):
    tool = body.get("tool")
    sid = body.get("session") or body.get("id") or ""
    cwd = body.get("cwd") or ""
    pid = None
    # 调用方已知进程 PID（如活跃会话卡片）可直接传入，免去反查
    raw_pid = body.get("pid")
    if isinstance(raw_pid, int) and raw_pid > 0 and _pid_alive(raw_pid):
        pid = raw_pid
    elif tool == "claude" and _ID_RE.match(sid):
        pid = _find_claude_pid(sid)
    elif tool == "codex":
        pid = _find_codex_pid(cwd)
    if not pid:
        # Codex 桌面端线程无独立可寻进程，直接深链（App 未启动 open 也会拉起）
        if tool == "codex" and _ID_RE.match(sid):
            subprocess.run(["open", f"codex://threads/{sid}"], timeout=10)
            return {"ok": True, "via": "codex-thread", "thread": sid}
        return {"ok": False, "error": "session process not found"}
    if not cwd:
        try:
            cwd = _pid_cwd(pid)
        except Exception:
            pass
    # Codex 桌面端会话：不走终端启发式，deep link 直达线程，App 激活兜底
    if tool == "codex" and _ancestor_app(pid)[0] == "Codex":
        tid = sid if _ID_RE.match(sid) else _codex_thread_for_cwd(cwd)
        if tid:
            subprocess.run(["open", f"codex://threads/{tid}"], timeout=10)
        _osa('tell application "Codex" to activate')
        return {"ok": True, "via": "codex-thread" if tid else "app",
                "thread": tid, "app": "Codex"}
    tty = _pid_tty(pid)
    host, host_bundle = _ancestor_app(pid)   # 自动识别宿主终端
    # 宿主已知：只对真正的宿主做精确聚焦 / 激活，绝不 tell 其它终端（否则会把
    # 未运行的 Terminal / iTerm 误启动——正是「跳 Warp 却打开 Terminal」的根因）
    if host:
        try:
            if host == "iTerm" and tty and _focus_iterm(tty):
                return {"ok": True, "via": "tty", "app": "iTerm", "tty": tty}
            if host == "Terminal" and tty and _focus_terminal(tty):
                return {"ok": True, "via": "tty", "app": "Terminal", "tty": tty}
            if host == "Ghostty" and _focus_ghostty(cwd):
                return {"ok": True, "via": "ghostty-cwd", "app": "Ghostty"}
        except Exception:
            pass
        # 通用激活：优先 open <bundle 路径>（命中已运行实例、绝不挂起）；
        # 无 bundle 路径（进程名兜底）时退回按名 activate
        if host_bundle:
            subprocess.run(["open", host_bundle], capture_output=True, timeout=10)
        else:
            _osa(f'tell application "{host}" to activate')
        return {"ok": True, "via": "app", "app": host}
    # 宿主识别失败（tmux / ssh / 无 .app 祖先）：仅对“已在运行”的 iTerm / Terminal
    # 按 tty 兜底，避免凭空启动它们
    if tty:
        try:
            if _app_running("iTerm") and _focus_iterm(tty):
                return {"ok": True, "via": "tty", "app": "iTerm", "tty": tty}
            if _app_running("Terminal") and _focus_terminal(tty):
                return {"ok": True, "via": "tty", "app": "Terminal", "tty": tty}
        except Exception:
            pass
    return {"ok": False, "error": "terminal not located"}


# ------------------------------------------------- 额度采样 / 告警 / 历史曲线

_alert_state = {}   # (tool, account_id, window_id) -> "normal" | "warn" | "crit"
ALERT_STATE_FILE = DATA_DIR / "alert_state.json"


def _alert_state_load():
    """告警状态跨重启持久化：同一次越阈只通知一次，重启不重发。"""
    try:
        for k, v in json.loads(ALERT_STATE_FILE.read_text()).items():
            parts = k.split("|", 2)
            if len(parts) == 2:   # v2.1.2 及更早：仅主账号
                tool, win = parts
                account = "default"
            elif len(parts) == 3:
                tool, account, win = parts
            else:
                continue
            _alert_state[(tool, account, win)] = v
    except (OSError, ValueError):
        pass


def _alert_state_save():
    try:
        _atomic_write_text(ALERT_STATE_FILE, json.dumps(
            {f"{t}|{a}|{w}": v for (t, a, w), v in _alert_state.items()}))
    except OSError:
        pass


def _push_alert(tool, msg, level, sound=False):
    """额度告警走事件流（壳层用灵动岛弹丸统一渲染），不再用 osascript 系统通知。
    kind=alert 标记：「最近完成」卡过滤掉，灵动岛通道照常推送。"""
    global _event_seq
    # tool 存小写（与会话完成事件一致）→ 壳层 appIcon 选对 Claude/Codex 图标；msg 里仍是显示名
    evt = {"tool": (tool or "").lower(), "kind": "alert", "level": level, "title": msg,
           "session": "", "cwd": "", "project": "", "sound": bool(sound), "ts": time.time()}
    with _events_lock:
        _event_seq += 1
        _events.append({"id": _event_seq, **evt})
    _events_persist(evt)


def _check_alerts(tool_name, windows, account_id="default", account_label="",
                  show_account=False):
    s = get_settings()
    if not s["notify_enabled"]:
        return
    warn_th, crit_th, sound = s["notify_warn"], s["notify_crit"], s["notify_sound"]
    loc = _effective_locale()
    strs = NOTIFY_STRINGS.get(loc, NOTIFY_STRINGS["en"])
    labels = WINDOW_LABELS.get(loc, WINDOW_LABELS["en"])
    display_tool = tool_name
    if show_account and account_label:
        display_tool = f"{tool_name} · {account_label}"
    for w in windows:
        key = (tool_name, account_id or "default", w.get("id") or w.get("label"))
        pct = w.get("used_percent") or 0
        prev = _alert_state.get(key, "normal")
        cur = "crit" if pct >= crit_th else "warn" if pct >= warn_th else "normal"
        # 按 id 本地化窗口标签（通知用当前语言，不受采样时缓存影响）
        label = labels.get(w.get("id") or "", w.get("label", ""))
        if cur != prev:
            if cur == "crit":
                _push_alert(tool_name, strs["crit"].format(tool=display_tool, label=label, pct=pct), "crit", sound)
            elif cur == "warn" and prev == "normal":
                _push_alert(tool_name, strs["warn"].format(tool=display_tool, label=label, pct=pct), "warn")
            elif cur == "normal" and prev in ("warn", "crit") and s["notify_reset"]:
                _push_alert(tool_name, strs["reset"].format(tool=display_tool, label=label, pct=pct), "reset", sound)
            _alert_state[key] = cur
            _alert_state_save()


def _sample_once():
    q = api_quota()
    sample = {"ts": round(time.time())}
    cl, cx = q.get("claude") or {}, q.get("codex") or {}
    if cl.get("ok"):
        for w in cl.get("windows", []):
            if w.get("id") == "five_hour":
                sample["c5h"] = w["used_percent"]
            elif w.get("id") == "seven_day":
                sample["c7d"] = w["used_percent"]
    if cx.get("ok"):
        for w in cx.get("windows", []):
            if w.get("id") == "five_hour":
                sample["x5h"] = w["used_percent"]
            elif w.get("id") == "seven_day":
                sample["x7d"] = w["used_percent"]
    account_groups = q.get("accounts") or {}
    for key, tool_name, primary in (("claude", "Claude", cl), ("codex", "Codex", cx)):
        accounts = account_groups.get(key) or ([primary] if primary.get("ok") else [])
        show_account = len(accounts) > 1
        for account in accounts:
            if account.get("ok"):
                _check_alerts(tool_name, account.get("windows", []),
                              str(account.get("account_id") or "default"),
                              str(account.get("account") or ""), show_account)
    if len(sample) > 1:
        DATA_DIR.mkdir(exist_ok=True)
        with open(HISTORY_FILE, "a") as f:
            f.write(json.dumps(sample) + "\n")


def _trim_history():
    try:
        if HISTORY_FILE.stat().st_size < 2_000_000:
            return
        cutoff = time.time() - HISTORY_KEEP
        lines = [l for l in HISTORY_FILE.read_text().splitlines()
                 if json.loads(l).get("ts", 0) > cutoff]
        _atomic_write_text(HISTORY_FILE, "\n".join(lines) + "\n")
    except (OSError, ValueError):
        pass


def _sampler_loop():
    while True:
        try:
            _sample_once()
            _trim_history()
        except Exception:
            pass
        time.sleep(max(get_settings()["sample_interval"], 60))


# ------------------------------------------------------------- 保持唤醒（防休眠）
# 有活跃会话且开关开时，持有一个 caffeinate 阻止系统/磁盘 idle 休眠——网络掉线本质是
# 休眠副作用，阻止休眠即可保活长会话。-w <本进程 pid> 兜底：daemon 被杀时 caffeinate
# 自动退出，绝不残留「永不休眠」的孤儿假设。（不阻止合盖休眠，不强制亮屏。）
_caffeinate = None
_caffeinate_lock = threading.Lock()


def _has_active_sessions():
    try:
        return bool(api_active().get("active"))
    except Exception:
        return False


def _update_keepawake():
    """按「开关 + 是否有活跃会话」持有或释放 caffeinate。幂等，可反复调用。"""
    global _caffeinate
    want = get_settings().get("keep_awake", True) and _has_active_sessions()
    with _caffeinate_lock:
        alive = _caffeinate is not None and _caffeinate.poll() is None
        if want and not alive:
            try:
                _caffeinate = subprocess.Popen(
                    ["caffeinate", "-i", "-m", "-s", "-w", str(os.getpid())])
            except Exception:
                _caffeinate = None
        elif alive and not want:
            try:
                _caffeinate.terminate()
            except Exception:
                pass
            _caffeinate = None


def _keepawake_loop():
    while True:
        try:
            _update_keepawake()
        except Exception:
            pass
        time.sleep(30)


def api_history(query):
    hours = min(int(query.get("hours", ["24"])[0]), 168)
    cutoff = time.time() - hours * 3600
    samples = []
    try:
        with open(HISTORY_FILE) as f:
            for line in f:
                try:
                    s = json.loads(line)
                except ValueError:
                    continue
                if s.get("ts", 0) >= cutoff:
                    samples.append(s)
    except OSError:
        pass
    return {"samples": samples, "hours": hours, "ts": time.time()}


# ----------------------------------------------------------------- 用量统计

_CLAUDE_USAGE_CACHE_VERSION = 2


def _claude_usage_key(msg, evt):
    mid, rid = msg.get("id"), evt.get("requestId")
    if mid is None and rid is None:
        return None
    raw = f"{mid or ''}\0{rid or ''}".encode("utf-8", "replace")
    return hashlib.blake2s(raw, digest_size=8).hexdigest()


def _parse_claude_usage_state(path, state=None):
    """Incrementally aggregate Claude usage while preserving response de-duplication."""
    state = dict(state or {})
    agg = state.get("agg") or {}
    seen = set(state.get("seen") or [])
    offset = int(state.get("offset") or 0)
    committed_offset = offset
    with open(path, "rb") as f:
        f.seek(offset)
        while True:
            raw = f.readline()
            if not raw:
                break
            line_end = f.tell()
            terminated = raw.endswith(b"\n")
            line = raw.decode("utf-8", "replace")
            if '"usage"' not in line:
                # A writer may be between writes. Do not permanently skip a partial
                # final JSON object merely because its interesting fields are absent.
                if not terminated:
                    try:
                        json.loads(line)
                    except ValueError:
                        break
                committed_offset = line_end
                continue
            try:
                evt = json.loads(line)
            except ValueError:
                if not terminated:
                    break
                committed_offset = line_end
                continue
            msg = evt.get("message") or {}
            usage = msg.get("usage")
            if not usage or evt.get("type") != "assistant":
                committed_offset = line_end
                continue
            key = _claude_usage_key(msg, evt)
            if key is not None:
                if key in seen:
                    committed_offset = line_end
                    continue
                seen.add(key)
            ts = evt.get("timestamp", "")
            hour = ts[:13]
            model = msg.get("model", "unknown")
            slot = agg.setdefault(hour, {}).setdefault(model, [0, 0, 0, 0, 0])
            slot[0] += usage.get("input_tokens", 0)
            slot[1] += usage.get("output_tokens", 0)
            slot[2] += usage.get("cache_read_input_tokens", 0)
            cc = usage.get("cache_creation")
            if isinstance(cc, dict):
                slot[3] += cc.get("ephemeral_5m_input_tokens", 0)
                slot[4] += cc.get("ephemeral_1h_input_tokens", 0)
            else:   # 老格式无细分，按 5m 档保守计
                slot[3] += usage.get("cache_creation_input_tokens", 0)
            committed_offset = line_end
    return {"agg": agg, "seen": sorted(seen), "offset": committed_offset}


def _parse_claude_file_usage(path):
    return _parse_claude_usage_state(path)["agg"]


def _load_claude_usage_cache():
    try:
        data = json.loads(CLAUDE_USAGE_CACHE_FILE.read_text())
        if data.get("version") == _CLAUDE_USAGE_CACHE_VERSION \
                and isinstance(data.get("files"), dict):
            return data["files"]
    except (OSError, ValueError, AttributeError):
        pass
    return {}


def _cached_claude_file_usage(path, disk_cache):
    stat = path.stat()
    key = str(path)
    entry = disk_cache.get(key)
    if isinstance(entry, dict) and entry.get("version") == _CLAUDE_USAGE_CACHE_VERSION:
        same_file = entry.get("inode") == stat.st_ino
        if (same_file and entry.get("size") == stat.st_size
                and entry.get("mtime_ns") == stat.st_mtime_ns):
            return entry.get("agg") or {}, False
        state = entry if same_file and stat.st_size >= int(entry.get("offset") or 0) else None
    else:
        state = None
    parsed = _parse_claude_usage_state(path, state)
    parsed.update({"version": _CLAUDE_USAGE_CACHE_VERSION, "inode": stat.st_ino,
                   "size": stat.st_size, "mtime_ns": stat.st_mtime_ns})
    disk_cache[key] = parsed
    return parsed["agg"], True


_claude_cwd_cache = {}


def _claude_file_cwd(path):
    """Claude 转写文件 → 会话 cwd（取首个带 cwd 的事件行，永久缓存）。"""
    key = str(path)
    if key in _claude_cwd_cache:
        return _claude_cwd_cache[key]
    cwd = ""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for _ in range(20):
                line = f.readline()
                if not line:
                    break
                if '"cwd"' not in line:
                    continue
                try:
                    cwd = json.loads(line).get("cwd") or ""
                except ValueError:
                    continue
                if cwd:
                    break
    except OSError:
        pass
    _claude_cwd_cache[key] = cwd
    return cwd


def _iter_claude_usage_files():
    """Return top-level and subagent Claude transcripts without duplicates."""
    files = set()
    for src in claude_sources():
        projects = src["path"] / "projects"
        files.update(projects.glob("*/*.jsonl"))
        files.update(projects.glob("*/**/subagents/*.jsonl"))
    return sorted(files)


_CODEX_USAGE_CACHE_VERSION = 5
_CODEX_USAGE_ACTIVITY_TYPES = {
    "user_message", "agent_message", "task_started", "task_complete",
}


def _parse_codex_usage_state(path, state=None):
    """Incrementally parse a rollout and return serializable aggregation state."""
    state = dict(state or {})
    meta = _rollout_meta(path)
    detected_kind = str(meta.get("subagent_kind") or "")
    if detected_kind == "thread_spawn" \
            and state.get("subagent_kind") != "thread_spawn":
        # The first session_meta line may have been incomplete during an earlier
        # pass. Once a fork is identified, discard any provisional top-level
        # state and replay from byte zero so copied parent history is excluded.
        state = {}
    agg = {hour: [int(value[0]), float(value[1])]
           for hour, value in (state.get("agg") or {}).items()}
    previous = state.get("previous")
    model = str(state.get("model") or "")
    offset = int(state.get("offset") or 0)
    has_activity = bool(state.get("has_activity"))
    has_usage = bool(state.get("has_usage"))
    stat = path.stat()
    subagent = bool(state.get("subagent")) or bool(meta.get("subagent"))
    subagent_kind = str(state.get("subagent_kind") or meta.get("subagent_kind") or "")
    replay_complete = bool(state.get("replay_complete")) \
        if "replay_complete" in state else subagent_kind != "thread_spawn"
    session_started_at = meta.get("started_at")
    fallback_hour = datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc) \
        .strftime("%Y-%m-%dT%H")
    committed_offset = offset
    with open(path, "rb") as lines:
        lines.seek(offset)
        while True:
            raw = lines.readline()
            if not raw:
                break
            line_end = lines.tell()
            terminated = raw.endswith(b"\n")
            line = raw.decode("utf-8", "replace")
            interesting = ('"total_token_usage"' in line or '"model"' in line
                           or any(f'"{kind}"' in line
                                  for kind in _CODEX_USAGE_ACTIVITY_TYPES))
            if not interesting:
                if not terminated:
                    try:
                        json.loads(line)
                    except ValueError:
                        break
                committed_offset = line_end
                continue
            try:
                evt = json.loads(line)
            except ValueError:
                if not terminated:
                    break
                committed_offset = line_end
                continue
            payload = evt.get("payload") or {}
            payload_type = payload.get("type")
            if not replay_complete:
                child_start = payload.get("started_at")
                if (payload_type == "task_started"
                        and isinstance(child_start, (int, float))
                        and isinstance(session_started_at, (int, float))
                        and child_start >= int(session_started_at)):
                    replay_complete = True
                else:
                    # A thread_spawn rollout starts with a physical copy of the
                    # parent's history. Preserve its last cumulative snapshot as
                    # the baseline, but never aggregate that replay into the child.
                    replay_usage = (payload.get("info") or {}).get(
                        "total_token_usage")
                    if isinstance(replay_usage, dict):
                        replay_input = max(
                            0, int(replay_usage.get("input_tokens") or 0))
                        replay_output = max(
                            0, int(replay_usage.get("output_tokens") or 0))
                        previous = {
                            "input": replay_input,
                            "cached": max(0, int(
                                replay_usage.get("cached_input_tokens") or 0)),
                            "output": replay_output,
                            "total": max(
                                replay_input + replay_output,
                                int(replay_usage.get("total_tokens") or 0)),
                        }
                    committed_offset = line_end
                    continue
            if payload_type in _CODEX_USAGE_ACTIVITY_TYPES:
                has_activity = True
            elif (evt.get("type") == "response_item" and payload_type == "message"
                  and payload.get("role") in ("user", "assistant")):
                has_activity = True
            if evt.get("type") == "turn_context" and payload.get("model"):
                model = str(payload["model"])
            info = payload.get("info") or {}
            usage = info.get("total_token_usage")
            if not isinstance(usage, dict):
                committed_offset = line_end
                continue
            current = {
                "input": max(0, int(usage.get("input_tokens") or 0)),
                "cached": max(0, int(usage.get("cached_input_tokens") or 0)),
                "output": max(0, int(usage.get("output_tokens") or 0)),
            }
            current["total"] = max(
                current["input"] + current["output"],
                int(usage.get("total_tokens") or 0))
            if current["total"] > 0:
                has_usage = True
            reset = previous is None or any(current[k] < previous[k] for k in current)
            base = {k: 0 for k in current} if reset else previous
            inp = current["input"] - base["input"]
            cached = min(current["cached"] - base["cached"], inp)
            out = current["output"] - base["output"]
            previous = current
            total = max(inp + out, current["total"] - base["total"])
            if total <= 0:
                committed_offset = line_end
                continue
            prices = _codex_price(model)
            cost = ((inp - cached) * prices[0] + out * prices[1]
                    + cached * prices[2]) / 1e6
            stamp = str(evt.get("timestamp") or "")
            hour = stamp[:13] if re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}", stamp) \
                else fallback_hour
            prev_total, prev_cost = agg.get(hour, (0, 0.0))
            agg[hour] = [prev_total + total, prev_cost + cost]
            committed_offset = line_end
    return {"agg": agg, "previous": previous, "model": model,
            "offset": committed_offset, "subagent": subagent,
            "subagent_kind": subagent_kind, "replay_complete": replay_complete,
            "has_activity": has_activity, "has_usage": has_usage}


def _parse_codex_file_usage(path):
    """Aggregate positive cumulative deltas by event hour for one rollout."""
    state = _parse_codex_usage_state(path)
    return {hour: (value[0], value[1]) for hour, value in state["agg"].items()}


def _load_codex_usage_cache():
    try:
        data = json.loads(CODEX_USAGE_CACHE_FILE.read_text())
        if data.get("version") == _CODEX_USAGE_CACHE_VERSION \
                and isinstance(data.get("files"), dict):
            return data["files"]
    except (OSError, ValueError, AttributeError):
        pass
    return {}


def _cached_codex_file_usage(path, disk_cache):
    stat = path.stat()
    key = str(path)
    entry = disk_cache.get(key)
    if isinstance(entry, dict) and entry.get("version") == _CODEX_USAGE_CACHE_VERSION:
        same_file = entry.get("inode") == stat.st_ino
        same_content = (same_file and entry.get("size") == stat.st_size
                        and entry.get("mtime_ns") == stat.st_mtime_ns)
        if same_content:
            coverage = {"has_activity": bool(entry.get("has_activity")),
                        "has_usage": bool(entry.get("has_usage"))}
            return ({hour: (value[0], value[1])
                     for hour, value in (entry.get("agg") or {}).items()},
                    False, coverage)
        appendable = same_file and stat.st_size >= int(entry.get("offset") or 0)
        state = entry if appendable else None
    else:
        state = None
    parsed = _parse_codex_usage_state(path, state)
    parsed.update({"version": _CODEX_USAGE_CACHE_VERSION, "inode": stat.st_ino,
                   "size": stat.st_size, "mtime_ns": stat.st_mtime_ns})
    disk_cache[key] = parsed
    coverage = {"has_activity": bool(parsed.get("has_activity")),
                "has_usage": bool(parsed.get("has_usage"))}
    return ({hour: (value[0], value[1]) for hour, value in parsed["agg"].items()},
            True, coverage)


def _model_short(model):
    for key in MODEL_PRICES:
        if key in model:
            return key
    return "other"


def _cost(model, tokens):
    prices = MODEL_PRICES.get(_model_short(model))
    if not prices:
        return 0.0
    return sum(t * p for t, p in zip(tokens, prices)) / 1e6


def _hour_epoch(hour_key):
    try:
        return datetime.strptime(hour_key, "%Y-%m-%dT%H") \
            .replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def _usage_project_cwd(cwd, mappings):
    """Canonicalize project attribution through a user-confirmed move mapping."""
    original = _normalize_session_cwd(cwd)
    if not original:
        return ""
    target = mappings.get(original)
    if target and os.path.isdir(target):
        return os.path.realpath(target)
    return os.path.realpath(original) if os.path.isdir(original) else original


def api_usage():
    def build():
        cutoff = time.time() - 30 * 86400
        days = [(datetime.now() - timedelta(days=n)).strftime("%Y-%m-%d")
                for n in range(29, -1, -1)]
        claude_daily = {d: {} for d in days}
        cost_daily = {d: 0.0 for d in days}
        cost_30d = cost_7d = 0.0
        week_cut = days[-7]
        now = time.time()
        hour_cut = now - 48 * 3600    # 48h：近 24h 画曲线，前 24h 供环比
        hourly = {}   # epoch_hour -> {"c": tokens, "x": tokens}
        projects = {}  # cwd -> {"tokens": n, "cost": $}（近 7 天）
        with _path_mappings_lock:
            path_mappings = _load_path_mappings()

        claude_usage_files = _iter_claude_usage_files()
        claude_cache = _load_claude_usage_cache()
        valid_claude_paths = {str(path) for path in claude_usage_files}
        claude_cache_dirty = False
        for stale_key in set(claude_cache) - valid_claude_paths:
            claude_cache.pop(stale_key, None)
            claude_cache_dirty = True
        for path in claude_usage_files:
            try:
                if path.stat().st_mtime < cutoff:
                    continue
                agg, changed = _cached_claude_file_usage(path, claude_cache)
                claude_cache_dirty = claude_cache_dirty or changed
            except OSError:
                continue
            fcwd = None   # 懒读：仅当文件有周内用量时才解析 cwd
            for hour, models in agg.items():
                # 本地日聚合：UTC 小时转本地日期
                ep = _hour_epoch(hour)
                day = datetime.fromtimestamp(ep).strftime("%Y-%m-%d") if ep else hour[:10]
                for model, tk in models.items():
                    if day in claude_daily:
                        short = _model_short(model)
                        slot = claude_daily[day].setdefault(short, [0] * 5)
                        for n in range(len(tk)):
                            slot[n] += tk[n]
                        c = _cost(model, tk)
                        cost_30d += c
                        cost_daily[day] += c
                        if day >= week_cut:
                            cost_7d += c
                            if fcwd is None:
                                fcwd = _claude_file_cwd(path)
                            if fcwd:
                                project_cwd = _usage_project_cwd(fcwd, path_mappings)
                                if project_cwd:
                                    p = projects.setdefault(
                                        project_cwd, {"tokens": 0, "cost": 0.0})
                                    p["tokens"] += sum(tk)
                                    p["cost"] += c
                    if ep and ep >= hour_cut:
                        hourly.setdefault(ep, {"c": 0, "x": 0})["c"] += sum(tk)

        if claude_cache_dirty:
            try:
                _atomic_write_text(CLAUDE_USAGE_CACHE_FILE, json.dumps({
                    "version": _CLAUDE_USAGE_CACHE_VERSION, "files": claude_cache},
                    ensure_ascii=False, separators=(",", ":")))
            except OSError:
                pass

        codex_daily = {d: 0 for d in days}
        xcost_30d = xcost_7d = 0.0
        codex_files = _iter_codex_files(None)
        codex_cache = _load_codex_usage_cache()
        valid_codex_paths = {str(path) for path in codex_files}
        cache_dirty = False
        codex_coverage_files = codex_missing_usage_files = 0
        for stale_key in set(codex_cache) - valid_codex_paths:
            codex_cache.pop(stale_key, None)
            cache_dirty = True
        for path in codex_files:
            try:
                if path.stat().st_mtime < cutoff:
                    continue
                stat = path.stat()
                agg, changed, coverage = _cached_codex_file_usage(path, codex_cache)
                cache_dirty = cache_dirty or changed
            except OSError:
                continue
            if coverage["has_activity"]:
                codex_coverage_files += 1
                # Active rollouts can receive their first token snapshot shortly after
                # task start; only flag stable files as irrecoverably incomplete.
                if not coverage["has_usage"] and now - stat.st_mtime > 120:
                    codex_missing_usage_files += 1
            for hour, (total, cost) in agg.items():
                ep = _hour_epoch(hour)
                day = datetime.fromtimestamp(ep).strftime("%Y-%m-%d") if ep else hour[:10]
                if day in codex_daily:
                    codex_daily[day] += total
                    xcost_30d += cost
                    cost_daily[day] += cost
                    if day >= week_cut:
                        xcost_7d += cost
                        cwd = _rollout_meta(path)["cwd"]
                        if cwd:
                            project_cwd = _usage_project_cwd(cwd, path_mappings)
                            if project_cwd:
                                p = projects.setdefault(
                                    project_cwd, {"tokens": 0, "cost": 0.0})
                                p["tokens"] += total
                                p["cost"] += cost
                if ep and ep >= hour_cut:
                    hourly.setdefault(ep, {"c": 0, "x": 0})["x"] += total

        if cache_dirty:
            try:
                _atomic_write_text(CODEX_USAGE_CACHE_FILE, json.dumps({
                    "version": _CODEX_USAGE_CACHE_VERSION, "files": codex_cache},
                    ensure_ascii=False, separators=(",", ":")))
            except OSError:
                pass

        top = sorted(projects.items(), key=lambda kv: -kv[1]["tokens"])[:6]
        projects_7d = [{"cwd": cwd, "name": Path(cwd).name or cwd,
                        "tokens": v["tokens"], "cost": round(v["cost"], 2)}
                       for cwd, v in top]

        return {
            "days": days,
            "claude_daily": claude_daily,
            "codex_daily": codex_daily,
            "hourly": [{"ts": ep, **v} for ep, v in sorted(hourly.items())],
            "projects_7d": projects_7d,
            "cost_daily": {d: round(v, 2) for d, v in cost_daily.items()},
            "cost_7d": round(cost_7d + xcost_7d, 2),
            "cost_30d": round(cost_30d + xcost_30d, 2),
            "claude_cost_7d": round(cost_7d, 2),
            "claude_cost_30d": round(cost_30d, 2),
            "codex_cost_7d": round(xcost_7d, 2),
            "codex_cost_30d": round(xcost_30d, 2),
            "coverage": {
                "codex_files": codex_coverage_files,
                "codex_missing_usage_files": codex_missing_usage_files,
            },
            "ts": time.time(),
        }
    return cached("usage", 120, build)


# ----------------------------------------------------------------- 恢复会话

_ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")
_path_mappings_lock = threading.Lock()


def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def _osa_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def _normalize_session_cwd(value):
    """Return a stable absolute path for resume lookup, or None for unusable metadata."""
    if not isinstance(value, str):
        return None
    if not value or len(value) > 4096 or "\0" in value:
        return None
    expanded = os.path.expanduser(value)
    if not os.path.isabs(expanded):
        return None
    return os.path.normpath(expanded)


def _load_path_mappings():
    try:
        payload = json.loads(PATH_MAPPINGS_FILE.read_text())
    except (OSError, ValueError):
        return {}
    raw = payload.get("mappings") if isinstance(payload, dict) else None
    if not isinstance(raw, dict):
        return {}
    mappings = {}
    for old, new in raw.items():
        old_path = _normalize_session_cwd(old)
        new_path = _normalize_session_cwd(new)
        if old_path and new_path:
            mappings[old_path] = new_path
    return mappings


def _save_path_mappings(mappings):
    payload = {"version": 1, "mappings": mappings}
    _atomic_write_text(PATH_MAPPINGS_FILE,
                       json.dumps(payload, ensure_ascii=False, indent=1))


def _mapped_session_cwd(original_cwd):
    with _path_mappings_lock:
        target = _load_path_mappings().get(original_cwd)
    if target and os.path.isdir(target):
        return os.path.realpath(target)
    return None


def _remember_session_cwd(original_cwd, replacement_cwd):
    replacement = _normalize_session_cwd(replacement_cwd)
    if not original_cwd or not replacement or not os.path.isdir(replacement):
        return None
    replacement = os.path.realpath(replacement)
    with _path_mappings_lock:
        mappings = _load_path_mappings()
        mappings[original_cwd] = replacement
        _save_path_mappings(mappings)
    with _cache_lock:
        _ttl_cache.pop("usage", None)
    return replacement


def _forget_session_cwd(original_cwd):
    if not original_cwd:
        return False
    with _path_mappings_lock:
        mappings = _load_path_mappings()
        removed = mappings.pop(original_cwd, None) is not None
        if removed:
            _save_path_mappings(mappings)
    if removed:
        with _cache_lock:
            _ttl_cache.pop("usage", None)
    return removed


def _resume_command(tool, sid, env_prefix, cwd=None):
    binary = "claude --resume" if tool == "claude" else "codex resume"
    command = f"{env_prefix}{binary} {_shell_quote(sid)}"
    return f"cd {_shell_quote(cwd)} && {command}" if cwd else command


# 可直接注入命令的终端：(mode, App 名, 显示名)，auto 按此优先级取第一个已安装的
_RESUME_TERMS = [
    ("iterm", "iTerm", "iTerm2"),
    ("ghostty", "Ghostty", "Ghostty"),
    ("kitty", "kitty", "kitty"),
    ("wezterm", "WezTerm", "WezTerm"),
    ("alacritty", "Alacritty", "Alacritty"),
    ("terminal", "Terminal", "Terminal"),
]
# 无法用 CLI/AppleScript 注入命令的常见终端：改为「打开 App（尽量定位到 cwd）+ 复制
# 命令」，由用户粘贴回车恢复——open -a 对任意已安装 App 通用，覆盖面广。
_PASTE_TERMS = [
    ("warp", "Warp", "Warp"),
    ("vscode", "Visual Studio Code", "VS Code"),
    ("cursor", "Cursor", "Cursor"),
    ("windsurf", "Windsurf", "Windsurf"),
    ("hyper", "Hyper", "Hyper"),
    ("tabby", "Tabby", "Tabby"),
    ("rio", "Rio", "Rio"),
    ("wave", "Wave", "Wave"),
]


def _term_installed(app):
    if app == "Terminal":     # 系统自带
        return True
    return Path(f"/Applications/{app}.app").exists() \
        or Path(f"{HOME}/Applications/{app}.app").exists()


def api_data(body):
    """数据管理：打开数据目录 / 导出用量 CSV / 清空完成记录。"""
    act = body.get("action")
    if act == "open":
        subprocess.run(["open", str(DATA_DIR)], timeout=10)
        return {"ok": True}
    if act == "export":
        u = api_usage()
        out = Path.home() / "Downloads" / \
            f"agentdeck-usage-{datetime.now().strftime('%Y%m%d')}.csv"
        rows = ["day,claude_tokens,codex_tokens,api_cost_usd"]
        for d in u["days"]:
            ct = sum(sum(v) for v in (u["claude_daily"].get(d) or {}).values())
            rows.append(f"{d},{ct},{u['codex_daily'].get(d, 0)},"
                        f"{u['cost_daily'].get(d, 0)}")
        _atomic_write_text(out, "\n".join(rows) + "\n")
        subprocess.run(["open", "-R", str(out)], timeout=10)   # Finder 中显示
        return {"ok": True, "path": str(out)}
    if act == "clear_events":
        with _events_lock:
            _events.clear()
        try:
            with _events_file_lock:
                _atomic_write_text(EVENTS_FILE, "")
        except OSError:
            pass
        return {"ok": True}
    return {"ok": False, "error": "unknown action"}


def api_terminals():
    out = [{"mode": m, "name": disp}
           for m, app, disp in _RESUME_TERMS if _term_installed(app)]
    out += [{"mode": m, "name": disp, "paste": True}
            for m, app, disp in _PASTE_TERMS if _term_installed(app)]
    return {"terminals": out}


def api_path_mapping(body):
    original_cwd = _normalize_session_cwd(body.get("original_cwd"))
    if not original_cwd:
        return {"ok": False, "error": "invalid original directory"}
    action = body.get("action")
    if action == "set":
        replacement = _remember_session_cwd(
            original_cwd, body.get("replacement_cwd"))
        if replacement is None:
            return {"ok": False, "error": "invalid replacement directory"}
        return {"ok": True, "mapped": True, "resolved_cwd": replacement}
    if action == "remove":
        return {"ok": True, "mapped": False,
                "removed": _forget_session_cwd(original_cwd)}
    return {"ok": False, "error": "invalid action"}


def api_resume(body):
    tool = body.get("tool")
    sid = body.get("id", "")
    if tool not in ("claude", "codex") or not _ID_RE.match(sid):
        return {"ok": False, "error": "invalid args"}

    # 复合身份里的账号决定 CLI 应读取哪套配置目录。显式传账号时始终固定环境变量，
    # 包括 default：否则用户 shell 里已有的 CLAUDE_CONFIG_DIR/CODEX_HOME 会把恢复
    # 请求悄悄导向另一账号。旧客户端不传 account_id 时保留原行为。
    account_id = str(body.get("account_id") or "")
    env_prefix = ""
    if account_id:
        if not re.fullmatch(r"[a-z0-9-]{1,120}", account_id):
            return {"ok": False, "error": "invalid account"}
        sources = claude_sources() if tool == "claude" else codex_sources()
        source = next((item for item in sources if item["id"] == account_id), None)
        if source is None:
            return {"ok": False, "error": "account not found"}
        env_name = "CLAUDE_CONFIG_DIR" if tool == "claude" else "CODEX_HOME"
        env_prefix = f"/usr/bin/env {env_name}={_shell_quote(str(source['path']))} "

    original_cwd = _normalize_session_cwd(body.get("cwd"))
    cwd = None
    mapped = False
    if original_cwd:
        replacement = body.get("replacement_cwd")
        if replacement is not None:
            cwd = _remember_session_cwd(original_cwd, replacement)
            if cwd is None:
                return {"ok": False, "error": "invalid replacement directory"}
            mapped = True
        else:
            cwd = _mapped_session_cwd(original_cwd)
            mapped = cwd is not None
            if cwd is None and os.path.isdir(original_cwd):
                cwd = os.path.realpath(original_cwd)
        if cwd is None:
            # 先让原生壳选择迁移后的工程目录；取消时 command 可直接作为无 cd 的安全降级。
            return {"ok": True, "copy": True, "needs_path": True,
                    "command": _resume_command(tool, sid, env_prefix),
                    "original_cwd": original_cwd}
    elif body.get("replacement_cwd") is not None:
        return {"ok": False, "error": "invalid original directory"}

    cmd = _resume_command(tool, sid, env_prefix, cwd)

    if body.get("copy_only") is True:
        return {"ok": True, "copy": True, "command": cmd,
                "resolved_cwd": cwd, "path_mapped": mapped}

    mode = get_settings()["terminal"]
    if mode == "copy":   # 仅返回命令，由前端复制到剪贴板
        return {"ok": True, "copy": True, "command": cmd}
    run_avail = {m: app for m, app, _ in _RESUME_TERMS if _term_installed(app)}
    paste_avail = {m: app for m, app, _ in _PASTE_TERMS if _term_installed(app)}
    if mode not in run_avail and mode not in paste_avail:   # auto / 未安装 → 回退
        mode = (next((m for m, _, _ in _RESUME_TERMS if m in run_avail), None)
                or next((m for m, _, _ in _PASTE_TERMS if m in paste_avail), None)
                or "copy")
        if mode == "copy":   # 一个支持的终端都没装
            return {"ok": True, "copy": True, "command": cmd}

    if mode in paste_avail:
        # 无法注入命令：打开 App（尽量带 cwd）+ 由前端复制命令，粘贴回车即恢复
        app = paste_avail[mode]
        open_args = ["open", "-a", app] + ([cwd] if cwd else [])
        r = subprocess.run(open_args,
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0:    # 该 App 不接受目录参数时退化为仅打开
            subprocess.run(["open", "-a", app], capture_output=True, timeout=20)
        disp = next(d for m, _, d in _PASTE_TERMS if m == mode)
        # 用户开启「唤起后自动粘贴」时由前端经 Swift 桥合成 ⌘V + 回车（需辅助功能授权）
        auto_paste = bool(get_settings().get("auto_paste_resume"))
        return {"ok": True, "copy": True, "paste": True, "command": cmd,
                "terminal": mode, "app": disp, "auto_paste": auto_paste}

    if mode == "iterm":
        script = (
            'tell application "iTerm"\n  activate\n'
            "  set w to (create window with default profile)\n"
            f'  tell current session of w to write text "{_osa_escape(cmd)}"\n'
            "end tell"
        )
        proc = subprocess.run(["osascript", "-e", script],
                              capture_output=True, text=True, timeout=20)
    elif mode == "terminal":
        script = (
            'tell application "Terminal"\n  activate\n'
            f'  do script "{_osa_escape(cmd)}"\nend tell'
        )
        proc = subprocess.run(["osascript", "-e", script],
                              capture_output=True, text=True, timeout=20)
    else:
        # 命令行直启（open --args）；会话退出后 exec zsh 保住窗口
        keep = f"{cmd}; exec zsh -i"
        launch_cwd = cwd or str(HOME)
        args = {
            "ghostty": ["-e", "zsh", "-ic", keep],
            "kitty": ["--directory", launch_cwd, "zsh", "-ic", keep],
            "wezterm": ["start", "--cwd", launch_cwd, "--", "zsh", "-ic", keep],
            "alacritty": ["--working-directory", launch_cwd, "-e", "zsh", "-ic", keep],
        }[mode]
        proc = subprocess.run(["open", "-na", run_avail[mode], "--args", *args],
                              capture_output=True, text=True, timeout=20)
    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip()}
    return {"ok": True, "command": cmd, "terminal": mode}


# ----------------------------------------------------------------- HTTP 层

_LOCAL_HTTP_HOSTS = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}


def _local_http_host(headers):
    """Only the loopback origin may address daemon APIs (DNS-rebinding barrier)."""
    return headers.get("Host", "").strip().lower() in _LOCAL_HTTP_HOSTS

class Handler(BaseHTTPRequestHandler):
    server_version = "agentdeck/1.0"

    def _send(self, code, payload, ctype="application/json; charset=utf-8"):
        body = payload if isinstance(payload, bytes) else \
            json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        path, query = parsed.path, parse_qs(parsed.query)
        if path.startswith("/api/") and not _local_http_host(self.headers):
            return self._send(403, {"error": "forbidden"})
        try:
            if path == "/api/health":
                self._send(200, {"ok": True, "pid": os.getpid(),
                                 "version": VERSION})
            elif path == "/api/quota":
                self._send(200, api_quota(
                    force=query.get("force", ["0"])[0] in ("1", "true")))
            elif path == "/api/diag":
                self._send(200, api_diag())
            elif path == "/api/sessions":
                self._send(200, api_sessions(
                    query.get("q", [""])[0],
                    tool=query.get("tool", ["all"])[0],
                    limit=query.get("limit", [None])[0],
                    cursor=query.get("cursor", [""])[0]))
            elif path == "/api/usage":
                self._send(200, api_usage())
            elif path == "/api/active":
                self._send(200, api_active())
            elif path == "/api/preview":
                self._send(200, api_preview(query))
            elif path == "/api/history":
                self._send(200, api_history(query))
            elif path == "/api/settings":
                self._send(200, _settings_response())
            elif path == "/api/update":
                self._send(200, api_update(force=query.get("force") == ["1"]))
            elif path == "/api/update/install":
                self._send(200, _update_status())
            elif path == "/api/terminals":
                self._send(200, api_terminals())
            elif path == "/api/events":
                self._send(200, api_events(query))
            elif path == "/favicon.ico":
                self._send(204, b"", "image/x-icon")
            elif path.startswith("/brand/") and re.fullmatch(r"[\w@.-]+\.png",
                                                             path[7:]):
                f = STATIC_DIR / "brand" / path[7:]
                if f.is_file():
                    self._send(200, f.read_bytes(), "image/png")
                else:
                    self._send(404, {"error": "not found"})
            elif path in ("/", "/index.html"):
                self._send(200, (STATIC_DIR / "index.html").read_bytes(),
                           "text/html; charset=utf-8")
            else:
                self._send(404, {"error": "not found"})
        except Exception as exc:
            self._send(500, {"error": str(exc)})

    def _csrf_ok(self):
        """CSRF 屏障（结构化校验，防字符串前缀绕过）：
        ① Content-Type 主类型必须恰为 application/json（no-cors 请求带不了）
        ② Origin 若存在必须是本机同源  ③ Host 必须本机（封 DNS rebinding）"""
        from urllib.parse import urlparse
        ctype = self.headers.get("Content-Type", "") \
            .split(";", 1)[0].strip().lower()
        if ctype != "application/json":
            return False
        origin = self.headers.get("Origin", "")
        if origin:
            p = urlparse(origin)
            if p.scheme != "http" or p.netloc.lower() not in _LOCAL_HTTP_HOSTS:
                return False
        return _local_http_host(self.headers)

    def do_POST(self):
        if not self._csrf_ok():
            return self._send(403, {"error": "forbidden"})
        path = self.path.split("?")[0]
        handlers = {"/api/resume": api_resume, "/api/path-mapping": api_path_mapping,
                    "/api/pin": api_pin,
                    "/api/settings": api_settings_save, "/api/event": api_event,
                    "/api/focus": api_focus, "/api/data": api_data,
                    "/api/update/install": api_update_install}
        fn = handlers.get(path)
        if not fn:
            return self._send(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            self._send(200, fn(body))
        except Exception as exc:
            self._send(500, {"error": str(exc)})

    def log_message(self, *args):
        pass


def _parent_watchdog():
    """壳进程（App）退出后自杀，避免后台 daemon 残留成孤儿。
    App 用 Process 拉起时 daemon 的父进程就是 App；App 一死，daemon 被 launchd
    收养、PPID 变为 1，据此退出。启动时若已是孤儿（PPID≤1，如 launchd 直拉）则不看守，
    手动 `python3 agentdeckd.py` 直跑时父是 shell，关掉 shell 也会随之退出（开发以前台 Ctrl-C 为主，不受影响）。"""
    start_ppid = os.getppid()
    if start_ppid <= 1:
        return
    while True:
        time.sleep(10)   # 省电：10s 足够（App 退出后 daemon 至多多活 10s 再自杀），减少进程唤醒
        if os.getppid() != start_ppid:
            os._exit(0)


def main():
    _events_load()
    _alert_state_load()
    _ensure_session_index_started()
    install_integration()   # 启动即自动接好完成事件钩子（幂等、只合并不覆盖）
    threading.Thread(target=_parent_watchdog, daemon=True).start()
    threading.Thread(target=_sampler_loop, daemon=True).start()
    threading.Thread(target=_keepawake_loop, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"agentdeckd listening on http://127.0.0.1:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    # 卸载用：build.sh uninstall 调 `agentdeckd.py --remove-integration` 干净还原我们的配置改动
    if "--remove-integration" in sys.argv:
        remove_integration()
        print("integration removed")
    elif "--install-integration" in sys.argv:
        install_integration()
        print("integration installed")
    else:
        main()
