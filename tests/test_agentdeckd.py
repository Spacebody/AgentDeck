import json
import io
import os
import plistlib
import shutil
import subprocess
import sys
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
    def test_update_get_cannot_force_network_when_automatic_check_is_disabled(self):
        handler = object.__new__(daemon.Handler)
        handler.path = "/api/update?force=1"
        handler.headers = {"Host": "127.0.0.1:7777"}
        sent = []
        handler._send = lambda code, payload, ctype="": sent.append((code, payload))
        with mock.patch.object(daemon, "get_settings",
                               return_value={"update_check": False}), \
                mock.patch.object(daemon.urllib.request, "urlopen") as urlopen:
            handler.do_GET()

        self.assertEqual(sent[0][0], 200)
        self.assertTrue(sent[0][1]["disabled"])
        urlopen.assert_not_called()

    def test_health_exposes_daemon_and_parent_process_identity(self):
        handler = object.__new__(daemon.Handler)
        handler.path = "/api/health"
        handler.headers = {"Host": "127.0.0.1:7777"}
        sent = []
        handler._send = lambda code, payload, ctype="": sent.append((code, payload))
        with mock.patch.object(daemon.os, "getpid", return_value=123), \
                mock.patch.object(daemon.os, "getppid", return_value=456):
            handler.do_GET()

        self.assertEqual(sent[0][0], 200)
        self.assertEqual(sent[0][1]["pid"], 123)
        self.assertEqual(sent[0][1]["parent_pid"], 456)
        self.assertEqual(sent[0][1]["instance_id"], daemon._DAEMON_INSTANCE_ID)
        self.assertEqual(sent[0][1]["started_at"], daemon._DAEMON_STARTED_AT)
        self.assertEqual(sent[0][1]["update_transaction"], daemon._UPDATE_TRANSACTION)
        self.assertEqual(sent[0][1]["owner_token"], daemon._BACKEND_OWNER_TOKEN)
        self.assertEqual(sent[0][1]["script_path"], str(Path(daemon.__file__).resolve()))

    def test_shutdown_requires_matching_daemon_instance(self):
        def invoke(instance_id):
            payload = json.dumps({"instance_id": instance_id}).encode()
            handler = object.__new__(daemon.Handler)
            handler.path = "/api/shutdown"
            handler.headers = {
                "Host": "127.0.0.1:7777",
                "Content-Type": "application/json",
                "Content-Length": str(len(payload)),
            }
            handler.rfile = io.BytesIO(payload)
            sent = []
            handler._send = lambda code, body, ctype="": sent.append((code, body))
            requested = threading.Event()
            with mock.patch.object(daemon, "_daemon_shutdown_requested", requested):
                handler.do_POST()
            return sent, requested

        sent, requested = invoke("wrong-instance")
        self.assertEqual(sent, [(403, {"error": "forbidden"})])
        self.assertFalse(requested.is_set())

        sent, requested = invoke(daemon._DAEMON_INSTANCE_ID)
        self.assertEqual(sent, [(200, {"ok": True})])
        self.assertTrue(requested.is_set())

    def test_only_loopback_hosts_are_accepted(self):
        self.assertTrue(daemon._local_http_host({"Host": "127.0.0.1:7777"}))
        self.assertTrue(daemon._local_http_host({"Host": "LOCALHOST:7777"}))
        self.assertFalse(daemon._local_http_host({"Host": "rebind.example"}))
        self.assertFalse(daemon._local_http_host({"Host": "127.0.0.1:7777.evil"}))

    def test_delayed_background_loop_waits_for_health_startup_window(self):
        shutdown = mock.Mock()
        shutdown.wait.return_value = False
        task = mock.Mock()

        daemon._run_delayed_loop(3, shutdown, task)

        shutdown.wait.assert_called_once_with(3)
        task.assert_called_once_with()

    def test_delayed_background_loop_does_not_start_during_shutdown(self):
        shutdown = mock.Mock()
        shutdown.wait.return_value = True
        task = mock.Mock()

        daemon._run_delayed_loop(3, shutdown, task)

        task.assert_not_called()

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

    def test_event_long_poll_requires_same_origin_and_rejects_excess_waiters(self):
        handler = object.__new__(daemon.Handler)
        handler.path = "/api/events?since=1&wait=25"
        sent = []
        handler._send = lambda code, payload, ctype="": sent.append((code, payload))
        with mock.patch.object(daemon, "api_events") as events:
            handler.headers = {
                "Host": "127.0.0.1:7777",
                "Sec-Fetch-Site": "cross-site",
                "Origin": "https://attacker.example",
            }
            handler.do_GET()
            self.assertEqual(sent, [(403, {"error": "forbidden"})])
            events.assert_not_called()

            sent.clear()
            handler.headers = {"Host": "127.0.0.1:7777"}
            slots = SimpleNamespace(acquire=lambda blocking=False: False)
            with mock.patch.object(daemon, "_event_wait_slots", slots):
                handler.do_GET()
            self.assertEqual(sent, [(429, {"error": "too many event watchers"})])
            events.assert_not_called()

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


class DaemonLifecycleTests(unittest.TestCase):
    def test_parent_watchdog_requests_graceful_shutdown(self):
        requested = threading.Event()
        with mock.patch.object(daemon.os, "getppid", side_effect=[123, 1]), \
                mock.patch.object(daemon.os, "_exit") as hard_exit:
            worker = threading.Thread(
                target=daemon._parent_watchdog,
                args=(requested, 0.001))
            worker.start()
            worker.join(timeout=1)

        self.assertFalse(worker.is_alive())
        self.assertTrue(requested.is_set())
        hard_exit.assert_not_called()

    def test_sigterm_wakes_shutdown_thread(self):
        shutdown_called = threading.Event()
        server = SimpleNamespace(shutdown=shutdown_called.set)
        handlers = {}

        def register(sig, callback):
            handlers[sig] = callback

        with mock.patch.object(daemon.signal, "signal", side_effect=register):
            requested = daemon._daemon_shutdown_controller(server)
        handlers[daemon.signal.SIGTERM](daemon.signal.SIGTERM, None)

        self.assertTrue(requested.wait(timeout=1))
        self.assertTrue(shutdown_called.wait(timeout=1))

    def test_sigterm_stops_a_real_http_server_loop(self):
        server = daemon.ThreadingHTTPServer(("127.0.0.1", 0), daemon.Handler)
        server.daemon_threads = True
        handlers = {}
        with mock.patch.object(
                daemon.signal, "signal",
                side_effect=lambda sig, callback: handlers.__setitem__(sig, callback)):
            requested = daemon._daemon_shutdown_controller(server)
        worker = threading.Thread(target=server.serve_forever)
        worker.start()
        try:
            handlers[daemon.signal.SIGTERM](daemon.signal.SIGTERM, None)
            worker.join(timeout=1)
            self.assertTrue(requested.is_set())
            self.assertFalse(worker.is_alive())
        finally:
            requested.set()
            server.shutdown()
            server.server_close()


class EventLongPollTests(unittest.TestCase):
    def setUp(self):
        with daemon._events_change:
            self.events = list(daemon._events)
            self.event_seq = daemon._event_seq
            self.event_keys = list(daemon._event_keys)
            self.event_key_set = set(daemon._event_key_set)
            self.event_key_times = dict(daemon._event_key_times)
            daemon._events.clear()
            daemon._event_keys.clear()
            daemon._event_key_set.clear()
            daemon._event_key_times.clear()
            daemon._event_seq = 0

    def tearDown(self):
        with daemon._events_change:
            daemon._events.clear()
            daemon._events.extend(self.events)
            daemon._event_keys.clear()
            daemon._event_keys.extend(self.event_keys)
            daemon._event_key_set.clear()
            daemon._event_key_set.update(self.event_key_set)
            daemon._event_key_times.clear()
            daemon._event_key_times.update(self.event_key_times)
            daemon._event_seq = self.event_seq
            daemon._events_change.notify_all()

    def test_event_long_poll_wakes_when_event_is_queued(self):
        result = {}

        def wait_for_event():
            result.update(daemon.api_events({
                "since": ["0"], "wait": ["1"],
                "boot": [daemon._event_boot_id],
            }))

        waiter = threading.Thread(target=wait_for_event)
        waiter.start()
        time.sleep(0.05)
        self.assertTrue(waiter.is_alive())

        event = {
            "id": 1, "tool": "codex", "session": "session-1",
            "cwd": "/tmp/project", "title": "done", "project": "project",
            "duration": 1, "ts": time.time(),
        }
        with daemon._events_change:
            daemon._event_seq = 1
            daemon._events.append(event)
            daemon._events_change.notify_all()

        waiter.join(timeout=0.5)
        self.assertFalse(waiter.is_alive())
        self.assertEqual(result["events"], [event])
        self.assertEqual(result["last"], 1)

    def test_stale_boot_returns_without_waiting_on_reset_sequence(self):
        started = time.monotonic()
        result = daemon.api_events({
            "since": ["77"], "wait": ["1"], "boot": ["old-boot"],
        })

        self.assertLess(time.monotonic() - started, 0.2)
        self.assertEqual(result["boot_id"], daemon._event_boot_id)
        self.assertEqual(result["events"], [])

    def test_same_turn_is_deduplicated_but_later_turn_with_same_title_is_kept(self):
        base = {
            "type": "agent-turn-complete",
            "thread-id": "019fa64d-043a-7512-aaf1-3a7a58f36c9d",
            "cwd": "/Users/test/project",
            "input-messages": ["same title"],
        }
        settings = dict(daemon.DEFAULT_SETTINGS, notify_session_done=True)
        with mock.patch.object(daemon, "get_settings", return_value=settings), \
                mock.patch.object(daemon._codex_quota_manager, "note_turn_complete"), \
                mock.patch.object(daemon, "_events_persist"), \
                mock.patch.object(daemon, "_request_session_index_scan"):
            first = daemon.api_event({**base, "turn-id": "turn-1"})
            duplicate = daemon.api_event({**base, "turn-id": "turn-1"})
            later = daemon.api_event({**base, "turn-id": "turn-2"})

        self.assertEqual(first["queued"], 1)
        self.assertEqual(duplicate["skipped"], "duplicate")
        self.assertEqual(later["queued"], 2)

    def test_stable_turn_remains_deduplicated_after_heuristic_window(self):
        key = daemon._event_key({
            "tool": "codex", "session": "session-1", "cwd": "/work/project",
            "title": "same title", "turn": "turn-1",
        })
        self.assertTrue(daemon._remember_event_key(key, 100))
        self.assertFalse(daemon._remember_event_key(key, 160))

    def test_heuristic_same_title_is_allowed_after_short_retry_window(self):
        key = daemon._event_key({
            "tool": "codex", "session": "session-1", "cwd": "/work/project",
            "title": "same title",
        })
        self.assertTrue(daemon._remember_event_key(key, 100))
        self.assertFalse(daemon._remember_event_key(key, 101))
        self.assertTrue(daemon._remember_event_key(key, 103))


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
                    mock.patch.object(daemon, "qoder_sources", return_value=[]), \
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


