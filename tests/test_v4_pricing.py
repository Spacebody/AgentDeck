import unittest

from v4_pricing import api_equivalent_usd


def components(**counts):
    return dict(dict(input_tokens=0, output_tokens=0, cache_read_tokens=0,
                     cache_write_5m_tokens=0, cache_write_1h_tokens=0), **counts)


class PricingTests(unittest.TestCase):
    def test_claude_cache_ttl_categories_are_disjoint(self):
        counts = components(input_tokens=1000, output_tokens=2000, cache_read_tokens=3000,
                            cache_write_5m_tokens=4000, cache_write_1h_tokens=5000)
        for model in ("claude-sonnet-4-5", "claude-sonnet-4-5-20250929", "claude-sonnet-4-6"):
            self.assertEqual(api_equivalent_usd("claude", model, counts), 0.0789)
        self.assertEqual(api_equivalent_usd("claude", "claude-haiku-4-5", counts), 0.0263)
        self.assertEqual(api_equivalent_usd("claude", "claude-opus-4-6", counts), 0.1315)

    def test_codex_counts_and_precision(self):
        counts = components(input_tokens=70, cache_read_tokens=30, output_tokens=10)
        self.assertEqual(api_equivalent_usd("codex", "gpt-5.3-codex", counts), 0.00026775)
        self.assertEqual(api_equivalent_usd("codex", "gpt-5.4-mini",
                                           components(cache_read_tokens=1)), 0.000000075)
        self.assertEqual(api_equivalent_usd("codex", "gpt-5.5", components()), 0.0)
        for key in ("cache_write_1h_tokens", "cache_write_5m_tokens"):
            self.assertIsNone(api_equivalent_usd("codex", "gpt-5.5", components(**{key: 1})))

    def test_missing_rates_do_not_become_zero_or_credit_charges(self):
        for agent, model in (("qoder", "gpt-5.5"), ("qoder_cn", "claude-opus-4-6"),
                             ("antigravity", "gpt-5.5"), ("codex", "gpt-5.5-pro"),
                             ("claude", "claude-sonnet-4-5-20260101"),
                             ("codex", "GPT-5.2"), ("claude", ["claude-opus-4-6"])):
            self.assertIsNone(api_equivalent_usd(agent, model, components()))

    def test_unknown_and_overlapping_components_are_rejected(self):
        incomplete = components()
        del incomplete["cache_write_5m_tokens"]
        for counts in (None, {}, incomplete, components(reasoning_tokens=1),
                       components(cache_write_tokens=1),
                       *(components(input_tokens=n) for n in (True, -1, None, 1.0, "4", 10**100))):
            self.assertIsNone(api_equivalent_usd("claude", "claude-opus-4-6", counts))

    def test_context_boundaries_use_all_prompt_components(self):
        for model in ("gpt-5.4", "gpt-5.5-2026-04-23"):
            counts = components(input_tokens=2000, cache_read_tokens=270000, output_tokens=7)
            self.assertIsNotNone(api_equivalent_usd("codex", model, counts))
            counts["input_tokens"] += 1
            self.assertIsNone(api_equivalent_usd("codex", model, counts))
        self.assertIsNone(api_equivalent_usd("claude", "claude-sonnet-4-5",
                          components(input_tokens=195000, cache_write_1h_tokens=4999, output_tokens=2)))
        self.assertIsNone(api_equivalent_usd("codex", "gpt-5.2", components(output_tokens=128001)))
