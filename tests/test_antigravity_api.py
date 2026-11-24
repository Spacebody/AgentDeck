import json
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

import agentdeckd as d
import antigravity_usage as adapter


class AntigravityAPITests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for p in (patch.object(adapter, "STORE", self.root / "samples"),
                  patch.multiple(d, HOME=self.root, SETTINGS_FILE=self.root / "settings",
                                 _settings_cache=None, _ttl_cache={},
                                 CODEX_USAGE_CACHE_FILE=self.root / "codex",
                                 CLAUDE_USAGE_CACHE_FILE=self.root / "claude",
                                 QODER_USAGE_CACHE_FILE=self.root / "qoder",
                                 PATH_MAPPINGS_FILE=self.root / "mappings",
                                 codex_sources=lambda: [], claude_sources=lambda: [],
                                 qoder_sources=lambda: [], qoder_cn_sources=lambda: [])):
            p.start()
            self.addCleanup(p.stop)

    def quota(self):
        settings = {**d.get_settings(), **{prefix + agent: False
                    for prefix in ("show_", "menubar_") for agent in d.AGENT_IDS
                    if agent != "antigravity"}}
        with patch.object(d, "get_settings", return_value=settings):
            return d.api_quota(cache_only=True)

    def test_install_detection_explicit_preferences_and_hidden_surface(self):
        with patch.object(d, "_antigravity_snapshot") as read:
            self.assertTrue(self.quota()["agents"][-1]["hidden"])
            read.assert_not_called()
        for name in ("antigravity-cli", "antigravity"):
            installed = self.root / ".gemini" / name
            installed.mkdir(parents=True, exist_ok=True)
            self.assertTrue(d.get_settings()["show_antigravity"])
            installed.rmdir()
        with patch.object(d, "_effective_locale", return_value="en"):
            d.api_settings_save({"show_antigravity": True, "color_antigravity": "#112233"})
            self.assertTrue(self.quota()["antigravity"]["no_quota"])
            installed.mkdir()
            d.api_settings_save({"show_antigravity": False, "menubar_antigravity": True,
                                 "color_antigravity": "invalid"})
        q = self.quota()
        self.assertTrue(q["agents"][-1]["hidden"])
        self.assertTrue(q["menubar"]["antigravity"])
        self.assertTrue(q["antigravity"]["no_quota"])
        self.assertEqual(d.get_settings()["color_antigravity"], "#112233")

    def test_official_quota_and_token_deltas_do_not_create_cost_or_project(self):
        (self.root / ".gemini/antigravity-cli").mkdir(parents=True)
        now = int(time.time())
        payload = {"conversation_id": "example", "context_window": {
            "total_input_tokens": 500, "total_output_tokens": 100},
            "quota": {"model": {"remaining_fraction": 1, "reset_in_seconds": 3600},
                      "credits": {"remaining_amount": 0}},
            "email": "private@example.com", "cost": {"total_usd": 7}, "cwd": "/private"}
        adapter.record(payload, now=now-1)
        q = self.quota()
        account = q["accounts"]["antigravity"][0]
        self.assertEqual(q["agents"][-1]["accounts"], [account])
        self.assertEqual(account["windows"], [{"id": "model", "label": "model",
                         "used_percent": 0, "resets_at": now-1+3600}])
        self.assertEqual(account["remaining_amounts"], [{"id": "credits", "label": "credits",
                         "remaining": 0, "resets_at": None}])
        self.assertNotIn(payload["email"], json.dumps(q))
        baseline = d.api_usage()
        self.assertEqual(baseline["antigravity_daily"], {})
        self.assertFalse(baseline["coverage"]["antigravity_available"])
        payload["context_window"].update(total_input_tokens=508, total_output_tokens=103)
        adapter.record(payload, now=now)
        d._ttl_cache.pop("usage", None)
        u = d.api_usage()
        self.assertEqual(u["antigravity_daily"], {datetime.fromtimestamp(now).strftime("%Y-%m-%d"): 11})
        self.assertTrue(u["coverage"]["antigravity_available"])
        self.assertEqual(u["hourly"][-1]["ag"], 11)
        for field in ("cost_7d", "cost_30d", "costs_by_agent_daily", "projects_7d",
                      "claude_daily", "codex_daily", "qoder_daily", "qoder_cn_daily"):
            self.assertEqual(u[field], baseline[field])