class QoderHookTests(unittest.TestCase):
    def test_hook_merge_is_idempotent_and_preserves_user_stop_hooks(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            settings = root / "settings.json"
            wrapper = root / "qoder-stop-hook.sh"
            external = {"matcher": "", "hooks": [
                {"type": "command", "command": "/usr/bin/true", "timeout": 2}]}
            settings.write_text(json.dumps({"hooks": {"Stop": [external]}}))
            command = f"sh {json.dumps(str(wrapper))}"
            with mock.patch.multiple(
                    daemon, _QODER_HOOK_WRAPPER=wrapper, _QODER_HOOK_CMD=command):
                self.assertTrue(daemon._install_qoder_hook(settings))
                self.assertFalse(daemon._install_qoder_hook(settings))
                installed = json.loads(settings.read_text())["hooks"]["Stop"]
                self.assertEqual(installed[0], external)
                self.assertEqual(len(installed), 2)
                self.assertEqual(installed[1]["hooks"][0]["command"], command)
                syntax = daemon.subprocess.run(
                    ["sh", "-n", str(wrapper)], capture_output=True, text=True)
                self.assertEqual(syntax.returncode, 0, syntax.stderr)

                daemon._remove_qoder_hook(settings)
                self.assertEqual(json.loads(settings.read_text())["hooks"]["Stop"],
                                 [external])


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
            qoder = root / "qoder"
            session_dir = codex / "sessions" / "2026" / "07" / "15"
            session_dir.mkdir(parents=True)
            rollout = session_dir / "rollout-2026-07-15T01-00-00-test.jsonl"
            now = daemon.datetime.now(daemon.timezone.utc)
            stamp = now.isoformat().replace("+00:00", "Z")
            old = "/missing/old/project"
            replacement = root / "moved-project"
            replacement.mkdir()
            qoder_project = qoder / "projects" / "sample"
            qoder_project.mkdir(parents=True)
            qoder_transcript = qoder_project / "session.jsonl"
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
            _jsonl(qoder_transcript, [
                {"timestamp": stamp, "type": "system", "cwd": str(replacement)},
                {"timestamp": stamp, "type": "assistant", "requestId": "q1",
                 "message": {"id": "q1", "model": "qoder-model", "usage": {
                     "input_tokens": 50, "output_tokens": 10,
                     "cache_read_input_tokens": 0}}},
            ])
            mappings = root / "path_mappings.json"
            mappings.write_text(json.dumps({
                "version": 1, "mappings": {old: str(replacement)}}))
            with mock.patch.multiple(
                    daemon,
                    CODEX_USAGE_CACHE_FILE=root / "codex-cache.json",
                    CLAUDE_USAGE_CACHE_FILE=root / "claude-cache.json",
                    QODER_USAGE_CACHE_FILE=root / "qoder-cache.json",
                    PATH_MAPPINGS_FILE=mappings), \
                    mock.patch.object(daemon, "codex_sources", return_value=[{
                        "path": codex}]), \
                    mock.patch.object(daemon, "claude_sources", return_value=[]), \
                    mock.patch.object(daemon, "qoder_sources", return_value=[{
                        "path": qoder}]):
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
            self.assertEqual(sum(usage["qoder_daily"].values()), 60)
            self.assertEqual(usage["projects_7d"][0]["tokens"], 170)
            self.assertEqual(usage["projects_7d"][0]["agents"], {
                "codex": 110, "qoder": 60})


class SessionIndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.db = self.root / "session-index.sqlite3"
        self.pins = self.root / "pins.json"
        self.claude_sources = []
        self.codex_sources = []
        self.qoder_sources = []
        self.patches = [
            mock.patch.object(daemon, "SESSION_INDEX_FILE", self.db),
            mock.patch.object(daemon, "PINS_FILE", self.pins),
            mock.patch.object(daemon, "claude_sources",
                              side_effect=lambda: self.claude_sources),
            mock.patch.object(daemon, "codex_sources",
                              side_effect=lambda: self.codex_sources),
            mock.patch.object(daemon, "qoder_sources",
                              side_effect=lambda: self.qoder_sources),
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
            revision = daemon._query_session_index(limit=10)["revision"]
            self.assertEqual(parse.call_count, 3)
            daemon._session_index_scan()
            self.assertEqual(parse.call_count, 3)
            self.assertEqual(
                daemon._query_session_index(limit=10)["revision"], revision)
            with paths[0].open("a") as handle:
                handle.write(json.dumps({"type": "event_msg", "payload": {
                    "type": "agent_message", "message": "later"}}) + "\n")
            daemon._session_index_scan()
            self.assertEqual(parse.call_count, 3)
            self.assertGreater(
                daemon._query_session_index(limit=10)["revision"], revision)

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

    def test_changed_index_invalidates_cursor_and_returns_new_first_page(self):
        base = self.source()
        for index in range(6):
            self.write_codex(base, index, f"session {index}")
        daemon._session_index_scan()
        first = daemon._query_session_index(limit=2)
        target = daemon._query_session_index(limit=10)["sessions"][-1]

        daemon.api_pin({"pinned": True, "session": target})
        refreshed = daemon._query_session_index(
            limit=2, cursor=first["next_cursor"])

        self.assertTrue(refreshed["cursor_stale"])
        self.assertEqual(refreshed["sessions"][0]["id"], target["id"])

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

    def test_qoder_app_metadata_is_indexed_without_message_content(self):
        sid = self.session_id(42)
        self.qoder_sources.append({
            "id": "default", "label": "Default", "path": self.root / "qoder"})
        app_entry = {
            "tool": "qoder", "account_id": "default", "account": "Default",
            "path": f"qoder-app://{sid}", "inode": 0, "size": 0, "mtime": 42,
            "preparsed": {"session_id": sid, "title": "Desktop session",
                          "cwd": "/work/desktop", "project": "desktop", "branch": ""},
        }
        with mock.patch.object(daemon, "_qoder_app_session_entries",
                               return_value=[app_entry]):
            daemon._session_index_scan()
        result = daemon._query_session_index(tool="qoder", limit=10)
        self.assertEqual(result["total"], 1)
        self.assertEqual(result["sessions"][0]["source"], "qoder_app")
        self.assertEqual(result["sessions"][0]["title"], "Desktop session")

    def test_unchanged_qoder_app_metadata_is_not_rewritten(self):
        sid = self.session_id(44)
        app_entry = {
            "tool": "qoder", "account_id": "default", "account": "Default",
            "path": f"qoder-app://{sid}", "inode": 0, "size": 0, "mtime": 44,
            "preparsed": {"session_id": sid, "title": "Stable desktop session",
                          "cwd": "/work/desktop", "project": "desktop", "branch": ""},
        }
        with mock.patch.object(daemon, "_qoder_app_session_entries",
                               return_value=[app_entry]), \
                mock.patch.object(daemon, "_session_file_state_upsert",
                                  wraps=daemon._session_file_state_upsert) as upsert:
            daemon._session_index_scan()
            self.assertEqual(upsert.call_count, 1)
            daemon._session_index_scan()
            self.assertEqual(upsert.call_count, 1)

    def test_qoder_app_ipc_outage_keeps_previous_index_snapshot(self):
        sid = self.session_id(43)
        app_entry = {
            "tool": "qoder", "account_id": "default", "account": "Default",
            "path": f"qoder-app://{sid}", "inode": 0, "size": 0, "mtime": 43,
            "preparsed": {"session_id": sid, "title": "Keep during outage",
                          "cwd": "/work/desktop", "project": "desktop", "branch": ""},
        }
        daemon._qoder_app_scan_authoritative = True
        with mock.patch.object(daemon, "_qoder_app_session_entries",
                               return_value=[app_entry]):
            daemon._session_index_scan()
        daemon._qoder_app_scan_authoritative = False
        with mock.patch.object(daemon, "_qoder_app_session_entries", return_value=[]):
            daemon._session_index_scan()
        result = daemon._query_session_index(tool="qoder", limit=10)
        self.assertEqual(result["sessions"][0]["title"], "Keep during outage")

    def test_malformed_cursor_falls_back_to_first_page(self):
        base = self.source()
        self.write_codex(base, 1, "first")
        daemon._session_index_scan()
        malformed = daemon.base64.urlsafe_b64encode(json.dumps({
            "v": 2, "scope": daemon._cursor_scope("", "all")
        }).encode()).decode().rstrip("=")
        result = daemon._query_session_index(limit=10, cursor=malformed)
        self.assertEqual(result["total"], 1)
        self.assertEqual(len(result["sessions"]), 1)


class ActiveSessionTests(unittest.TestCase):
    def test_api_active_empty_runtime_and_index_returns_without_error(self):
        class EmptyCursor:
            def fetchall(self):
                return []

        class EmptyConnection:
            def execute(self, *_args, **_kwargs):
                return EmptyCursor()
            def close(self):
                pass

        with daemon._cache_lock:
            previous = daemon._ttl_cache.pop("active", None)
        try:
            with mock.patch.object(daemon, "_iter_claude_pidfiles", return_value=[]), \
                    mock.patch.object(daemon.subprocess, "run",
                                      return_value=SimpleNamespace(stdout="")), \
                    mock.patch.object(daemon, "_codex_desktop_rollout_candidates",
                                      return_value=[]), \
                    mock.patch.object(daemon, "_session_db_connect",
                                      return_value=EmptyConnection()):
                self.assertEqual(daemon.api_active()["active"], [])
        finally:
            with daemon._cache_lock:
                daemon._ttl_cache.pop("active", None)
                if previous is not None:
                    daemon._ttl_cache["active"] = previous

    def test_active_sessions_sort_by_latest_activity_then_stable_tie_breakers(self):
        active = [
            {"tool": "qoder", "pid": 30, "last_active_at": 100},
            {"tool": "codex", "pid": 20, "last_active_at": 300},
            {"tool": "claude", "pid": 10, "last_active_at": 200},
            {"tool": "claude", "pid": 8, "last_active_at": 200},
        ]

        active.sort(key=daemon._active_sort_key)

        self.assertEqual([(item["tool"], item["pid"]) for item in active], [
            ("codex", 20), ("claude", 8), ("claude", 10), ("qoder", 30)])

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

    def test_codex_rollout_status_stays_busy_during_silent_tool_execution(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
                {"type": "response_item", "payload": {
                    "type": "custom_tool_call", "name": "long-running"}},
            ])
            os.utime(path, (100, 100))

            self.assertEqual(daemon._codex_rollout_work_status(path), "busy")

    def test_codex_rollout_status_finds_boundary_before_large_silent_payload(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
                {"type": "response_item", "payload": {
                    "type": "custom_tool_call_output", "output": "x" * 600_000}},
            ])

            self.assertEqual(daemon._codex_rollout_work_status(path), "busy")

    def test_codex_rollout_status_bounds_initial_scan_to_recent_tail(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
                {"type": "response_item", "payload": {
                    "type": "custom_tool_call_output", "output": "x" * 4096}},
            ])

            with mock.patch.object(daemon, "CODEX_ROLLOUT_TAIL_BYTES", 1024):
                self.assertIsNone(daemon._codex_rollout_work_status(path))

    def test_codex_rollout_status_drops_stale_state_when_large_append_is_skipped(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_complete"}},
            ])
            self.assertEqual(daemon._codex_rollout_work_status(path), "idle")
            with path.open("a") as stream:
                stream.write(json.dumps({
                    "type": "event_msg", "payload": {"type": "task_started"}
                }) + "\n")
                stream.write(json.dumps({
                    "type": "response_item", "payload": {
                        "type": "custom_tool_call_output", "output": "x" * 4096}
                }) + "\n")

            with mock.patch.object(daemon, "CODEX_ROLLOUT_TAIL_BYTES", 1024):
                self.assertIsNone(daemon._codex_rollout_work_status(path))
                with path.open("a") as stream:
                    stream.write(json.dumps({
                        "type": "event_msg", "payload": {"type": "task_complete"}
                    }) + "\n")
                self.assertEqual(daemon._codex_rollout_work_status(path), "idle")

    def test_codex_rollout_status_cache_processes_appended_completion(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
            ])
            self.assertEqual(daemon._codex_rollout_work_status(path), "busy")
            with path.open("a") as stream:
                stream.write(json.dumps({
                    "type": "event_msg", "payload": {"type": "task_complete"}
                }) + "\n")
            self.assertEqual(daemon._codex_rollout_work_status(path), "idle")

    def test_codex_rollout_status_reparses_long_partial_final_line(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            event = json.dumps({
                "type": "event_msg", "padding": "x" * 1000,
                "payload": {"type": "task_started"},
            }).encode()
            path.write_bytes(event[:-1])
            self.assertIsNone(daemon._codex_rollout_work_status(path))
            with path.open("ab") as stream:
                stream.write(event[-1:] + b"\n")
            self.assertEqual(daemon._codex_rollout_work_status(path), "busy")

    def test_busy_desktop_rollout_has_bounded_silent_grace(self):
        self.assertTrue(daemon._codex_desktop_rollout_is_active(
            mtime=100, work_status="busy", app_server_alive=True,
            now=100 + daemon.CODEX_DESKTOP_BUSY_MAX_SECS))
        self.assertFalse(daemon._codex_desktop_rollout_is_active(
            mtime=100, work_status="busy", app_server_alive=False, now=10_000))
        self.assertFalse(daemon._codex_desktop_rollout_is_active(
            mtime=100, work_status="busy", app_server_alive=True,
            now=101 + daemon.CODEX_DESKTOP_BUSY_MAX_SECS))
        self.assertFalse(daemon._codex_desktop_rollout_is_active(
            mtime=9_500, work_status="idle", app_server_alive=False, now=10_000))
        self.assertTrue(daemon._codex_desktop_rollout_is_active(
            mtime=9_500, work_status="idle", app_server_alive=True, now=10_000))

    def test_desktop_app_server_excludes_agentdeck_and_editor_helpers(self):
        self.assertTrue(daemon._is_codex_desktop_app_server(
            "/Applications/ChatGPT.app/Contents/Resources/codex "
            "-c features.code_mode_host=true app-server --analytics-default-enabled"))
        self.assertFalse(daemon._is_codex_desktop_app_server(
            "/opt/homebrew/bin/codex app-server --stdio"))
        self.assertFalse(daemon._is_codex_desktop_app_server(
            "/Users/test/.vscode/extensions/openai/bin/codex app-server"))

    def test_desktop_candidates_keep_known_busy_rollout_after_recent_cutoff(self):
        old = Path("/tmp/old.jsonl")
        recent = [Path(f"/tmp/recent-{index}.jsonl") for index in range(20)]
        with daemon._codex_work_status_lock:
            previous = dict(daemon._codex_work_status_cache)
            daemon._codex_work_status_cache.clear()
            daemon._codex_work_status_cache[str(old)] = {"status": "busy"}
        try:
            with mock.patch.object(daemon, "_recent_codex_activity_files",
                                   return_value=recent), \
                    mock.patch.object(Path, "is_file", return_value=True):
                candidates = daemon._codex_desktop_rollout_candidates()
            self.assertEqual(candidates[:-1], recent)
            self.assertEqual(candidates[-1], old)
        finally:
            with daemon._codex_work_status_lock:
                daemon._codex_work_status_cache.clear()
                daemon._codex_work_status_cache.update(previous)

    def test_codex_rollout_status_uses_latest_completion_boundary(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "rollout.jsonl"
            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
                {"type": "event_msg", "payload": {"type": "task_complete"}},
            ])
            self.assertEqual(daemon._codex_rollout_work_status(path), "idle")

            _jsonl(path, [
                {"type": "event_msg", "payload": {"type": "task_started"}},
                {"type": "event_msg", "payload": {"type": "turn_aborted"}},
            ])
            self.assertEqual(daemon._codex_rollout_work_status(path), "idle")

    def test_qoder_activity_uses_newest_open_main_transcript(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            project = base / "projects" / "sample"
            child_dir = project / "subagents"
            child_dir.mkdir(parents=True)
            older_id = "11111111-1111-1111-1111-111111111111"
            newer_id = "22222222-2222-2222-2222-222222222222"
            older = project / f"{older_id}.jsonl"
            newer = project / f"{newer_id}.jsonl"
            child = child_dir / "33333333-3333-3333-3333-333333333333.jsonl"
            _jsonl(older, [{"type": "system", "sessionId": older_id,
                            "cwd": "/work/older"}])
            _jsonl(newer, [{"type": "system", "sessionId": newer_id,
                            "cwd": "/work/newer"}])
            _jsonl(child, [{"type": "system", "cwd": "/work/child"}])
            os.utime(older, (100, 100))
            os.utime(newer, (200, 200))
            os.utime(child, (300, 300))
            lsof = SimpleNamespace(stdout=f"n{older}\nn{child}\nn{newer}\n")
            with mock.patch.object(daemon.subprocess, "run", return_value=lsof), \
                    mock.patch.object(daemon, "qoder_sources", return_value=[{
                        "path": base}]):
                info = daemon._pid_qoder_transcript_info(123)

            self.assertEqual(info, {
                "id": newer_id, "cwd": "/work/newer", "mtime": 200})

    def test_qoder_app_active_rows_require_live_host_and_expire(self):
        sid = "11111111-1111-1111-1111-111111111111"
        rows = [(sid, "/work/app", "app", 990.0)]
        active = daemon._qoder_app_active_entries(rows, now=1000, app_alive=True)
        self.assertEqual(len(active), 1)
        self.assertEqual(active[0]["status"], "busy")
        self.assertEqual(active[0]["source"], "qoder_app")
        self.assertEqual(active[0]["host"], "app")
        self.assertEqual(
            daemon._qoder_app_active_entries(rows, now=1000, app_alive=False), [])
        self.assertEqual(daemon._qoder_app_active_entries(
            rows, now=991 + daemon.QODER_APP_ACTIVE_MAX_SECS + 1,
            app_alive=True), [])

    def test_codex_desktop_orphan_busy_grace_is_at_most_thirty_minutes(self):
        self.assertLessEqual(daemon.CODEX_DESKTOP_BUSY_MAX_SECS, 30 * 60)


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
                        "windowDurationMins": 300,
                        "resetsAt": time.time() + 14400,
                    },
                    "secondary": {
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
                         ["seven_day", "five_hour_codex-bengalfox",
                          "seven_day_codex-bengalfox"])
        self.assertEqual(quota["windows"][1]["label"], "GPT-5.3-Codex-Spark")
        self.assertEqual(quota["windows"][2]["label"], "GPT-5.3-Codex-Spark")
        self.assertNotIn("10080m", quota["windows"][2]["label"])
        self.assertEqual(quota["credits"]["balance"], "0")

    def test_named_window_notification_includes_localized_period(self):
        labels = daemon.WINDOW_LABELS["zh-CN"]
        self.assertEqual(daemon._localized_window_label({
            "id": "five_hour_codex-bengalfox",
            "label": "GPT-5.3-Codex-Spark",
        }, "zh-CN", labels), "GPT-5.3-Codex-Spark · 5 小时额度")
        self.assertEqual(daemon._localized_window_label({
            "id": "seven_day_codex-bengalfox",
            "label": "GPT-5.3-Codex-Spark · 10080m",
        }, "zh-CN", labels), "GPT-5.3-Codex-Spark · 周额度")

    def test_web_quota_policy_matches_general_first_and_localizes_named_windows(self):
        node = shutil.which("node")
        if not node:
            self.skipTest("Node.js is required for the Web fallback behavior test")
        html = (Path(__file__).parents[1] / "static" / "index.html").read_text()
        i18n_start = html.index("const I18N =")
        i18n_end = html.index("const WEEKDAYS", i18n_start)
        production_i18n = html[i18n_start:i18n_end]
        start = html.index("const winLabel =")
        end = html.index("// 秒 →", start)
        policy = html[start:end]
        harness = production_i18n + r"""
let LOCALE = 'zh-CN';
const t = (key, values) => {
  let value = I18N[LOCALE]?.[key] ?? I18N.en?.[key] ?? key;
  for (const name in values || {}) value = value.split(`{${name}}`).join(values[name]);
  return value;
};
""" + policy + r"""
const windows = [
  {id: 'seven_day', label: '周限额'},
  {id: 'five_hour_codex-bengalfox', label: 'GPT-5.3-Codex-Spark'},
  {id: 'seven_day_codex-bengalfox', label: 'GPT-5.3-Codex-Spark · 10080m'},
];
if (primaryWindowIndex(windows) !== 0) throw new Error('general weekly must be primary');
if (primaryWindowIndex(windows.slice(1)) !== 0) throw new Error('shortest named window must be primary fallback');
for (const [locale, five, weekly] of [
  ['zh-CN', 'GPT-5.3-Codex-Spark · 5 小时额度', 'GPT-5.3-Codex-Spark · 周额度'],
  ['en', 'GPT-5.3-Codex-Spark · 5-hour quota', 'GPT-5.3-Codex-Spark · weekly quota'],
  ['ja', 'GPT-5.3-Codex-Spark · 5時間枠', 'GPT-5.3-Codex-Spark · 週間上限'],
]) {
  LOCALE = locale;
  if (winLabel(windows[1]) !== five) throw new Error(`${locale} five-hour label mismatch`);
  if (winLabel(windows[2]) !== weekly) throw new Error(`${locale} weekly label mismatch`);
  if (winLabel(windows[2]).includes('10080m')) throw new Error(`${locale} leaked raw minutes`);
}
"""
        completed = subprocess.run(
            [node, "-e", harness], capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_rollout_snapshot_preserves_named_limit_identity(self):
        quota = daemon._codex_quota_from_rollout_limits({
            "limit_id": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark",
            "primary": {
                "used_percent": 0,
                "window_minutes": 10080,
                "resets_at": time.time() + 86400,
            },
        }, "2026-08-07T14:17:42Z")

        self.assertEqual(quota["windows"], [{
            "id": "seven_day_codex-bengalfox",
            "label": "GPT-5.3-Codex-Spark",
            "used_percent": 0.0,
            "resets_at": quota["windows"][0]["resets_at"],
        }])

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

    def test_interrupted_app_server_client_cannot_start(self):
        client = daemon._CodexAppServerClient(Path("/tmp/codex-home"))
        client.interrupt()
        with mock.patch.object(daemon.subprocess, "Popen") as popen:
            with self.assertRaisesRegex(RuntimeError, "retired"):
                client.read_rate_limits()
        popen.assert_not_called()

    def test_interrupt_releases_a_real_blocked_app_server_read(self):
        client = daemon._CodexAppServerClient(Path("/tmp/codex-home"))
        proc = daemon.subprocess.Popen(
            ["/bin/cat"], stdin=daemon.subprocess.PIPE,
            stdout=daemon.subprocess.PIPE, stderr=daemon.subprocess.DEVNULL,
            bufsize=0)
        with client._process_lock:
            client._proc = proc
        entered = threading.Event()
        errors = []

        def blocked_read():
            with client._lock:
                entered.set()
                try:
                    client._read_message_locked(time.monotonic() + 12)
                except Exception as exc:
                    errors.append(exc)

        worker = threading.Thread(target=blocked_read)
        worker.start()
        self.assertTrue(entered.wait(timeout=1))
        client.interrupt()
        worker.join(timeout=2)
        try:
            self.assertFalse(worker.is_alive())
            self.assertIsNotNone(proc.poll())
            self.assertTrue(errors)
        finally:
            client.close()
            if proc.poll() is None:
                proc.kill()
                proc.wait(timeout=1)

    def test_manager_stop_interrupts_refresh_before_waiting_for_gate(self):
        manager = daemon.CodexQuotaManager()
        gate_held = threading.Event()
        release_gate = threading.Event()
        client = SimpleNamespace(
            interrupt=mock.Mock(side_effect=release_gate.set),
            retire=mock.Mock())
        manager._clients = {"default": client}

        def active_refresh():
            with manager._refresh_gate:
                gate_held.set()
                release_gate.wait(timeout=1)

        worker = threading.Thread(target=active_refresh)
        worker.start()
        self.assertTrue(gate_held.wait(timeout=1))
        manager.stop()
        worker.join(timeout=1)

        self.assertFalse(worker.is_alive())
        client.interrupt.assert_called_once_with()
        client.retire.assert_called_once_with()

    def test_manager_stop_interrupts_multiple_clients_in_parallel(self):
        manager = daemon.CodexQuotaManager()
        all_started = threading.Event()
        lock = threading.Lock()
        started = 0

        def interrupt():
            nonlocal started
            with lock:
                started += 1
                if started == 4:
                    all_started.set()
            all_started.wait(timeout=1.5)

        clients = [SimpleNamespace(
            interrupt=mock.Mock(side_effect=interrupt),
            retire=mock.Mock()) for _ in range(4)]
        manager._clients = {str(index): client
                            for index, client in enumerate(clients)}

        started_at = time.monotonic()
        manager.stop()
        elapsed = time.monotonic() - started_at

        self.assertTrue(all_started.is_set())
        self.assertLess(elapsed, 1.0)
        for client in clients:
            client.interrupt.assert_called_once_with()
            client.retire.assert_called_once_with()

    def test_app_server_path_includes_codex_launcher_directory(self):
        client = daemon._CodexAppServerClient(Path("/tmp/codex-home"))
        proc = SimpleNamespace(poll=lambda: None)
        with tempfile.TemporaryDirectory() as td:
            runtime = Path(td)
            node = runtime / "node"
            codex = runtime / "codex"
            node.write_text("#!/bin/sh\nexit 0\n")
            codex.write_text("#!/usr/bin/env node\n")
            node.chmod(0o755)
            codex.chmod(0o755)
            try:
                with mock.patch.dict(daemon.os.environ, {
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        }, clear=False), \
                        mock.patch.object(
                            daemon, "_codex_executable", return_value=str(codex)), \
                        mock.patch.object(daemon.subprocess, "Popen",
                                          return_value=proc) as popen, \
                        mock.patch.object(client, "_request_locked",
                                          return_value={}), \
                        mock.patch.object(client, "_send_locked"):
                    client._start_locked()

                env = popen.call_args.kwargs["env"]
                self.assertEqual(env["PATH"].split(os.pathsep)[0],
                                 os.path.realpath(td))
                self.assertIn("/usr/bin", env["PATH"].split(os.pathsep))
                self.assertEqual(env["CODEX_HOME"], "/tmp/codex-home")
            finally:
                client._proc = None

    def test_custom_codex_prefix_can_find_separate_homebrew_node(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            runtime = home / ".volta" / "bin"
            runtime.mkdir(parents=True)
            node = runtime / "node"
            node.write_text("#!/bin/sh\nexit 0\n")
            node.chmod(0o755)
            with mock.patch.dict(daemon.os.environ, {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    }, clear=False), \
                    mock.patch.object(daemon, "HOME", home), \
                    mock.patch.object(daemon.shutil, "which", return_value=None):
                env = daemon._codex_process_env("/tmp/npm-prefix/bin/codex")

            paths = env["PATH"].split(os.pathsep)
            self.assertEqual(paths[0], os.path.realpath(runtime))
            self.assertNotIn("/tmp/npm-prefix/bin", paths)

    def test_codex_child_env_rejects_world_writable_node_fallback(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            runtime = home / ".volta" / "bin"
            runtime.mkdir(parents=True)
            node = runtime / "node"
            node.write_text("#!/bin/sh\nexit 0\n")
            node.chmod(0o777)
            with mock.patch.dict(daemon.os.environ, {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    }, clear=False), \
                    mock.patch.object(daemon, "HOME", home), \
                    mock.patch.object(daemon.shutil, "which", return_value=None):
                env = daemon._codex_process_env("/tmp/npm-prefix/bin/codex")

            self.assertNotIn(str(runtime), env["PATH"].split(os.pathsep))

    def test_codex_child_env_resolves_sibling_node_across_process_boundary(self):
        with tempfile.TemporaryDirectory() as td:
            runtime = Path(td)
            node = runtime / "node"
            codex = runtime / "codex"
            node.write_text("#!/bin/sh\nprintf codex-runtime-ok\n")
            codex.write_text("#!/usr/bin/env node\n")
            node.chmod(0o755)
            codex.chmod(0o755)
            with mock.patch.dict(daemon.os.environ, {
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    }, clear=False):
                result = daemon.subprocess.run(
                    [str(codex)], env=daemon._codex_process_env(str(codex)),
                    capture_output=True, text=True, timeout=2)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "codex-runtime-ok")

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
        settings = {"show_claude": True, "show_codex": False,
                    "show_qoder": False, "menubar_claude": False,
                    "menubar_codex": False, "menubar_qoder": False}
        unavailable = [{"ok": False, "no_quota": True, "kind": "gateway"}]
        with mock.patch.object(
                daemon, "_claude_quota_accounts", return_value=unavailable):
            self.assertEqual(
                daemon._force_quota_refreshes(settings, ttl=600), unavailable)

    def test_normal_quota_refreshes_enforces_all_provider_budget(self):
        settings = {**daemon.DEFAULT_SETTINGS,
                    "show_claude": True, "show_codex": True, "show_qoder": True}
        gate = threading.Event()
        def blocked(*_args, **_kwargs):
            gate.wait(1)
            return []
        started = time.monotonic()
        try:
            with mock.patch.object(daemon, "_claude_quota_accounts",
                                   side_effect=blocked), \
                    mock.patch.object(daemon, "_qoder_quota_accounts",
                                      side_effect=blocked), \
                    mock.patch.object(daemon, "_codex_quota_accounts",
                                      side_effect=blocked), \
                    mock.patch.object(daemon._codex_quota_manager,
                                      "ensure_fresh"):
                accounts = daemon._normal_quota_accounts(settings, 300, budget=0.05)
        finally:
            gate.set()
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertTrue(accounts["claude"][0].get("stale")
                        or not accounts["claude"][0].get("ok"))
        self.assertTrue(accounts["qoder"][0].get("stale")
                        or not accounts["qoder"][0].get("ok"))

    def test_api_quota_normal_request_honors_shared_provider_budget(self):
        settings = {**daemon.DEFAULT_SETTINGS,
                    "show_claude": True, "show_codex": True, "show_qoder": True}
        gate = threading.Event()
        def blocked(*_args, **_kwargs):
            gate.wait(1)
            return []
        started = time.monotonic()
        try:
            with mock.patch.object(daemon, "get_settings", return_value=settings), \
                    mock.patch.object(daemon, "QUOTA_NORMAL_BUDGET_SECS", 0.05), \
                    mock.patch.object(daemon, "_claude_quota_accounts",
                                      side_effect=blocked), \
                    mock.patch.object(daemon, "_qoder_quota_accounts",
                                      side_effect=blocked), \
                    mock.patch.object(daemon, "_codex_quota_accounts",
                                      side_effect=blocked), \
                    mock.patch.object(daemon._codex_quota_manager,
                                      "ensure_fresh"):
                result = daemon.api_quota()
        finally:
            gate.set()
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertEqual([agent["id"] for agent in result["agents"]],
                         ["claude", "codex", "qoder", "qoder_cn"])

    def test_quota_timeout_preserves_known_multi_account_shape(self):
        settings = {**daemon.DEFAULT_SETTINGS,
                    "claude_dirs": ["/tmp/claude-work"],
                    "qoder_dirs": ["/tmp/qoder-work"]}
        claude_sources = [
            {"id": "default", "label": "默认", "is_default": True},
            {"id": "work", "label": "work", "is_default": False},
        ]
        qoder_sources = [
            {"id": "default", "label": "默认", "is_default": True},
            {"id": "work", "label": "work", "is_default": False},
        ]
        with daemon._cache_lock:
            previous_claude = daemon._ttl_cache.get("sources_claude")
            previous_qoder = daemon._ttl_cache.get("sources_qoder")
            daemon._ttl_cache["sources_claude"] = (time.time() + 60, claude_sources)
            daemon._ttl_cache["sources_qoder"] = (time.time() + 60, qoder_sources)
        try:
            claude = daemon._quota_timeout_accounts("claude", settings)
            qoder = daemon._quota_timeout_accounts("qoder", settings)
        finally:
            with daemon._cache_lock:
                if previous_claude is None:
                    daemon._ttl_cache.pop("sources_claude", None)
                else:
                    daemon._ttl_cache["sources_claude"] = previous_claude
                if previous_qoder is None:
                    daemon._ttl_cache.pop("sources_qoder", None)
                else:
                    daemon._ttl_cache["sources_qoder"] = previous_qoder
        self.assertEqual([item["account_id"] for item in claude], ["default", "work"])
        self.assertEqual([item["account_id"] for item in qoder], ["default", "work"])

    def test_codex_timeout_never_uses_qoder_cache(self):
        source = {"id": "default", "label": "默认", "is_default": True,
                  "path": Path("/tmp/codex")}
        codex_value = {"ok": True, "source": "codex_app_server", "windows": []}
        qoder_value = {"ok": True, "source": "qoder_app", "windows": []}
        with daemon._cache_lock:
            previous_sources = daemon._ttl_cache.get("sources_codex")
            daemon._ttl_cache["sources_codex"] = (time.time() + 60, [source])
        with daemon._codex_quota_manager._lock:
            previous_states = daemon._codex_quota_manager._states
            daemon._codex_quota_manager._states = {
                os.path.realpath(source["path"]): {"quota": codex_value}}
        try:
            with mock.patch.object(
                    daemon, "_qoder_cached_snapshot",
                    return_value=qoder_value) as qoder_cache:
                account = daemon._quota_timeout_accounts(
                    "codex", daemon.DEFAULT_SETTINGS)[0]
        finally:
            with daemon._cache_lock:
                if previous_sources is None:
                    daemon._ttl_cache.pop("sources_codex", None)
                else:
                    daemon._ttl_cache["sources_codex"] = previous_sources
            with daemon._codex_quota_manager._lock:
                daemon._codex_quota_manager._states = previous_states
        self.assertEqual(account["source"], "codex_app_server")
        self.assertTrue(account["stale"])
        qoder_cache.assert_not_called()

    def test_codex_timeout_preserves_multi_account_shape(self):
        sources = [
            {"id": "default", "label": "默认", "is_default": True,
             "path": Path("/tmp/codex")},
            {"id": "work", "label": "work", "is_default": False,
             "path": Path("/tmp/codex-work")},
        ]
        with daemon._cache_lock:
            previous = daemon._ttl_cache.get("sources_codex")
            daemon._ttl_cache["sources_codex"] = (time.time() + 60, sources)
        try:
            accounts = daemon._quota_timeout_accounts(
                "codex", daemon.DEFAULT_SETTINGS)
        finally:
            with daemon._cache_lock:
                if previous is None:
                    daemon._ttl_cache.pop("sources_codex", None)
                else:
                    daemon._ttl_cache["sources_codex"] = previous
        self.assertEqual([item["account_id"] for item in accounts],
                         ["default", "work"])

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

    def test_turn_completion_after_quota_manager_stop_is_ignored(self):
        manager = daemon.CodexQuotaManager()
        manager.stop()

        with mock.patch.object(daemon, "_codex_rollout_for_thread") as locate:
            manager.note_turn_complete("stopped-thread", "/work/project")

        locate.assert_not_called()
        self.assertNotIn("stopped-thread", manager._pending_threads)

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

    def test_named_rollout_update_preserves_official_base_limit(self):
        manager = daemon.CodexQuotaManager()
        src = {
            "id": "default", "label": "默认", "path": Path("/tmp/codex-home-3"),
            "is_default": True, "session_only": False,
        }
        official = {"ok": True, "windows": [
            {"id": "seven_day", "label": "周限额",
             "used_percent": 89, "resets_at": time.time() + 86400},
            {"id": "seven_day_codex-bengalfox", "label": "Spark",
             "used_percent": 0, "resets_at": time.time() + 86400},
        ]}
        local = {"ok": True, "windows": [
            {"id": "seven_day_codex-bengalfox", "label": "Spark",
             "used_percent": 1, "resets_at": time.time() + 86400},
        ]}
        try:
            with mock.patch.object(daemon, "_remember_last_good"), \
                    mock.patch.object(daemon, "_bump_quota_revision"), \
                    mock.patch.object(daemon, "_check_alerts"):
                manager._apply(src, official, 100, official=True)
                manager._apply(src, local, 101, official=False)
            windows = manager.quota_for_source(src)["windows"]
            self.assertEqual([w["id"] for w in windows], [
                "seven_day_codex-bengalfox", "seven_day"])
            self.assertEqual(windows[0]["used_percent"], 1)
            self.assertEqual(windows[1]["used_percent"], 89)
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

    def test_sampler_never_confirms_codex_reset(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            payload = {
                "claude": {"ok": True, "windows": [{
                    "id": "seven_day", "used_percent": 10,
                }]},
                "codex": {"ok": True, "windows": [{
                    "id": "seven_day", "used_percent": 90,
                }]},
                "accounts": {"claude": [], "codex": []},
            }
            with mock.patch.multiple(
                    daemon, DATA_DIR=root, HISTORY_FILE=root / "history.jsonl"), \
                    mock.patch.object(daemon, "api_quota", return_value=payload), \
                    mock.patch.object(daemon, "_check_alerts") as alerts:
                daemon._sample_once()

        self.assertEqual(alerts.call_count, 2)
        self.assertEqual(alerts.call_args_list[0].args[0], "Claude")
        self.assertTrue(alerts.call_args_list[0].kwargs["allow_reset"])
        self.assertEqual(alerts.call_args_list[1].args[0], "Codex")
        self.assertFalse(alerts.call_args_list[1].kwargs["allow_reset"])

    def test_unofficial_snapshot_cannot_confirm_quota_reset(self):
        key = ("Codex", "default", "seven_day")
        settings = dict(daemon.DEFAULT_SETTINGS, notify_enabled=True,
                        notify_reset=True)
        previous = daemon._alert_state
        daemon._alert_state = {key: "warn"}
        window = [{"id": "seven_day", "label": "周限额", "used_percent": 0}]
        try:
            with mock.patch.object(daemon, "get_settings", return_value=settings), \
                    mock.patch.object(daemon, "_push_alert") as push, \
                    mock.patch.object(daemon, "_alert_state_save"):
                daemon._check_alerts("Codex", window, allow_reset=False)
                self.assertEqual(daemon._alert_state[key], "warn")
                push.assert_not_called()

                daemon._check_alerts("Codex", window, allow_reset=True)
                self.assertEqual(daemon._alert_state[key], "normal")
                self.assertEqual(push.call_args.args[2], "reset")
        finally:
            daemon._alert_state = previous

    def test_unofficial_snapshot_cannot_downgrade_critical_alert(self):
        key = ("Codex", "default", "seven_day")
        settings = dict(daemon.DEFAULT_SETTINGS, notify_enabled=True,
                        notify_warn=80, notify_crit=95)
        previous = daemon._alert_state
        daemon._alert_state = {key: "crit"}
        window = [{"id": "seven_day", "label": "周限额", "used_percent": 85}]
        try:
            with mock.patch.object(daemon, "get_settings", return_value=settings), \
                    mock.patch.object(daemon, "_push_alert") as push, \
                    mock.patch.object(daemon, "_alert_state_save"):
                daemon._check_alerts("Codex", window, allow_reset=False)
                self.assertEqual(daemon._alert_state[key], "crit")
                push.assert_not_called()

                daemon._check_alerts("Codex", window, allow_reset=True)
                self.assertEqual(daemon._alert_state[key], "warn")
                push.assert_not_called()
        finally:
            daemon._alert_state = previous


class PersistenceAndUpdateTests(unittest.TestCase):
    def setUp(self):
        with daemon._update_job_lock:
            self.previous_update_job = dict(daemon._update_job)
            daemon._update_job.clear()

    def tearDown(self):
        with daemon._cache_lock:
            daemon._ttl_cache.pop("update_manifest", None)
        with daemon._update_job_lock:
            daemon._update_job.clear()
            daemon._update_job.update(self.previous_update_job)

    def test_automatic_update_check_respects_disabled_setting(self):
        with mock.patch.object(daemon, "get_settings",
                               return_value={"update_check": False}), \
                mock.patch.object(daemon.urllib.request, "urlopen") as urlopen:
            result = daemon.api_update()

        self.assertTrue(result["disabled"])
        self.assertFalse(result["available"])
        urlopen.assert_not_called()

    def test_manual_update_check_bypasses_disabled_automatic_setting(self):
        manifest = io.BytesIO(json.dumps({
            "version": "2.8.3",
            "dmg": "https://github.com/Spacebody/AgentDeck/releases/download/v2.8.3/AgentDeck-2.8.3.dmg",
        }).encode())
        with mock.patch.object(daemon, "get_settings",
                               return_value={"update_check": False}), \
                mock.patch.object(daemon, "VERSION", "2.8.2"), \
                mock.patch.object(daemon, "UPDATE_MANIFEST_URLS",
                                  ("https://primary.invalid/version.json",)), \
                mock.patch.object(daemon.urllib.request, "urlopen",
                                  return_value=manifest):
            result = daemon.api_update(force=True)

        self.assertTrue(result["available"])
        self.assertEqual(result["latest"], "2.8.3")

    def test_update_manifest_falls_back_to_official_github_copy(self):
        fallback = io.BytesIO(json.dumps({
            "version": "2.8.3",
            "dmg": "https://github.com/Spacebody/AgentDeck/releases/download/v2.8.3/AgentDeck-2.8.3.dmg",
        }).encode())
        with mock.patch.object(daemon, "get_settings",
                               return_value={"update_check": True}), \
                mock.patch.object(daemon, "VERSION", "2.8.2"), \
                mock.patch.object(daemon, "UPDATE_MANIFEST_URLS",
                                  ("https://primary.invalid/version.json",
                                   "https://fallback.invalid/version.json")), \
                mock.patch.object(daemon.urllib.request, "urlopen",
                                  side_effect=[OSError("offline"), fallback]) as urlopen:
            result = daemon.api_update(force=True)

        self.assertTrue(result["available"])
        self.assertEqual(urlopen.call_count, 2)

    def test_update_download_retries_from_a_clean_file(self):
        class PartialFailure:
            headers = {"Content-Length": str(1024 * 1024)}

            def __init__(self):
                self.reads = 0

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _size):
                self.reads += 1
                if self.reads == 1:
                    return b"a" * (512 * 1024)
                raise OSError("connection reset")

        payload = b"x" * (1024 * 1024)
        response = io.BytesIO(payload)
        response.headers = {"Content-Length": str(len(payload))}
        with tempfile.TemporaryDirectory() as td:
            dmg = Path(td) / "update.dmg"
            with mock.patch.object(daemon.urllib.request, "urlopen",
                                   side_effect=[PartialFailure(), response]) as urlopen, \
                    mock.patch.object(daemon, "_set_update_job"), \
                    mock.patch.object(daemon, "_append_update_log"), \
                    mock.patch.object(daemon.time, "sleep"):
                daemon._download_update_dmg("https://example.invalid/update.dmg", dmg)

            self.assertEqual(dmg.read_bytes(), payload)
            self.assertEqual(urlopen.call_count, 2)

    def test_update_download_exhausts_retries_and_removes_final_partial(self):
        class PartialFailure:
            headers = {"Content-Length": str(1024 * 1024)}

            def __init__(self):
                self.reads = 0

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _size):
                self.reads += 1
                if self.reads == 1:
                    return b"a" * (512 * 1024)
                raise OSError("offline")

        with tempfile.TemporaryDirectory() as td:
            dmg = Path(td) / "update.dmg"
            failures = [PartialFailure() for _ in range(3)]
            with mock.patch.object(daemon.urllib.request, "urlopen",
                                   side_effect=failures) as urlopen, \
                    mock.patch.object(daemon, "_set_update_job"), \
                    mock.patch.object(daemon, "_append_update_log") as update_log, \
                    mock.patch.object(daemon.time, "sleep") as sleep:
                with self.assertRaisesRegex(OSError, "offline"):
                    daemon._download_update_dmg(
                        "https://example.invalid/update.dmg", dmg)

            self.assertEqual(urlopen.call_count, 3)
            self.assertEqual(update_log.call_count, 3)
            self.assertEqual(sleep.call_count, 2)
            self.assertFalse(dmg.exists())
            for attempt, call in enumerate(update_log.call_args_list, start=1):
                self.assertIn(f"download attempt {attempt} failed", call.args[0])

    def test_update_worker_cleans_temp_and_logs_exhausted_download(self):
        with tempfile.TemporaryDirectory() as parent:
            job_dir = Path(parent) / "job"
            job_dir.mkdir()
            with mock.patch.object(daemon.tempfile, "mkdtemp",
                                   return_value=str(job_dir)), \
                    mock.patch.object(daemon, "_download_update_dmg",
                                      side_effect=OSError("offline")), \
                    mock.patch.object(daemon, "_append_update_log") as update_log:
                daemon._update_install_worker(
                    "job-1",
                    "https://github.com/Spacebody/AgentDeck/releases/download/v2.8.3/AgentDeck-2.8.3.dmg",
                    "2.8.3")

            self.assertFalse(job_dir.exists())
            self.assertEqual(daemon._update_status()["stage"], "error")
            self.assertIn("offline", daemon._update_status()["error"])
            self.assertEqual(update_log.call_count, 2)

    def test_update_install_reserves_one_job_before_manifest_check(self):
        entered = threading.Event()
        release = threading.Event()
        first = {}

        def check_update(force=False):
            self.assertTrue(force)
            entered.set()
            self.assertTrue(release.wait(2))
            return {
                "latest": "2.8.3", "available": True,
                "dmg": "https://github.com/Spacebody/AgentDeck/releases/download/v2.8.3/AgentDeck-2.8.3.dmg",
            }

        def run_first():
            first["result"] = daemon.api_update_install({"version": "2.8.3"})

        with mock.patch.object(daemon, "api_update", side_effect=check_update), \
                mock.patch.object(daemon, "_update_install_worker") as worker:
            thread = threading.Thread(target=run_first)
            thread.start()
            self.assertTrue(entered.wait(2))
            second = daemon.api_update_install({"version": "2.8.3"})
            release.set()
            thread.join(2)
            self.assertFalse(thread.is_alive())
            for _ in range(20):
                if worker.call_count:
                    break
                time.sleep(0.01)

        self.assertEqual(second["id"], first["result"]["id"])
        self.assertEqual(second["stage"], "checking")
        worker.assert_called_once()

    def test_update_install_rejection_is_a_visible_error_status(self):
        with mock.patch.object(daemon, "api_update", return_value={
                "latest": "2.8.2", "available": False}):
            result = daemon.api_update_install({"version": "2.8.3"})

        self.assertFalse(result["ok"])
        self.assertFalse(result["running"])
        self.assertEqual(result["stage"], "error")
        self.assertEqual(result["error"], "no matching update available")

    def test_update_installer_keeps_backup_until_transaction_health_check(self):
        script = daemon._update_install_script(
            Path("/tmp/update"), Path("/tmp/update/stage"),
            Path("/tmp/update/mount"), "2.8.0", "a" * 32)

        launch = script.index("AGENTDECK_UPDATE_TRANSACTION=")
        ready = script.index("wait_for_replacement", launch)
        remove_old = script.index('/bin/rm -rf "$OLD"', ready)
        self.assertLess(launch, ready)
        self.assertLess(ready, remove_old)
        self.assertIn('data.get("update_transaction") == transaction', script)
        self.assertIn('data.get("owner_token", "")', script)
        self.assertIn('int(data.get("parent_pid", -1)) == int(app_pid)', script)
        self.assertIn('[ "$(process_count "$APP_PATTERN")" -eq 1 ]', script)
        self.assertIn('[ "$(process_count "$DAEMON_PATTERN")" -eq 1 ]', script)
        self.assertIn('kill_matches_tree "$APP_PATTERN" KILL', script)
        self.assertLess(script.index("snapshot_installed"), script.index("osascript"))
        self.assertIn('[ "$PID" = "$$" ] && return 0', script)
        self.assertIn('CURRENT=$(/bin/ps -p "$PID" -o lstart=', script)
        self.assertIn("signal_snapshot TERM", script)
        syntax = subprocess.run(
            ["/bin/sh", "-n"], input=script, text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

    def test_update_installer_rolls_back_before_reopening_previous_bundle(self):
        script = daemon._update_install_script(
            Path("/tmp/update"), Path("/tmp/update/stage"),
            Path("/tmp/update/mount"), "2.8.0", "b" * 32)
        restore = script[script.index("restore() {"):script.index("replacement_ready() {")]
        self.assertIn("stop_installed", restore)
        self.assertIn('/bin/mv "$OLD" "$APP"', restore)
        self.assertIn('/usr/bin/open -n "$APP"', restore)

    def test_update_installer_snapshot_excludes_detached_helper_subtree(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            script = daemon._update_install_script(
                root, root / "stage", root / "mount", "2.8.0", "c" * 32)
            function_prefix = script[:script.index("\ntrap restore ERR INT TERM\n")]
            sleeper = subprocess.Popen(["/bin/sleep", "30"])
            try:
                probe = function_prefix + '''
: > "$PROCESS_SNAPSHOT"
snapshot_tree "$OLD_DAEMON_PID"
! /usr/bin/grep -q "^$$|" "$PROCESS_SNAPSHOT"
/usr/bin/grep -q "^$SIBLING_PID|" "$PROCESS_SNAPSHOT"
'''
                env = dict(os.environ, OLD_DAEMON_PID=str(os.getpid()),
                           SIBLING_PID=str(sleeper.pid))
                result = subprocess.run(
                    ["/bin/sh"], input=probe, text=True, capture_output=True,
                    env=env, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
            finally:
                sleeper.terminate()
                sleeper.wait(timeout=2)

    def test_update_url_requires_matching_semver_tag_and_asset(self):
        self.assertTrue(daemon._safe_update_url(
            "https://github.com/Spacebody/AgentDeck/releases/download/v2.2.0/AgentDeck-2.2.0.dmg"))
        self.assertFalse(daemon._safe_update_url(
            "https://github.com/Spacebody/AgentDeck/releases/download/v2.2.0/AgentDeck-2.1.0.dmg"))
        self.assertFalse(daemon._safe_update_url(
            "https://github.com/Spacebody/AgentDeck/releases/download/v../../AgentDeck-../../x.dmg"))
        with self.assertRaisesRegex(ValueError, "update url"):
            daemon._normalize_update_manifest({
                "version": "2.8.3",
                "dmg": "https://example.invalid/AgentDeck-2.8.3.dmg",
            })

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


class QoderSupportTests(unittest.TestCase):
    def setUp(self):
        with daemon._cache_lock:
            self.cached_app_sessions = daemon._ttl_cache.pop(
                "qoder_app_session_entries", None)
            self.cached_qoder_sources = daemon._ttl_cache.pop(
                "sources_qoder", None)
            self.cached_qoder_cn_sources = daemon._ttl_cache.pop(
                "sources_qoder_cn", None)

    def tearDown(self):
        with daemon._cache_lock:
            daemon._ttl_cache.pop("qoder_app_session_entries", None)
            daemon._ttl_cache.pop("sources_qoder", None)
            daemon._ttl_cache.pop("sources_qoder_cn", None)
            if self.cached_app_sessions is not None:
                daemon._ttl_cache["qoder_app_session_entries"] = \
                    self.cached_app_sessions
            if self.cached_qoder_sources is not None:
                daemon._ttl_cache["sources_qoder"] = self.cached_qoder_sources
            if self.cached_qoder_cn_sources is not None:
                daemon._ttl_cache["sources_qoder_cn"] = \
                    self.cached_qoder_cn_sources

    def test_qoder_ipc_client_rejects_unlisted_method(self):
        with self.assertRaises(ValueError):
            daemon._qoder_app_request("auth/token")

    def test_qoder_ipc_client_decodes_lsp_frame_and_checks_response_id(self):
        class FakeSocket:
            def __init__(self, bad_id=False):
                self.bad_id = bad_id
                self.sent = b""
                self.response = b""

            def __enter__(self): return self
            def __exit__(self, *_): return False
            def settimeout(self, _): pass
            def connect(self, _): pass
            def getsockopt(self, *_):
                return (123).to_bytes(4, byteorder=sys.byteorder, signed=True)
            def sendall(self, data):
                self.sent = data
                request_id = json.loads(data.split(b"\r\n\r\n", 1)[1])["id"]
                body = json.dumps({"jsonrpc": "2.0",
                                   "id": "wrong" if self.bad_id else request_id,
                                   "result": {"totalUsagePercentage": 7}}).encode()
                self.response = (f"Content-Length: {len(body)}\r\n\r\n".encode()
                                 + body)
            def recv(self, size):
                chunk, self.response = self.response[:size], self.response[size:]
                return chunk

        good = FakeSocket()
        with mock.patch.object(daemon, "_qoder_app_ipc_endpoint",
                               return_value={"path": "/tmp/qoder.sock", "pid": 123,
                                             "dev": 1, "ino": 2}), \
                mock.patch.object(daemon.os, "lstat", return_value=SimpleNamespace(
                    st_dev=1, st_ino=2)), \
                mock.patch.object(daemon.socket, "socket", return_value=good):
            self.assertEqual(daemon._qoder_app_request("credit/usage"),
                             {"totalUsagePercentage": 7})
        self.assertIn(b'"method":"credit/usage"', good.sent)

        bad = FakeSocket(bad_id=True)
        with mock.patch.object(daemon, "_qoder_app_ipc_endpoint",
                               return_value={"path": "/tmp/qoder.sock", "pid": 123,
                                             "dev": 1, "ino": 2}), \
                mock.patch.object(daemon.os, "lstat", return_value=SimpleNamespace(
                    st_dev=1, st_ino=2)), \
                mock.patch.object(daemon.socket, "socket", return_value=bad), \
                self.assertRaises(daemon.QoderAppUnavailable):
            daemon._qoder_app_request("credit/usage")

    def test_qoder_ipc_client_rejects_wrong_peer_pid(self):
        class FakeSocket:
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def settimeout(self, _): pass
            def connect(self, _): pass
            def getsockopt(self, *_):
                return (999).to_bytes(4, byteorder=sys.byteorder, signed=True)

        endpoint = {"path": "/tmp/qoder.sock", "pid": 123,
                    "dev": 1, "ino": 2}
        with mock.patch.object(daemon, "_qoder_app_ipc_endpoint",
                               return_value=endpoint), \
                mock.patch.object(daemon.os, "lstat", return_value=SimpleNamespace(
                    st_dev=1, st_ino=2)), \
                mock.patch.object(daemon.socket, "socket", return_value=FakeSocket()), \
                self.assertRaises(daemon.QoderAppUnavailable):
            daemon._qoder_app_request("credit/usage")

    def test_qoder_ipc_read_uses_absolute_deadline(self):
        sock = mock.Mock()
        sock.recv.return_value = b"x"
        with mock.patch.object(daemon.time, "monotonic", side_effect=[0.0, 0.2, 1.1]), \
                self.assertRaisesRegex(daemon.QoderAppUnavailable, "timed out"):
            daemon._qoder_ipc_recv(sock, 3, deadline=1.0)

    def test_qoder_ipc_endpoint_rejects_socket_outside_private_cache(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td) / "cache"
            root.mkdir()
            outside = Path(td) / "outside.sock"
            (root / ".info.json").write_text(json.dumps({
                "pid": 123, "ipcServerPath": str(outside)}))
            (root / ".process-meta.json").write_text(json.dumps({
                "pid": 123,
                "binaryPath": "/Applications/Qoder.app/Contents/Resources/Qoder"}))
            socket_stat = SimpleNamespace(st_mode=daemon.stat.S_IFSOCK | 0o600,
                                          st_uid=os.getuid())
            with mock.patch.object(daemon, "QODER_APP_CACHE", root), \
                    mock.patch.object(daemon, "_pid_alive", return_value=True), \
                    mock.patch.object(daemon.os, "lstat", return_value=socket_stat), \
                    self.assertRaises(daemon.QoderAppUnavailable):
                daemon._qoder_app_ipc_endpoint()

    def test_qoder_signature_cache_identity_includes_service_binary(self):
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / "Qoder.app"
            seal = app / "Contents" / "_CodeSignature" / "CodeResources"
            binary = app / "Contents" / "Resources" / "Qoder"
            seal.parent.mkdir(parents=True)
            binary.parent.mkdir(parents=True)
            seal.write_bytes(b"seal")
            binary.write_bytes(b"one")
            checked = daemon.subprocess.CompletedProcess([], 0, stdout="", stderr="")
            daemon._qoder_bundle_validation.clear()
            with mock.patch.object(daemon.subprocess, "run",
                                   return_value=checked) as run:
                daemon._qoder_verify_app_bundle(str(app), str(binary))
                daemon._qoder_verify_app_bundle(str(app), str(binary))
                self.assertEqual(run.call_count, 2)
                binary.write_bytes(b"changed")
                daemon._qoder_verify_app_bundle(str(app), str(binary))
                self.assertEqual(run.call_count, 4)

    def test_qoder_signature_cache_identity_includes_resource_seal(self):
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / "Qoder.app"
            seal = app / "Contents" / "_CodeSignature" / "CodeResources"
            binary = app / "Contents" / "Resources" / "Qoder"
            seal.parent.mkdir(parents=True)
            binary.parent.mkdir(parents=True)
            seal.write_bytes(b"seal")
            binary.write_bytes(b"service")
            checked = daemon.subprocess.CompletedProcess([], 0, stdout="", stderr="")
            daemon._qoder_bundle_validation.clear()
            with mock.patch.object(daemon.subprocess, "run",
                                   return_value=checked) as run:
                daemon._qoder_verify_app_bundle(str(app), str(binary))
                daemon._qoder_verify_app_bundle(str(app), str(binary))
                self.assertEqual(run.call_count, 2)
                seal.write_bytes(b"changed")
                daemon._qoder_verify_app_bundle(str(app), str(binary))
                self.assertEqual(run.call_count, 4)

    def test_qoder_signature_cache_rejects_change_during_verification(self):
        with tempfile.TemporaryDirectory() as td:
            app = Path(td) / "Qoder.app"
            seal = app / "Contents" / "_CodeSignature" / "CodeResources"
            binary = app / "Contents" / "Resources" / "Qoder"
            seal.parent.mkdir(parents=True)
            binary.parent.mkdir(parents=True)
            seal.write_bytes(b"seal")
            binary.write_bytes(b"one")
            checked = daemon.subprocess.CompletedProcess([], 0, stdout="", stderr="")
            calls = 0
            def run(*_args, **_kwargs):
                nonlocal calls
                calls += 1
                if calls == 2:
                    binary.write_bytes(b"changed")
                return checked
            daemon._qoder_bundle_validation.clear()
            with mock.patch.object(daemon.subprocess, "run", side_effect=run), \
                    self.assertRaisesRegex(
                        daemon.QoderAppUnavailable, "changed during"):
                daemon._qoder_verify_app_bundle(str(app), str(binary))

    def test_qoder_sources_keeps_cli_process_environment_discovery(self):
        with mock.patch.object(daemon, "_discover", return_value=[]) as discover:
            daemon.qoder_sources()
        qoder_call = next(call for call in discover.call_args_list
                          if call.args[0] == "QODER_CONFIG_DIR")
        self.assertEqual(qoder_call.kwargs["proc_tools"], ("qodercli",))

    def test_qoder_cn_sources_use_independent_environment_and_runtime(self):
        with mock.patch.object(daemon, "_discover", return_value=[]) as discover:
            daemon.qoder_cn_sources()
        self.assertEqual(discover.call_args.args[:4], (
            "QODERCN_CONFIG_DIR", daemon.HOME / ".qoder-cn", ".qoder-cn-*",
            "qoder_cn_dirs"))
        self.assertEqual(discover.call_args.kwargs["proc_tools"],
                         ("qoderclicn", "qodercn", "qoder-cn"))

    def test_qoder_and_qoder_cn_sources_are_independent_agents(self):
        with tempfile.TemporaryDirectory() as td:
            home = Path(td)
            global_dir = home / ".qoder"
            cn_dir = home / ".qoder-cn"
            custom_cn = home / "team-cn"
            for path in (global_dir, cn_dir, custom_cn):
                path.mkdir()
                (path / "settings.json").write_text("{}")
            with mock.patch.object(daemon, "HOME", home), \
                    mock.patch.dict(daemon.os.environ, {
                        "QODER_CONFIG_DIR": "",
                        "QODERCN_CONFIG_DIR": str(custom_cn),
                    }), \
                    mock.patch.object(daemon, "get_settings",
                                      return_value={"qoder_dirs": [],
                                                    "qoder_cn_dirs": []}), \
                    mock.patch.object(daemon, "_shell_rc_dirs", return_value=[]), \
                    mock.patch.object(daemon, "_proc_env_dirs", return_value=[]):
                global_sources = daemon.qoder_sources()
                cn_sources = daemon.qoder_cn_sources()

        self.assertEqual([source["path"] for source in global_sources], [global_dir])
        self.assertTrue(global_sources[0]["is_default"])
        self.assertTrue(all(source["agent_id"] == "qoder"
                            for source in global_sources))
        self.assertEqual({source["path"] for source in cn_sources},
                         {cn_dir, custom_cn})
        self.assertTrue(all(source["agent_id"] == "qoder_cn"
                            for source in cn_sources))

    def test_qoder_cli_resolver_selects_matching_runtime(self):
        def which(name):
            return f"/opt/bin/{name}" if name in ("qodercli", "qoderclicn") else None

        with mock.patch.object(daemon.shutil, "which", side_effect=which):
            self.assertEqual(daemon._qoder_cli_path({"agent_id": "qoder"}),
                             "/opt/bin/qodercli")
            self.assertEqual(daemon._qoder_cli_path({"agent_id": "qoder_cn"}),
                             "/opt/bin/qoderclicn")

    def test_qoder_cn_cli_quota_uses_cn_binary_and_preserves_usage_contract(self):
        stream = json.dumps({"type": "control_response", "response": {
            "request_id": "usage", "response": {"usage": {
                "userType": "pro", "totalUsagePercentage": 25,
                "userQuota": {"total": 100, "used": 25, "remaining": 75,
                              "percentage": 25, "unit": "credits"},
            }}}})
        completed = daemon.subprocess.CompletedProcess([], 0, stdout=stream, stderr="")
        source = {"path": Path("/tmp/qoder-cn"), "agent_id": "qoder_cn"}
        with mock.patch.object(daemon, "_qoder_cli_path",
                               return_value="/opt/bin/qoderclicn") as resolver, \
                mock.patch.object(daemon.subprocess, "run",
                                  return_value=completed) as run:
            quota = daemon._qoder_cli_quota_for(source)

        resolver.assert_called_once_with(source)
        self.assertEqual(run.call_args.args[0][0], "/opt/bin/qoderclicn")
        self.assertEqual(run.call_args.args[0][2], "/tmp/qoder-cn")
        self.assertTrue(quota["ok"])
        self.assertEqual(quota["source"], "qoder_cn_cli")
        self.assertEqual([window["id"] for window in quota["windows"]],
                         ["total", "plan"])

    def test_qoder_cn_cli_auth_failure_is_explicit_and_sanitized(self):
        stream = json.dumps({"type": "assistant", "error": "authentication_failed",
                             "message": {"content": "private upstream detail"}})
        completed = daemon.subprocess.CompletedProcess([], 1, stdout=stream, stderr="secret")
        source = {"path": Path("/tmp/qoder-cn"), "agent_id": "qoder_cn"}
        with mock.patch.object(daemon, "_qoder_cli_path",
                               return_value="/opt/bin/qoderclicn"), \
                mock.patch.object(daemon.subprocess, "run", return_value=completed):
            quota = daemon._qoder_cli_quota_for(source)

        self.assertFalse(quota["ok"])
        self.assertTrue(quota["no_quota"])
        self.assertEqual(quota["source"], "qoder_cn_cli")
        self.assertEqual(quota["error"], "Qoder CN CLI account is not logged in")
        self.assertNotIn("private", json.dumps(quota))
        self.assertNotIn("secret", json.dumps(quota))

    def test_qoder_cn_cli_missing_runtime_has_actionable_error(self):
        source = {"path": Path("/tmp/qoder-cn"), "agent_id": "qoder_cn"}
        with mock.patch.object(daemon, "_qoder_cli_path", return_value=None):
            quota = daemon._qoder_cli_quota_for(source)

        self.assertFalse(quota["ok"])
        self.assertTrue(quota["no_quota"])
        self.assertEqual(quota["source"], "qoder_cn_cli")
        self.assertEqual(quota["error"], "Qoder CN CLI is not installed")

    def test_qoder_cn_cli_timeout_names_the_cn_runtime(self):
        source = {"path": Path("/tmp/qoder-cn"), "agent_id": "qoder_cn"}
        with mock.patch.object(daemon, "_qoder_cli_path",
                               return_value="/opt/bin/qoderclicn"), \
                mock.patch.object(daemon.subprocess, "run",
                                  side_effect=subprocess.TimeoutExpired("qoderclicn", 9)), \
                self.assertRaisesRegex(RuntimeError,
                                       "Qoder CN CLI usage request timed out"):
            daemon._qoder_cli_quota_for(source)

    def test_qoder_quota_cache_key_isolated_by_provider_and_config_path(self):
        old = {"id": "work", "path": Path("/old/work")}
        new = {"id": "work", "path": Path("/new/work")}

        self.assertNotEqual(daemon._qoder_quota_cache_key("qoder_cn", old),
                            daemon._qoder_quota_cache_key("qoder_cn", new))
        self.assertNotEqual(daemon._qoder_quota_cache_key("qoder", old),
                            daemon._qoder_quota_cache_key("qoder_cn", old))

    def test_qoder_cn_quota_refresh_honors_configured_interval(self):
        source = {"id": "default", "label": "Default", "is_default": True,
                  "path": Path("/tmp/qoder-cn"), "agent_id": "qoder_cn"}
        quota = {"ok": True, "source": "qoder_cn_cli", "windows": []}
        with mock.patch.object(daemon, "qoder_cn_sources", return_value=[source]), \
                mock.patch.object(daemon, "_qoder_resilient",
                                  return_value=quota) as resilient:
            account = daemon._qoder_quota_accounts(
                ttl=300, provider="qoder_cn")[0]

        self.assertEqual(resilient.call_args.args[0],
                         daemon._qoder_quota_cache_key("qoder_cn", source))
        self.assertEqual(resilient.call_args.args[1], 300)
        self.assertTrue(account["ok"])

    def test_qoder_cn_alert_uses_stable_agent_id(self):
        with mock.patch.object(daemon, "_events", []), \
                mock.patch.object(daemon, "_event_seq", 0), \
                mock.patch.object(daemon, "_events_persist"):
            daemon._push_alert("Qoder CN", "quota warning", "warn")

            self.assertEqual(daemon._events[-1]["tool"], "qoder_cn")

    def test_qoder_app_quota_uses_allowlisted_ipc_and_drops_identity(self):
        usage = {
            "userId": "must-not-leak", "userType": "pro",
            "totalUsagePercentage": 35,
            "userQuota": {"total": 100, "used": 35, "remaining": 65,
                          "percentage": 35, "unit": "credits"},
        }
        with mock.patch.object(daemon, "_qoder_app_request",
                               return_value=usage) as request:
            quota = daemon._qoder_app_quota()
        request.assert_called_once_with("credit/usage", timeout=8)
        self.assertEqual(quota["source"], "qoder_app")
        self.assertNotIn("must-not-leak", json.dumps(quota))

    def test_default_qoder_prefers_app_and_falls_back_to_cli(self):
        source = {"path": Path("/tmp/qoder-test"), "is_default": True}
        app_quota = {"ok": True, "source": "qoder_app", "windows": []}
        with mock.patch.object(daemon, "_qoder_app_quota", return_value=app_quota), \
                mock.patch.object(daemon, "_qoder_cli_quota_for") as cli:
            self.assertEqual(daemon._qoder_quota_for(source), app_quota)
            cli.assert_not_called()
        cli_quota = {"ok": True, "source": "qoder_cli", "windows": []}
        with mock.patch.object(daemon, "_qoder_app_quota",
                               side_effect=daemon.QoderAppUnavailable("offline")), \
                mock.patch.object(daemon, "_qoder_cli_quota_for",
                                  return_value=cli_quota):
            self.assertEqual(daemon._qoder_quota_for(source), cli_quota)

    def test_qoder_cache_only_prefers_cli_success_over_app_failure(self):
        source = {"id": "default", "label": "Default", "is_default": True,
                  "path": Path("/tmp/qoder-test")}
        snapshots = {
            "qoder_app_quota": {"ok": False, "error": "app unavailable"},
            daemon._qoder_quota_cache_key("qoder", source): {
                "ok": True, "source": "qoder_cli", "windows": []},
        }
        with mock.patch.object(daemon, "qoder_sources", return_value=[source]), \
                mock.patch.object(daemon, "_qoder_cached_snapshot",
                                  side_effect=lambda key: snapshots.get(key)):
            account = daemon._qoder_quota_accounts(cache_only=True)[0]
        self.assertTrue(account["ok"])
        self.assertEqual(account["source"], "qoder_cli")

    def test_qoder_normal_refresh_stays_within_client_budget(self):
        source = {"id": "default", "label": "Default", "is_default": True,
                  "path": Path("/tmp/qoder-test")}
        calls = []
        app_failure = {"ok": False, "error": "app timed out"}
        cli_success = {"ok": True, "source": "qoder_cli", "windows": []}
        def resilient(key, _ttl, fn, deadline):
            result = fn(max(0.1, deadline - daemon.time.monotonic()))
            calls.append((key, result))
            return result
        with mock.patch.object(daemon, "qoder_sources", return_value=[source]), \
                mock.patch.object(daemon, "_qoder_resilient", side_effect=resilient), \
                mock.patch.object(daemon, "_qoder_app_quota",
                                  side_effect=lambda timeout: (
                                      calls.append(("app_timeout", timeout)) or app_failure)), \
                mock.patch.object(daemon, "_qoder_cli_quota_for",
                                  side_effect=lambda _src, timeout: (
                                      calls.append(("cli_timeout", timeout)) or cli_success)):
            account = daemon._qoder_quota_accounts(budget=18)[0]
        app_timeout = next(value for key, value in calls if key == "app_timeout")
        cli_timeout = next(value for key, value in calls if key == "cli_timeout")
        self.assertLessEqual(app_timeout, 7.2)
        self.assertLessEqual(cli_timeout, 18)
        self.assertEqual(account["source"], "qoder_cli")

    def test_qoder_app_session_metadata_never_persists_chat_records(self):
        sid = "00000000-0000-0000-0000-000000000123"
        metadata = daemon._qoder_app_session_metadata({
            "sessionId": sid, "title": "Implement App support",
            "project_uri": "file:///work/qoder", "updatedAt": 1_800_000_000_000,
            "chatRecords": [{"message": "private body"}],
            "userId": "private-user",
        }, "/work/sample.code-workspace")
        self.assertEqual(metadata["session_id"], sid)
        self.assertEqual(metadata["cwd"], "/work/qoder")
        self.assertNotIn("private body", json.dumps(metadata))
        self.assertNotIn("private-user", json.dumps(metadata))

    def test_qoder_app_session_metadata_filters_side_tasks(self):
        item = {"sessionId": "00000000-0000-0000-0000-000000000123",
                "title": "hidden", "sessionType": "side_task"}
        self.assertIsNone(daemon._qoder_app_session_metadata(item, "/work/test"))

    def test_qoder_app_session_scan_is_not_authoritative_on_protocol_error(self):
        with mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=["/work/qoder"]), \
                mock.patch.object(daemon, "_qoder_app_request",
                                  return_value=({"unexpected": True}, 128)):
            self.assertEqual(daemon._qoder_app_session_entries(), [])
        self.assertFalse(daemon._qoder_app_scan_authoritative)

    def test_qoder_app_empty_workspace_snapshot_is_authoritative(self):
        with mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=([], True)):
            self.assertEqual(daemon._qoder_app_session_entries(), [])
        self.assertTrue(daemon._qoder_app_scan_authoritative)

    def test_qoder_app_session_scan_is_short_cached(self):
        with mock.patch.object(daemon, "_qoder_app_session_entries_uncached",
                               return_value=[]) as scan:
            daemon._qoder_app_scan_authoritative = True
            daemon._qoder_app_session_entries()
            daemon._qoder_app_session_entries()
        scan.assert_called_once()

    def test_qoder_app_session_scan_is_not_authoritative_on_item_schema_drift(self):
        with mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=["/work/qoder"]), \
                mock.patch.object(daemon, "_qoder_app_request",
                                  return_value=([{"newSessionShape": True}], 128)):
            self.assertEqual(daemon._qoder_app_session_entries(), [])
        self.assertFalse(daemon._qoder_app_scan_authoritative)

    def test_qoder_app_session_scan_is_not_authoritative_when_truncated(self):
        item = {"sessionId": "00000000-0000-0000-0000-000000000123",
                "title": "kept"}
        with mock.patch.object(daemon, "_QODER_APP_MAX_SESSIONS_PER_WORKSPACE", 1), \
                mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=["/work/qoder"]), \
                mock.patch.object(daemon, "_qoder_app_request",
                                  return_value=([item, item], 256)):
            entries = daemon._qoder_app_session_entries()
        self.assertEqual(len(entries), 1)
        self.assertFalse(daemon._qoder_app_scan_authoritative)

    def test_qoder_app_workspace_discovery_keeps_moved_path(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            storage = root / "storage" / "one"
            storage.mkdir(parents=True)
            missing = root / "moved-project"
            (storage / "workspace.json").write_text(json.dumps({
                "folder": missing.as_uri()}))
            with mock.patch.object(daemon, "QODER_APP_WORKSPACES", root / "storage"):
                self.assertEqual(daemon._qoder_app_workspace_paths(),
                                 [os.path.realpath(missing)])

    def test_qoder_workspace_discovery_skips_symlink_and_oversized_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            storage = Path(td) / "storage"
            target = Path(td) / "target.json"
            target.write_text(json.dumps({"folder": Path(td).as_uri()}))
            linked = storage / "linked"
            linked.mkdir(parents=True)
            (linked / "workspace.json").symlink_to(target)
            large = storage / "large"
            large.mkdir()
            (large / "workspace.json").write_bytes(
                b"x" * (daemon._QODER_WORKSPACE_METADATA_MAX_BYTES + 1))
            with mock.patch.object(daemon, "QODER_APP_WORKSPACES", storage):
                self.assertEqual(daemon._qoder_app_workspace_paths(), [])

    def test_qoder_workspace_discovery_marks_corrupt_metadata_incomplete(self):
        with tempfile.TemporaryDirectory() as td:
            storage = Path(td) / "storage"
            broken = storage / "broken"
            broken.mkdir(parents=True)
            (broken / "workspace.json").write_text("not-json")
            with mock.patch.object(daemon, "QODER_APP_WORKSPACES", storage):
                self.assertEqual(
                    daemon._qoder_app_workspace_paths(include_status=True),
                    ([], False))

    def test_qoder_workspace_discovery_does_not_block_on_fifo(self):
        with tempfile.TemporaryDirectory() as td:
            storage = Path(td) / "storage"
            fifo_dir = storage / "fifo"
            fifo_dir.mkdir(parents=True)
            os.mkfifo(fifo_dir / "workspace.json")
            started = time.monotonic()
            with mock.patch.object(daemon, "QODER_APP_WORKSPACES", storage):
                self.assertEqual(daemon._qoder_app_workspace_paths(), [])
            self.assertLess(time.monotonic() - started, 0.5)

    def test_qoder_app_session_scan_total_limit_preserves_old_snapshot(self):
        first = {"sessionId": "00000000-0000-0000-0000-000000000123",
                 "title": "one"}
        second = {"sessionId": "00000000-0000-0000-0000-000000000124",
                  "title": "two"}
        response = ([first, second], 256)
        with mock.patch.object(daemon, "_QODER_APP_MAX_TOTAL_SESSIONS", 1), \
                mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=["/work/qoder"]), \
                mock.patch.object(daemon, "_qoder_app_request",
                                  return_value=response):
            daemon._qoder_app_session_entries()
        self.assertFalse(daemon._qoder_app_scan_authoritative)

    def test_qoder_app_scan_enforces_remaining_bytes_before_read(self):
        observed_limits = []
        item = {"sessionId": "00000000-0000-0000-0000-000000000123",
                "title": "one"}
        def request(*_args, **kwargs):
            observed_limits.append(kwargs["max_body"])
            return [item], 60
        with mock.patch.object(daemon, "_QODER_APP_MAX_SCAN_BYTES", 100), \
                mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=["/work/one", "/work/two"]), \
                mock.patch.object(daemon, "_qoder_app_request",
                                  side_effect=request):
            daemon._qoder_app_session_entries()
        self.assertEqual(observed_limits, [100, 40])

    def test_qoder_app_session_scan_has_one_global_deadline(self):
        observed_timeouts = []
        def blocked(*_args, **kwargs):
            observed_timeouts.append(kwargs["timeout"])
            time.sleep(kwargs["timeout"])
            raise daemon.QoderAppUnavailable("late")
        started = time.monotonic()
        with mock.patch.object(daemon, "_QODER_APP_SCAN_DEADLINE_SECS", 0.05), \
                mock.patch.object(daemon, "_qoder_app_available", return_value=True), \
                mock.patch.object(daemon, "_qoder_app_workspace_paths",
                                  return_value=[f"/work/{i}" for i in range(8)]), \
                mock.patch.object(daemon, "_qoder_app_request",
                                  side_effect=blocked):
            self.assertEqual(daemon._qoder_app_session_entries(), [])
        self.assertLess(time.monotonic() - started, 0.5)
        self.assertLessEqual(sum(observed_timeouts), 0.06)
        self.assertFalse(daemon._qoder_app_scan_authoritative)

    def test_qoder_app_resume_opens_app_without_creating_cli_command(self):
        with tempfile.TemporaryDirectory() as td:
            project = Path(td) / "qoder"
            project.mkdir()
            body = {"tool": "qoder",
                    "id": "00000000-0000-0000-0000-000000000123",
                    "source": "qoder_app", "cwd": str(project)}
            completed = daemon.subprocess.CompletedProcess([], 0, stdout="", stderr="")
            with mock.patch.object(daemon.subprocess, "run",
                                   return_value=completed) as run:
                result = daemon.api_resume(body)
        self.assertTrue(result["opened"])
        self.assertEqual(run.call_args.args[0],
                         ["open", "-a", "Qoder", os.path.realpath(project)])

    def test_qoder_app_focus_never_selects_matching_cli_process(self):
        body = {"tool": "qoder", "session":
                "00000000-0000-0000-0000-000000000123",
                "source": "qoder_app", "cwd": "/work/qoder"}
        completed = daemon.subprocess.CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(daemon, "_find_qoder_pid") as find_cli, \
                mock.patch.object(daemon.subprocess, "run",
                                  return_value=completed) as run:
            result = daemon.api_focus(body)
        self.assertTrue(result["ok"])
        find_cli.assert_not_called()
        self.assertEqual(run.call_args.args[0], ["open", "-a", "Qoder", "/work/qoder"])

    def test_qoder_app_resume_uses_saved_path_mapping(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            old = root / "old"
            new = root / "new"
            new.mkdir()
            mappings = root / "mappings.json"
            mappings.write_text(json.dumps({
                "version": 1, "mappings": {str(old): str(new)}}))
            body = {"tool": "qoder",
                    "id": "00000000-0000-0000-0000-000000000123",
                    "source": "qoder_app", "cwd": str(old)}
            completed = daemon.subprocess.CompletedProcess([], 0, stdout="", stderr="")
            with mock.patch.object(daemon, "PATH_MAPPINGS_FILE", mappings), \
                    mock.patch.object(daemon.subprocess, "run",
                                      return_value=completed) as run:
                result = daemon.api_resume(body)
        self.assertTrue(result["opened"])
        self.assertEqual(run.call_args.args[0],
                         ["open", "-a", "Qoder", os.path.realpath(new)])

    def test_qoder_app_resume_requests_replacement_for_missing_project(self):
        with tempfile.TemporaryDirectory() as td:
            missing = Path(td) / "moved"
            body = {"tool": "qoder",
                    "id": "00000000-0000-0000-0000-000000000123",
                    "source": "qoder_app", "cwd": str(missing)}
            with mock.patch.object(
                    daemon, "PATH_MAPPINGS_FILE", Path(td) / "mappings.json"), \
                    mock.patch.object(daemon.subprocess, "run") as run:
                result = daemon.api_resume(body)
        self.assertTrue(result["needs_path"])
        self.assertEqual(result["original_cwd"], str(missing))
        run.assert_not_called()

    def test_enabled_agent_without_account_has_explicit_flat_status_page(self):
        settings = {**daemon.DEFAULT_SETTINGS,
                    "show_claude": False, "show_codex": False, "show_qoder": True}
        with mock.patch.object(daemon, "get_settings", return_value=settings), \
                mock.patch.object(daemon, "_qoder_quota_accounts", return_value=[]), \
                mock.patch.object(daemon._codex_quota_manager, "ensure_fresh"):
            quota = daemon.api_quota(cache_only=True)

        qoder = next(agent for agent in quota["agents"] if agent["id"] == "qoder")
        self.assertEqual(len(qoder["accounts"]), 1)
        self.assertTrue(qoder["accounts"][0]["no_quota"])
        self.assertIn("not found", qoder["accounts"][0]["error"])

    def test_menubar_only_agent_still_receives_quota_accounts(self):
        settings = {**daemon.DEFAULT_SETTINGS,
                    "show_claude": False, "menubar_claude": False,
                    "show_codex": False, "menubar_codex": False,
                    "show_qoder": False, "menubar_qoder": True}
        account = {"account_id": "default", "account": "默认",
                   "is_default": True, "ok": True,
                   "windows": [{"id": "total", "used_percent": 42}]}
        with mock.patch.object(daemon, "get_settings", return_value=settings), \
                mock.patch.object(daemon, "_qoder_quota_accounts",
                                  return_value=[account]) as qoder_accounts:
            quota = daemon.api_quota(cache_only=True)

        self.assertEqual(quota["accounts"]["qoder"], [account])
        self.assertTrue(next(agent for agent in quota["agents"]
                             if agent["id"] == "qoder")["hidden"])
        qoder_accounts.assert_called_once()

    def test_qoder_cn_has_independent_agent_settings_and_accounts(self):
        settings = {**daemon.DEFAULT_SETTINGS,
                    "show_qoder": False, "menubar_qoder": False,
                    "show_qoder_cn": True, "menubar_qoder_cn": True}
        cn_account = {"account_id": "default", "account": "默认",
                      "is_default": True, "ok": True,
                      "source": "qoder_cn_cli", "windows": []}
        with mock.patch.object(daemon, "get_settings", return_value=settings), \
                mock.patch.object(daemon, "_qoder_cn_quota_accounts",
                                  return_value=[cn_account]) as cn_accounts:
            quota = daemon.api_quota(cache_only=True)

        qoder = next(agent for agent in quota["agents"] if agent["id"] == "qoder")
        qoder_cn = next(agent for agent in quota["agents"]
                        if agent["id"] == "qoder_cn")
        self.assertTrue(qoder["hidden"])
        self.assertFalse(qoder_cn["hidden"])
        self.assertEqual(qoder_cn["accounts"], [cn_account])
        self.assertEqual(quota["accounts"]["qoder_cn"], [cn_account])
        self.assertTrue(quota["menubar"]["qoder_cn"])
        cn_accounts.assert_called_once()

    def test_usage_info_maps_supported_buckets_without_identity_fields(self):
        quota = daemon._qoder_quota_from_usage({
            "userId": "must-not-leak",
            "userType": "pro",
            "totalUsagePercentage": 42.5,
            "expiresAt": 1_800_000_000_000,
            "userQuota": {"total": 1000, "used": 400, "remaining": 600,
                          "percentage": 40, "unit": "credits"},
            "orgResourcePackage": {"cap": 500, "used": 100, "remaining": 400,
                                   "percentage": 20, "available": True,
                                   "unit": "credits"},
        }, sampled_at="2026-08-12T00:00:00Z")

        self.assertTrue(quota["ok"])
        self.assertEqual([w["id"] for w in quota["windows"]],
                         ["total", "plan", "organization"])
        self.assertEqual(quota["windows"][0]["resets_at"], 1_800_000_000)
        self.assertEqual(quota["windows"][1]["total"], 1000)
        self.assertNotIn("userId", json.dumps(quota))

    def test_usage_info_omits_qoder_non_expiring_sentinel(self):
        quota = daemon._qoder_quota_from_usage({
            "userType": "pro",
            "totalUsagePercentage": 42.5,
            "expiresAt": 253_402_214_400_000,
            "userQuota": {"total": 1000, "used": 400, "remaining": 600,
                          "percentage": 40, "unit": "credits"},
        })

        self.assertTrue(quota["ok"])
        self.assertIsNone(quota["windows"][0]["resets_at"])
        self.assertIsNone(quota["windows"][1]["resets_at"])

    def test_qoder_expiry_accepts_epoch_units_and_rejects_far_future_seconds(self):
        self.assertEqual(daemon._qoder_expiry(1_800_000_000), 1_800_000_000)
        self.assertEqual(daemon._qoder_expiry(1_800_000_000_000), 1_800_000_000)
        self.assertIsNone(daemon._qoder_expiry(253_402_214_400))
        self.assertIsNone(daemon._qoder_expiry(253_402_214_399))

    def test_qoder_cli_parses_only_named_usage_control_response(self):
        stream = "\n".join([
            json.dumps({"type": "control_response", "response": {
                "request_id": "init", "response": {"email": "discarded@example.invalid"}}}),
            json.dumps({"type": "control_response", "response": {
                "request_id": "usage", "response": {"usage": {
                    "userId": "private", "userType": "free",
                    "totalUsagePercentage": 12,
                    "userQuota": {"total": 10, "used": 1.2, "remaining": 8.8,
                                  "percentage": 12, "unit": "credits"}}}}}),
        ])
        source = {"path": Path("/tmp/qoder-test")}
        completed = daemon.subprocess.CompletedProcess([], 0, stdout=stream, stderr="")
        with mock.patch.object(daemon, "_qoder_app_quota",
                               side_effect=daemon.QoderAppUnavailable("offline")), \
                mock.patch.object(daemon, "_qoder_cli_path", return_value="qodercli"), \
                mock.patch.object(daemon.subprocess, "run", return_value=completed) as run:
            quota = daemon._qoder_quota_for(source)

        self.assertTrue(quota["ok"])
        self.assertNotIn("private", json.dumps(quota))
        self.assertIn("--no-session-persistence", run.call_args.args[0])

    def test_qoder_usage_cache_deduplicates_repeated_assistant_messages(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "qoder.jsonl"
            event = {
                "timestamp": "2026-08-12T10:00:00Z", "type": "assistant",
                "requestId": "request-1", "message": {
                    "id": "message-1", "model": "qoder-model", "usage": {
                        "input_tokens": 10, "output_tokens": 2,
                        "cache_read_input_tokens": 3}}}
            _jsonl(path, [event, event])

            usage, changed = daemon._cached_qoder_file_usage(path, {})

            self.assertTrue(changed)
            self.assertEqual(usage["2026-08-12T10"]["qoder-model"],
                             [10, 2, 3, 0, 0])

    def test_qoder_session_parser_accepts_claude_compatible_jsonl(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "00000000-0000-0000-0000-000000000123.jsonl"
            _jsonl(path, [
                {"type": "system", "cwd": "/work/qoder", "gitBranch": "main"},
                {"type": "user", "sessionId": path.stem,
                 "message": {"content": "Implement the carousel"}},
            ])
            self.assertEqual(daemon._qoder_session_info(path), (
                path.stem, "/work/qoder", "Implement the carousel", "main"))

    def test_qoder_resume_command_uses_qodercli(self):
        command = daemon._resume_command(
            "qoder", "00000000-0000-0000-0000-000000000123", "", "/work/qoder")
        self.assertIn("qodercli --resume", command)
        self.assertTrue(command.startswith("cd "))


if __name__ == "__main__":
    unittest.main()
