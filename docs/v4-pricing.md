# API-equivalent token cost

`standard-text-usd-2026-11-25.1` is an offline comparison against a fixed list of first-party, standard, global text API rates in USD. Applying the snapshot to an older request answers what its recorded tokens would cost under this reference, not what the user was billed on that date. Updating the snapshot changes the comparison, not the recorded facts.

## Rates

All numbers are USD per million tokens. A dash means the component is unsupported, not free. Model matching is exact and scoped to the agent. The dated IDs alongside their short names below are the only additional aliases.

| Claude API model ID | Ordinary input | Output | Cache read | 5-minute write | 1-hour write |
|---|---:|---:|---:|---:|---:|
| `claude-haiku-4-5`, `claude-haiku-4-5-20251001` | 1 | 5 | 0.10 | 1.25 | 2 |
| `claude-sonnet-4-5`, `claude-sonnet-4-5-20250929`, `claude-sonnet-4-6` | 3 | 15 | 0.30 | 3.75 | 6 |
| `claude-opus-4-5`, `claude-opus-4-5-20251101`, `claude-opus-4-6`, `claude-opus-4-7`, `claude-opus-4-8` | 5 | 25 | 0.50 | 6.25 | 10 |

Sources: [Anthropic pricing and cache lifetimes](https://platform.claude.com/docs/en/about-claude/pricing), [model limits](https://platform.claude.com/docs/en/models/overview), [model IDs and lifecycle](https://platform.claude.com/docs/en/about-claude/model-deprecations). For the listed 4.5 models the reference is limited to 200,000 total / 64,000 output tokens; the listed 4.6 and later models allow 1,000,000 / 128,000.

| OpenAI API model ID and official reference | Ordinary input | Output | Cached input |
|---|---:|---:|---:|
| [gpt-5.2](https://developers.openai.com/api/docs/models/gpt-5.2), `gpt-5.2-2025-12-11`, [gpt-5.2-codex](https://developers.openai.com/api/docs/models/gpt-5.2-codex), [gpt-5.3-codex](https://developers.openai.com/api/docs/models/gpt-5.3-codex) | 1.75 | 14 | 0.175 |
| [gpt-5.4-mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini), `gpt-5.4-mini-2026-03-17` | 0.75 | 4.50 | 0.075 |
| [gpt-5.4](https://developers.openai.com/api/docs/models/gpt-5.4), `gpt-5.4-2026-03-05` | 2.50 | 15 | 0.25 |
| [gpt-5.5](https://developers.openai.com/api/docs/models/gpt-5.5), `gpt-5.5-2026-04-23` | 5 | 30 | 0.50 |

The listed OpenAI models allow 128,000 output tokens. The first two rows have a 400,000-token context limit. For GPT-5.4 and GPT-5.5 the comparison is for an independent short-context request. Prompts over 272,000 tokens (cached plus uncached) trigger special session pricing; they return unavailable. These figures do not reconstruct a session's tariff, tool fees, batch, priority, fast-mode or regional adjustments.

## Query contract

Call `api_equivalent_usd(agent, model, components)` at query time, **once per recorded call before grouping**. Supply just five non-negative integers: `input_tokens` (uncached), `output_tokens` (including reasoning), `cache_read_tokens`, `cache_write_5m_tokens`, and `cache_write_1h_tokens`. For Codex, subtract cache hits from inclusive input once; do not add reasoning to inclusive output. Do not add an aggregate cache-write count to its TTL breakdown. Supply zero only when known, including structurally inapplicable cache writes on OpenAI.

Do not pass sampled or cumulative deltas as calls. An unrecognized model, missing count, unknown nonzero cache-write TTL or unsupported scope is not a zero-dollar observation. Keep unavailable calls visible in coverage when grouping. The equivalent is separate from reported monetary cost; do not add them together. Qoder credits and Antigravity observations have no dollar conversion here.
