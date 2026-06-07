#!/usr/bin/env python3
"""AgentDeck daemon — Claude Code / Codex 额度与会话监控后端（纯标准库，零依赖）。

API:
  GET  /api/health    存活探测
  GET  /api/quota     Claude 官方额度(OAuth) + Codex rate_limits(本地解析)
  GET  /api/sessions  双端最近会话合并列表
  GET  /api/usage     近 7/30 天 token 用量 + 成本估算
  POST /api/resume    在终端中恢复指定会话
"""

import json
import os
import re
import subprocess
import threading
import time
import urllib.request
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
PORT = 7777
try:
    VERSION = (Path(__file__).resolve().parent / "VERSION").read_text().strip()
except OSError:
    VERSION = "dev"
SAMPLE_INTERVAL = 180          # 额度采样周期（秒）
HISTORY_KEEP = 7 * 86400       # 历史保留 7 天

# 更新检测：向自托管的 Cloudflare Pages 清单查最新版本号（不带任何凭据；可在设置中关闭）。
# 部署后把域名改成你的 Pages 项目地址即可。
UPDATE_MANIFEST_URL = "https://agentdeck.yilin.dev/version.json"

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
    "show_active": True,       # 活跃会话卡片
    "sessions_limit": 15,      # 每端会话列表数量
    "refresh_interval": 30,    # 前端自动刷新（秒）
    "sample_interval": 180,    # 额度采样间隔（秒）
    "terminal": "auto",        # auto | iterm | terminal | copy
    "font_scale": 100,         # 面板/小组件字体缩放 %（整体 zoom）
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
}
_settings_lock = threading.Lock()


def get_settings():
    s = dict(DEFAULT_SETTINGS)
    with _settings_lock:
        try:
            saved = json.loads(SETTINGS_FILE.read_text())
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
        clean[k] = v
    with _settings_lock:
        try:
            cur = json.loads(SETTINGS_FILE.read_text())
        except (OSError, ValueError):
            cur = {}
        cur.update(clean)
        SETTINGS_FILE.parent.mkdir(exist_ok=True)
        SETTINGS_FILE.write_text(json.dumps(cur, ensure_ascii=False, indent=1))
    with _cache_lock:
        _ttl_cache.pop("sessions", None)   # 数量类设置立即生效
    if "keep_awake" in clean:   # 立即生效，不阻塞响应
        threading.Thread(target=_update_keepawake, daemon=True).start()
    return {"ok": True, "settings": _settings_response()}


_cache_lock = threading.Lock()
_ttl_cache = {}        # key -> (expire_ts, value)，接口级 TTL 缓存
_file_agg_cache = {}   # path -> (mtime, size, parsed)，文件级解析缓存


def cached(key, ttl, fn):
    now = time.time()
    with _cache_lock:
        hit = _ttl_cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
    val = fn()
    with _cache_lock:
        _ttl_cache[key] = (now + ttl, val)
    return val


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
    """系统首选语言 → zh-CN / en / ja，识别不出回退 en。"""
    try:
        out = subprocess.run(["defaults", "read", "-g", "AppleLanguages"],
                             capture_output=True, text=True, timeout=5)
        for line in out.stdout.splitlines():
            tok = line.strip().strip('(),"').lower()
            if not tok:
                continue
            if tok.startswith("zh"):
                return "zh-CN"
            if tok.startswith("ja"):
                return "ja"
            if tok.startswith("en"):
                return "en"
            return "en"   # 首个非空语言码无法识别，回退
    except Exception:
        pass
    return "en"


def _effective_locale():
    """设置为 auto 时跟随系统；否则用设置值。系统探测带 5 分钟缓存。"""
    lang = get_settings().get("language", "auto")
    if lang in LOCALES:
        return lang
    return cached("syslang", 300, _system_locale)


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
    return {"current": VERSION, "latest": latest,
            "available": bool(latest) and _ver_key(latest) > _ver_key(VERSION),
            "url": str(m.get("url") or ""),
            "notes_url": str(m.get("notes_url") or "")}


