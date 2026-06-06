<h1 align="center">AgentDeck</h1>

<p align="center">
  A macOS menu-bar app that unifies quota, session, and usage monitoring for <b>Claude Code</b> and <b>Codex</b>.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/dependencies-none-brightgreen" alt="Dependencies">
  <img src="https://img.shields.io/badge/i18n-中%20%C2%B7%20EN%20%C2%B7%20日-8a7cff" alt="i18n">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="License">
</p>

<p align="center">
  <a href="https://agentdeck.yilin.dev">Website</a> ·
  <a href="README.md">简体中文</a> · <b>English</b>
</p>

<p align="center">
  <img src="docs/screenshots/i18n-demo.gif" width="300" alt="Overview and sessions panel (zh / en / ja)">
  &nbsp;
  <img src="docs/screenshots/settings-zh.png" width="300" alt="Settings panel">
</p>
<p align="center"><sub>Left: overview / sessions panel (trilingual rotation, follows the system language) · Right: settings</sub></p>

AgentDeck integrates quota monitoring, session management, and usage analytics for Claude Code and Codex into a single menu-bar panel. The backend is a pure standard-library Python daemon, the app shell is a single Swift file compiled directly with `swiftc`, and the UI is a single HTML file — no package manager, no build chain, no runtime downloads.

## Design principles

- **Zero third-party dependencies** — stdlib Python + natively compiled Swift + WKWebView; no Node, Electron, or bundlers
- **Local-first** — all data is processed on your machine with zero telemetry; exactly two outbound requests (quota query, update check), both transparent in intent and the latter can be disabled
- **Native experience** — continuous-curvature corners, glass materials, and a desktop widget held to system-widget visual standards
- **Multilingual** — Simplified Chinese / English / Japanese unified across all three layers (panel / notifications / menus), following the system by default

## Features

**Quota monitoring**
- Live aggregation of Claude's official quota (5-hour / 7-day windows) and Codex rate limits
- Always-on usage percentage in the menu bar (configurable: one side, both, or hidden)
- Window-reset progress bars; system notifications for nearing or refilled quota (configurable thresholds)

**Session management**
- Detects active sessions on both sides, covering terminal CLI sessions and Codex desktop sessions
- Click an active session to focus its terminal: the host `.app` is auto-detected by walking the process tree, so any terminal works without a maintained allowlist; iTerm2 / Terminal focus the exact tab; Codex desktop sessions deep-link via `codex://`
- Session-done popups, click to jump back; events are deduplicated and alert once
- One-click resume for past sessions: direct command injection for iTerm2 / Terminal / Ghostty / kitty / WezTerm / Alacritty; "open app + copy command" for Warp / VS Code / Cursor / Windsurf / Hyper / Tabby / Rio / Wave
- Session list with search, per-side filtering, pinning, and conversation preview

**Usage analytics**
- 7- / 30-day token usage and cost estimates (methodology below)
- Daily digest, 24-hour comparison curve, model breakdown, per-project ranking
- CSV export

**Interface & system**
- Font scaling from 80–160% (panel and widget in sync); panel dimming, minimal mode, and other appearance options
- Keeps the system awake while sessions are active so long tasks survive sleep (on by default, can be disabled)
- Update discovery: automatic checks (version number only, can be disabled) plus a manual check in Settings; a dismissible banner appears when a new version ships
- Desktop widget: a glass info card on the desktop layer with drag, resize, and position memory

## Installation

```bash
git clone https://github.com/Spacebody/AgentDeck.git && cd AgentDeck
./build.sh install
```

Compiles, installs to `/Applications`, and launches; the first launch registers a login item.

**Requirements**: macOS 13+; [Claude Code](https://claude.com/claude-code) or [Codex](https://openai.com/codex) installed (either); Xcode Command Line Tools (provides `swiftc`; install via `xcode-select --install`).

Other build targets:

```bash
./build.sh           # build dist/AgentDeck.app only
./build.sh dmg       # produce a distributable DMG
./build.sh uninstall # uninstall (data directory kept by default)
```

The first "jump to session" prompts for **Automation (Apple Events)** permission, which is used to focus terminal windows.

## Optional: session-done alerts

Done alerts rely on Claude / Codex event callbacks. AgentDeck never modifies external config files; wire it up manually (one line each):

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

**Codex** — point `notify` in `~/.codex/config.toml` to the wrapper script in this repo:

```toml
notify = ["/path/to/agentdeck/scripts/codex-notify.sh"]
```

If `notify` is already used by another tool, chain-forward the original command with `exec` at the end of the script (see the script's comments).

## Architecture

```
agentdeckd.py        backend daemon: collection / parsing / aggregation / HTTP API (stdlib only)
app/main.swift       app shell: menu bar, panel, desktop widget, done alerts
static/index.html    panel UI: single file, no build step
site/                website and update manifest (Cloudflare Pages, dependency-free static page)
build.sh             build / install / DMG / uninstall
scripts/             icon & DMG-background generation, Codex notify wrapper, CSRF regression test
```

The app shell starts the daemon on launch (listening on `127.0.0.1:7777`); the panel and widget are WKWebViews loading the same local page and reading data over the HTTP API.

## Data sources & privacy

All data is **processed locally** — no telemetry, no reporting:

| Data | Source | Notes |
|------|--------|-------|
| Claude quota | Claude Code OAuth credential in Keychain → `api.anthropic.com/api/oauth/usage` | Your own credentials querying your own quota |
| Update check | `agentdeck.yilin.dev/version.json` (static manifest, 6-hour cache) | Version comparison only; carries no credentials or machine info; can be disabled in Settings |
| Claude usage / sessions | parses local `~/.claude/projects/**/*.jsonl` | token stats, cost estimates, session list |
| Codex quota / usage / sessions | parses local `~/.codex/sessions` rollout files | same as above |
| Done events | Claude Stop hook / Codex notify callback (see optional config) | done alerts and the event stream |

Runtime artifacts: data directory `~/Library/Application Support/AgentDeck/`, log `~/Library/Logs/AgentDeck.log`.

## Security

- The daemon binds only the loopback address `127.0.0.1` and is never exposed to the LAN
- All POST endpoints sit behind a CSRF barrier: exact Content-Type matching, structured Origin validation, and a Host allowlist (blocks DNS rebinding); regression test at `scripts/test-csrf.sh`
- Any "read a file from a request parameter" path is confined to `~/.claude` (realpath-checked)
- The health check is identity-verified so a port occupied by another process is not mistaken for the app

## Cost methodology

- **Claude**: usage rows deduplicated by `(message.id, requestId)`; cache writes priced separately for ephemeral 5m / 1h tiers; price table matched by model-version prefix
- **Codex**: uses `total_token_usage.total_tokens` (cached is a subset of input, reasoning a subset of output, avoiding double counting); API-equivalent reference pricing for subscription plans
- Cross-calibrated against [ccusage](https://github.com/ryoppippi/ccusage) with roughly ±4% deviation (from cache-tier pricing precision)
- Each ⓘ entry in the panel documents the exact methodology of its view

## Acknowledgements

- Menu-bar brand glyphs come from the template images bundled with the official Claude / Codex apps; copyright belongs to Anthropic / OpenAI, used solely for source identification
- Terminal focusing for session jumps originally borrowed MioIsland's idea (Ghostty cwd-precise focus); it has since evolved into automatic host detection for any terminal via the process tree
- Usage statistics are cross-calibrated against [ccusage](https://github.com/ryoppippi/ccusage) as an independent baseline

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE)
