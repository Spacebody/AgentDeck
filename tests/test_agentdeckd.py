import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import agentdeckd as daemon


def _jsonl(path, events):
    path.write_text("".join(json.dumps(event) + "\n" for event in events))


class HTTPBoundaryTests(unittest.TestCase):
    def test_only_loopback_hosts_are_accepted(self):
        self.assertTrue(daemon._local_http_host({"Host": "127.0.0.1:7777"}))
        self.assertTrue(daemon._local_http_host({"Host": "LOCALHOST:7777"}))
        self.assertFalse(daemon._local_http_host({"Host": "rebind.example"}))
        self.assertFalse(daemon._local_http_host({"Host": "127.0.0.1:7777.evil"}))

    def test_handler_rejects_rebound_get_for_every_api(self):
        handler = object.__new__(daemon.Handler)
        handler.path = "/api/sessions"
        handler.headers = {"Host": "rebind.example"}
        sent = []
        handler._send = lambda code, payload, ctype="": sent.append((code, payload))
        handler.do_GET()
        self.assertEqual(sent, [(403, {"error": "forbidden"})])


class CodexNotifyTests(unittest.TestCase):
    def test_notify_is_inserted_at_toml_root(self):
        source = 'model = "gpt-5"\n[profiles.work]\nnotify = ["nested"]\n'
        updated = daemon._codex_set_notify(source, ["agentdeck"])
        self.assertEqual(daemon._codex_read_notify(updated), ["agentdeck"])
        self.assertIn('[profiles.work]\nnotify = ["nested"]', updated)
        removed = daemon._codex_set_notify(updated, None)
        self.assertIsNone(daemon._codex_read_notify(removed))
        self.assertIn('[profiles.work]\nnotify = ["nested"]', removed)

    def test_external_previous_notify_chain_is_unwrapped(self):
        wrapper = str(daemon._CODEX_WRAPPER)
        external = ["computer-use", "turn-ended", "--previous-notify",
                    json.dumps([wrapper])]
        self.assertTrue(daemon._codex_notify_is_ours(external))
        self.assertFalse(daemon._codex_notify_direct_is_ours(external))
        self.assertEqual(daemon._codex_notify_without_ours(external),
                         ["computer-use", "turn-ended"])

    def test_external_owner_install_and_remove_do_not_form_a_cycle(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            config = root / "config.toml"
            wrapper = root / "codex-notify.sh"
            integration = root / "integration.json"
            external = ["computer-use", "turn-ended", "--previous-notify",
                        json.dumps([str(wrapper)])]
            config.write_text("notify = " + json.dumps(external) + "\n[model]\nname='x'\n")
            integration.write_text(json.dumps({
                "codex_prev_notify": ["computer-use", "turn-ended"]}))
            with mock.patch.multiple(daemon, _CODEX_CONFIG=config, _CODEX_WRAPPER=wrapper,
                                     INTEGRATION_FILE=integration):
                self.assertTrue(daemon._install_codex_notify())
                self.assertEqual(daemon._codex_read_notify(config.read_text()), external)
                self.assertIn("true   #", wrapper.read_text())
                daemon._remove_codex_notify()
                self.assertEqual(daemon._codex_read_notify(config.read_text()),
                                 ["computer-use", "turn-ended"])


class ClaudeHookTests(unittest.TestCase):
    def test_existing_wrapper_is_rewritten_when_template_changes(self):
        with tempfile.TemporaryDirectory() as td:
            wrapper = Path(td) / "claude-stop-hook.sh"
            wrapper.write_text("old wrapper")
            with mock.patch.object(daemon, "_HOOK_WRAPPER", wrapper):
                self.assertFalse(daemon._hook_wrapper_is_current())
                self.assertTrue(daemon._write_hook_wrapper())
                self.assertTrue(daemon._hook_wrapper_is_current())


class CodexUsageTests(unittest.TestCase):
    def setUp(self):
        daemon._rollout_meta_cache.clear()

    @staticmethod
    def _token(timestamp, inp, cached, out):
        return {"timestamp": timestamp, "type": "event_msg", "payload": {
            "type": "token_count", "info": {"total_token_usage": {
                "input_tokens": inp, "cached_input_tokens": cached,
                "output_tokens": out, "total_tokens": inp + out}}}}

    def test_cumulative_usage_is_split_into_positive_hourly_deltas(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "session_meta", "payload": {"id": "top", "source": "cli"}},
                {"type": "turn_context", "payload": {"model": "gpt-5"}},
                self._token("2026-07-10T10:00:00Z", 100, 20, 10),
                self._token("2026-07-10T11:00:00Z", 160, 40, 30),
                self._token("2026-07-10T11:01:00Z", 160, 40, 30),
                self._token("2026-07-10T12:00:00Z", 5, 0, 2),
            ])
            usage = daemon._parse_codex_file_usage(path)
        self.assertEqual(usage["2026-07-10T10"][0], 110)
        self.assertEqual(usage["2026-07-10T11"][0], 80)
        self.assertEqual(usage["2026-07-10T12"][0], 7)
        self.assertAlmostEqual(usage["2026-07-10T10"][1], 0.0002025)

    def test_subagent_replay_does_not_duplicate_parent_usage(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "session_meta", "payload": {
                    "id": "child", "source": {"subagent": {"thread_spawn": {}}}}},
                self._token("2026-07-10T10:00:00Z", 100, 20, 10),
            ])
            self.assertEqual(daemon._parse_codex_file_usage(path), {})


