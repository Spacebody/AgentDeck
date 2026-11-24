# Antigravity lifecycle hooks

Opt-in integration for Google Antigravity App, CLI (`agy`), and IDE. This is not
Gemini CLI. No discovery, configuration write, transcript read, or private API
is required. See Google's [hook schema and I/O contract](https://antigravity.google/docs/hooks).

After approval, merge this named group into **one** existing hook map:
`.agents/hooks.json` in the workspace or `~/.gemini/config/hooks.json` globally.
Preserve other groups. Do not put it in Gemini CLI settings. The commands
below assume AgentDeck is installed in `/Applications`. Use Settings >
Customizations > Hooks (App) or `/hooks` (CLI) to check it loaded.

```json
{
  "agentdeck-lifecycle": {
    "enabled": true,
    "PreInvocation": [
      {"type":"command","command":"/usr/bin/python3 '/Applications/AgentDeck.app/Contents/Resources/antigravity-hook.py' PreInvocation","timeout":3}
    ],
    "Stop": [
      {"type":"command","command":"/usr/bin/python3 '/Applications/AgentDeck.app/Contents/Resources/antigravity-hook.py' Stop","timeout":3}
    ]
  }
}
```

AgentDeck packages `scripts/antigravity-hook.py` as
`AgentDeck.app/Contents/Resources/antigravity-hook.py`; no separate script
installation is needed. Packaging does not enable the hooks. Requires Python 3
and a matching running daemon. Hook delivery uses only the Unix socket at
`~/Library/Application Support/AgentDeck/lifecycle/events.sock`, under a
mode-0700 directory owned by the user. Both endpoints verify the connected
peer's UID; the hook sends nothing before verification. Other processes running
as the same user are inside this trust boundary. If the daemon is unavailable,
the event is dropped; there is no HTTP fallback, spool or retry. Disable the
group to stop delivery.

`PreInvocation` marks the identified conversation busy. A fully idle `Stop`
removes it even when notifications are disabled. A missing stop expires the
display row and its generation after ten minutes without a pre-invocation.
The next pre-invocation starts a fresh clock even if nobody polled the display.
Expiration never queues an event.
Only `Stop` with `terminationReason=model_stop`, literal `fullyIdle=true`,
and no reported error can queue a notification. This describes the reported
execution boundary, not proof that a user's task succeeded; another Stop hook
can request continuation. The bridge itself never requests continuation.

Only the conversation UUID, working directory (or unambiguous workspace),
recognized App/CLI/IDE source tag, event and stop metadata are forwarded. The
tag is derived locally from the documented artifact-directory field without
opening it. Matching indexed App/CLI rows keep their original source and
account. No prompt, transcript, error text, PID or focus target is forwarded.

The first observed pre-invocation opens a generation and starts its duration
clock. Further invocations leave that clock unchanged. A fully idle stop
consumes the generation, even if it is too short or notifications are off.
Without an open generation, even a much later stop is ignored. Two observed
pre/stop cycles get distinct queue keys regardless of timing. A daemon restart
discards open generations. The hooks do not supply a shared unique turn ID:
an out-of-order replay arriving during a different open generation cannot be
distinguished from that generation's own otherwise identical stop.
The bridge is synchronous and does not retry or guarantee exactly-once delivery.
