import json
import os
import plistlib
import tempfile
import threading
import time
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

    def test_quota_long_poll_requires_a_local_same_origin_request(self):
        local = {"Host": "127.0.0.1:7777"}
        self.assertTrue(daemon._local_long_poll_request(local))
        self.assertTrue(daemon._local_long_poll_request({
            **local, "Sec-Fetch-Site": "same-origin",
            "Origin": "http://127.0.0.1:7777",
        }))
        self.assertFalse(daemon._local_long_poll_request({
            **local, "Sec-Fetch-Site": "cross-site",
        }))
        self.assertFalse(daemon._local_long_poll_request({
            **local, "Origin": "https://attacker.example",
        }))

    def test_quota_long_poll_rejects_excess_waiters(self):
        handler = object.__new__(daemon.Handler)
        handler.path = "/api/quota/changes?after=1"
        handler.headers = {"Host": "127.0.0.1:7777"}
        sent = []
        handler._send = lambda code, payload, ctype="": sent.append((code, payload))
        slots = SimpleNamespace(acquire=lambda blocking=False: False)
        with mock.patch.object(daemon, "_quota_wait_slots", slots), \
                mock.patch.object(daemon, "api_quota_changes") as changes:
            handler.do_GET()
        self.assertEqual(sent, [(429, {"error": "too many quota watchers"})])
        changes.assert_not_called()

    def test_cross_site_request_cannot_trigger_quota_refresh(self):
        for query in ("", "force=1", "fresh_codex=1"):
            with self.subTest(query=query):
                handler = object.__new__(daemon.Handler)
                handler.path = f"/api/quota?{query}" if query else "/api/quota"
                handler.headers = {
                    "Host": "127.0.0.1:7777",
                    "Sec-Fetch-Site": "cross-site",
                    "Origin": "https://attacker.example",
                }
                sent = []
                handler._send = lambda code, payload, ctype="": \
                    sent.append((code, payload))
                with mock.patch.object(daemon, "api_quota") as quota:
                    handler.do_GET()
                self.assertEqual(sent, [(403, {"error": "forbidden"})])
                quota.assert_not_called()

    def test_handler_rejects_rebound_get_for_every_api(self):
        handler = object.__new__(daemon.Handler)
        handler.path = "/api/sessions"
        handler.headers = {"Host": "rebind.example"}
        sent = []
        handler._send = lambda code, payload, ctype="": sent.append((code, payload))
        handler.do_GET()
        self.assertEqual(sent, [(403, {"error": "forbidden"})])


