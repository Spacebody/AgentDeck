<h1 align="center">AgentDeck</h1>

<p align="center">
  Keep an eye on <b>Claude Code</b> &amp; <b>Codex</b> — quota, sessions, and usage — right from your menu bar.<br>
  Native liquid-glass feel · zero third-party dependencies · everything stays on your Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="Dependencies">
  <img src="https://img.shields.io/badge/i18n-中%20%C2%B7%20EN%20%C2%B7%20日-8a7cff" alt="i18n">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

<p align="center"><a href="README.md">简体中文</a> · <b>English</b></p>

<p align="center">
  <img src="docs/screenshots/i18n-demo.gif" width="300" alt="AgentDeck panel (中 / EN / 日)">
  &nbsp;
  <img src="docs/screenshots/settings-zh.png" width="300" alt="Settings">
</p>
<p align="center"><sub>Overview panel (Simplified Chinese / English / 日本語, follows the system) · Settings</sub></p>

AgentDeck tucks Claude Code's and Codex's **quota, sessions, and usage** into one menu-bar window: it warns you before a window fills up, jumps you back to whichever terminal a session is running in, and shows at a glance how many tokens today burned. The whole project has zero third-party dependencies — a pure standard-library Python daemon + a single-file Swift app shell + a single-file HTML UI. No package manager, no build chain, no runtime downloads.

## Highlights

- **Both agents, one place** — Claude Code and Codex quota / sessions / usage in a single panel; no flipping between tools
- **Zero deps, natively compiled** — no Node, no Electron, no bundler; `swiftc` builds a real native app you can run immediately
- **Local-only privacy** — everything is processed on your machine; just two outbound requests: your own credentials reading your own quota, and an optional update check. No telemetry, no upload
- **System-grade polish** — continuous-curvature corners, glass material, a desktop widget — built to the look of native macOS widgets
- **Multilingual out of the box** — Simplified Chinese / English / 日本語, follows the system, switch instantly in Settings

## Features

**Quota monitoring**
- Aggregates Claude's official quota (5-hour / 7-day windows) and Codex rate limits in real time
- Always-on usage percentage in the menu bar — show one, several, or hide
- Window-reset progress bar; system alerts when quota nears the limit or refills (configurable thresholds)

**Session management**
- Detects active sessions on both sides — CLI sessions running in a terminal and Codex desktop sessions
- Click an active session to focus its terminal — **auto-detects the host terminal, works with any terminal** (walks the process tree to the owning `.app`, no list to maintain; iTerm2 / Terminal focus the exact tab); Codex desktop sessions jump straight to the thread via a `codex://` deep link
- Session-done popup (Dynamic-Island style), click to jump back; events deduped, alerts once
- Resume a past session in a terminal with one click — auto-run in iTerm2 / Terminal / Ghostty / kitty / WezTerm / Alacritty, or "open + paste" for Warp / VS Code / Cursor / Windsurf / Hyper / Tabby / Rio / Wave

**Usage analysis**
- 7- / 30-day token usage and cost estimates, cross-calibrated against an independent tool (see below)
- Today summary, 24-hour comparison curve, model breakdown, top projects
- Export to CSV

**Desktop widget**
- A glass info card that lives on the desktop — drag, resize, and remembers its position

**Interface & system**
- Multilingual UI: Simplified Chinese / English / 日本語, follows the system, switch instantly in Settings
- Keeps the system awake while a session is active, so long tasks survive sleep / network drops (toggle, on by default)

## Quick start

```bash
git clone https://github.com/Spacebody/AgentDeck.git && cd AgentDeck
./build.sh install
```

One command compiles, installs to `/Applications`, and launches; the first launch registers a login item for auto-start. Click the menu-bar icon to open the panel.

**Requirements**: macOS 13+ · [Claude Code](https://claude.com/claude-code) or [Codex](https://openai.com/codex) installed (either is fine) · Xcode Command Line Tools (provides `swiftc`; run `xcode-select --install`).

Other build targets:

```bash
./build.sh           # build dist/AgentDeck.app only
./build.sh dmg       # produce a distributable DMG (with drag-to-install layout)
./build.sh uninstall # uninstall the app (data dir kept by default)
```

The first time you use "jump to session", macOS asks for **Automation (Apple Events)** permission to focus the target terminal — please allow it.

## Optional: session-done alerts

Done alerts rely on Claude / Codex event callbacks. AgentDeck never edits your config files for you — wire it up manually (a one-line change each):

**Claude Code** — append to `hooks.Stop` in `~/.claude/settings.json`:

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

**Codex** — point `notify` to the wrapper script in this repo, in `~/.codex/config.toml`:

```toml
notify = ["/path/to/agentdeck/scripts/codex-notify.sh"]
```

If `notify` is already taken by another tool, chain-forward the original command with `exec` at the end of the script (see the script's notes).

## Architecture

```
agentdeckd.py        backend daemon: collection / parsing / aggregation / HTTP API (stdlib only)
app/main.swift       app shell: menu bar, glass panel, desktop widget, done popup
static/index.html    panel UI: single file, no build step
build.sh             build / install / DMG / uninstall
scripts/             icon & DMG-background generation, Codex notify wrapper, CSRF regression test
```

The app shell starts the backend daemon (listening on `127.0.0.1:7777`) on launch; the panel and widget are both WKWebViews loading the same local page, talking to it over the HTTP API.

## Data sources & privacy

Everything is **processed locally only** — no telemetry, no reporting:

| Data | Source | Notes |
|------|--------|-------|
| Claude quota | Claude Code OAuth credential in Keychain → `api.anthropic.com/api/oauth/usage` | Your own credentials reading your own quota |
| Update check | `agentdeck.yilin.dev/version.json` (static manifest, 6h cache) | Version string comparison only — no credentials, no machine info; can be disabled in Settings |
| Claude usage / sessions | parses local `~/.claude/projects/**/*.jsonl` | token stats, cost estimates, session list |
| Codex quota / usage / sessions | parses local `~/.codex/sessions` rollout files | same as above |
| Done events | Claude Stop hook / Codex notify callback (see optional config) | done alerts and the event stream |

Runtime artifacts: data dir `~/Library/Application Support/AgentDeck/`, log `~/Library/Logs/AgentDeck.log`.

## Security

- The daemon binds the loopback address `127.0.0.1` only — never exposed to the LAN
- All POST endpoints have a CSRF barrier: exact Content-Type match + structured Origin validation + Host allowlist (blocks DNS rebinding), with a regression test `scripts/test-csrf.sh`
- Any "read a file by request parameter" path is confined within `~/.claude` (realpath-checked)
- Health check is identity-verified, so a port taken by another process isn't mistaken for the app

## Cost methodology

- **Claude**: usage rows deduped by `(message.id, requestId)`; cache writes priced separately for ephemeral 5m / 1h tiers; price table matched by model-version prefix
- **Codex**: uses `total_token_usage.total_tokens` (cached is a subset of input, reasoning a subset of output, to avoid double-counting); shows an API-equivalent reference price for subscriptions
- Overall cross-calibrated against [ccusage](https://github.com/ryoppippi/ccusage), within ~±4% (the gap comes from cache-tier precision)
- Each ⓘ in the panel explains the methodology for that specific view

## Credits

- Menu-bar brand glyphs are taken from Claude / Codex's official in-app menu-bar template images, copyright Anthropic / OpenAI, used purely for source attribution
- The "focus by working directory" idea for Ghostty references MioIsland
- Usage stats are cross-calibrated against [ccusage](https://github.com/ryoppippi/ccusage) as an independent baseline

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
