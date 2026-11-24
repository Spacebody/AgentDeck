import json
import sqlite3
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

import qoder_usage_provider as q


class QoderCollectorTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.global_root = self.home / "intl"
        self.cn_root = self.home / "cn"
        self.logs = self.global_root / "projects"
        self.logs.mkdir(parents=True)
        self.provider = q.Provider(lambda: [dict(id="default", path=self.global_root)],
                                   lambda: [dict(id="default", path=self.cn_root)], self.home)

    def source(self, kind):
        return next(s for s in self.provider.discover()["sources"] if s["source_kind"] == kind)

    @staticmethod
    def row(usage=None, **changes):
        obj = dict(type="assistant", sessionId="session", timestamp="2025-02-02T09:00:00+08:00",
                   cwd="/alpha/build", message=dict(id="msg", model="actual", content="PRIVATE-CONTENT"))
        if usage is not None:
            obj["message"]["usage"] = usage
        obj.update(changes)
        return json.dumps(obj).encode() + b"\n"

    def test_discovery_inventory_and_distinct_lineage(self):
        self.assertEqual(self.provider.discover(), dict(sources=[], complete_scopes=["qoder_cli:default"]))
        cn_logs = self.cn_root / "projects"
        cn_logs.mkdir(parents=True)
        for root in [self.logs, cn_logs]:
            (root / "sample.jsonl").write_bytes(self.row())
        (self.logs / "linked.jsonl").symlink_to(cn_logs / "sample.jsonl")
        result = self.provider.discover()
        self.assertEqual(len(result["sources"]), 2)
        facts = [q.read_batch(s)["facts"][0] for s in result["sources"]]
        self.assertNotEqual(facts[0]["event_key"], facts[1]["event_key"])
        self.assertEqual({f["agent"] for f in facts}, {"qoder", "qoder_cn"})
        (self.logs / "sample.jsonl").unlink()
        self.assertIn("qoder_cli:default", self.provider.discover()["complete_scopes"])

    def test_append_partial_alias_fields_and_privacy(self):
        p = self.logs / "session.jsonl"
        first = self.row()
        second = self.row(dict(input_tokens=100, output_tokens=4, cache_read_input_tokens=20,
                               cache_creation=dict(ephemeral_5m_input_tokens=2, ephemeral_1h_input_tokens=1),
                               request_id="request", credits=0.5))
        p.write_bytes(first + second[:-1])
        s = self.source("qoder_cli")
        batch = q.read_batch(s)
        self.assertTrue(batch["done"])
        self.assertEqual(batch["next_cursor"]["offset"], len(first))
        observed, = batch["facts"]
        self.assertIsNone(observed["calls"])
        self.assertFalse(observed["call_observed"])
        self.assertIsNone(observed["tokens_total"])
        with p.open("ab") as f:
            f.write(b"\n")
        batch = q.read_batch(s, json.loads(json.dumps(batch["next_cursor"])))
        call, obs = batch["facts"]
        self.assertEqual(obs["event_key"], observed["event_key"])
        self.assertEqual(call["calls"], 1)
        self.assertTrue(obs["call_observed"])
        self.assertIsNone(call["input_tokens"])
        self.assertEqual([obs[k] for k in ("input_tokens", "output_tokens", "cache_read_tokens",
                                           "cache_write_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens")],
                         [100, 4, 20, 3, 2, 1])
        self.assertEqual(obs["project"], "/alpha/build")
        self.assertEqual(obs["observed_at"], 1738458000)
        self.assertEqual(obs["credits"], 0.5)
        self.assertIsNone(obs["tokens_total"])
        self.assertIsNone(obs["cost_usd"])
        self.assertNotIn("PRIVATE-CONTENT", json.dumps(batch))
        self.assertEqual(q.read_batch(s, batch["next_cursor"])["facts"], [])
        p.write_bytes(b"")
        with self.assertRaises(ValueError):
            q.read_batch(s, batch["next_cursor"])

    def test_missing_or_redacted_is_not_zero_and_projects_do_not_collide(self):
        p = self.logs / "session.jsonl"
        p.write_bytes(b'{"type":"runtime-config","model":"configured"}\n' +
                      self.row(dict(input_tokens=0, output_tokens=0, original_credits=1)) +
                      self.row(dict(output_tokens=10), cwd="/beta/build") +
                      self.row(dict(output_tokens=3), cwd="relative"))
        facts = q.read_batch(self.source("qoder_cli"))["facts"]
        self.assertEqual([f["project"] for f in facts], ["/alpha/build", "/beta/build", None])
        self.assertEqual(facts[0]["model"], "actual")
        self.assertEqual(facts[0]["configured_model"], "configured")
        self.assertEqual(facts[0]["credits"], 1)
        self.assertIsNone(facts[0]["input_tokens"])
        self.assertIsNone(facts[1]["tokens_total"])

    def test_cli_envelope_request_id_without_usage_and_precedence(self):
        p = self.logs / "sample.jsonl"
        p.write_bytes(self.row(requestId="actual") +
                      self.row(dict(request_id="other", output_tokens=7), requestId="actual") +
                      self.row(dict(request_id="actual"), requestId=""))
        facts = q.read_batch(self.source("qoder_cli"))["facts"]
        calls = [f for f in facts if f["kind"] == "call"]
        self.assertEqual(len(calls), 3)
        self.assertEqual(len({f["event_key"] for f in calls}), 1)
        self.assertTrue(all(f["call_observed"] for f in facts if f["kind"] == "usage_delta"))

    def test_pinned_generation_finishes_while_writer_commits_between_every_page(self):
        path = self.provider.desktop_db
        path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(path)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE chat_message(id,session_id,request_id,role,gmt_create,token_info,model_info)")
            def insert(i):
                writer.execute("INSERT INTO chat_message VALUES(?,?,?,'assistant',1700000000000,NULL,NULL)",
                               (str(i), str(i), str(i)))
            for i in range(30):
                insert(i)
            writer.commit()
            s = self.source("qoder_desktop")
            self.assertTrue(s["pinned_snapshot"])
            cursor, sessions = None, []
            with self.provider.open_snapshot(s) as read:
                for i in range(31):
                    writer.execute("DELETE FROM chat_message WHERE session_id=?", (str(i),))
                    insert(i + 30)
                    writer.commit()
                    page = read(cursor, {"max_rows":1})
                    sessions.extend(f["session_id"] for f in page["facts"] if f["kind"] == "call")
                    cursor = page["next_cursor"]
                    if page["done"]:
                        break
                self.assertTrue(page["done"])
                self.assertEqual(sessions, list(map(str, range(30))))
            with self.provider.open_snapshot(s) as read:
                with self.assertRaises(ValueError):
                    read(cursor, {})
                page = read(None, {"max_rows":1})
                self.assertEqual(page["facts"][0]["session_id"], "31")

    def test_db_wal_change_rejects_mixed_pages(self):
        db = self.provider.desktop_db
        db.parent.mkdir(parents=True)
        with closing(sqlite3.connect(db)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE chat_message(id,session_id,request_id,role,gmt_create,"
                           "token_info,model_info,content)")
            for i in range(2):
                writer.execute("INSERT INTO chat_message VALUES(?,?,?,?,?,?,?,?)",
                               (str(i), "session", "rid", "assistant", 1700000000000,
                                '{"prompt_tokens":99,"completion_tokens":8,"cached_tokens":10}',
                                '{"model_key":"actual"}', "PRIVATE-CONTENT"))
            writer.commit()
            s = self.source("qoder_desktop")
            page = q.read_batch(s, None, {"max_rows":1})
            self.assertFalse(page["done"])
            call, obs = page["facts"]
            self.assertEqual(call["calls"], 1)
            self.assertEqual(obs["tokens_total"], 107)
            self.assertTrue(obs["call_observed"])
            self.assertEqual(obs["cache_read_tokens"], 10)
            self.assertIsNone(obs["project"])
            self.assertEqual(obs["source_kind"], q.SESSION_SOURCE_KINDS["qoder_app"])
            self.assertNotIn("PRIVATE-CONTENT", json.dumps(page))
            next_page = q.read_batch(s, page["next_cursor"], {"max_rows":1})
            self.assertEqual(next_page["facts"][0]["event_key"], call["event_key"])
            writer.execute("DELETE FROM chat_message")
            writer.commit()
            with self.assertRaises(ValueError):
                q.read_batch(s, page["next_cursor"])
            self.assertEqual(q.read_batch(s)["facts"], [])