class ClaudeQuotaTests(unittest.TestCase):
    def test_successful_quota_fetch_records_sample_time(self):
        response = mock.MagicMock()
        response.__enter__.return_value.read.return_value = json.dumps({
            "five_hour": {
                "utilization": 12.5,
                "resets_at": "2026-07-24T20:00:00Z",
            },
        }).encode()
        source = {"path": Path("/tmp/claude-home"), "is_default": True}

        with mock.patch.object(
                daemon, "_source_token", return_value=("token", "oauth")), \
                mock.patch.object(
                    daemon.urllib.request, "urlopen", return_value=response):
            quota = daemon._claude_quota_for(source)

        self.assertTrue(quota["ok"])
        self.assertRegex(
            quota["sampled_at"],
            r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$")


class CodexNotifyTests(unittest.TestCase):
    def test_notify_is_inserted_at_toml_root(self):
        source = 'model = "gpt-5"\n[profiles.work]\nnotify = ["nested"]\n'
        updated = daemon._codex_set_notify(source, ["agentdeck"])
        self.assertEqual(daemon._codex_read_notify(updated), ["agentdeck"])
        self.assertIn('[profiles.work]\nnotify = ["nested"]', updated)
        removed = daemon._codex_set_notify(updated, None)
        self.assertIsNone(daemon._codex_read_notify(removed))
        self.assertIn('[profiles.work]\nnotify = ["nested"]', removed)

    def test_python39_fallback_preserves_single_quoted_notify(self):
        source = "notify = ['external-tool', '--flag']\nmodel = 'gpt-5'\n"
        with mock.patch.dict("sys.modules", {"tomllib": None}):
            self.assertEqual(
                daemon._codex_read_notify(source),
                ["external-tool", "--flag"])

    def test_multiline_notify_is_replaced_without_leaving_toml_fragments(self):
        source = """
notify = [
  'external-tool', # owner
  "--flag",
]
[profiles.work]
model = "gpt-5"
""".lstrip()
        self.assertEqual(
            daemon._codex_read_notify(source),
            ["external-tool", "--flag"])
        updated = daemon._codex_set_notify(source, ["agentdeck"])
        self.assertEqual(daemon._codex_read_notify(updated), ["agentdeck"])
        self.assertNotIn("'external-tool'", updated)
        self.assertNotIn('  "--flag"', updated)
        self.assertIn('[profiles.work]\nmodel = "gpt-5"', updated)

    def test_notify_text_inside_multiline_string_is_not_a_root_key_or_table(self):
        source = '''
description = """
notify = ['not-a-hook']
[not-a-table]
"""
model = "gpt-5"
[profiles.work]
model = "gpt-5"
'''.lstrip()
        self.assertIsNone(daemon._codex_read_notify(source))
        updated = daemon._codex_set_notify(source, ["agentdeck"])
        self.assertEqual(daemon._codex_read_notify(updated), ["agentdeck"])
        self.assertIn("notify = ['not-a-hook']", updated)
        self.assertLess(
            updated.index('notify = ["agentdeck"]'),
            updated.index("[profiles.work]"))

    def test_quoted_notify_root_keys_are_recognized_and_replaced(self):
        for source in (
                '"notify" = ["external"]\n',
                "'notify' = ['external']\n",
                r'"not\u0069fy" = ["external"]' + "\n"):
            with self.subTest(source=source):
                self.assertEqual(
                    daemon._codex_read_notify(source), ["external"])
                updated = daemon._codex_set_notify(source, ["agentdeck"])
                self.assertEqual(
                    daemon._codex_read_notify(updated), ["agentdeck"])
                self.assertEqual(updated.count("notify"), 1)

    def test_literal_quoted_key_does_not_decode_backslash_escapes(self):
        source = r"'noti\u0066y' = ['unrelated']" + "\n"
        self.assertIsNone(daemon._codex_read_notify(source))
        updated = daemon._codex_set_notify(source, ["agentdeck"])
        self.assertEqual(daemon._codex_read_notify(updated), ["agentdeck"])
        self.assertIn(r"'noti\u0066y' = ['unrelated']", updated)

    def test_unrelated_codex_notify_name_is_not_claimed(self):
        external = ["/opt/tools/my-codex-notify-hook"]
        self.assertFalse(daemon._codex_notify_is_ours(external))
        self.assertFalse(daemon._codex_notify_direct_is_ours(external))

    def test_malformed_notify_fails_closed_without_overwriting_config(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            config = root / "config.toml"
            wrapper = root / "codex-notify.sh"
            integration = root / "integration.json"
            original = 'notify = ["external-tool"\nmodel = "gpt-5"\n'
            config.write_text(original)
            with mock.patch.object(daemon, "INTEGRATION_FILE", integration):
                self.assertFalse(daemon._install_codex_notify(
                    config=config, wrapper=wrapper))
            self.assertEqual(config.read_text(), original)
            self.assertFalse(wrapper.exists())

    def test_wrapper_self_cleanup_restores_multiline_original_notify(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            data = root / "data"
            data.mkdir()
            config = root / "config.toml"
            wrapper = data / "codex-notify.sh"
            integration = data / "integration.json"
            config.write_text('"notify" = [\n  \'/usr/bin/true\',\n]\n')
            with mock.patch.multiple(
                    daemon, DATA_DIR=data, INTEGRATION_FILE=integration,
                    _CODEX_WRAPPER=wrapper):
                self.assertTrue(daemon._install_codex_notify(
                    config=config, wrapper=wrapper))
            script = wrapper.read_text().replace(
                'APP="/Applications/AgentDeck.app"',
                f'APP="{root}/missing.app"').replace(
                    "127.0.0.1:7777", "127.0.0.1:9")
            wrapper.write_text(script)
            result = daemon.subprocess.run(
                [str(wrapper), '{"type":"test"}'],
                capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                daemon._codex_read_notify(config.read_text()),
                ["/usr/bin/true"])
            self.assertFalse(wrapper.exists())

    def test_wrapper_self_cleanup_removes_notify_when_no_original_existed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            data = root / "data"
            data.mkdir()
            config = root / "config.toml"
            config.write_text('''
description = """
notify = ['not-a-hook']
[not-a-table]
"""
model = "gpt-5"
'''.lstrip())
            wrapper = data / "codex-notify.sh"
            integration = data / "integration.json"
            with mock.patch.multiple(
                    daemon, DATA_DIR=data, INTEGRATION_FILE=integration,
                    _CODEX_WRAPPER=wrapper):
                self.assertTrue(daemon._install_codex_notify(
                    config=config, wrapper=wrapper))
            script = wrapper.read_text().replace(
                'APP="/Applications/AgentDeck.app"',
                f'APP="{root}/missing.app"').replace(
                    "127.0.0.1:7777", "127.0.0.1:9")
            wrapper.write_text(script)
            result = daemon.subprocess.run(
                [str(wrapper), '{"type":"test"}'],
                capture_output=True, text=True, timeout=8)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIsNone(daemon._codex_read_notify(config.read_text()))
            self.assertIn('model = "gpt-5"', config.read_text())
            self.assertIn("notify = ['not-a-hook']", config.read_text())
            self.assertFalse(wrapper.exists())

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

    def test_install_creates_config_for_an_initialized_home_without_one(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            home = root / ".codex-work"
            data = root / "data"
            home.mkdir()
            data.mkdir()
            (home / "auth.json").write_text("{}")
            config = home / "config.toml"
            wrapper = data / "codex-notify-0123456789ab.sh"
            integration = data / "integration.json"
            with mock.patch.multiple(
                    daemon, DATA_DIR=data, INTEGRATION_FILE=integration):
                self.assertTrue(daemon._install_codex_notify(
                    config=config, wrapper=wrapper,
                    state_key="codex_prev_notify_work"))
                self.assertEqual(
                    daemon._codex_read_notify(config.read_text()),
                    [str(wrapper)])
                daemon._remove_codex_notify(
                    config=config, wrapper=wrapper,
                    state_key="codex_prev_notify_work")
            self.assertIsNone(daemon._codex_read_notify(config.read_text()))

    def test_integration_installs_and_restores_every_codex_home(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            data = root / "data"
            default_home = root / ".codex"
            work_home = root / ".codex-work"
            data.mkdir()
            default_home.mkdir()
            work_home.mkdir()
            original_default = ["default-notify"]
            original_work = ["work-notify"]
            (default_home / "config.toml").write_text(
                "notify = " + json.dumps(original_default) + "\n")
            (work_home / "config.toml").write_text(
                "notify = " + json.dumps(original_work) + "\n")
            sources = [
                {"id": "default", "path": default_home, "is_default": True,
                 "session_only": False},
                {"id": "work", "path": work_home, "is_default": False,
                 "session_only": False},
            ]
            integration = data / "integration.json"
            default_wrapper = data / "codex-notify.sh"
            with mock.patch.multiple(
                    daemon, DATA_DIR=data, INTEGRATION_FILE=integration,
                    _CODEX_CONFIG=default_home / "config.toml",
                    _CODEX_WRAPPER=default_wrapper), \
                    mock.patch.object(daemon, "codex_sources", return_value=sources), \
                    mock.patch.object(daemon, "_install_claude_hook", return_value=False), \
                    mock.patch.object(daemon, "_remove_claude_hook"), \
                    mock.patch.object(daemon, "_remove_legacy_codex_stop_hook"):
                daemon.install_integration()
                default_notify = daemon._codex_read_notify(
                    (default_home / "config.toml").read_text())
                work_notify = daemon._codex_read_notify(
                    (work_home / "config.toml").read_text())
                self.assertEqual(default_notify, [str(default_wrapper)])
                self.assertEqual(len(work_notify), 1)
                self.assertNotEqual(work_notify[0], str(default_wrapper))
                self.assertTrue(Path(work_notify[0]).is_file())
                state = json.loads(integration.read_text())
                self.assertEqual(len(state["codex_notify_targets"]), 2)

                daemon.remove_integration()
                self.assertEqual(daemon._codex_read_notify(
                    (default_home / "config.toml").read_text()), original_default)
                self.assertEqual(daemon._codex_read_notify(
                    (work_home / "config.toml").read_text()), original_work)
                self.assertFalse(default_wrapper.exists())
                self.assertFalse(Path(work_notify[0]).exists())


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

    def test_subagent_usage_is_counted_as_independent_work(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"timestamp": "2026-07-10T10:00:00.500Z",
                 "type": "session_meta", "payload": {
                    "id": "child", "timestamp": "2026-07-10T10:00:00.250Z",
                    "source": {"subagent": {"thread_spawn": {}}}}},
                {"type": "session_meta", "payload": {"id": "parent"}},
                self._token("2026-07-10T10:00:00Z", 100, 20, 10),
                {"type": "event_msg", "payload": {
                    "type": "task_started", "started_at": 1783677600}},
                self._token("2026-07-10T10:01:00Z", 140, 30, 20),
            ])
            usage = daemon._parse_codex_file_usage(path)
            self.assertEqual(usage["2026-07-10T10"][0], 50)

    def test_partial_final_line_is_reparsed_after_append(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            raw = json.dumps(self._token(
                "2026-07-10T10:00:00Z", 100, 20, 10)).encode()
            split = len(raw) // 2
            path.write_bytes(raw[:split])
            state = daemon._parse_codex_usage_state(path)
            self.assertEqual(state["offset"], 0)
            with path.open("ab") as f:
                f.write(raw[split:] + b"\n")
            state = daemon._parse_codex_usage_state(path, state)
            self.assertEqual(state["agg"]["2026-07-10T10"][0], 110)

    def test_activity_without_usable_token_snapshot_is_incomplete(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
                {"type": "event_msg", "payload": {
                    "type": "token_count", "info": {"total_token_usage": {
                        "input_tokens": 0, "cached_input_tokens": 0,
                        "output_tokens": 0}}}},
            ])
            state = daemon._parse_codex_usage_state(path)
            self.assertTrue(state["has_activity"])
            self.assertFalse(state["has_usage"])

    def test_total_only_import_is_counted_without_guessing_cost(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "user_message"}},
                {"timestamp": "2026-07-10T10:00:00Z", "type": "event_msg",
                 "payload": {"type": "token_count", "info": {
                    "total_token_usage": {"input_tokens": 0,
                                          "cached_input_tokens": 0,
                                          "output_tokens": 0,
                                          "total_tokens": 3951}}}},
            ])
            state = daemon._parse_codex_usage_state(path)
            self.assertEqual(state["agg"]["2026-07-10T10"], [3951, 0.0])
            self.assertTrue(state["has_usage"])

    def test_partial_session_meta_is_not_cached_as_top_level(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            path.write_text('{"type":"session_meta","payload":')
            self.assertFalse(daemon._rollout_meta(path)["subagent"])
            self.assertNotIn(str(path), daemon._rollout_meta_cache)
            path.write_text(json.dumps({
                "timestamp": "2026-07-10T10:00:00Z",
                "type": "session_meta", "payload": {
                    "id": "child", "timestamp": "2026-07-10T10:00:00Z",
                    "source": {"subagent": {"thread_spawn": {}}}}}) + "\n")
            self.assertTrue(daemon._rollout_meta(path)["subagent"])

    def test_partial_session_meta_rebuilds_provisional_usage_state(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            meta = json.dumps({
                "timestamp": "2026-07-10T10:00:00.500Z",
                "type": "session_meta", "payload": {
                    "id": "child", "timestamp": "2026-07-10T10:00:00.250Z",
                    "source": {"subagent": {"thread_spawn": {}}}}})
            split = len(meta) // 2
            path.write_text(meta[:split])
            state = daemon._parse_codex_usage_state(path)
            self.assertEqual(state["offset"], 0)
            self.assertTrue(state["replay_complete"])
            with path.open("a") as f:
                f.write(meta[split:] + "\n")
                f.write(json.dumps(self._token(
                    "2026-07-10T10:00:00Z", 100, 20, 10)) + "\n")
                f.write(json.dumps({"type": "event_msg", "payload": {
                    "type": "task_started", "started_at": 1783677600}}) + "\n")
                f.write(json.dumps(self._token(
                    "2026-07-10T10:01:00Z", 140, 30, 20)) + "\n")
            state = daemon._parse_codex_usage_state(path, state)
            self.assertEqual(state["agg"]["2026-07-10T10"][0], 50)

    def test_v4_cache_is_rejected_after_fork_replay_fix(self):
        with tempfile.TemporaryDirectory() as td:
            cache_file = Path(td) / "codex-cache.json"
            cache_file.write_text(json.dumps({
                "version": 4,
                "files": {"polluted.jsonl": {
                    "version": 4, "subagent_kind": "thread_spawn",
                    "agg": {"2026-07-10T10": [160, 0.0]}}}}))
            with mock.patch.object(daemon, "CODEX_USAGE_CACHE_FILE", cache_file):
                self.assertEqual(daemon._load_codex_usage_cache(), {})


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

    def test_partial_final_line_is_reparsed_after_append(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "claude.jsonl"
            raw = json.dumps(self._assistant(
                "2026-07-10T10:00:00Z", "m1", "r1", 10)).encode()
            split = len(raw) // 2
            path.write_bytes(raw[:split])
            state = daemon._parse_claude_usage_state(path)
            self.assertEqual(state["offset"], 0)
            with path.open("ab") as f:
                f.write(raw[split:] + b"\n")
            state = daemon._parse_claude_usage_state(path, state)
            self.assertEqual(
                state["agg"]["2026-07-10T10"]["claude-sonnet-4-6"][0], 10)

    def test_usage_files_include_nested_subagents(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            project = root / "projects" / "project"
            child_dir = project / "session" / "subagents"
            child_dir.mkdir(parents=True)
            top = project / "session.jsonl"
            child = child_dir / "agent.jsonl"
            top.touch()
            child.touch()
            with mock.patch.object(daemon, "claude_sources", return_value=[{
                    "path": root}]):
                self.assertEqual(set(daemon._iter_claude_usage_files()),
                                 {top, child})


class UsageProjectTests(unittest.TestCase):
    def test_project_mapping_merges_old_and_new_directory_keys(self):
        with tempfile.TemporaryDirectory() as td:
            replacement = os.path.realpath(td)
            old = "/missing/old/project"
            mappings = {old: replacement}
            self.assertEqual(daemon._usage_project_cwd(old, mappings), replacement)
            self.assertEqual(daemon._usage_project_cwd(replacement, mappings),
                             replacement)

    def test_path_mapping_change_invalidates_usage_memory_cache(self):
        with tempfile.TemporaryDirectory() as td:
            mappings = Path(td) / "path_mappings.json"
            replacement = Path(td) / "replacement"
            replacement.mkdir()
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings):
                with daemon._cache_lock:
                    daemon._ttl_cache["usage"] = (time.time() + 120, {"stale": True})
                daemon._remember_session_cwd("/old/project", str(replacement))
                with daemon._cache_lock:
                    self.assertNotIn("usage", daemon._ttl_cache)
                    daemon._ttl_cache["usage"] = (
                        time.time() + 120, {"stale": True})
                daemon._forget_session_cwd("/old/project")
                with daemon._cache_lock:
                    self.assertNotIn("usage", daemon._ttl_cache)

    def test_usage_api_exposes_coverage_and_mapped_project(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            codex = root / "codex"
            session_dir = codex / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / "rollout-2026-07-15T01-00-00-test.jsonl"
            now = daemon.datetime.now(daemon.timezone.utc)
            stamp = now.isoformat().replace("+00:00", "Z")
            old = "/missing/old/project"
            replacement = root / "moved-project"
            replacement.mkdir()
            _jsonl(rollout, [
                {"timestamp": stamp, "type": "session_meta", "payload": {
                    "id": "session", "cwd": old, "originator": "codex-tui",
                    "timestamp": stamp, "source": "cli"}},
                {"timestamp": stamp, "type": "event_msg",
                 "payload": {"type": "user_message"}},
                {"timestamp": stamp, "type": "event_msg", "payload": {
                    "type": "token_count", "info": {"total_token_usage": {
                        "input_tokens": 100, "cached_input_tokens": 20,
                        "output_tokens": 10, "total_tokens": 110}}}},
            ])
            mappings = root / "path_mappings.json"
            mappings.write_text(json.dumps({
                "version": 1, "mappings": {old: str(replacement)}}))
            with mock.patch.multiple(
                    daemon,
                    CODEX_USAGE_CACHE_FILE=root / "codex-cache.json",
                    CLAUDE_USAGE_CACHE_FILE=root / "claude-cache.json",
                    PATH_MAPPINGS_FILE=mappings), \
                    mock.patch.object(daemon, "codex_sources", return_value=[{
                        "path": codex}]), \
                    mock.patch.object(daemon, "claude_sources", return_value=[]):
                daemon._rollout_meta_cache.clear()
                with daemon._cache_lock:
                    daemon._ttl_cache.pop("usage", None)
                usage = daemon.api_usage()
                with daemon._cache_lock:
                    daemon._ttl_cache.pop("usage", None)

            self.assertEqual(usage["coverage"], {
                "codex_files": 1, "codex_missing_usage_files": 0})
            self.assertEqual(usage["projects_7d"][0]["cwd"],
                             os.path.realpath(replacement))
            self.assertEqual(sum(usage["codex_daily"].values()), 110)


class SessionIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / "session-index.sqlite3"
        self.pins = self.root / "pins.json"
        self.claude_sources = []
        self.codex_sources = []
        self.patches = [
            mock.patch.object(daemon, "SESSION_INDEX_FILE", self.db),
            mock.patch.object(daemon, "PINS_FILE", self.pins),
            mock.patch.object(daemon, "claude_sources",
                              side_effect=lambda: self.claude_sources),
            mock.patch.object(daemon, "codex_sources",
                              side_effect=lambda: self.codex_sources),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        daemon._session_schema_paths.discard(os.path.realpath(self.db))
        daemon._rollout_meta_cache.clear()
        daemon._session_state(indexing=False, indexed_at=0.0, total_files=0,
                              processed_files=0, error="")

    def source(self, name="default"):
        base = self.root / name
        (base / "sessions" / "2026" / "07" / "12").mkdir(parents=True)
        source = {"id": name, "label": name.title(), "path": base}
        self.codex_sources.append(source)
        return base

    @staticmethod
    def session_id(index):
        return f"00000000-0000-0000-0000-{index:012d}"

    def write_codex(self, base, index, title, sid=None, mtime=None, source="cli"):
        sid = sid or self.session_id(index)
        folder = base / "sessions" / "2026" / "07" / "12"
        path = folder / f"rollout-2026-07-12T00-{index // 60:02d}-{index % 60:02d}-{sid}.jsonl"
        _jsonl(path, [
            {"type": "session_meta", "payload": {
                "id": sid, "source": source, "cwd": f"/work/project-{index}"}},
            {"type": "event_msg", "payload": {
                "type": "user_message", "message": title}},
        ])
        stamp = float(index + 1 if mtime is None else mtime)
        os.utime(path, (stamp, stamp))
        return path

    def test_search_finds_session_older_than_legacy_240_file_window(self):
        base = self.source()
        for index in range(260):
            title = "unique historical needle" if index == 0 else f"session {index}"
            self.write_codex(base, index, title)
        daemon._session_index_scan()
        result = daemon._query_session_index("historical needle", limit=10)
        self.assertEqual(result["total"], 1)
        self.assertEqual(result["sessions"][0]["id"], self.session_id(0))

    def test_unchanged_and_growing_files_are_not_reparsed(self):
        base = self.source()
        paths = [self.write_codex(base, i, f"session {i}") for i in range(3)]
        original = daemon._session_file_info
        with mock.patch.object(daemon, "_session_file_info", wraps=original) as parse:
            daemon._session_index_scan()
            self.assertEqual(parse.call_count, 3)
            daemon._session_index_scan()
            self.assertEqual(parse.call_count, 3)
            with paths[0].open("a") as handle:
                handle.write(json.dumps({"type": "event_msg", "payload": {
                    "type": "agent_message", "message": "later"}}) + "\n")
            daemon._session_index_scan()
            self.assertEqual(parse.call_count, 3)

    def test_keyset_pagination_returns_every_session_once(self):
        base = self.source()
        for index in range(75):
            self.write_codex(base, index, f"session {index}")
        daemon._session_index_scan()
        cursor, seen = "", []
        while True:
            page = daemon._query_session_index(limit=17, cursor=cursor)
            seen.extend((item["tool"], item["account_id"], item["id"])
                        for item in page["sessions"])
            if not page["has_more"]:
                break
            cursor = page["next_cursor"]
        self.assertEqual(len(seen), 75)
        self.assertEqual(len(set(seen)), 75)

    def test_same_session_id_isolated_by_account_for_pin_and_preview(self):
        default = self.source("default")
        work = self.source("work")
        sid = self.session_id(1)
        self.write_codex(default, 1, "default account message", sid=sid, mtime=10)
        self.write_codex(work, 2, "work account message", sid=sid, mtime=20)
        daemon._session_index_scan()
        result = daemon._query_session_index(limit=10)
        self.assertEqual(result["total"], 2)

        work_item = next(item for item in result["sessions"] if item["account_id"] == "work")
        daemon.api_pin({"pinned": True, "session": work_item})
        pinned = daemon._query_session_index(limit=10)["sessions"]
        self.assertTrue(next(item for item in pinned if item["account_id"] == "work")["pinned"])
        self.assertFalse(next(item for item in pinned if item["account_id"] == "default")["pinned"])
        self.assertIn(daemon._pin_key("codex", "work", sid), json.loads(self.pins.read_text()))

        preview = daemon.api_preview({"tool": ["codex"], "id": [sid],
                                      "account_id": ["default"]})
        self.assertEqual(preview["messages"][-1]["text"], "default account message")
        work_preview = daemon.api_preview({"tool": ["codex"], "id": [sid],
                                           "account_id": ["work"]})
        self.assertEqual(work_preview["messages"][-1]["text"], "work account message")

    def test_corrupt_derived_database_is_recreated(self):
        self.db.write_bytes(b"not a sqlite database")
        daemon._session_schema_paths.discard(os.path.realpath(self.db))
        conn = daemon._session_db_connect()
        try:
            tables = {row[0] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")}
        finally:
            conn.close()
        self.assertIn("session_index", tables)
        self.assertTrue(daemon._session_status()["indexing"])

    def test_legacy_pin_key_migrates_without_losing_pin(self):
        base = self.source("default")
        sid = self.session_id(7)
        self.write_codex(base, 7, "legacy pinned session", sid=sid)
        self.pins.write_text(json.dumps({sid: {
            "tool": "codex", "id": sid, "title": "legacy pinned session",
            "cwd": "/work/project-7", "mtime": 8,
        }}))
        daemon._session_index_scan()
        result = daemon._query_session_index(limit=10)
        self.assertTrue(result["sessions"][0]["pinned"])
        pins = json.loads(self.pins.read_text())
        self.assertIn(daemon._pin_key("codex", "default", sid), pins)
        self.assertNotIn(sid, pins)

    def test_subagent_rollout_is_not_indexed(self):
        base = self.source()
        self.write_codex(base, 1, "top level")
        self.write_codex(base, 2, "hidden child", source={"subagent": {"other": "guardian"}})
        daemon._session_index_scan()
        result = daemon._query_session_index(limit=10)
        self.assertEqual(result["total"], 1)
        self.assertEqual(result["sessions"][0]["title"], "top level")

    def test_non_object_json_lines_do_not_abort_index_or_preview(self):
        base = self.source()
        sid = self.session_id(9)
        path = (base / "sessions" / "2026" / "07" / "12"
                / f"rollout-2026-07-12T00-00-09-{sid}.jsonl")
        _jsonl(path, [
            [],
            {"type": "session_meta", "payload": []},
            {"type": "event_msg", "payload": {
                "type": "user_message", "message": []}},
            {"type": "session_meta", "payload": {
                "id": sid, "source": "cli", "cwd": "/work/resilient"}},
            {"type": "event_msg", "payload": {
                "type": "user_message", "message": "valid after malformed rows"}},
        ])
        daemon._session_index_scan()
        result = daemon._query_session_index("malformed rows", limit=10)
        self.assertEqual(result["total"], 1)
        preview = daemon.api_preview({"tool": ["codex"], "id": [sid],
                                      "account_id": ["default"]})
        self.assertEqual(preview["messages"][-1]["text"],
                         "valid after malformed rows")

    def test_duplicate_session_in_one_account_keeps_newest_copy(self):
        base = self.source()
        sid = self.session_id(9)
        newest = self.write_codex(base, 1, "newest copy", sid=sid, mtime=20)
        self.write_codex(base, 2, "older copy", sid=sid, mtime=10)
        daemon._session_index_scan()
        result = daemon._query_session_index(limit=10)
        self.assertEqual(result["total"], 1)
        self.assertEqual(result["sessions"][0]["title"], "newest copy")
        newest.unlink()
        daemon._session_index_scan()
        fallback = daemon._query_session_index(limit=10)
        self.assertEqual(fallback["total"], 1)
        self.assertEqual(fallback["sessions"][0]["title"], "older copy")

    def test_malformed_cursor_falls_back_to_first_page(self):
        base = self.source()
        self.write_codex(base, 1, "first")
        daemon._session_index_scan()
        malformed = daemon.base64.urlsafe_b64encode(json.dumps({
            "v": 1, "scope": daemon._cursor_scope("", "all")
        }).encode()).decode().rstrip("=")
        result = daemon._query_session_index(limit=10, cursor=malformed)
        self.assertEqual(result["total"], 1)
        self.assertEqual(len(result["sessions"]), 1)


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


class ResumeCommandTests(unittest.TestCase):
    def test_missing_cwd_requests_replacement_with_a_pathless_command(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            missing = root / "moved-project"
            mappings = root / "path-mappings.json"
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings):
                result = daemon.api_resume({
                    "tool": "codex", "id": sid, "cwd": str(missing),
                    "copy_only": True,
                })
        self.assertTrue(result["ok"])
        self.assertTrue(result["needs_path"])
        self.assertEqual(result["original_cwd"], str(missing))
        self.assertEqual(result["command"],
                         f"codex resume {daemon._shell_quote(sid)}")
        self.assertNotIn("cd ", result["command"])

    def test_replacement_cwd_is_persisted_and_reused(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            missing = root / "old" / "project"
            replacement = root / "new" / "project"
            replacement.mkdir(parents=True)
            mappings = root / "path-mappings.json"
            body = {"tool": "codex", "id": sid, "cwd": str(missing),
                    "copy_only": True}
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings):
                first = daemon.api_resume({
                    **body, "replacement_cwd": str(replacement)})
                second = daemon.api_resume(body)
                saved = json.loads(mappings.read_text())
        resolved = os.path.realpath(replacement)
        expected = f"cd {daemon._shell_quote(resolved)} && codex resume"
        self.assertTrue(first["path_mapped"])
        self.assertTrue(second["path_mapped"])
        self.assertIn(expected, first["command"])
        self.assertEqual(second["command"], first["command"])
        self.assertEqual(saved["mappings"][str(missing)], resolved)

    def test_stale_mapping_requests_a_new_replacement(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            missing = root / "old-project"
            stale = root / "also-missing"
            mappings = root / "path-mappings.json"
            mappings.write_text(json.dumps({
                "version": 1, "mappings": {str(missing): str(stale)}}))
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings):
                result = daemon.api_resume({
                    "tool": "claude", "id": sid, "cwd": str(missing),
                    "copy_only": True,
                })
        self.assertTrue(result["needs_path"])
        self.assertNotIn("cd ", result["command"])

    def test_invalid_replacement_directory_is_rejected(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            with mock.patch.object(
                    daemon, "PATH_MAPPINGS_FILE", root / "path-mappings.json"):
                result = daemon.api_resume({
                    "tool": "codex", "id": sid,
                    "cwd": str(root / "old-project"),
                    "replacement_cwd": str(root / "missing-replacement"),
                    "copy_only": True,
                })
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "invalid replacement directory")

    def test_existing_directory_with_trailing_space_is_preserved(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            project = Path(td) / "project "
            project.mkdir()
            result = daemon.api_resume({
                "tool": "codex", "id": sid, "cwd": str(project),
                "copy_only": True,
            })
        self.assertIn(f"cd {daemon._shell_quote(os.path.realpath(project))} &&",
                      result["command"])

    def test_path_mapping_api_can_replace_and_remove_a_mapping(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            original = root / "old-project"
            replacement = root / "new-project"
            replacement.mkdir()
            mappings = root / "path-mappings.json"
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings):
                saved = daemon.api_path_mapping({
                    "action": "set", "original_cwd": str(original),
                    "replacement_cwd": str(replacement),
                })
                resumed = daemon.api_resume({
                    "tool": "codex",
                    "id": "11111111-1111-1111-1111-111111111111",
                    "cwd": str(original), "copy_only": True,
                })
                removed = daemon.api_path_mapping({
                    "action": "remove", "original_cwd": str(original),
                })
                payload = json.loads(mappings.read_text())
        self.assertTrue(saved["ok"])
        self.assertIn(daemon._shell_quote(os.path.realpath(replacement)),
                      resumed["command"])
        self.assertTrue(removed["removed"])
        self.assertEqual(payload["mappings"], {})

    def test_explicit_mapping_overrides_an_existing_original_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            original = root / "original"
            replacement = root / "replacement"
            original.mkdir()
            replacement.mkdir()
            mappings = root / "path-mappings.json"
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings):
                daemon.api_path_mapping({
                    "action": "set", "original_cwd": str(original),
                    "replacement_cwd": str(replacement),
                })
                result = daemon.api_resume({
                    "tool": "codex", "id": sid, "cwd": str(original),
                    "copy_only": True,
                })
        self.assertIn(daemon._shell_quote(os.path.realpath(replacement)),
                      result["command"])
        self.assertNotIn(daemon._shell_quote(os.path.realpath(original)),
                         result["command"])

    def test_terminal_copy_mode_uses_the_resolved_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td, \
                mock.patch.object(daemon, "get_settings",
                                  return_value={"terminal": "copy"}):
            result = daemon.api_resume({
                "tool": "codex", "id": sid, "cwd": td,
            })
        self.assertTrue(result["copy"])
        self.assertIn(f"cd {daemon._shell_quote(os.path.realpath(td))} &&",
                      result["command"])

    def test_paste_terminal_opens_the_resolved_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        completed = SimpleNamespace(returncode=0, stderr="")
        with tempfile.TemporaryDirectory() as td, \
                mock.patch.object(daemon, "get_settings", return_value={
                    "terminal": "warp", "auto_paste_resume": False}), \
                mock.patch.object(daemon, "_term_installed",
                                  side_effect=lambda app: app == "Warp"), \
                mock.patch.object(daemon.subprocess, "run",
                                  return_value=completed) as run:
            result = daemon.api_resume({
                "tool": "codex", "id": sid, "cwd": td,
            })
        self.assertTrue(result["paste"])
        self.assertEqual(run.call_args.args[0],
                         ["open", "-a", "Warp", os.path.realpath(td)])

    def test_terminal_applescript_contains_the_resolved_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        completed = SimpleNamespace(returncode=0, stderr="")
        with tempfile.TemporaryDirectory() as td, \
                mock.patch.object(daemon, "get_settings",
                                  return_value={"terminal": "terminal"}), \
                mock.patch.object(daemon, "_term_installed",
                                  side_effect=lambda app: app == "Terminal"), \
                mock.patch.object(daemon.subprocess, "run",
                                  return_value=completed) as run:
            result = daemon.api_resume({
                "tool": "claude", "id": sid, "cwd": td,
            })
        self.assertTrue(result["ok"])
        script = run.call_args.args[0][-1]
        self.assertIn(f"cd {daemon._shell_quote(os.path.realpath(td))} &&",
                      script)

    def test_iterm_applescript_contains_the_resolved_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        completed = SimpleNamespace(returncode=0, stderr="")
        with tempfile.TemporaryDirectory() as td, \
                mock.patch.object(daemon, "get_settings",
                                  return_value={"terminal": "iterm"}), \
                mock.patch.object(daemon, "_term_installed",
                                  side_effect=lambda app: app == "iTerm"), \
                mock.patch.object(daemon.subprocess, "run",
                                  return_value=completed) as run:
            result = daemon.api_resume({
                "tool": "codex", "id": sid, "cwd": td,
            })
        self.assertTrue(result["ok"])
        script = run.call_args.args[0][-1]
        self.assertIn(f"cd {daemon._shell_quote(os.path.realpath(td))} &&",
                      script)

    def test_direct_launch_terminals_receive_the_resolved_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        completed = SimpleNamespace(returncode=0, stderr="")
        cases = [("ghostty", "Ghostty"), ("kitty", "kitty"),
                 ("wezterm", "WezTerm"), ("alacritty", "Alacritty")]
        for mode, app in cases:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as td, \
                    mock.patch.object(daemon, "get_settings",
                                      return_value={"terminal": mode}), \
                    mock.patch.object(daemon, "_term_installed",
                                      side_effect=lambda candidate, app=app: candidate == app), \
                    mock.patch.object(daemon.subprocess, "run",
                                      return_value=completed) as run:
                result = daemon.api_resume({
                    "tool": "codex", "id": sid, "cwd": td,
                })
                args = run.call_args.args[0]
                self.assertTrue(result["ok"])
                self.assertEqual(args[:4], ["open", "-na", app, "--args"])
                self.assertIn(daemon._shell_quote(os.path.realpath(td)),
                              " ".join(args))

    def test_account_scoped_resume_pins_the_matching_config_directory(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "codex-work"
            source.mkdir()
            with mock.patch.object(daemon, "codex_sources", return_value=[{
                    "id": "work", "label": "Work", "path": source}]):
                result = daemon.api_resume({
                    "tool": "codex", "id": sid, "cwd": td,
                    "account_id": "work", "copy_only": True,
                })
            self.assertTrue(result["ok"])
            self.assertIn(f"CODEX_HOME={daemon._shell_quote(str(source))}",
                          result["command"])
            self.assertIn(f"codex resume {daemon._shell_quote(sid)}",
                          result["command"])

    def test_unknown_resume_account_is_rejected(self):
        sid = "11111111-1111-1111-1111-111111111111"
        with mock.patch.object(daemon, "claude_sources", return_value=[]):
            result = daemon.api_resume({
                "tool": "claude", "id": sid, "account_id": "missing",
                "copy_only": True,
            })
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "account not found")


class CodexQuotaRealtimeTests(unittest.TestCase):
    @staticmethod
    def rollout_event(timestamp, percent):
        return {"timestamp": timestamp, "type": "event_msg", "payload": {
            "type": "token_count",
            "rate_limits": {
                "primary": {
                    "used_percent": percent,
                    "window_minutes": 10080,
                    "resets_at": time.time() + 86400,
                },
                "secondary": None,
                "credits": {"has_credits": False, "balance": "0"},
            },
        }}

    def test_app_server_snapshot_maps_all_limit_ids(self):
        result = {
            "rateLimits": {
                "limitId": "codex",
                "primary": {
                    "usedPercent": 50,
                    "windowDurationMins": 10080,
                    "resetsAt": time.time() + 86400,
                },
                "secondary": None,
                "credits": {
                    "hasCredits": False, "unlimited": False, "balance": "0",
                },
            },
            "rateLimitsByLimitId": {
                "codex": {
                    "limitId": "codex",
                    "primary": {
                        "usedPercent": 50,
                        "windowDurationMins": 10080,
                        "resetsAt": time.time() + 86400,
                    },
                },
                "codex_bengalfox": {
                    "limitId": "codex_bengalfox",
                    "limitName": "GPT-5.3-Codex-Spark",
                    "primary": {
                        "usedPercent": 0,
                        "windowDurationMins": 10080,
                        "resetsAt": time.time() + 86400,
                    },
                },
            },
        }

        quota = daemon._codex_quota_from_app_server(result, "2026-07-23T15:00:00Z")

        self.assertTrue(quota["ok"])
        self.assertEqual([w["id"] for w in quota["windows"]],
                         ["seven_day", "seven_day_codex-bengalfox"])
        self.assertEqual(quota["windows"][1]["label"], "GPT-5.3-Codex-Spark")
        self.assertEqual(quota["credits"]["balance"], "0")

    def test_sparse_app_server_notification_never_overwrites_full_snapshot(self):
        manager = daemon.CodexQuotaManager()
        try:
            with mock.patch.object(manager, "request_reconcile") as reconcile, \
                    mock.patch.object(manager, "_apply") as apply:
                self.assertTrue(manager._apply_notification({}, {
                    "rateLimits": {
                        "limitId": "codex",
                        "primary": {"usedPercent": 52},
                    },
                }))
            reconcile.assert_not_called()
            apply.assert_not_called()
        finally:
            manager.stop()

    def test_official_refresh_uses_timestamp_captured_inside_client_lock(self):
        manager = daemon.CodexQuotaManager()
        src = {
            "id": "default", "label": "默认", "path": Path("/tmp/codex-home"),
            "is_default": True, "session_only": False,
        }
        response = {
            "rateLimits": {
                "limitId": "codex",
                "primary": {
                    "usedPercent": 50,
                    "windowDurationMins": 10080,
                    "resetsAt": time.time() + 86400,
                },
            },
        }
        client = SimpleNamespace(
            read_rate_limits_observed=lambda: (response, 1234.5))
        try:
            with mock.patch.object(manager, "_client_for", return_value=client), \
                    mock.patch.object(manager, "_apply", return_value=True) as apply:
                self.assertTrue(manager._refresh_source_official(src))
            self.assertEqual(apply.call_args.args[2], 1234.5)
        finally:
            manager.stop()

    def test_official_refresh_rejects_response_without_quota_windows(self):
        manager = daemon.CodexQuotaManager()
        src = {
            "id": "default", "label": "默认", "path": Path("/tmp/codex-home"),
            "is_default": True, "session_only": False,
        }
        client = SimpleNamespace(
            read_rate_limits_observed=lambda: ({}, 1234.5))
        try:
            with mock.patch.object(manager, "_client_for", return_value=client), \
                    mock.patch.object(manager, "_apply") as apply:
                self.assertFalse(manager._refresh_source_official(src))
            apply.assert_not_called()
        finally:
            manager.stop()

    def test_retired_app_server_client_cannot_restart(self):
        client = daemon._CodexAppServerClient(Path("/tmp/codex-home"))
        client.retire()
        with mock.patch.object(daemon.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(RuntimeError, "retired"):
                client.read_rate_limits()
        popen.assert_not_called()

    def test_force_refresh_waits_for_active_reconcile_before_starting(self):
        manager = daemon.CodexQuotaManager()
        manager._last_force = 0
        result = []
        worker = threading.Thread(
            target=lambda: result.append(manager.force_refresh()))
        try:
            with mock.patch.object(
                    manager, "_refresh_all_locked", return_value=True) as refresh:
                manager._refresh_gate.acquire()
                worker.start()
                time.sleep(0.03)
                self.assertTrue(worker.is_alive())
                manager._refresh_gate.release()
                worker.join(timeout=1)
                self.assertFalse(worker.is_alive())
                self.assertEqual(result, [True])
                refresh.assert_called_once_with()
        finally:
            if manager._refresh_gate.locked():
                manager._refresh_gate.release()
            worker.join(timeout=1)
            manager.stop()

    def test_concurrent_force_refreshes_share_one_batch_result(self):
        manager = daemon.CodexQuotaManager()
        entered = threading.Event()
        release = threading.Event()
        results = []

        def refresh():
            entered.set()
            release.wait(timeout=1)
            return True

        workers = [
            threading.Thread(target=lambda: results.append(
                manager.force_refresh(timeout=1)))
            for _ in range(2)
        ]
        try:
            with mock.patch.object(
                    manager, "_refresh_all_locked", side_effect=refresh) as batch:
                workers[0].start()
                self.assertTrue(entered.wait(timeout=1))
                workers[1].start()
                time.sleep(0.03)
                release.set()
                for worker in workers:
                    worker.join(timeout=1)
            self.assertEqual(sorted(results), [True, True])
            batch.assert_called_once_with()
        finally:
            release.set()
            for worker in workers:
                worker.join(timeout=1)
            manager.stop()

    def test_force_refresh_has_a_total_wait_deadline(self):
        manager = daemon.CodexQuotaManager()
        try:
            manager._refresh_gate.acquire()
            started = time.monotonic()
            self.assertFalse(manager.force_refresh(timeout=0.03))
            self.assertLess(time.monotonic() - started, 0.2)
        finally:
            if manager._refresh_gate.locked():
                manager._refresh_gate.release()
            manager.stop()

    def test_api_quota_reports_forced_codex_refresh_failure(self):
        settings = {
            "quota_interval": 600, "show_claude": False, "show_codex": True,
        }
        with mock.patch.object(daemon, "get_settings", return_value=settings), \
                mock.patch.object(
                    daemon._codex_quota_manager, "force_refresh",
                    return_value=False):
            with self.assertRaisesRegex(RuntimeError, "refresh failed"):
                daemon.api_quota(force=True)

    def test_force_quota_refreshes_enforces_end_to_end_budget(self):
        release = threading.Event()

        def blocked_refresh(_timeout):
            release.wait(timeout=1)
            return True

        settings = {"show_claude": False, "show_codex": True}
        started = time.monotonic()
        try:
            with mock.patch.object(
                    daemon._codex_quota_manager, "force_refresh",
                    side_effect=blocked_refresh):
                with self.assertRaisesRegex(RuntimeError, "timed out"):
                    daemon._force_quota_refreshes(
                        settings, ttl=600, budget=0.03)
            self.assertLess(time.monotonic() - started, 0.2)
        finally:
            release.set()

    def test_force_quota_refreshes_reports_claude_semantic_failure(self):
        settings = {"show_claude": True, "show_codex": False}
        failed = [{"ok": False, "error": "upstream failed"}]
        with mock.patch.object(
                daemon, "_claude_quota_accounts", return_value=failed):
            with self.assertRaisesRegex(RuntimeError, "Claude"):
                daemon._force_quota_refreshes(settings, ttl=600)

    def test_force_quota_refreshes_allows_expected_no_quota_account(self):
        settings = {"show_claude": True, "show_codex": False}
        unavailable = [{"ok": False, "no_quota": True, "kind": "gateway"}]
        with mock.patch.object(
                daemon, "_claude_quota_accounts", return_value=unavailable):
            self.assertEqual(
                daemon._force_quota_refreshes(settings, ttl=600), unavailable)

    def test_stopping_manager_cannot_spawn_a_new_app_server(self):
        manager = daemon.CodexQuotaManager()
        manager._stop.set()
        try:
            with self.assertRaisesRegex(RuntimeError, "stopping"):
                manager._client_for({
                    "id": "default", "path": Path("/tmp/codex-home"),
                    "is_default": True,
                })
            self.assertEqual(manager._clients, {})
        finally:
            manager.stop()

    def test_reconcile_prunes_removed_account_processes_and_state(self):
        manager = daemon.CodexQuotaManager()
        removed = SimpleNamespace(retire=mock.Mock())
        removed_key = os.path.realpath("/tmp/removed")
        kept_key = os.path.realpath("/tmp/kept")
        manager._clients = {removed_key: removed, kept_key: SimpleNamespace()}
        manager._states = {
            removed_key: {"quota": {"ok": True}},
            kept_key: {"quota": {"ok": True}},
        }
        try:
            with mock.patch.object(manager, "_path_key", return_value=kept_key):
                manager._prune_inactive([{"path": Path("/tmp/kept")}])
            self.assertNotIn(removed_key, manager._clients)
            self.assertNotIn(removed_key, manager._states)
            self.assertIn(removed_key, manager._inactive_paths)
            removed.retire.assert_called_once_with()
            removed_src = {
                "id": "removed", "label": "Removed",
                "path": Path("/tmp/removed"), "is_default": False,
            }
            self.assertFalse(manager._apply(
                removed_src, {"ok": True, "windows": []}, time.time()))
            with self.assertRaisesRegex(RuntimeError, "inactive"):
                manager._client_for(removed_src)
        finally:
            manager._clients.clear()
            manager.stop()

    def test_rollout_fallback_uses_latest_event_not_latest_filename(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            recent_dir = base / "sessions" / "2026" / "07" / "22"
            resumed_dir = base / "sessions" / "2026" / "06" / "29"
            recent_dir.mkdir(parents=True)
            resumed_dir.mkdir(parents=True)
            recent = recent_dir / "rollout-2026-07-22T00-00-00-new.jsonl"
            resumed = resumed_dir / "rollout-2026-06-29T00-00-00-old.jsonl"
            _jsonl(recent, [self.rollout_event("2026-07-22T12:00:00Z", 23)])
            _jsonl(resumed, [self.rollout_event("2026-07-23T15:00:00Z", 50)])
            os.utime(recent, (100, 100))
            os.utime(resumed, (200, 200))

            quota = daemon._codex_quota(base)

        self.assertEqual(quota["windows"][0]["used_percent"], 50)
        self.assertEqual(quota["sampled_at"], "2026-07-23T15:00:00Z")

    def test_codex_quota_refresh_runs_when_completion_pills_are_disabled(self):
        settings = dict(daemon.DEFAULT_SETTINGS, notify_session_done=False)
        body = {
            "type": "agent-turn-complete",
            "thread-id": "019f0f1d-8408-7600-bc4f-0c53dd24d3d3",
            "cwd": "/tmp/project",
        }
        with mock.patch.object(daemon, "get_settings", return_value=settings), \
                mock.patch.object(daemon._codex_quota_manager,
                                  "note_turn_complete") as refresh:
            result = daemon.api_event(body)

        self.assertEqual(result["skipped"], "disabled")
        refresh.assert_called_once_with(body["thread-id"], body["cwd"])

    def test_older_rollout_event_cannot_replace_newer_official_snapshot(self):
        manager = daemon.CodexQuotaManager()
        src = {
            "id": "default", "label": "默认", "path": Path("/tmp/codex-home"),
            "is_default": True, "session_only": False,
        }
        official = {"ok": True, "windows": [{
            "id": "seven_day", "label": "周限额",
            "used_percent": 50, "resets_at": time.time() + 86400,
        }], "sampled_at": "2026-07-23T15:00:00Z"}
        older = {"ok": True, "windows": [{
            "id": "seven_day", "label": "周限额",
            "used_percent": 23, "resets_at": time.time() + 86400,
        }], "sampled_at": "2026-07-22T15:00:00Z"}
        try:
            with mock.patch.object(daemon, "_remember_last_good"), \
                    mock.patch.object(daemon, "_bump_quota_revision"), \
                    mock.patch.object(daemon, "_check_alerts"):
                self.assertTrue(manager._apply(src, official, 200, official=True))
                self.assertFalse(manager._apply(src, older, 100, official=False))
            self.assertEqual(manager.quota_for_source(src)["windows"][0]["used_percent"], 50)
        finally:
            manager.stop()

    def test_rollout_update_preserves_named_official_limits(self):
        manager = daemon.CodexQuotaManager()
        src = {
            "id": "default", "label": "默认", "path": Path("/tmp/codex-home-2"),
            "is_default": True, "session_only": False,
        }
        official = {"ok": True, "windows": [
            {"id": "seven_day", "label": "周限额",
             "used_percent": 40, "resets_at": time.time() + 86400},
            {"id": "seven_day_codex-bengalfox", "label": "Spark",
             "used_percent": 5, "resets_at": time.time() + 86400},
        ], "sampled_at": "2026-07-23T15:00:00Z"}
        local = {"ok": True, "windows": [
            {"id": "seven_day", "label": "周限额",
             "used_percent": 41, "resets_at": time.time() + 86400},
        ], "sampled_at": "2026-07-23T15:01:00Z"}
        try:
            with mock.patch.object(daemon, "_remember_last_good"), \
                    mock.patch.object(daemon, "_bump_quota_revision"), \
                    mock.patch.object(daemon, "_check_alerts"):
                manager._apply(src, official, 100, official=True)
                manager._apply(src, local, 101, official=False)
            windows = manager.quota_for_source(src)["windows"]
            self.assertEqual([w["id"] for w in windows],
                             ["seven_day", "seven_day_codex-bengalfox"])
            self.assertEqual(windows[0]["used_percent"], 41)
        finally:
            manager.stop()

    def test_quota_change_long_poll_wakes_on_revision(self):
        old_revision = daemon._quota_revision
        try:
            with daemon._quota_change:
                daemon._quota_revision = 100

            def bump():
                time.sleep(0.03)
                daemon._bump_quota_revision()

            thread = daemon.threading.Thread(target=bump)
            thread.start()
            with mock.patch.object(daemon, "api_quota",
                                   return_value={"codex": {"ok": True}}):
                result = daemon.api_quota_changes({
                    "after": ["100"], "boot": [daemon._quota_boot_id],
                    "timeout": ["1"],
                })
            thread.join()
            self.assertEqual(result["revision"], 101)
            self.assertTrue(result["quota"]["codex"]["ok"])
        finally:
            with daemon._quota_change:
                daemon._quota_revision = old_revision


class QuotaSamplingTests(unittest.TestCase):
    def sample(self, windows):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            history = root / "quota-history.jsonl"
            payload = {
                "claude": {"ok": False},
                "codex": {"ok": True, "windows": windows},
                "accounts": {"claude": [], "codex": []},
            }
            with mock.patch.multiple(
                    daemon, DATA_DIR=root, HISTORY_FILE=history), \
                    mock.patch.object(daemon, "api_quota", return_value=payload), \
                    mock.patch.object(daemon, "_check_alerts"):
                daemon._sample_once()
            return json.loads(history.read_text().strip())

    def test_codex_weekly_only_is_recorded_as_weekly(self):
        sample = self.sample([{
            "id": "seven_day", "used_percent": 19,
        }])
        self.assertEqual(sample["x7d"], 19)
        self.assertNotIn("x5h", sample)

    def test_codex_samples_are_selected_by_id_not_position(self):
        sample = self.sample([
            {"id": "seven_day", "used_percent": 61},
            {"id": "five_hour", "used_percent": 17},
        ])
        self.assertEqual(sample["x5h"], 17)
        self.assertEqual(sample["x7d"], 61)


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