# ---------------------------------------------------------------- Claude 额度

def _keychain_token():
    out = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
        capture_output=True, text=True, timeout=15,
    )
    if out.returncode != 0:
        raise RuntimeError(f"keychain: {out.stderr.strip() or 'denied'}")
    return json.loads(out.stdout.strip())["claudeAiOauth"]["accessToken"]


def _claude_quota():
    token = _keychain_token()
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
    return {"ok": True, "windows": windows, "raw": raw}


# ----------------------------------------------------------------- Codex 额度

def _iter_codex_files(limit=60):
    files = sorted(CODEX_SESSIONS.glob("*/*/*/rollout-*.jsonl"), reverse=True)
    return files[:limit]


def _tail_lines(path, size=262144):
    with open(path, "rb") as f:
        f.seek(0, 2)
        end = f.tell()
        f.seek(max(0, end - size))
        data = f.read()
    return data.decode("utf-8", "replace").splitlines()


def _codex_quota():
    primary = secondary = credits = stamp = None
    for path in _iter_codex_files(30):
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


_last_good = {}        # key -> 最近一次成功结果（失败时降级返回）
LAST_GOOD_FILE = None  # 延迟初始化，DATA_DIR 定义在前文


def _resilient(key, ttl, fn):
    """失败时回退到最近一次成功值；429 限流额外退避 10 分钟。"""
    global LAST_GOOD_FILE
    if LAST_GOOD_FILE is None:
        LAST_GOOD_FILE = DATA_DIR / "last_good.json"
        try:  # 进程重启后恢复降级数据，避免重启风暴打爆接口
            _last_good.update(json.loads(LAST_GOOD_FILE.read_text()))
        except (OSError, ValueError):
            pass
    try:
        val = cached(key, ttl, fn)
        if not val.get("stale") and _last_good.get(key) != val:
            _last_good[key] = val
            try:
                DATA_DIR.mkdir(exist_ok=True)
                LAST_GOOD_FILE.write_text(json.dumps(_last_good, ensure_ascii=False))
            except OSError:
                pass
        return val
    except Exception as exc:
        err = str(exc)
        stale = _last_good.get(key)
        out = dict(stale, stale=True, error=err) if stale \
            else {"ok": False, "error": err}
        backoff = 600 if "429" in err else 60
        with _cache_lock:                       # 失败结果也缓存，防止重试风暴
            _ttl_cache[key] = (time.time() + backoff, out)
        return out


def api_quota():
    s = get_settings()
    return {"claude": _resilient("claude_quota", 120, _claude_quota),
            "codex": _resilient("codex_quota", 30, _codex_quota),
            "menubar": {"claude": s["menubar_claude"],
                        "codex": s["menubar_codex"]},
            "ts": time.time()}


# ----------------------------------------------------------------- 会话列表

_SKIP_PREFIXES = ("<command-name>", "<local-command", "<user_instructions",
                  "<environment_context", "<ENVIRONMENT_CONTEXT", "Caveat:",
                  "<system-reminder>", "<task-notification>",
                  "# AGENTS.md", "<permissions")


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


