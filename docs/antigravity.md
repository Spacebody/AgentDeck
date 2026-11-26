# Antigravity CLI usage (opt-in)

Opening AgentDeck or showing the agent does not enable collection. Explicitly
enable it from the Antigravity quota panel, or manually merge the entry below
into `~/.gemini/antigravity-cli/settings.json` using the actual installed path.
Desktop alone does not supply these measurements.

```json
{
  "statusLine": {
    "type": "command",
    "stack_with_default": true,
    "command": "/usr/bin/python3 '/Applications/AgentDeck.app/Contents/Resources/antigravity_usage.py'"
  }
}
```

This keeps the CLI's built-in status line and adds the fixed label `Antigravity CLI`.
It does not display quota, session identifiers, or input text. Keep any
previous entry and restore it (or remove this entry) to stop collection.
The [official status-line JSON contract](https://antigravity.google/docs/cli/statusline/)
is the only input. No network, credentials, transcripts or prompts are accessed;
raw stdin is never saved or logged.

The opt-in action only inserts a missing `statusLine` into the initialized CLI
directory; it refuses custom/disabled entries, malformed settings and unsafe
paths. An already enabled AgentDeck command is left as-is. To stop collection,
disable the command in the CLI or remove the AgentDeck entry. Normal quota
refreshes pick up the first usable observation without forcing a scan.

The `antigravity.setup_state` field on `GET /api/quota` is `ready` when the
visible quota surface has usable reported quota; without it, `waiting` means
the receiver is configured, `available` means it can be installed, `conflict`
means settings cannot safely be changed, and `cli_missing` means the CLI
configuration directory is absent. These are not subscription or usage values.
`POST /api/antigravity/enable` accepts only a valid per-instance `proof` with
the usual loopback Host, Origin and JSON checks. The proof is lowercase hex
HMAC-SHA256 over UTF-8 `antigravity-enable:<health.instance_id>`, keyed by the
UTF-8 hex contents of the daemon's owner-only `antigravity-enable.token` in
AgentDeck Application Support. The key rotates after successful port binding,
is never sent over HTTP, and is not needed to read quota. A rejected proof
returns HTTP 403; an authorized request returns `{ok, setup_state}` without
returning settings, paths, credentials or command text.

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
