import hashlib
import hmac
import io
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

    def quota(self, cache_only=True):
        settings = {**d.get_settings(), **{prefix + agent: False
                    for prefix in ("show_", "menubar_") for agent in d.AGENT_IDS
                    if agent != "antigravity"}}
        with patch.object(d, "get_settings", return_value=settings):
            return d.api_quota(cache_only=cache_only)

    def post_enable(self, proof=None, **headers):
        handler = object.__new__(d.Handler)
        handler.path = "/api/antigravity/enable"
        body = json.dumps({} if proof is None else {"proof": proof}).encode()
        handler.headers = {"Host": "localhost:7777", "Content-Type": "application/json",
                           "Content-Length": str(len(body)), **headers}
        handler.rfile = io.BytesIO(body)
        reply = []
        handler._send = lambda status, data: reply.append((status, data))
        handler.do_POST()
        return reply.pop()

    def test_authenticated_enable_and_regular_refresh(self):
        folder = self.root / ".gemini/antigravity-cli"
        path = folder / "settings.json"
        self.assertEqual(d._ag_setup(self.root), "cli_missing")
        folder.mkdir(parents=True)
        self.assertEqual(self.quota()["antigravity"]["setup_state"], "available")
        self.assertFalse(path.exists())
        def provision():
            d._ag_provision_enable_key(self.root)
            secret = self.root / "antigravity-enable.token"
            self.assertEqual(secret.stat().st_mode & 0o777, 0o600)
            return hmac.new(secret.read_bytes(), ("antigravity-enable:" + d._DAEMON_INSTANCE_ID).encode(),
                            hashlib.sha256).hexdigest()
        with patch.object(d, "_ag_enable_key", None):
            stale = provision()
            current = provision()
            for proof in (None, "not a proof", stale):
                self.assertEqual(self.post_enable(proof)[0], 403)
            self.assertEqual(self.post_enable(current, Origin="https://example.org")[0], 403)
            self.assertFalse(path.exists())
            self.assertEqual(self.post_enable(current), (200, {"ok": True, "setup_state": "waiting"}))
            line = json.loads(path.read_bytes())["statusLine"]
            self.assertIs(line["stack_with_default"], True)
            self.assertEqual(line["type"], "command")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            first = path.stat().st_mtime_ns
            self.assertEqual(self.post_enable(current)[1]["setup_state"], "waiting")
            self.assertEqual(path.stat().st_mtime_ns, first)
            self.assertTrue(self.quota()["antigravity"]["no_quota"])
            adapter.record({"quota": {"daily": {"remaining_fraction": 0}}})
            live = self.quota(cache_only=False)["antigravity"]
            self.assertEqual(live["setup_state"], "ready")
            self.assertEqual(live["windows"][0]["used_percent"], 100)

    def test_enable_preserves_other_settings_and_refuses_conflicts(self):
        folder = self.root / ".gemini/antigravity-cli"
        folder.mkdir(parents=True)
        path = folder / "settings.json"
        other = b'"custom": {"token": 1.00000000000000000001}'
        path.write_bytes(b"{ " + other + b" }")
        self.assertEqual(d._ag_setup(self.root, enable=True), "waiting")
        self.assertIn(other, path.read_bytes())
        owned = json.loads(path.read_bytes())["statusLine"]
        for raw in (b'{} trailing', b'[]', b'{"statusLine": null}', b'{"a":1,"a":2}',
                    b'{"statusLine": {"command":"private-custom-command"}}',
                    json.dumps({"statusLine": {**owned, "enabled": False}}).encode()):
            path.write_bytes(raw)
            self.assertEqual(d.api_antigravity_enable({}), {"ok": False, "setup_state": "conflict"})
            self.assertEqual(path.read_bytes(), raw)
        path.unlink()
        target = self.root / "unrelated"
        target.write_bytes(b"{}")
        path.symlink_to(target)
        self.assertEqual(d._ag_setup(self.root, enable=True), "conflict")
        self.assertEqual(target.read_bytes(), b"{}")

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

    def test_first_enable_rescans_existing_history_once(self):
        with patch.object(d, "_request_session_index_scan") as sessions, \
                patch.object(d, "_analytics_store") as analytics, \
                patch.object(d, "_effective_locale", return_value="en"):
            d._ttl_cache["usage"] = (time.time() + 60, {})
            d.api_settings_save({"show_antigravity": True})
            self.assertNotIn("usage", d._ttl_cache)
            d.api_settings_save({"show_antigravity": True})
            sessions.assert_called_once()
            analytics.request_scan.assert_called_once()
