# Antigravity CLI usage (opt-in)

AgentDeck does not install a hook or change CLI settings. The desktop app alone
does not supply these measurements. To opt in, manually merge this entry into
`~/.gemini/antigravity-cli/settings.json` using the actual installed path:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/usr/bin/python3 '/Applications/AgentDeck.app/Contents/Resources/antigravity_usage.py'"
  }
}
```

This replaces the current status line with the fixed label `Antigravity CLI`.
It does not display quota, session identifiers, or input text. Keep any
previous entry and restore it (or remove this entry) to stop collection.
The [official status-line JSON contract](https://antigravity.google/docs/cli/statusline/)
is the only input. No network, credentials, transcripts or prompts are accessed;
raw stdin is never saved or logged.

- Quota is the latest reported CLI quota map, not a list of accounts. Only bucket
  IDs, reported balances/fractions, reset fields and observation time are retained.
  Disabled or known-expired buckets are omitted. Missing is unknown, not zero.
  Identical snapshots are coalesced for up to a minute; reset seconds are relative
  to `observed_at`, not to the time the dashboard reads the record.
- Each session's first cumulative input/output counters establish a baseline,
  not historical usage. A restored session with the same ID resumes from its
  saved high-water mark. Replays and regressing counters add nothing. Increases
  are grouped by the UTC hour they were observed, including after a gap; actual
  generation times within that gap are unknown. No missing hours are backfilled.
- Only hashed session IDs and their counters, hourly sums, and the quota snapshot
  are stored in `~/Library/Application Support/AgentDeck/antigravity-usage/`
  (directory 0700, SQLite file 0600). After disabling the hook, removing this
  directory clears collection history and baselines.

**Packaging:** bundle `antigravity_usage.py` beside `agentdeckd.py` in
`Contents/Resources/` before signing. No third-party Python packages are needed.
The daemon calls `antigravity_usage.read_usage()` without starting the CLI.
It returns `quota` and up to 744 observed UTC hourly bins in `hourly`; no
store returns `{"quota": {}, "hourly": []}` without creating files.
