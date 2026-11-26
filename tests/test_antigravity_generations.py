import json
from pathlib import Path
import shutil
import sqlite3
import tempfile
import unittest

import antigravity_generations as ag
import antigravity_usage


SID = "00000000-0000-0000-0000-000000000001"
TS = 1700000000


def var(n):
    buf = bytearray()
    while n >= 128:
        buf.append((n & 127) | 128)
        n >>= 7
    return bytes(buf) + bytes([n])


def field(n, v):
    return (var(n * 8) + var(v) if isinstance(v, int)
            else var(n * 8 + 2) + var(len(v)) + v)


def record(*counts, ts=None):
    data = field(4, b"".join(field(n, v) for n, v in counts))
    return data if ts is None else data + field(9, field(4, field(1, ts)))


class GenerationsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.home = Path(temp.name)

    def database(self, root="antigravity"):
        path = self.home / ".gemini" / root / "conversations" / (SID + ".db")
        path.parent.mkdir(parents=True)
        db = sqlite3.connect(path)
        self.addCleanup(db.close)
        db.executescript("CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY,data BLOB);"
                         "CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB,step_payload TEXT);")
        return db

    def sources(self):
        return {s["scope"]: s for s in ag.discover(home=self.home)["sources"]}

    def scan(self, source, rows=1):
        facts, cursor = [], None
        for _ in range(30):
            res = ag.read_batch(source, cursor, {"max_rows": rows, "max_bytes": 256})
            self.assertLessEqual(len(res["facts"]), rows)
            facts.extend(res["facts"])
            if res["done"]:
                return facts
            nxt = json.loads(json.dumps(res["next_cursor"]))
            self.assertNotEqual(nxt, cursor)
            cursor = nxt
        self.fail("cursor made no progress")

    def test_discovery_scopes_and_empty_database(self):
        self.assertEqual(ag.discover(home=self.home)["complete_scopes"], [])
        self.database()
        db = self.database("antigravity-cli")
        cli = self.sources()[ag.CLI]
        p = Path(cli["path"])
        p.with_name("unrelated.db").touch()
        p.with_name(SID[:-1] + "2.db").symlink_to(p)
        result = ag.discover(home=self.home)
        self.assertEqual(len(result["sources"]), 2)
        self.assertCountEqual(result["complete_scopes"], [ag.APP, ag.CLI])
        self.assertEqual(self.scan(cli), [])
        db.execute("DROP TABLE gen_metadata")
        with self.assertRaises(sqlite3.Error):
            ag.read_batch(cli)

    def test_fallback_paging_replay_and_corrupt_sibling(self):
        db = self.database()
        private = "private text not for analytics"
        valid = (record((2, 10), (3, 12), (5, 3), (9, 7), (10, 5))
                 + field(19, b"model-1") + field(99, private.encode())
                 + field(11, field(2, 1000000)) + field(12, field(1, 1)))
        with db:
            db.execute("INSERT INTO steps VALUES (17,?,?)", (field(1, field(1, TS)), private))
            db.execute("INSERT INTO gen_metadata VALUES (5,?)",
                       (field(1, b"\xff") + field(1, valid)
                        + field(1, record((2, 0), (3, 0), ts=TS+1)) + field(2, var(17)),))
        src = self.sources()[ag.APP]
        facts = self.scan(src)
        self.assertEqual(facts, self.scan(src, 256))
        self.assertEqual(len(facts), 2)
        first, second = facts
        self.assertTrue(first["event_key"].endswith(":5:1"))
        self.assertEqual((first["input_tokens"], first["output_tokens"], first["tokens_total"],
                          first["reasoning_output_tokens"], first["observed_at"], first["latency_ms"]),
                         (13, 12, 25, 7, TS, 1001))
        self.assertEqual((second["observed_at"], second["tokens_total"]), (TS+1, 0))
        self.assertEqual((first["generation_ms"], first["speed_output_tokens"]), (1000, 5))
        self.assertIsNone(second["generation_ms"])
        self.assertNotIn(private, json.dumps(facts))
        self.assertNotIn(str(self.home), json.dumps(facts))

    def test_stream_pairs_with_reply_not_total_or_first_token_wait(self):
        timing = field(12, field(2, 2000000))
        for counts, reply in [([(3, 12), (9, 8)], 4), ([(10, 5)], 5),
                              ([(9, 6), (10, 0)], 0), ([(3, 5)], None),
                              ([(3, 10), (9, 9), (10, 9)], None)]:
            with self.subTest(counts=counts):
                fact = ag._generation(record(*counts, ts=TS) + timing)
                self.assertEqual(fact["speed_output_tokens"], reply)
                self.assertEqual(fact["generation_ms"], None if reply is None else 2)
                self.assertFalse(fact.get("speed_includes_wait"))
                self.assertIsNone(fact["latency_ms"])

    def test_invalid_or_ambiguous_stream_does_not_discard_usage(self):
        good = field(12, field(1, 1))
        for timing in [b"", field(12, b""), field(12, field(1, 86400)),
                       field(12, field(2, 10**9)), field(12, b"\xff"), good + good,
                       field(12, field(1, 1) + field(1, 2)), field(12, field(3, 2))]:
            with self.subTest(timing=timing):
                fact = ag._generation(record((3, 9), (10, 9), ts=TS) + field(11, field(1, 2)) + timing)
                self.assertIsNone(fact["generation_ms"])
                self.assertEqual(fact["output_tokens"], 9)
                self.assertEqual(fact["ttft_ms"], 2000)

    def test_cli_live_wal_and_late_metadata(self):
        db = self.database("antigravity-cli")
        db.execute("PRAGMA journal_mode=WAL")
        with db:
            db.execute("INSERT INTO gen_metadata VALUES (0,?)",
                       (field(1, record((2, 2))) + field(2, var(3)),))
        src = self.sources()[ag.CLI]
        self.assertEqual(self.scan(src), [])
        with db:
            db.execute("INSERT INTO steps VALUES (3,?,NULL)", (field(1, field(1, TS)),))
        fact, = self.scan(src)
        self.assertEqual(fact["source_kind"], ag.CLI)
        self.assertIsNone(fact["tokens_total"])
        self.assertIsNone(fact["output_tokens"])
        self.assertEqual(fact["calls"], 1)
        with db:
            db.execute("UPDATE gen_metadata SET data=?", (field(1, record((2, 3), (3, 2), ts=TS)),))
        updated, = self.scan(src)
        self.assertEqual(updated["event_key"], fact["event_key"])
        self.assertEqual(updated["tokens_total"], 5)

    def test_distinct_lineage_and_rejected_unknown_or_oversize_usage(self):
        for root in ("antigravity", "antigravity-cli"):
            db = self.database(root)
            with db:
                db.execute("INSERT INTO gen_metadata VALUES (0,?)", (b"".join([
                    field(1, record((2, ag.MAX_COUNT+1), ts=TS)),
                    field(1, record((42, 100), ts=TS)),
                    field(1, record((2, 1), (3, 4), ts=TS)),
                ]),))
        sources = self.sources()
        app, = self.scan(sources[ag.APP])
        cli, = self.scan(sources[ag.CLI])
        self.assertNotEqual(app["event_key"], cli["event_key"])
        for fact in (app, cli):
            self.assertTrue(fact["event_key"].endswith(":0:2"))
            self.assertEqual(fact["tokens_total"], 5)

    def test_snapshot_anchors_before_first_page_and_survives_wal_commits(self):
        db = self.database()
        db.execute("PRAGMA journal_mode=WAL")
        def insert(idx):
            with db:
                db.execute("INSERT INTO gen_metadata VALUES (?,?)",
                           (idx, field(1, record((2, idx), (3, 1), ts=TS))))
        insert(1)
        insert(2)
        src = self.sources()[ag.APP]
        with ag.open_snapshot(src) as page:
            insert(3)
            a = page(None, {"max_rows": 1})
            insert(4)
            b = page(a["next_cursor"], {"max_rows": 16})
            self.assertTrue(b["done"])
            self.assertEqual([f["input_tokens"] for f in a["facts"] + b["facts"]], [1, 2])
        self.assertEqual([f["input_tokens"] for f in self.scan(src)], [1, 2, 3, 4])
        self.assertEqual(db.execute("PRAGMA wal_checkpoint(TRUNCATE)").fetchone()[0], 0)
        copy = self.home / (SID + ".db")
        shutil.copyfile(src["path"], copy)
        src = dict(src, path=str(copy))
        sidecar = Path(src["path"] + "-wal")
        self.assertFalse(sidecar.exists())
        self.assertEqual(len(self.scan(src)), 4)
        self.assertFalse(sidecar.exists())

    def test_hourly_sample_is_replacement_and_unattributed(self):
        root = self.home / "Library/Application Support/AgentDeck/antigravity-usage"
        def observe(n):
            antigravity_usage.record(dict(session_id=SID, context_window=dict(
                total_input_tokens=n, total_output_tokens=n)), directory=root, now=TS)
        observe(5)
        observe(6)
        src = self.sources()[ag.SAMPLE]
        before, = self.scan(src)
        observe(8)
        after, = self.scan(src)
        self.assertEqual(before["event_key"], after["event_key"])
        self.assertEqual((before["tokens_total"], after["tokens_total"]), (2, 6))
        self.assertEqual((after["kind"], after["basis"]), ("usage_delta", "sampled"))
        for key in ("session_id", "account_id", "cost_usd", "calls", "model"):
            self.assertIsNone(after[key])
        (root / "usage.sqlite3").chmod(0o644)
        with self.assertRaises(PermissionError):
            ag.read_batch(src)
