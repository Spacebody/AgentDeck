import csv
import io
import json
import os
import sqlite3
import tempfile
import threading
import time
import tracemalloc
import unittest
from contextlib import closing, contextmanager
from pathlib import Path
from unittest.mock import patch

import v4_analytics as v


def fact(key, tokens=10, **extra):
    return dict(dict(event_key=key, agent="claude", source_kind="transcript", kind="call",
                     basis="recorded", observed_at=100, model="model-"+key, tokens_total=tokens,
                     session_id="session", account_id="default", calls=1), **extra)


class Provider:
    def __init__(self, root):
        self.root, self.complete, self.reads = root, True, []

    def discover(self):
        return dict(sources=[dict(scope="test",source_id=p.name,path=str(p),
                                 mode="snapshot" if p.suffix==".db" else "append")
                            for p in self.root.iterdir() if p.suffix in (".db",".log")],
                    complete_scopes=["test"] if self.complete else [])

    def read_batch(self, src, cursor, budget):
        offset = (cursor or {}).get("offset",0)
        self.reads.append((src["source_id"],offset))
        if src["mode"] == "snapshot":
            with closing(sqlite3.connect("file:"+src["path"]+"?mode=ro",uri=True)) as db:
                row = db.execute("SELECT data FROM entries ORDER BY id LIMIT 1 OFFSET ?",(offset,)).fetchone()
            return dict(facts=[json.loads(row[0])] if row else [], next_cursor={"offset":offset+1}, done=not row)
        with open(src["path"],"rb") as stream:
            stream.seek(offset)
            line = stream.readline()
            return dict(facts=[json.loads(line)] if line else [], next_cursor={"offset":stream.tell()},done=not line)


