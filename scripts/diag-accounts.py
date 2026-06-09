#!/usr/bin/env python3
"""AgentDeck 多账号额度诊断 —— 摸清 Claude Code 在本机怎么存订阅 token。

跑法：  python3 diag-accounts.py
不泄露任何 token：只输出「是否含 claudeAiOauth / 订阅类型 / 末4位指纹」等非敏感信息。
把全部输出回贴给开发即可。会弹钥匙串授权，点「始终允许」可少弹几次。
"""
import json
import os
import re
import subprocess
from pathlib import Path

HOME = Path.home()


def redact(tok):
    if not tok:
        return None
    return f"len={len(tok)} …{tok[-4:]}"


def cred_summary(data):
    """从一份凭据 JSON 里提取非敏感摘要。"""
    if not isinstance(data, dict):
        return {"parse": "非 JSON 对象"}
    out = {"keys": sorted(data.keys())}
    oauth = data.get("claudeAiOauth")
    if isinstance(oauth, dict):
        out["claudeAiOauth"] = {
            "accessToken": redact(oauth.get("accessToken")),
            "subscriptionType": oauth.get("subscriptionType"),
            "scopes": oauth.get("scopes"),
            "expiresAt": oauth.get("expiresAt"),
        }
    out["has_mcpOAuth"] = "mcpOAuth" in data
    return out


def keychain_query(account=None):
    cmd = ["security", "find-generic-password", "-s", "Claude Code-credentials"]
    if account is not None:
        cmd += ["-a", account]
    cmd += ["-w"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    if r.returncode != 0:
        return {"found": False, "err": (r.stderr or "").strip()[:80]}
    try:
        return {"found": True, **cred_summary(json.loads(r.stdout.strip()))}
    except ValueError:
        return {"found": True, "parse": "非 JSON"}


def keychain_default_account():
    """无 -a 查询命中的那条 item 的 account 名（-g 打印 attributes）。"""
    r = subprocess.run(
        ["security", "find-generic-password", "-s", "Claude Code-credentials", "-g"],
        capture_output=True, text=True, timeout=20)
    blob = (r.stdout or "") + (r.stderr or "")
    m = re.search(r'"acct"<blob>=(?:"([^"]*)"|0x[0-9A-Fa-f]+\s+"([^"]*)")', blob)
    if m:
        return m.group(1) or m.group(2)
    return None


def discover_dirs():
    dirs = []
    seen = set()

    def add(p, why):
        p = Path(os.path.expanduser(str(p).replace("$HOME", str(HOME))))
        rp = os.path.realpath(p)
        if rp in seen or not p.is_dir():
            return
        seen.add(rp)
        dirs.append((p, why))

    env = os.environ.get("CLAUDE_CONFIG_DIR")
    if env:
        add(env, "CLAUDE_CONFIG_DIR(进程 env)")
    add(HOME / ".claude", "默认 ~/.claude")
    for p in sorted(HOME.glob(".claude-*")):
        add(p, "通配 ~/.claude-*")
    pat = re.compile(r'CLAUDE_CONFIG_DIR=(?:"([^"]*)"|\'([^\']*)\'|([^\s;]+))')
    for name in (".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"):
        try:
            txt = (HOME / name).read_text(errors="replace")
        except OSError:
            continue
        for m in pat.finditer(txt):
            raw = m.group(1) or m.group(2) or m.group(3) or ""
            if raw:
                add(raw, f"shell rc({name})")
    return dirs


print("=" * 64)
print("AgentDeck 多账号额度诊断")
print("=" * 64)

print("\n[1] 发现的 Claude 配置目录")
dirs = discover_dirs()
for p, why in dirs:
    line = f"  {p}   （{why}）"
    cf = p / ".credentials.json"
    if cf.exists():
        try:
            line += f"\n      .credentials.json: {cred_summary(json.loads(cf.read_text()))}"
        except (OSError, ValueError) as e:
            line += f"\n      .credentials.json 读取失败: {e}"
    else:
        line += "\n      .credentials.json: 不存在"
    sf = p / "settings.json"
    if sf.exists():
        try:
            s = json.loads(sf.read_text())
            env = (s.get("env") or {}) if isinstance(s, dict) else {}
            gw = env.get("ANTHROPIC_BASE_URL") or env.get("ANTHROPIC_AUTH_TOKEN")
            line += f"\n      settings.json 网关标记: {'有(' + str(env.get('ANTHROPIC_BASE_URL','AUTH_TOKEN')) + ')' if gw else '无'}"
        except (OSError, ValueError):
            pass
    print(line)

print("\n[2] 钥匙串 service='Claude Code-credentials' 探测")
print(f"  无 -a 查询命中的 account 名: {keychain_default_account()!r}")
print("  各候选 account 查询结果（found + 是否含 claudeAiOauth）:")
candidates = [None, os.environ.get("USER")]
for p, _ in dirs:
    candidates.append(str(p))
    candidates.append(p.name)
seen_acct = set()
for acct in candidates:
    key = repr(acct)
    if key in seen_acct:
        continue
    seen_acct.add(key)
    print(f"    -a {acct!r:42} → {keychain_query(acct)}")

print("\n[3] 完。把以上全部输出回贴即可（无 token 明文）。")