class ClaudeUsageTests(unittest.TestCase):
    @staticmethod
    def _assistant(timestamp, message_id, request_id, tokens):
        return {"timestamp": timestamp, "type": "assistant", "requestId": request_id,
                "message": {"id": message_id, "model": "claude-sonnet-4-6",
                            "usage": {"input_tokens": tokens, "output_tokens": 2,
                                      "cache_read_input_tokens": 3}}}

    def test_incremental_cache_keeps_response_deduplication(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "claude.jsonl"
            first = self._assistant("2026-07-10T10:00:00Z", "m1", "r1", 10)
            _jsonl(path, [first, first])
            cache = {}
            usage, changed = daemon._cached_claude_file_usage(path, cache)
            self.assertTrue(changed)
            self.assertEqual(usage["2026-07-10T10"]["claude-sonnet-4-6"][0], 10)
            with path.open("a") as f:
                f.write(json.dumps(self._assistant(
                    "2026-07-10T11:00:00Z", "m2", "r2", 20)) + "\n")
            usage, changed = daemon._cached_claude_file_usage(path, cache)
            self.assertTrue(changed)
            self.assertEqual(usage["2026-07-10T11"]["claude-sonnet-4-6"][0], 20)


class ActiveSessionTests(unittest.TestCase):
    def test_open_subagent_rollout_cannot_replace_parent_identity(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            folder = base / "sessions" / "2026" / "07" / "11"
            folder.mkdir(parents=True)
            parent_id = "11111111-1111-1111-1111-111111111111"
            child_id = "22222222-2222-2222-2222-222222222222"
            parent = folder / f"rollout-parent-{parent_id}.jsonl"
            child = folder / f"rollout-child-{child_id}.jsonl"
            _jsonl(parent, [{"type": "session_meta", "payload": {
                "id": parent_id, "source": "cli", "cwd": "/parent"}}])
            _jsonl(child, [{"type": "session_meta", "payload": {
                "id": child_id, "source": {"subagent": {"other": "guardian"}},
                "cwd": "/child"}}])
            os.utime(parent, (100, 100))
            os.utime(child, (200, 200))
            daemon._rollout_meta_cache.clear()
            lsof = SimpleNamespace(stdout=f"n{child}\nn{parent}\n")
            with mock.patch.object(daemon.subprocess, "run", return_value=lsof), \
                    mock.patch.object(daemon, "codex_sources",
                                      return_value=[{"path": base}]):
                info = daemon._pid_codex_rollout_info(123)
            self.assertEqual(info["id"], parent_id)
            self.assertEqual(info["cwd"], "/parent")


class PersistenceAndUpdateTests(unittest.TestCase):
    def test_update_url_requires_matching_semver_tag_and_asset(self):
        self.assertTrue(daemon._safe_update_url(
            "https://github.com/Spacebody/AgentDeck/releases/download/v2.2.0/AgentDeck-2.2.0.dmg"))
        self.assertFalse(daemon._safe_update_url(
            "https://github.com/Spacebody/AgentDeck/releases/download/v2.2.0/AgentDeck-2.1.0.dmg"))
        self.assertFalse(daemon._safe_update_url(
            "https://github.com/Spacebody/AgentDeck/releases/download/v../../AgentDeck-../../x.dmg"))

    def test_legacy_alert_state_migrates_to_default_account(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "alerts.json"
            path.write_text(json.dumps({"Claude|five_hour": "warn"}))
            previous = daemon._alert_state
            daemon._alert_state = {}
            try:
                with mock.patch.object(daemon, "ALERT_STATE_FILE", path):
                    daemon._alert_state_load()
                    self.assertEqual(daemon._alert_state[("Claude", "default", "five_hour")],
                                     "warn")
                    daemon._alert_state_save()
                self.assertIn("Claude|default|five_hour", json.loads(path.read_text()))
            finally:
                daemon._alert_state = previous

    def test_update_bundle_version_is_verified_before_codesign(self):
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / "AgentDeck.app"
            info = app / "Contents" / "Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "com.agentdeck.app",
                "CFBundleShortVersionString": "2.2.0",
                "CFBundleVersion": "2.2.0",
            }))
            with mock.patch.object(daemon, "_run_checked") as run, \
                    mock.patch.object(daemon, "_codesign_team", return_value="2E56T94S33"):
                daemon._verify_update_app(app, "2.2.0")
                run.assert_has_calls([
                    mock.call(["codesign", "--verify", "--deep", "--strict", str(app)],
                              timeout=60),
                    mock.call(["spctl", "--assess", "--type", "execute", "--verbose=2",
                               str(app)], timeout=60),
                ])
            with self.assertRaisesRegex(RuntimeError, "version"):
                daemon._verify_update_app(app, "2.2.1")

    def test_notification_thresholds_remain_strictly_ordered(self):
        with tempfile.TemporaryDirectory() as td:
            settings = Path(td) / "settings.json"
            settings.write_text(json.dumps({"notify_warn": 80, "notify_crit": 95}))
            previous_cache = daemon._settings_cache
            daemon._settings_cache = None
            try:
                with mock.patch.object(daemon, "SETTINGS_FILE", settings), \
                        mock.patch.object(daemon, "_effective_locale", return_value="en"):
                    daemon.api_settings_save({"notify_warn": 100})
                saved = json.loads(settings.read_text())
                self.assertEqual(saved["notify_warn"], 99)
                self.assertEqual(saved["notify_crit"], 100)
                with mock.patch.object(daemon, "SETTINGS_FILE", settings), \
                        mock.patch.object(daemon, "_effective_locale", return_value="en"):
                    daemon.api_settings_save({"notify_crit": 0})
                saved = json.loads(settings.read_text())
                self.assertEqual(saved["notify_warn"], 59)
                self.assertEqual(saved["notify_crit"], 60)
            finally:
                daemon._settings_cache = previous_cache


if __name__ == "__main__":
    unittest.main()
