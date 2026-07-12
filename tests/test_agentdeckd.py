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
