import tempfile
import unittest
from contextlib import closing
from pathlib import Path
from unittest import mock

import agentdeckd as daemon


class PublicationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.entries = []
        root = Path(temp.name)
        for name, value in (("SESSION_INDEX_FILE", root / "index.db"),
                            ("PINS_FILE", root / "pins.json"),
                            ("_session_index_state", daemon._session_status()),
                            ("_session_source_files", lambda: self.entries)):
            patch = mock.patch.object(daemon, name, value)
            patch.start()
            self.addCleanup(patch.stop)

    def add(self, path, sid, stamp=1):
        self.entries.append(dict(path=path, account_id="default", account="Default",
                                 tool="codex", inode=1, size=1, mtime=stamp,
                                 preparsed=dict(session_id=sid, title=path)))

    def snapshot(self):
        with closing(daemon._session_db_connect()) as conn:
            conn.execute("BEGIN")
            return (daemon._session_revision(conn),
                    conn.execute("SELECT count(*) FROM session_index").fetchone()[0],
                    conn.execute("SELECT count(*) FROM session_file_state").fetchone()[0])

    def test_readers_and_retry_never_see_partial_batch(self):
        for i in range(60):
            self.add(str(i), str(i))
        upsert = daemon._session_file_state_upsert
        observations = []

        def fail(conn, entry, status, info):
            if entry["path"] == "55":
                observations.append(self.snapshot())
                raise RuntimeError("interrupted")
            upsert(conn, entry, status, info)

        with mock.patch.object(daemon, "_session_file_state_upsert", fail):
            self.assertIsNone(daemon._session_index_scan())
        self.assertEqual(observations, [(1, 50, 50)])
        self.assertEqual(self.snapshot(), observations[0])
        with mock.patch.object(daemon, "_session_file_state_upsert", wraps=upsert) as writes:
            self.assertTrue(daemon._session_index_scan())
        self.assertEqual(writes.call_count, 10)
        self.assertEqual(self.snapshot(), (2, 60, 60))

    def test_next_batch_parses_without_holding_writer(self):
        for i in range(51):
            self.add(str(i), str(i), i)
        del self.entries[0]["preparsed"]  # Oldest file is parsed after the first commit.
        observations = []

        def parse(tool, path):
            observations.append(self.snapshot())
            with closing(daemon._session_db_connect()) as writer:
                writer.execute("PRAGMA busy_timeout=0")
                writer.execute("BEGIN IMMEDIATE")
            acquired = daemon._session_index_write_lock.acquire(blocking=False)
            self.assertTrue(acquired)
            daemon._session_index_write_lock.release()
            return "indexed", {"session_id": path, "title": path}

        with mock.patch.object(daemon, "_session_file_info", parse):
            self.assertTrue(daemon._session_index_scan(), daemon._session_status()["error"])
        self.assertEqual(observations, [(1, 50, 50)])
        self.assertEqual(self.snapshot(), (2, 51, 51))

    def test_legacy_half_commit_reconciled_once_even_without_source_changes(self):
        self.add("path", "sid", 10)
        self.assertTrue(daemon._session_index_scan())
        with closing(daemon._session_db_connect()) as conn, conn:
            conn.execute("DELETE FROM session_meta WHERE key='batch_publication_v1'")
            conn.execute("UPDATE session_index SET mtime=1")
        with mock.patch.object(daemon, "_session_file_state_upsert") as upsert:
            self.assertTrue(daemon._session_index_scan())
            upsert.assert_not_called()
        with closing(daemon._session_db_connect()) as conn:
            self.assertEqual(conn.execute("SELECT mtime FROM session_index").fetchone()[0], 10)
        self.assertEqual(self.snapshot(), (2, 1, 1))
        with mock.patch.object(daemon, "_rebuild_session_rows") as rebuild:
            self.assertFalse(daemon._session_index_scan())
            rebuild.assert_not_called()

    def test_losing_copy_and_unrelated_pinned_row_are_not_rewritten(self):
        self.add("winner", "a", 10)
        self.add("loser", "a")
        self.add("unrelated", "pinned-id")
        self.assertTrue(daemon._session_index_scan())
        pin = daemon.api_pin({"session": {"tool": "codex", "account_id": "default",
                                          "id": "pinned-id"}, "pinned": True})
        self.assertTrue(pin["ok"])
        before = self.snapshot()
        with closing(daemon._session_db_connect()) as conn:
            for event in ("DELETE", "UPDATE"):
                conn.execute(f"""CREATE TRIGGER guard_{event} BEFORE {event}
                    ON session_index WHEN OLD.session_id='pinned-id'
                    BEGIN SELECT RAISE(ABORT, 'unrelated row written'); END""")
        self.entries[1]["mtime"] = 2
        self.assertTrue(daemon._session_index_scan())
        self.assertEqual(self.snapshot(), before)
        self.entries[0]["preparsed"]["session_id"] = "c"
        self.assertTrue(daemon._session_index_scan())
        self.assertEqual(self.snapshot(), (before[0] + 1, 3, 3))
        with closing(daemon._session_db_connect()) as conn:
            rows = conn.execute("SELECT session_id,path FROM session_index")
            self.assertEqual(dict(rows), {"a": "loser", "pinned-id": "unrelated", "c": "winner"})

    def test_idle_timeout_is_bounded_and_wake_resets_backoff(self):
        wake = mock.Mock()
        wake.wait.side_effect = [False] * 6 + [True, False, StopIteration]
        with mock.patch.object(daemon, "_session_index_wake", wake), \
                mock.patch.object(daemon, "_session_index_scan", return_value=False) as scan:
            with self.assertRaises(StopIteration):
                daemon._session_index_loop()
        self.assertEqual([c.args[0] for c in wake.wait.call_args_list],
                         [30, 60, 120, 240, 300, 300, 300, 30, 60])
        self.assertEqual(scan.call_count, 9)

    def test_legacy_work_pin_waits_for_completed_scan(self):
        sid = "work-only"
        legacy = {sid: {"tool": "codex", "id": sid}}
        daemon._save_pins(legacy)
        for i in range(50):
            self.add(str(i), f"default-{i}", 10)
        self.add("late", sid)
        self.entries[-1]["account_id"] = "work"
        original = daemon._session_file_state_upsert

        def interrupt(conn, entry, *args):
            if entry["path"] == "late":
                raise RuntimeError("interrupt")
            return original(conn, entry, *args)

        with mock.patch.object(daemon, "_session_file_state_upsert", interrupt):
            self.assertIsNone(daemon._session_index_scan())
        self.assertEqual(daemon._load_pins(), legacy)
        self.assertTrue(daemon.api_pin({"pinned": True, "session": {
            "tool": "codex", "id": "default-0"}})["ok"])
        self.assertIn(sid, daemon._load_pins())
        self.assertTrue(daemon._session_index_scan())
        self.assertEqual(set(daemon._load_pins()), {"codex|work|work-only", "codex|default|default-0"})
        with closing(daemon._session_db_connect()) as conn:
            self.assertEqual([tuple(r) for r in conn.execute(
                "SELECT account_id,pinned FROM session_index WHERE session_id=?", (sid,))],
                [("work", 1)])

    def test_reconcile_releases_writer_and_replays_only_uncommitted_page(self):
        for i in range(55):
            self.add(str(i), f"session-{i:02}")
        self.assertTrue(daemon._session_index_scan())
        with closing(daemon._session_db_connect()) as conn, conn:
            conn.execute("UPDATE session_index SET mtime=0")
            conn.execute("DELETE FROM session_meta WHERE key='batch_publication_v1'")
        publish = daemon._publish_session_batch
        rebuild = daemon._rebuild_session_rows
        pages = []

        def intercept(conn, **kwargs):
            page = kwargs.get("reconcile")
            if page:
                pages.append(page)
                if len(pages) == 2:
                    self.assertFalse(conn.in_transaction)
                    pin = daemon.api_pin({"pinned": True, "session": {
                        "tool": "codex", "id": "session-00"}})
                    self.assertTrue(pin["ok"])

                    def fail_after_writes(conn, keys):
                        rebuild(conn, keys)
                        raise RuntimeError("interrupted reconciliation")

                    with mock.patch.object(daemon, "_rebuild_session_rows", fail_after_writes):
                        return publish(conn, **kwargs)
            return publish(conn, **kwargs)

        with mock.patch.object(daemon, "_publish_session_batch", intercept):
            self.assertIsNone(daemon._session_index_scan())
            with closing(daemon._session_db_connect()) as conn:
                self.assertEqual(conn.execute("SELECT COUNT(*) FROM session_index WHERE mtime=0").fetchone()[0], 5)
                self.assertEqual(conn.execute("SELECT pinned FROM session_index WHERE session_id='session-00'").fetchone()[0], 1)
            self.assertTrue(daemon._session_index_scan())
        self.assertEqual([len(page) for page in pages], [50, 5, 5])
        self.assertEqual(pages[1], pages[2])
        with closing(daemon._session_db_connect()) as conn:
            self.assertFalse(conn.execute("SELECT 1 FROM session_index WHERE mtime=0").fetchone())

    def test_ui_reads_share_one_stale_wake_and_polls_never_wake(self):
        with mock.patch.object(daemon, "_ensure_session_index_started"), \
                mock.patch.object(daemon, "_request_session_index_scan") as wake, \
                mock.patch.object(daemon, "api_active", return_value={}), \
                mock.patch.object(daemon, "_load_path_mappings", return_value={}):
            daemon._session_state(indexing=False, indexed_at=0, next_ui_wake=0)
            daemon.api_sessions()
            daemon.api_projects({})
            wake.assert_not_called()
            daemon.api_projects({"interactive": ["1"]})
            daemon.api_sessions(interactive=True)
            wake.assert_called_once()
            wake.reset_mock()
            daemon._session_state(indexed_at=daemon.time.time(), next_ui_wake=0)
            daemon.api_sessions(interactive=True)
            daemon._session_state(indexing=True, indexed_at=0)
            daemon.api_projects({"interactive": ["1"]})
            wake.assert_not_called()

    def test_reconcile_handles_stale_paths_owned_by_another_page(self):
        self.add("one", "aaa")
        self.add("two", "zzz")
        self.assertTrue(daemon._session_index_scan())
        with closing(daemon._session_db_connect()) as conn, conn:
            conn.execute("UPDATE session_index SET path='temp' WHERE path='one'")
            conn.execute("UPDATE session_index SET path='one' WHERE path='two'")
            conn.execute("UPDATE session_index SET path='two' WHERE path='temp'")
            conn.execute("DELETE FROM session_meta WHERE key='batch_publication_v1'")
        with mock.patch.object(daemon, "_SESSION_INDEX_BATCH", 1):
            self.assertTrue(daemon._session_index_scan(), daemon._session_status()["error"])
        with closing(daemon._session_db_connect()) as conn:
            self.assertEqual(dict(conn.execute("SELECT session_id,path FROM session_index")),
                             {"aaa": "one", "zzz": "two"})