class StoreTests(unittest.TestCase):
    params = dict(start=0,end=1000,timezone="UTC")

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.provider = Provider(self.root)
        self.store = v.AnalyticsStore(self.root/"analytics.sqlite",[self.provider])
        self.addCleanup(self.store.close)

    def write(self, name, *facts, mode="w"):
        with (self.root/name).open(mode) as stream:
            for f in facts:
                print(json.dumps(f),file=stream)

    def scan(self):
        with closing(self.store._writer()) as db:
            self.store._scan(db)

    def query(self, **kwargs):
        return self.store.query(dict(self.params,**kwargs))

    def total(self):
        return self.query()["summary"][0]["metrics"]["tokens_total"]

    def test_atomic_copy_deletion_and_non_authoritative_discovery(self):
        self.write("original.log",fact("a"),fact("b"))
        self.write("copy.log",fact("a"))
        self.scan()
        self.assertEqual(self.total(),20)
        self.provider.reads.clear()
        self.scan()
        self.assertFalse(self.provider.reads)
        (self.root/"original.log").unlink()
        self.provider.complete=False
        self.scan()
        self.assertEqual(self.total(),20)
        self.provider.complete=True
        self.scan()
        self.assertEqual(self.total(),10)

    def test_append_resume_and_truncate_regrow(self):
        self.write("a.log",fact("old"))
        self.scan()
        oldlen = (self.root/"a.log").stat().st_size
        self.provider.reads.clear()
        self.write("a.log",fact("new",4),mode="a")
        self.scan()
        self.assertEqual(self.provider.reads[0],("a.log",oldlen))
        self.assertEqual(self.total(),14)
        self.write("a.log",fact("other",31,project="p"*500))
        self.scan()
        self.assertEqual(self.total(),31)

    def test_wal_only_edit_delete_and_failed_generation(self):
        path=self.root/"events.db"
        with closing(sqlite3.connect(path)) as db:
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("CREATE TABLE entries(id INTEGER PRIMARY KEY,data TEXT)")
            db.executemany("INSERT INTO entries(data) VALUES(?)",[(json.dumps(fact(k)),) for k in "ab"])
            db.commit()
            self.scan()
            self.assertEqual(self.total(),20)
            main = path.stat().st_mtime_ns
            db.execute("DELETE FROM entries WHERE id=2")
            db.execute("UPDATE entries SET data=?",(json.dumps(fact("a",3)),))
            db.commit()
            self.assertEqual(path.stat().st_mtime_ns,main)
            read=self.provider.read_batch
            def fail(src,cur,budget):
                if cur:
                    raise OSError("transient")
                return read(src,cur,budget)
            with patch.object(self.provider,"read_batch",side_effect=fail):
                self.scan()
            self.assertEqual(self.total(),20)
            self.scan()
            self.assertEqual(self.total(),3)

    def test_null_basis_summary_not_page_scoped_csv_safety_and_stale_generation(self):
        self.write("facts.log",fact("a",5,cost_usd=.5,model="=FORMULA"),
                   fact("b",11),fact("s",99,basis="sampled",calls=None),
                   fact("summary",990,kind="turn_summary"),fact("unknown-time",24,observed_at=None))
        self.scan()
        p=dict(dimension="model",basis="recorded",limit=1)
        first=self.query(**p)
        self.assertEqual(first["summary"][0]["metrics"]["tokens_total"],16)
        self.assertEqual(first["series"][0]["day"],"1970-01-01")
        self.assertEqual(first["summary"][0]["quality"]["cost_usd"],"partial")
        self.assertIsNone(first["summary"][0]["metrics"]["cost_usd"])
        self.assertEqual(first["summary"][0]["known_subtotals"]["cost_usd"],.5)
        second=self.query(**p,cursor=first["next_cursor"])
        self.assertNotEqual(first["rows"][0]["key"],second["rows"][0]["key"])
        self.assertEqual(len(self.query()["summary"]),2)
        output=self.store.export_csv(dict(self.params,**p,generation=first["generation"]))
        rows=list(csv.DictReader(io.StringIO(output)))
        self.assertEqual(len(rows),2)
        self.assertIn("'=FORMULA",[r["model"] for r in rows])
        self.write("facts.log",fact("c"),mode="a")
        self.scan()
        with self.assertRaises(v.GenerationConflict):
            self.query(**p,cursor=first["next_cursor"])
        with self.assertRaises(v.GenerationConflict):
            self.store.export_csv(dict(self.params,generation=first["generation"]))

    def test_session_source_boundaries_and_no_overlap_total(self):
        self.write("facts.log",fact("d",agent="qoder",source_kind="qoder_desktop",kind="usage_delta"),
                   fact("c",agent="qoder",source_kind="qoder_cli",kind="usage_delta"))
        self.scan()
        self.assertIsNone(self.query()["summary"][0]["metrics"]["tokens_total"])
        self.assertEqual(len(self.query(dimension="session")["rows"]),2)
        self.assertEqual(self.query(source_kind="qoder_cli",account_id="default",
                                    session_id="session")["summary"][0]["metrics"]["tokens_total"],10)

    def test_cold_nonblocking_health_shutdown_and_newest_first(self):
        self.assertFalse(self.store.path.exists())
        with self.assertRaises(v.StoreNotReady):
            self.query()
        self.write("old.log",fact("a"))
        self.write("new.log",fact("b"))
        os.utime(self.root/"old.log",(123,123))
        entered,release=threading.Event(),threading.Event()
        read=self.provider.read_batch
        def slow(*args):
            entered.set()
            release.wait(2)
            return read(*args)
        with patch.object(self.provider,"read_batch",side_effect=slow):
            self.store.request_scan()
            try:
                self.assertTrue(entered.wait(2))
                start=time.monotonic()
                self.assertTrue(self.store.health()["scanning"])
                self.assertLess(time.monotonic()-start,.1)
            finally:
                release.set()
            limit=time.monotonic()+3
            while self.store.health()["scanning"] and time.monotonic()<limit:
                time.sleep(.005)
            self.assertEqual(self.total(),20)
            self.assertEqual(self.provider.reads[0][0],"new.log")

    def test_calendar_dst(self):
        p=v._parameters(dict(start=1710046800,end=1710129600,timezone="America/New_York"))
        self.assertEqual((p["end"]-p["start"])/3600,23)
        with self.assertRaises(ValueError):
            self.store.query(dict(period="forever"))

    def test_discovery_wake_never_starves_first_round(self):
        self.write("a.log",fact("a"))
        self.write("b.log",fact("b"))
        self.store._wake.set()
        self.scan()
        self.assertEqual(self.total(),20)
        self.assertEqual({s for s,pos in self.provider.reads if pos==0},{"a.log","b.log"})

    def test_pinned_wal_under_continuous_updates_releases_after_completion(self):
        path=self.root/"events.db"
        with closing(sqlite3.connect(path)) as writer:
            writer.execute("PRAGMA journal_mode=WAL")
            writer.execute("CREATE TABLE entries(n)")
            writer.executemany("INSERT INTO entries VALUES(?)",[(i,) for i in range(5)])
            writer.commit()
            closed=[]
            @contextmanager
            def pinned(src):
                with closing(sqlite3.connect(path)) as reader:
                    reader.execute("BEGIN")
                    reader.execute("SELECT n FROM entries LIMIT 1").fetchone()
                    def page(cur,budget):
                        offset=(cur or {}).get("offset",0)
                        row=reader.execute("SELECT n FROM entries ORDER BY rowid LIMIT 1 OFFSET ?",(offset,)).fetchone()
                        writer.execute("UPDATE entries SET n=n+1")
                        writer.commit()
                        return dict(facts=[fact(str(offset),row[0])] if row else [],
                                    next_cursor={"offset":offset+1},done=not row)
                    yield page
                closed.append(True)
            with patch.object(self.provider,"open_snapshot",pinned,create=True):
                self.scan()
            self.assertEqual(closed,[True])
            self.assertEqual(self.total(),10)
            self.assertEqual(self.store.health()["errors"],0)

    def test_csv_limit_counts_utf8_bytes_no_partial_export(self):
        self.write("unicode.log",fact("x",model="模型"*100))
        self.scan()
        args=dict(self.params,dimension="model")
        data=self.store.export_csv(args)
        with patch.object(v,"EXPORT_MAX_BYTES",len(data.encode())-1):
            with self.assertRaisesRegex(ValueError,"^export too large$"):
                self.store.export_csv(args)
        with patch.object(v,"EXPORT_MAX_BYTES",len(data.encode())):
            self.assertEqual(self.store.export_csv(args),data)

    def test_missing_selected_agent_partial_cost_and_pricing_not_applied_to_delta(self):
        self.write("priced.log",fact("p",model="known",input_basis="uncached",input_tokens=10,
                   output_tokens=2,cache_read_tokens=0,cache_write_tokens=0,cost_usd=0))
        self.scan()
        with patch("v4_pricing.api_equivalent_usd",return_value=.25) as price:
            item=self.query(agents="claude,antigravity")["summary"][0]
            self.assertIsNone(item["metrics"]["cost_usd"])
            self.assertEqual(item["known_subtotals"]["api_equivalent_usd"],.25)
            self.assertEqual(price.call_args.args[2]["input_tokens"],10)
            self.write("priced.log",fact("q",kind="usage_delta",input_tokens=10),mode="a")
            self.scan()
            item=self.query()["summary"][0]
            self.assertEqual(item["quality"]["api_equivalent_usd"],"partial")

    def test_bulk_removed_source_keeps_copy_without_python_key_list(self):
        self.write("survivor.log",fact("shared",3))
        self.scan()
        with closing(self.store._writer()) as db, db:
            key=json.dumps(["test","removed"],separators=(",",":"))
            db.execute("INSERT INTO sources VALUES(?,'test','1','1','[]',NULL,NULL,1)",(key,))
            body=json.dumps(fact("ignored"))
            db.executemany("INSERT INTO owners VALUES(?,'1',?,?,1)",
                           ((key,str(n)+"z"*500,body) for n in range(5000)))
            db.execute("INSERT INTO facts SELECT k,100,body FROM owners WHERE src=?",(key,))
            db.execute("INSERT INTO owners SELECT ?,'1',k,body,stamp FROM owners WHERE src<>?",(key,key))
        tracemalloc.start()
        try:
            self.scan()
            peak=tracemalloc.get_traced_memory()[1]
        finally:
            tracemalloc.stop()
        self.assertLess(peak,1024*1024)
        self.assertEqual(self.total(),3)

    def test_empty_snapshot_retracts_every_previous_fact(self):
        path=self.root/"events.db"
        with closing(sqlite3.connect(path)) as db:
            db.execute("CREATE TABLE entries(id,data)")
            db.execute("INSERT INTO entries VALUES(1,?)",(json.dumps(fact("a")),))
            db.commit()
            self.scan()
            self.assertEqual(self.total(),10)
            db.execute("DELETE FROM entries")
            db.commit()
            self.scan()
        self.assertEqual(self.query()["summary"],[])

    def test_parser_upgrade_replays_unchanged_source_without_touching_unrelated_data(self):
        self.write("a.log",fact("a",7))
        self.scan()
        old_generation=self.query()["generation"]
        with closing(sqlite3.connect(self.store.path)) as db, db:
            db.execute("CREATE TABLE unrelated(n)")
            db.execute("INSERT INTO unrelated VALUES(42)")
            db.execute("PRAGMA application_id=0")
            db.execute("PRAGMA user_version=0")
            db.execute("UPDATE facts SET body=json_set(body,'$.tokens_total',999)")
        with self.assertRaises(v.StoreNotReady):
            self.query()
        self.provider.reads.clear()
        self.scan()
        self.assertEqual(self.provider.reads[0],("a.log",0))
        self.assertEqual(self.total(),7)
        with self.assertRaises(v.GenerationConflict):
            self.query(generation=old_generation)
        with closing(sqlite3.connect(self.store.path)) as db:
            self.assertEqual(db.execute("SELECT n FROM unrelated").fetchone(),(42,))
            self.assertEqual(db.execute("PRAGMA user_version").fetchone(),(v.PARSER_REVISION,))
        self.provider.reads.clear()
        self.scan()
        self.assertFalse(self.provider.reads)
