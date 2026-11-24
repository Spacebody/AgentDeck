import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest.mock import patch

import agentdeckd as d


class AntigravityTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        home = Path(tmp.name)
        self.app = home / ".gemini/antigravity/conversation_summaries.db"
        self.cli = home / ".gemini/antigravity-cli/cache/last_conversations.json"
        self.cli.parent.mkdir(parents=True)
        self.app.parent.mkdir(parents=True)
        self.ids = [f"deadbeef-0000-4000-8000-{n:012d}" for n in range(6)]
        for name, value in dict(HOME=home, SESSION_INDEX_FILE=home/"index.sqlite",
                                PINS_FILE=home/"pins", SETTINGS_FILE=home/"settings",
                                _settings_cache=None, _antigravity_complete=set(),
                                _session_index_state=d._session_status(),
                                claude_sources=lambda: [], codex_sources=lambda: [],
                                qoder_sources=lambda: [], _qoder_app_session_entries=lambda: []).items():
            p = patch.object(d, name, value)
            p.start()
            self.addCleanup(p.stop)
        with closing(sqlite3.connect(self.app)) as conn, conn:
            conn.executescript("""
                CREATE TABLE conversation_summaries(conversation_id, title, workspace_uris,
                    last_modified_time, last_user_input_time, parent_conversation_id,
                    nesting_depth, preview, raw_summary);
                CREATE TABLE conversation_parents(conversation_id, parent_id);
            """)
            for i, sid in enumerate(self.ids[:5]):
                conn.execute("INSERT INTO conversation_summaries VALUES(?,?,?,?,?,?,?,?,?)",
                             (sid, "Workspace review", json.dumps(["file://remote/private",
                              "file:///tmp/my%20repo"]), "2024-01-02 09:00:00+08:00",
                              "", "parent" if i == 1 else "", int(i == 2),
                              "private sentinel", b"private sentinel"))
            conn.execute("INSERT INTO conversation_parents VALUES(?,?)", (self.ids[3], self.ids[0]))
        self.cli.write_text(json.dumps({"/tmp/cli": self.ids[5]}))

    def scan(self):
        self.assertIsNotNone(d._session_index_scan(), d._session_status()["error"])
        return d._query_session_index(tool="antigravity")["sessions"]

    def test_sources_query_cursor_and_privacy(self):
        original = self.app.read_bytes()
        rows = self.scan()
        self.assertEqual([r["id"] for r in rows], [self.ids[i] for i in (0, 4, 5)])
        self.assertEqual([(r["source"], r["mtime"]) for r in rows],
                         [("antigravity_app", 1704157200)] * 2 + [("antigravity_cli", 0)])
        self.assertEqual(rows[0]["cwd"], "/tmp/my repo")
        self.assertEqual(self.app.read_bytes(), original)
        self.assertEqual(d._query_session_index("private sentinel")["total"], 0)
        self.assertNotIn(b"private sentinel", d.SESSION_INDEX_FILE.read_bytes())
        args = dict(query="review", tool="antigravity,codex", project_cwds=["/tmp/my repo"], limit=1)
        page = d._query_session_index(**args)
        next_page = d._query_session_index(cursor=page["next_cursor"], **args)
        self.assertFalse(next_page["cursor_stale"])
        self.assertEqual([p["sessions"][0]["id"] for p in (page, next_page)], self.ids[::4])
        self.assertEqual(d._query_session_index(tool="codex")["total"], 0)
        self.assertNotIn("antigravity", d.TRANSCRIPT_TOOL_IDS)

    def test_independent_authoritative_deletion(self):
        self.scan()
        with closing(sqlite3.connect(self.app)) as writer:
            writer.execute("BEGIN EXCLUSIVE")
            self.cli.write_text(json.dumps({"/tmp/cli": None}))
            self.assertEqual(len(self.scan()), 3)
        self.app.rename(self.app.with_suffix(".away"))
        self.cli.write_text("{")
        self.assertEqual(len(self.scan()), 3)
        self.assertFalse(self.app.exists())
        self.cli.write_text("{}")
        self.assertEqual(len(self.scan()), 2)
        self.app.with_suffix(".away").rename(self.app)
        with closing(sqlite3.connect(self.app)) as conn, conn:
            conn.execute("DELETE FROM conversation_summaries")
        self.assertEqual(self.scan(), [])

    def test_cli_resume_requires_live_ownership(self):
        args = dict(tool="antigravity", source="antigravity_cli", account_id="cli", copy_only=True)
        self.assertIn("agy --conversation", d.api_resume(dict(args, id=self.ids[5]))["command"])
        missing = d.api_resume(dict(args, id=self.ids[0]))
        self.assertFalse(missing["ok"])
        self.assertFalse(missing.get("retryable", False))
        self.assertIn("not found", missing["error"])
        self.assertFalse(d.api_resume(dict(args, source="antigravity_app", id=self.ids[5]))["ok"])
        for data in (None, "{", json.dumps({"/tmp/cli": self.ids[5], "/tmp/other": None})):
            with self.subTest(data=data):
                if data is None:
                    self.cli.unlink()
                else:
                    self.cli.write_text(data)
                result = d.api_resume(dict(args, id=self.ids[5]))
                self.assertFalse(result["ok"])
                self.assertTrue(result["retryable"])
                self.assertNotIn("not found", result["error"])

    def test_remote_only_removed_but_workspace_free_session_survives_bad_timestamp(self):
        self.scan()
        with closing(sqlite3.connect(self.app)) as conn, conn:
            conn.execute("UPDATE conversation_summaries SET workspace_uris=? WHERE conversation_id=?",
                         (json.dumps(["file://remote/private", "ssh://host/project"]), self.ids[0]))
            conn.execute("UPDATE conversation_summaries SET workspace_uris='[]', last_modified_time=?,"
                         " last_user_input_time=? WHERE conversation_id=?",
                         (b"bad", "2024-01-02T01:00:00Z", self.ids[4]))
        rows = self.scan()
        self.assertEqual([r["id"] for r in rows], self.ids[4:])
        self.assertEqual((rows[0]["cwd"], rows[0]["mtime"]), ("", 1704157200))

    def test_settings_and_metadata_boundaries(self):
        with patch.object(d, "_settings_response", d.get_settings):
            self.assertFalse(d.api_settings_save({"show_antigravity": False})["settings"]["show_antigravity"])
        self.assertFalse(json.loads(d.SETTINGS_FILE.read_text())["show_antigravity"])
        for raw in ("file://elsewhere/tmp", "https://example.com/tmp", "file:relative",
                    "file:///tmp/%00", "file:///tmp?secret=query"):
            self.assertIsNone(d._antigravity_cwd(raw))
        for raw in (None, "", "[]", "null"):
            self.assertEqual(d._antigravity_cwd(raw), "")
        self.assertEqual(d._antigravity_time("2024-01-02 01:00:00"), 1704157200)
        self.assertEqual(d._antigravity_time("invalid"), 0)
