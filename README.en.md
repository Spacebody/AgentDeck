<p align="center">
  <img src="docs/icon.png" width="96" alt="AgentDeck icon">
</p>

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

AgentDeck integrates quota monitoring, session management, and usage analytics for Claude Code and Codex into a single menu-bar panel. The backend is a pure standard-library Python daemon, and the macOS client is a native AppKit + SwiftUI app in a SwiftPM package. It still has zero third-party runtime dependencies: no Node, Electron, bundlers, or runtime downloads.

## Design principles

- **Zero third-party dependencies** — stdlib Python + native SwiftPM AppKit / SwiftUI; no Node, Electron, or bundlers
- **Local-first** — all data is processed on your machine with zero telemetry; exactly two outbound requests (quota query, update check), both transparent in intent and the latter can be disabled
- **Native experience** — continuous-curvature corners, glass materials, and a desktop widget held to system-widget visual standards
- **Multilingual** — Simplified Chinese / English / Japanese unified across all three layers (panel / notifications / menus), following the system by default

## Features

**Quota monitoring**
- Live aggregation of Claude's official quota (5-hour / 7-day windows) and Codex rate limits
- Multi-account in parallel: auto-discovers multiple Claude config directories (`CLAUDE_CONFIG_DIR` / `~/.claude-*` / shell startup files), queries quota per account, with a panel carousel and an optional menu-bar rotation across accounts
- Always-on usage percentage in the menu bar (configurable: one side, both, or hidden; the number and the alert color each pick from the 5h / weekly / tightest window)
- Adjustable quota-query interval (default 10 minutes, up to 6 hours) to throttle official-endpoint calls and ease multi-account rate limiting
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
- Theme palette: pick custom Claude / Codex accent colors; quota rings, progress bars, usage curves, and the logo gradient all recolor in sync, with one-click reset to the built-in orange / teal
- Show-Agent toggles: users of only Claude or only Codex can hide the other side, after which no quota is fetched for it (skips Keychain reads and official-endpoint calls)
- Font scaling from 80–160% (panel and widget in sync); panel dimming, minimal mode, and other appearance options
- Keeps the system awake while sessions are active so long tasks survive sleep (on by default, can be disabled)
- Works behind corporate proxies: the app's traffic to its local daemon bypasses system-level PAC proxies, avoiding a blank panel when loopback gets rerouted
- Update discovery: automatic checks (version number only, can be disabled) plus a manual check in Settings; a dismissible banner appears when a new version ships
- Desktop widget: a glass info card on the desktop layer with drag, resize, and position memory

## Installation

```bash
git clone https://github.com/Spacebody/AgentDeck.git && cd AgentDeck
./build.sh install
```

Compiles, installs to `/Applications`, and launches; the first launch registers a login item.

**Requirements**: macOS 13+ (produces an Apple Silicon + Intel universal binary); [Claude Code](https://claude.com/claude-code) or [Codex](https://openai.com/codex) installed (either); Xcode Command Line Tools (provides SwiftPM / the Swift toolchain; install via `xcode-select --install`).

Other build targets:

```bash
./build.sh           # build dist/AgentDeck.app only
./build.sh dmg       # produce a distributable DMG
./build.sh uninstall # uninstall (data directory kept by default)
```

The first "jump to session" prompts for **Automation (Apple Events)** permission, which is used to focus terminal windows.

## Session-Done Alert Integration

Done alerts rely on Claude / Codex event callbacks. The current daemon wires them up **automatically and idempotently** on startup, and only merges / removes entries marked as AgentDeck-owned:

- Claude Code: merges a Stop hook into `~/.claude/settings.json` that points to `~/Library/Application Support/AgentDeck/claude-stop-hook.sh`.
- Codex: points `notify` in `~/.codex/config.toml` to `~/Library/Application Support/AgentDeck/codex-notify.sh`. If another notify command already exists, the generated wrapper chain-forwards back to it.
- Integration state is stored in `~/Library/Application Support/AgentDeck/integration.json`; `./build.sh uninstall` calls the daemon's `--remove-integration` path to restore only AgentDeck-owned entries.

The repository still includes `scripts/codex-notify.sh` for manual debugging, but normal app installs use the generated wrapper in Application Support.

The minimal manual Claude Stop forwarding command looks like this:

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

## Architecture

```
Package.swift        SwiftPM package: AgentDeck executable, AgentDeckKit library, PreviewGen renderer
Sources/AgentDeck/   AppKit shell: menu bar, NSPanel, desktop widget, island alerts, daemon supervision
Sources/AgentDeckKit/SwiftUI UI, API client, data models, trilingual i18n, preview rendering
Sources/PreviewGen/  headless UI screenshot renderer for development checks
agentdeckd.py        backend daemon: collection / parsing / aggregation / HTTP API / hook integration (stdlib only)
static/index.html    legacy Web UI / browser fallback; still served by the daemon at / and /index.html
site/                website and update manifest (Cloudflare Pages, dependency-free static page)
build.sh             build / install / DMG / uninstall
scripts/             icon & DMG-background generation, Codex notify wrapper, CSRF regression test
```

The app shell starts the daemon on launch (listening on `127.0.0.1:7777`); the panel and widget are SwiftUI roots hosted in `NSHostingView` and read data over the HTTP API. `static/index.html` is no longer the primary app UI.

## Data sources & privacy

All data is **processed locally** — no telemetry, no reporting:

| Data | Source | Notes |
|------|--------|-------|
| Claude quota | Claude Code OAuth credential in Keychain → `api.anthropic.com/api/oauth/usage` | Your own credentials querying your own quota; with multiple accounts, the matching credential is resolved per config directory |
| Update check | `agentdeck.yilin.dev/version.json` (static manifest, 6-hour cache) | Version comparison only; carries no credentials or machine info; can be disabled in Settings |
| Claude usage / sessions | parses `projects/**/*.jsonl` under each discovered Claude config directory | token stats, cost estimates, session list |
| Codex quota / usage / sessions | parses local `~/.codex/sessions` rollout files | same as above |
| Done events | AgentDeck-installed Claude Stop hook / Codex notify wrapper callbacks (see Session-Done Alert Integration) | done alerts and the event stream |

Runtime artifacts: data directory `~/Library/Application Support/AgentDeck/`, log `~/Library/Logs/AgentDeck.log`.

## Security

- The daemon binds only the loopback address `127.0.0.1` and is never exposed to the LAN
- All POST endpoints sit behind a CSRF barrier: exact Content-Type matching, structured Origin validation, and a Host allowlist (blocks DNS rebinding); regression test at `scripts/test-csrf.sh`
- Any "read a file from a request parameter" path is confined to the discovered Claude config directories (realpath-checked)
- The account-diagnostics endpoint `/api/diag` exposes credential fingerprints and local paths, so it carries an extra Host check to block DNS rebinding; its output is fully redacted (tokens kept to their last 4 characters)
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