def _claude_sessions(limit=15):
    files = sorted(CLAUDE_PROJECTS.glob("*/*.jsonl"),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    out = []
    for path in files:
        if len(out) >= limit:
            break
        if path.name.startswith("agent-"):   # subagent 旁链
            continue
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
                    if evt.get("isSidechain"):
                        title = None
                        break
                    cwd = evt.get("cwd") or cwd
                    branch = evt.get("gitBranch") or branch
                    if evt.get("type") == "user":
                        text = _msg_text((evt.get("message") or {}).get("content"))
                        if text and not text.lstrip().startswith(_SKIP_PREFIXES):
                            title = _clean_title(text)
                            break
        except OSError:
            continue
        if not title:
            continue
        st = path.stat()
        out.append({
            "tool": "claude",
            "id": path.stem,
            "title": title,
            "cwd": cwd,
            "project": Path(cwd).name if cwd else path.parent.name,
            "branch": branch,
            "mtime": st.st_mtime,
            "size": st.st_size,
        })
    return out


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
                payload = evt.get("payload") or {}
                if evt.get("type") == "session_meta":
                    sid = payload.get("id")
                    cwd = payload.get("cwd") or ""
                text = ""
                if payload.get("type") == "user_message":
                    text = payload.get("message", "")
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


def _codex_sessions(limit=15):
    out = []
    for path in _iter_codex_files(40):
        if len(out) >= limit:
            break
        info = _codex_session_info(path)
        if not info:
            continue
        sid, cwd, title = info
        st = path.stat()
        out.append({
            "tool": "codex",
            "id": sid,
            "title": title,
            "cwd": cwd,
            "project": Path(cwd).name if cwd else "",
            "branch": "",
            "mtime": st.st_mtime,
            "size": st.st_size,
        })
    return out


# ----------------------------------------------------------------- 收藏置顶

_pins_lock = threading.Lock()


def _load_pins():
    try:
        return json.loads(PINS_FILE.read_text())
    except (OSError, ValueError):
        return {}


def _save_pins(pins):
    DATA_DIR.mkdir(exist_ok=True)
    PINS_FILE.write_text(json.dumps(pins, ensure_ascii=False, indent=1))


def api_pin(body):
    sess = body.get("session") or {}
    sid = sess.get("id", "")
    if not _ID_RE.match(sid):
        return {"ok": False, "error": "invalid id"}
    with _pins_lock:
        pins = _load_pins()
        if body.get("pinned"):
            pins[sid] = {k: sess.get(k, "") for k in
                         ("tool", "id", "title", "cwd", "project", "branch", "mtime")}
        else:
            pins.pop(sid, None)
        _save_pins(pins)
    with _cache_lock:
        _ttl_cache.pop("sessions", None)   # 立即反映到列表
    return {"ok": True, "pinned": bool(body.get("pinned"))}


def api_sessions():
    def build():
        limit = get_settings()["sessions_limit"]
        merged = _claude_sessions(limit) + _codex_sessions(limit)
        merged.sort(key=lambda s: s["mtime"], reverse=True)
        pins = _load_pins()
        seen = set()
        for s in merged:
            s["pinned"] = s["id"] in pins
            seen.add(s["id"])
        # 已置顶但滚出最近列表的会话，从快照补回
        for sid, snap in pins.items():
            if sid not in seen and snap.get("tool"):
                snap = dict(snap)
                snap["pinned"] = True
                merged.append(snap)
        merged.sort(key=lambda s: (not s["pinned"], -float(s.get("mtime") or 0)))
        return {"sessions": merged, "ts": time.time()}
    return cached("sessions", 20, build)


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


def api_active():
    def build():
        active, claude_pids = [], {}
        # Claude: 官方 per-PID 索引文件，含 sessionId/cwd/status
        for f in CLAUDE_PIDFILES.glob("*.json"):
            try:
                info = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            pid = info.get("pid")
            if not (pid and _pid_alive(pid) and info.get("kind") == "interactive"):
                continue
            claude_pids[int(pid)] = info

        ps = subprocess.run(["ps", "-axo", "pid=,etime=,args="],
                            capture_output=True, text=True, timeout=10)
        for line in ps.stdout.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 3:
                continue
            pid, etime, args = parts
            m = re.match(r"^(?:\S+/)?(claude|codex)(?:\s+(.*))?$", args)
            if not m or "app-server" in (m.group(2) or ""):
                continue
            tool, pid_i = m.group(1), int(pid)
            entry = {"tool": tool, "pid": pid_i, "runtime": _fmt_etime(etime),
                     "runtime_secs": _etime_secs(etime),
                     "status": "", "id": "", "cwd": "", "project": ""}
            if tool == "claude":
                info = claude_pids.get(pid_i)
                if info:
                    entry.update(id=info.get("sessionId", ""),
                                 cwd=info.get("cwd", ""),
                                 status=info.get("status", ""))
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
                # Codex 桌面端 rollout cwd 可能是进程 cwd 的子目录，前缀匹配
                cands = [mt for c, mt in cwd_mtime.items()
                         if c == e["cwd"] or c.startswith(e["cwd"] + "/")
                         or e["cwd"].startswith(c + "/")]
                if cands:
                    e["status"] = "busy" if now - max(cands) < 30 else "idle"

        # 仍无状态来源的会话（如 Xcode 内置 Coding Assistant 拉起的 headless claude，
        # 不写 transcript 也无 pidfile）：按进程瞬时 CPU 占用推断忙闲
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
        term_cwds = [e["cwd"] for e in active if e["tool"] == "codex" and e["cwd"]]
        for f in _iter_codex_files(20):
            try:
                mt = f.stat().st_mtime
            except OSError:
                continue
            if now - mt > 600:        # 10 分钟内有写入才算「正在运行」
                continue
            meta = _rollout_meta(f)
            cwd = meta["cwd"]
            if meta["originator"] != "Codex Desktop":
                continue
            if any(cwd == c or cwd.startswith(c + "/") or c.startswith(cwd + "/")
                   for c in term_cwds):
                continue              # 已由终端进程行覆盖
            fm = re.match(r"rollout-(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2})"
                          r"-([0-9a-f-]{36})\.jsonl$", f.name)
            if not fm:
                continue
            try:
                start = time.mktime(time.strptime(fm.group(1), "%Y-%m-%dT%H-%M-%S"))
            except ValueError:
                start = mt
            active.append({"tool": "codex", "pid": 0, "host": "app",
                           "runtime": _fmt_secs(now - start),
                           "status": "busy" if now - mt < 30 else "idle",
                           "id": fm.group(2), "cwd": cwd,
                           "project": Path(cwd).name if cwd else "—"})

        active.sort(key=lambda a: (a["tool"], a["pid"]))
        return {"active": active, "ts": time.time()}
    return cached("active", 10, build)


_rollout_meta_cache = {}


def _rollout_meta(path):
    """rollout 文件 → session_meta {cwd, originator}（每文件恒定，永久缓存）。"""
    key = str(path)
    if key in _rollout_meta_cache:
        return _rollout_meta_cache[key]
    meta = {"cwd": "", "originator": ""}
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
                if evt.get("type") == "session_meta":
                    p = evt.get("payload") or {}
                    meta["cwd"] = p.get("cwd") or ""
                    meta["originator"] = p.get("originator") or ""
                    break
    except OSError:
        pass
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
        role, text = "", ""
        if codex:
            payload = evt.get("payload") or {}
            if payload.get("type") == "user_message":
                role, text = "user", payload.get("message", "")
            elif payload.get("type") == "agent_message":
                role, text = "assistant", payload.get("message", "")
            elif payload.get("role") in ("user", "assistant"):
                role, text = payload["role"], _msg_text(payload.get("content"))
        else:
            if evt.get("type") in ("user", "assistant") and not evt.get("isSidechain"):
                role = evt["type"]
                text = _msg_text((evt.get("message") or {}).get("content"))
        text = _clean_title(text or "")
        if role and text and not text.startswith(_SKIP_PREFIXES):
            msgs.append({"role": role, "text": text[:220]})
    return msgs[-4:]


def api_preview(query):
    tool = query.get("tool", [""])[0]
    sid = query.get("id", [""])[0]
    if tool not in ("claude", "codex") or not _ID_RE.match(sid):
        return {"ok": False, "error": "invalid args"}
    if tool == "claude":
        files = list(CLAUDE_PROJECTS.glob(f"*/{sid}.jsonl"))
    else:
        files = list(CODEX_SESSIONS.glob(f"*/*/*/rollout-*{sid}.jsonl"))
    if not files:
        return {"ok": False, "error": "transcript not found"}
    path = max(files, key=lambda p: p.stat().st_mtime)
    return {"ok": True, "messages": _collect_preview(path, codex=(tool == "codex"))}


# ------------------------------------------------- 会话完成事件（灵动岛提醒）

_events = deque(maxlen=50)
_events_lock = threading.Lock()
_event_seq = 0
EVENTS_FILE = DATA_DIR / "events.jsonl"


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
            _events.append(e)


def _events_persist(evt):
    try:
        EVENTS_FILE.parent.mkdir(exist_ok=True)
        with open(EVENTS_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(evt, ensure_ascii=False) + "\n")
        if EVENTS_FILE.stat().st_size > 256 * 1024:    # 防膨胀：超限保尾部
            tail = EVENTS_FILE.read_text().splitlines()[-100:]
            EVENTS_FILE.write_text("\n".join(tail) + "\n")
    except OSError:
        pass


def _last_user_msg(transcript_path):
    """返回 (时间戳, 文本)——最后一条真实用户消息，用于算任务时长和提醒文案。"""
    try:
        for line in reversed(_tail_lines(Path(transcript_path), 2_000_000)):
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            if evt.get("type") != "user" or evt.get("isSidechain"):
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
        # 外部输入→文件读取的唯一路径：限定在 ~/.claude 内，防任意文件读取
        tp = os.path.realpath(os.path.expanduser(body.get("transcript_path") or ""))
        if tp.startswith(str(HOME / ".claude") + os.sep) and os.path.exists(tp):
            t, text = _last_user_msg(tp)
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

    global _event_seq
    # 空标题存为 ""，由前端 / Swift 壳按当前语言本地化「任务完成」回退
    evt = {"tool": tool, "session": sid, "cwd": cwd,
           "title": title or "", "project": project,
           "duration": round(duration or 0), "ts": time.time()}
    with _events_lock:
        _event_seq += 1
        _events.append({"id": _event_seq, **evt})
    _events_persist(evt)
    return {"ok": True, "queued": _event_seq}


def api_events(query):
    with _events_lock:
        recent = int(query.get("recent", ["0"])[0])
        if recent:        # 「最近完成」卡：取末尾 N 条（新→旧）
            return {"events": list(_events)[-recent:][::-1], "last": _event_seq}
        since = int(query.get("since", ["0"])[0])
        # 灵动岛通道：排除重启回灌的历史事件，只推真正新发生的
        evs = [e for e in _events if e["id"] > since and not e.get("replayed")]
        # locale 随该通道下发给 Swift 壳（菜单 / 灵动岛 / 通知本地化）
        return {"events": evs, "last": _event_seq,
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
    for f in CLAUDE_PIDFILES.glob("*.json"):
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

_alert_state = {}   # (tool, window_id) -> "normal" | "warn" | "crit"
ALERT_STATE_FILE = DATA_DIR / "alert_state.json"


def _alert_state_load():
    """告警状态跨重启持久化：同一次越阈只通知一次，重启不重发。"""
    try:
        for k, v in json.loads(ALERT_STATE_FILE.read_text()).items():
            tool, _, win = k.partition("|")
            _alert_state[(tool, win)] = v
    except (OSError, ValueError):
        pass


def _alert_state_save():
    try:
        ALERT_STATE_FILE.parent.mkdir(exist_ok=True)
        ALERT_STATE_FILE.write_text(json.dumps(
            {f"{t}|{w}": v for (t, w), v in _alert_state.items()}))
    except OSError:
        pass


def _notify(msg, sound=False):
    script = (f'display notification "{_osa_escape(msg)}" '
              f'with title "AgentDeck"')
    if sound:
        script += ' sound name "Glass"'
    subprocess.run(["osascript", "-e", script], capture_output=True, timeout=10)


def _check_alerts(tool_name, windows):
    s = get_settings()
    if not s["notify_enabled"]:
        return
    warn_th, crit_th, sound = s["notify_warn"], s["notify_crit"], s["notify_sound"]
    loc = _effective_locale()
    strs = NOTIFY_STRINGS.get(loc, NOTIFY_STRINGS["en"])
    labels = WINDOW_LABELS.get(loc, WINDOW_LABELS["en"])
    for w in windows:
        key = (tool_name, w.get("id") or w.get("label"))
        pct = w.get("used_percent") or 0
        prev = _alert_state.get(key, "normal")
        cur = "crit" if pct >= crit_th else "warn" if pct >= warn_th else "normal"
        # 按 id 本地化窗口标签（通知用当前语言，不受采样时缓存影响）
        label = labels.get(w.get("id") or "", w.get("label", ""))
        if cur != prev:
            if cur == "crit":
                _notify(strs["crit"].format(tool=tool_name, label=label, pct=pct), sound=sound)
            elif cur == "warn" and prev == "normal":
                _notify(strs["warn"].format(tool=tool_name, label=label, pct=pct))
            elif cur == "normal" and prev in ("warn", "crit") and s["notify_reset"]:
                _notify(strs["reset"].format(tool=tool_name, label=label, pct=pct), sound=sound)
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
        _check_alerts("Claude", cl.get("windows", []))
    if cx.get("ok"):
        ws = cx.get("windows", [])
        if ws:
            sample["x5h"] = ws[0]["used_percent"]
        if len(ws) > 1:
            sample["x7d"] = ws[1]["used_percent"]
        _check_alerts("Codex", ws)
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
        HISTORY_FILE.write_text("\n".join(lines) + "\n")
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

def _parse_claude_file_usage(path):
    """返回 {hour: {model: [in, out, cache_read, cache_write_5m, cache_write_1h]}}

    同一条 API 响应会按 content block 拆成多行（usage 为相同快照），
    必须按 (message.id, requestId) 去重，否则 token/成本翻倍（实测重复率 55%）。
    cache 写入 5m/1h 单价不同（实测 91% 走 1h 档），按 cache_creation 细分。
    """
    agg = {}
    seen = set()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if '"usage"' not in line:
                continue
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            msg = evt.get("message") or {}
            usage = msg.get("usage")
            if not usage or evt.get("type") != "assistant":
                continue
            key = (msg.get("id"), evt.get("requestId"))
            if key != (None, None):
                if key in seen:
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
    return agg


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


def _cached_file_agg(path, parser):
    st = path.stat()
    key = str(path)
    with _cache_lock:
        hit = _file_agg_cache.get(key)
        if hit and hit[0] == st.st_mtime and hit[1] == st.st_size:
            return hit[2]
    parsed = parser(path)
    with _cache_lock:
        _file_agg_cache[key] = (st.st_mtime, st.st_size, parsed)
    return parsed


def _parse_codex_file_usage(path):
    """取该会话最后一条 token_count 的累计值，归属到文件 mtime 的 UTC 小时。

    返回 {hour: (tokens, api_cost)}；cached_input ⊂ input、reasoning ⊂ output，
    相加会翻倍，total_tokens 即 in+out。成本按官方 API 价折算（缓存读 -90%）。
    """
    total, cost, tu, model = 0, 0.0, None, ""
    for line in reversed(_tail_lines(path)):
        if tu is None and '"total_token_usage"' in line:
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            info = (evt.get("payload") or {}).get("info") or {}
            tu = info.get("total_token_usage") or {}
            continue
        if not model:
            m = re.search(r'"model":"([^"]+)"', line)
            if m:
                model = m.group(1)
        if tu is not None and model:
            break
    if tu:
        inp = tu.get("input_tokens", 0)
        cached = min(tu.get("cached_input_tokens", 0), inp)
        out = tu.get("output_tokens", 0)
        total = tu.get("total_tokens") or (inp + out)
        p = _codex_price(model)
        cost = ((inp - cached) * p[0] + out * p[1] + cached * p[2]) / 1e6
    hour = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc) \
        .strftime("%Y-%m-%dT%H")
    return {hour: (total, cost)}


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

        for path in CLAUDE_PROJECTS.glob("*/*.jsonl"):
            try:
                if path.stat().st_mtime < cutoff:
                    continue
                agg = _cached_file_agg(path, _parse_claude_file_usage)
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
                                p = projects.setdefault(fcwd, {"tokens": 0, "cost": 0.0})
                                p["tokens"] += sum(tk)
                                p["cost"] += c
                    if ep and ep >= hour_cut:
                        hourly.setdefault(ep, {"c": 0, "x": 0})["c"] += sum(tk)

        codex_daily = {d: 0 for d in days}
        xcost_30d = xcost_7d = 0.0
        for path in _iter_codex_files(200):
            try:
                if path.stat().st_mtime < cutoff:
                    continue
                agg = _cached_file_agg(path, _parse_codex_file_usage)
            except OSError:
                continue
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
                            p = projects.setdefault(cwd, {"tokens": 0, "cost": 0.0})
                            p["tokens"] += total
                            p["cost"] += cost
                if ep and ep >= hour_cut:
                    hourly.setdefault(ep, {"c": 0, "x": 0})["x"] += total

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
            "ts": time.time(),
        }
    return cached("usage", 120, build)


