# v3 Native Dashboard

## Scope

Implemented on branch `v3` from `AgentDeck-UI-开发包.zip` (START-HERE,
SPEC, ENGINEERING, ACCEPTANCE and four reference screens) for version 3.0.0.

## Implementation

- `RootView.swift`: shared graphite shell, four text navigation tabs, settings,
  refresh and a dedicated Quit button. Scaling and content-height reporting
  remain native. The panel minimum width is 420 logical points and scales with
  the font preference.
- `OverviewView.swift` / `DashboardComponents.swift`: today's usage beside the
  selected account's quota, hourly trend, active sessions and expandable
  project-grouped completions. `FlatQuotaCarousel` retains selection and menu-bar
  synchronization; widgets retain the previous quota presentation.
- `SessionsView.swift`: search and agent filtering in one row, active/history
  sections, existing pagination and asynchronous preview. Indexed active rows
  retain pin, copy, resume and directory-mapping actions. Only unambiguous
  account-scoped identities are deduplicated.
- `ProjectStore.swift` / `ProjectsView.swift`: independent project metadata and
  detail pagination. Expanded histories reconcile index revisions, scope changes
  clear incompatible snapshots, and background polling stops when the panel is
  hidden or settings are open.
- `UsageDashboardView.swift`: one 7/30-day scope for tokens, cost estimates,
  daily bars, agent proportions, project ranking and CSV export. Unknown costs
  remain unavailable. Codex incomplete-telemetry warnings remain visible.

## Backend Contracts

`GET /api/projects?tool=claude,codex` groups the entire SQLite session index
plus active sessions by resolved project path. It does not derive projects from
the current session page or usage rankings. Omitted/all selects all agents;
an explicit empty selection returns none.

`GET /api/projects?cwd=...&tool=...&cursor=...` returns account-scoped session
metadata in 30-row pages. Path mappings are applied once. Index or membership
changes invalidate the cursor and return the first page with `cursor_stale`.

`GET /api/usage` additionally returns `projects_all_30d` and
`costs_by_agent_daily` (agent -> local day -> estimated USD or null). Existing
fields are retained for old clients.

`POST /api/data` with `{"action":"export","days":7,"agents":["codex"]}`
exports the selected range and visible agents to a unique CSV in Downloads.
Missing cost cells are empty, not zero. Legacy exports without a range retain
their existing behavior.

## Verification

- `swift test`: unit/API tests, including range aggregation, localization,
  project visibility failures and stale pagination.
- `python3 -m unittest discover -s Tests -p 'test_*.py'`: daemon regressions,
  full-index projects, path mapping, account ambiguity and range CSV tests.
- `swift build --product PreviewGen`: `v3overview`, `v3sessions`, `v3projects`,
  `v3usage` modes use native AppKit snapshots so menus and input fields render.
  `AD_LOCALE` selects zh-CN/en/ja; `AD_FONT_SCALE` selects 80...160 percent.
- `./build.sh install`: signed arm64+x86_64 local installation, macOS 13 minimum.
- `python3 scripts/verify-runtime.py`: 30 health samples and existing API checks.
- Read-only runtime checks also compare every project count to its detail total
  and check the new 30-day fields and empty visibility selection.

Independent CR findings were fixed before handoff. Native UI automation cannot
currently attach to the app (Computer Use timeout). Static native rendering and
API tests do not replace live clicking, keyboard, hover or scrolling tests.
The owner still needs to verify navigation, settings, search/filter/paging,
project expansion, 7/30-day switching and export in the installed app.
Resume/focus actions on the owner's active sessions were deliberately not run.
Do not publish until the owner confirms the local build.

## November 20 companion surfaces

The panel and desktop widget use continuous AppKit masks (16 and 14 points)
and native shadows. The settings and agent pages use unframed rows; numeric
presets preserve the schema's storage units, including seconds for intervals
displayed in minutes. The widget shows up to two accounts and keeps the full
active-session count even when only one session fits.

The local browser client retains two tabs. Its widget, settings, quota rows and
methodology dialog share the new styling; the public website uses v3 screenshots.
Browser checks used synthetic loopback responses, not the owner's sessions.
PreviewGen covers the four main pages, settings, agent management and the
widget size/window matrices. Preview images are not evidence of AppKit window
shadows, dragging, click-through, or live color-panel interaction.
