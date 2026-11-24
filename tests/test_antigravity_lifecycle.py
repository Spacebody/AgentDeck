import io
import json
import os
import runpy
import socket
import sqlite3
import tempfile
import threading
import time
import unittest
from collections import deque
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import agentdeckd as d


bridge = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/antigravity-hook.py"))
SID = "cafebabe-0000-4000-8000-000000000001"


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.stack = stack = ExitStack()
        self.addCleanup(stack.close)
        self.settings = {"notify_session_done": True, "notify_done_min_secs": 0}
        for name, value in dict(get_settings=lambda: self.settings, _ag_hook_active={},
                                _events=deque(), _event_seq=0, _event_keys=deque(),
                                _event_key_times={}, _event_key_set=set(),
                                _events_persist=lambda _: None,
                                _request_session_index_scan=lambda: None).items():
            stack.enter_context(patch.object(d, name, value))

    def msg(self, event, **overrides):
        return bridge["envelope"](event, dict(dict(conversationId=SID,
            workspacePaths=["/work/repo"], fullyIdle=True, terminationReason="model_stop",
            lastUserInput="private", transcriptPath="/private", executionNum=1), **overrides))

    def send(self, event, **overrides):
        return d.api_event(self.msg(event, **overrides), _private_hook=True)

    def test_two_rapid_generations_and_late_duplicate(self):
        for _ in range(2):
            self.send("PreInvocation")
            self.send("Stop")
        with patch.object(d.time, "time", return_value=time.time() + 86400):
            self.assertEqual(self.send("Stop")["skipped"], "no_open_execution")
        self.assertEqual(len(d._events), 2)
        self.assertNotEqual(d._events[0]["turn"], d._events[1]["turn"])

    def test_threshold_from_first_pre(self):
        self.settings["notify_done_min_secs"] = 4
        with patch.object(d.time, "monotonic", side_effect=[0, 3, 4, 8, 9]):
            self.send("PreInvocation")
            self.assertEqual(self.send("Stop")["skipped"], "short")
            self.send("PreInvocation")
            self.send("PreInvocation")
            self.send("Stop")
        self.assertEqual([e["duration"] for e in d._events], [5])

    def test_expired_generation_cannot_complete_or_lend_start_to_next_pre(self):
        self.settings["notify_done_min_secs"] = 4
        with patch.object(d.time, "monotonic", side_effect=[0, 600, 700, 1301, 1302]):
            self.send("PreInvocation")
            self.assertEqual(self.send("Stop")["skipped"], "no_open_execution")
            self.send("PreInvocation")
            self.send("PreInvocation")  # No intervening active query to perform cleanup.
            self.assertEqual(self.send("Stop")["skipped"], "short")
        self.assertFalse(d._events)

    def test_public_input_cannot_create_or_consume_generation(self):
        self.assertFalse(d.api_event(self.msg("PreInvocation"))["ok"])
        self.assertFalse(d._ag_hook_active)
        self.send("PreInvocation")
        self.assertFalse(d.api_event(self.msg("Stop"))["ok"])
        self.assertTrue(d._ag_hook_active)
        self.assertFalse(d._events)

    def test_negative_boundaries(self):
        for change in [dict(fullyIdle=False), dict(fullyIdle="true"), dict(error="private"),
                       dict(terminationReason="error"), dict(terminationReason="max_steps_exceeded"),
                       dict(conversationId="bad")]:
            self.send("PreInvocation")
            self.send("Stop", **change)
        self.assertIsNone(self.msg("PostInvocation"))
        self.assertIsNone(self.msg("Stop", hookEventName="PreInvocation"))
        self.assertFalse(d._events)
        self.settings["notify_session_done"] = False
        self.send("PreInvocation")
        self.send("Stop")
        self.assertFalse(d._ag_hook_active)
        self.assertFalse(d._events)

    def test_active_binds_indexed_account_and_expires_without_event(self):
        def db():
            c = sqlite3.connect(":memory:")
            c.row_factory = sqlite3.Row
            c.execute("CREATE TABLE session_index(tool,account_id,session_id,title,cwd,path,"
                      "project,branch,mtime,account,pinned,source_present)")
            for account in ("cli", "app"):
                c.execute("INSERT INTO session_index VALUES('antigravity',?,?,?,'/work/repo',"
                          "'unused','repo','',0,'',0,1)", (account, SID, account))
            return c
        for name, value in dict(cached=lambda key, ttl, fn: fn(), _iter_claude_pidfiles=lambda: [],
                                _codex_desktop_rollout_candidates=lambda: [], _session_db_connect=db).items():
            self.stack.enter_context(patch.object(d, name, value))
        self.stack.enter_context(patch.object(d.subprocess, "run", return_value=SimpleNamespace(stdout="")))
        clock = self.stack.enter_context(patch.object(d.time, "monotonic", return_value=10000))
        for folder in ("antigravity", "antigravity-cli"):
            self.send("PreInvocation", artifactDirectoryPath=f"~/.gemini/{folder}/brain/{SID}")
        rows = d.api_active()["active"]
        self.assertEqual({r["source"] for r in rows}, {"antigravity_app", "antigravity_cli"})
        for r in rows:
            self.assertNotIn("pid", r)
            self.assertEqual(r["source"], r["indexed_session"]["source"])
            self.assertEqual(r["indexed_row_key"], f"antigravity:{r['title']}:{SID}")
        clock.return_value += 601
        self.assertFalse(d.api_active()["active"])
        self.assertFalse(d._ag_hook_active)
        self.assertFalse(d._events)

    def socket_path(self):
        tmp = self.stack.enter_context(tempfile.TemporaryDirectory(dir="/tmp"))
        path = Path(tmp) / "ipc/events.sock"
        self.stack.enter_context(patch.dict(bridge["deliver"].__globals__, ipc_path=lambda: path))
        return path

    def test_private_socket_roundtrip(self):
        path = self.socket_path()
        stop, received = threading.Event(), threading.Event()
        messages = []
        def observe(msg):
            messages.append(msg)
            received.set()
        thread = threading.Thread(target=bridge["listen"], args=(observe, stop))
        thread.start()
        try:
            for _ in range(100):
                if path.exists():
                    break
                time.sleep(.01)
            self.assertTrue(path.is_socket())
            bridge["deliver"](self.msg("Stop"))
            self.assertTrue(received.wait(1))
            self.assertNotIn("private", json.dumps(messages))
        finally:
            stop.set()
            thread.join(2)

    def test_no_send_to_unverified_peer_or_unsafe_directory(self):
        path = self.socket_path()
        path.parent.mkdir(mode=0o700)
        conn = MagicMock()
        with patch.object(socket, "socket") as factory, patch.dict(
                bridge["deliver"].__globals__, peer_uid=lambda _: os.getuid() + 1):
            factory.return_value.__enter__.return_value = conn
            bridge["deliver"](self.msg("Stop"))
            factory.assert_called_once_with(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.sendall.assert_not_called()
            path.parent.chmod(0o755)
            bridge["deliver"](self.msg("Stop"))
            self.assertEqual(factory.call_count, 1)

    def test_offline_hook_fails_open_without_network_fallback(self):
        path = self.socket_path()
        path.parent.mkdir(mode=0o700)
        with patch.object(socket, "socket", wraps=socket.socket) as factory:
            for event, response in (("Stop", {"decision": "allow"}), ("PreInvocation", {})):
                raw = json.dumps({"conversationId": SID}).encode()
                out = io.StringIO()
                with patch("sys.stdin", SimpleNamespace(buffer=io.BytesIO(raw))), redirect_stdout(out):
                    bridge["main"](event)
                self.assertEqual(json.loads(out.getvalue()), response)
            self.assertEqual([c.args for c in factory.call_args_list],
                             [(socket.AF_UNIX, socket.SOCK_STREAM)] * 2)