# ----------------------------------------------------------------- 恢复会话

_ID_RE = re.compile(r"^[A-Za-z0-9-]{8,64}$")


def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def _osa_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


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
        out.write_text("\n".join(rows) + "\n")
        subprocess.run(["open", "-R", str(out)], timeout=10)   # Finder 中显示
        return {"ok": True, "path": str(out)}
    if act == "clear_events":
        with _events_lock:
            _events.clear()
        try:
            EVENTS_FILE.write_text("")
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


def api_resume(body):
    tool = body.get("tool")
    sid = body.get("id", "")
    cwd = body.get("cwd") or str(HOME)
    if tool not in ("claude", "codex") or not _ID_RE.match(sid):
        return {"ok": False, "error": "invalid args"}
    if not os.path.isdir(cwd):
        cwd = str(HOME)
    binary = "claude --resume" if tool == "claude" else "codex resume"
    cmd = f"cd {_shell_quote(cwd)} && {binary} {sid}"

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
        r = subprocess.run(["open", "-a", app, cwd],
                           capture_output=True, text=True, timeout=20)
        if r.returncode != 0:    # 该 App 不接受目录参数时退化为仅打开
            subprocess.run(["open", "-a", app], capture_output=True, timeout=20)
        disp = next(d for m, _, d in _PASTE_TERMS if m == mode)
        return {"ok": True, "copy": True, "paste": True, "command": cmd,
                "terminal": mode, "app": disp}

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
        args = {
            "ghostty": ["-e", "zsh", "-ic", keep],
            "kitty": ["--directory", cwd, "zsh", "-ic", keep],
            "wezterm": ["start", "--cwd", cwd, "--", "zsh", "-ic", keep],
            "alacritty": ["--working-directory", cwd, "-e", "zsh", "-ic", keep],
        }[mode]
        proc = subprocess.run(["open", "-na", run_avail[mode], "--args", *args],
                              capture_output=True, text=True, timeout=20)
    if proc.returncode != 0:
        return {"ok": False, "error": proc.stderr.strip()}
    return {"ok": True, "command": cmd, "terminal": mode}


# ----------------------------------------------------------------- HTTP 层

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
        try:
            if path == "/api/health":
                self._send(200, {"ok": True, "pid": os.getpid(),
                                 "version": VERSION})
            elif path == "/api/quota":
                self._send(200, api_quota())
            elif path == "/api/sessions":
                self._send(200, api_sessions())
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
        allowed = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
        origin = self.headers.get("Origin", "")
        if origin:
            p = urlparse(origin)
            if p.scheme != "http" or p.netloc not in allowed:
                return False
        host = self.headers.get("Host", "")
        return host in allowed

    def do_POST(self):
        if not self._csrf_ok():
            return self._send(403, {"error": "forbidden"})
        path = self.path.split("?")[0]
        handlers = {"/api/resume": api_resume, "/api/pin": api_pin,
                    "/api/settings": api_settings_save, "/api/event": api_event,
                    "/api/focus": api_focus, "/api/data": api_data}
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


def main():
    _events_load()
    _alert_state_load()
    threading.Thread(target=_sampler_loop, daemon=True).start()
    threading.Thread(target=_keepawake_loop, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"agentdeckd listening on http://127.0.0.1:{PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
