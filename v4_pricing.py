"""Offline standard text API equivalents, not actual charges. See docs/v4-pricing.md."""

from collections.abc import Mapping
from typing import NamedTuple, Optional


PRICE_SNAPSHOT = "standard-text-usd-2026-11-25.1"
COMPONENTS = ("input_tokens", "output_tokens", "cache_read_tokens",
              "cache_write_5m_tokens", "cache_write_1h_tokens")


class _Rate(NamedTuple):
    # Integer nanodollars per token (equivalently milli-USD per million).
    prices: tuple
    context: int
    max_output: int
    max_priced_input: int


_OPUS45 = _Rate((5000, 25000, 500, 6250, 10000), 200000, 64000, 200000)
_OPUS46 = _Rate(_OPUS45.prices, 1000000, 128000, 1000000)
_SONNET45 = _Rate((3000, 15000, 300, 3750, 6000), 200000, 64000, 200000)
_SONNET46 = _Rate(_SONNET45.prices, 1000000, 128000, 1000000)
_HAIKU45 = _Rate((1000, 5000, 100, 1250, 2000), 200000, 64000, 200000)
_GPT52 = _Rate((1750, 14000, 175, None, None), 400000, 128000, 400000)
_GPT54_MINI = _Rate((750, 4500, 75, None, None), 400000, 128000, 400000)
_GPT54 = _Rate((2500, 15000, 250, None, None), 1050000, 128000, 272000)
_GPT55 = _Rate((5000, 30000, 500, None, None), 1050000, 128000, 272000)

_RATES = {
    "claude": {
        "claude-opus-4-5": _OPUS45, "claude-opus-4-5-20251101": _OPUS45,
        "claude-opus-4-6": _OPUS46, "claude-opus-4-7": _OPUS46,
        "claude-opus-4-8": _OPUS46,
        "claude-sonnet-4-5": _SONNET45, "claude-sonnet-4-5-20250929": _SONNET45,
        "claude-sonnet-4-6": _SONNET46,
        "claude-haiku-4-5": _HAIKU45, "claude-haiku-4-5-20251001": _HAIKU45,
    },
    "codex": {
        "gpt-5.2": _GPT52, "gpt-5.2-2025-12-11": _GPT52,
        "gpt-5.2-codex": _GPT52, "gpt-5.3-codex": _GPT52,
        "gpt-5.4-mini": _GPT54_MINI, "gpt-5.4-mini-2026-03-17": _GPT54_MINI,
        "gpt-5.4": _GPT54, "gpt-5.4-2026-03-05": _GPT54,
        "gpt-5.5": _GPT55, "gpt-5.5-2026-04-23": _GPT55,
    },
}


def api_equivalent_usd(agent, model, components) -> Optional[float]:
    """Compare one complete call to an independent standard global text request."""
    if not isinstance(agent, str) or not isinstance(model, str):
        return None
    rate = _RATES.get(agent, {}).get(model)
    if rate is None or not isinstance(components, Mapping) or components.keys() != set(COMPONENTS):
        return None
    counts = tuple(components[key] for key in COMPONENTS)
    if any(type(n) is not int or not 0 <= n <= rate.context for n in counts):
        return None
    output = counts[1]
    if (sum(counts) > rate.context or output > rate.max_output
            or sum(counts) - output > rate.max_priced_input):
        return None
    nano_usd = 0
    for n, price in zip(counts, rate.prices):
        if n:
            if price is None:
                return None
            nano_usd += n * price
    return nano_usd / 1_000_000_000
