import json
import tempfile
import unittest
from contextlib import closing
from pathlib import Path

from usage_claude_codex import MAX_LINE, Provider
from v4_analytics import AnalyticsStore


TS = "2026-11-25T00:00:00Z"
EPOCH = 1795564800
BIG = {"max_bytes": 262144, "max_rows": 256}


def row(kind, payload):
    return dict(type=kind, timestamp=TS, payload=payload)


def event(kind, **p):
    return row("event_msg", dict(type=kind, **p))


def meta(sid="main", **p):
    return row("session_meta", dict(id=sid, cwd="/workspace/a", **p))


def usage(i, o, c=0, r=0):
    return dict(input_tokens=i, output_tokens=o, total_tokens=i+o,
                cached_input_tokens=c, reasoning_output_tokens=r)


def count(vector, last=None):
    return event("token_count", info=dict(total_token_usage=vector, last_token_usage=last))


def claude(mid="m", **overrides):
    counts = dict(input_tokens=2, output_tokens=3, cache_read_input_tokens=5,
                  cache_creation_input_tokens=7,
                  cache_creation=dict(ephemeral_5m_input_tokens=3, ephemeral_1h_input_tokens=4))
    counts.update(overrides)
    return dict(type="assistant", sessionId="main", timestamp=TS, cwd="/workspace/a",
                message=dict(model="model-a", id=mid, content="SECRET", usage=counts))


class AdapterTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)

    def source(self, agent, records, name=None):
        name = name or ("projects/p/main.jsonl" if agent == "claude" else
                        "sessions/2026/11/25/rollout-main.jsonl")
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(x) + "\n" for x in records))
        provider = Provider(agent, lambda: [{"id": "default", "path": self.root}])
        source = next(x for x in provider.discover()["sources"] if x["path"] == str(path))
        return provider, source

    def read(self, pair, cursor=None, budget=BIG):
        facts = []
        for _ in range(100):
            batch = pair[0].read_batch(pair[1], cursor, budget)
            cursor = json.loads(json.dumps(batch["next_cursor"]))
            facts.extend(batch["facts"])
            if batch["done"]:
                return facts, cursor
        self.fail("batch reader did not converge")

    def test_claude_revisions_cache_and_child_copy(self):
        user = dict(type="user", uuid="turn1", timestamp=TS, message=dict(content="SECRET"))
        pair = self.source("claude", [user, claude(), claude(output_tokens=6),
                                      dict(type="system", subtype="turn_duration", durationMs=3000)])
        facts, cursor = self.read(pair)
        self.assertNotIn("SECRET", json.dumps([facts, cursor]))
        a, b, summary = facts
        self.assertEqual(a["event_key"], b["event_key"])
        self.assertEqual((b["calls"], b["tokens_total"], b["input_uncached_tokens"]), (1, 20, 2))
        self.assertEqual((b["cache_write_tokens"], b["cache_write_1h_tokens"]), (7, 4))
        self.assertEqual((b["project"], b["model"], b["turn_id"]), ("/workspace/a", "model-a", "turn1"))
        self.assertEqual((summary["kind"], summary["calls"], summary["duration_secs"]),
                         ("turn_summary", None, 3))
        child, _ = self.read(self.source("claude", [claude()], "projects/p/main/subagents/agent-abc.jsonl"))
        self.assertEqual((child[0]["session_id"], child[0]["parent_session_id"]), ("abc", "main"))
        self.assertEqual(child[0]["event_key"], a["event_key"])

    def test_nullable_claude_legacy_counts_time_and_identity(self):
        one = claude(cache_creation=None)
        one["timestamp"] = "invalid"
        two = claude("other", cache_read_input_tokens=None)
        facts, _ = self.read(self.source("claude", [one, two, claude(None)]))
        self.assertEqual(len(facts), 2)
        self.assertEqual(facts[0]["cache_write_tokens"], 7)
        self.assertIsNone(facts[0]["cache_write_5m_tokens"])
        self.assertIsNone(facts[0]["observed_at"])
        self.assertIsNone(facts[1]["tokens_total"])
        self.assertIsNone(facts[1]["cost_usd"])

    def test_claude_out_of_order_snapshot_does_not_undo_revision(self):
        newer = claude(output_tokens=10)
        newer["timestamp"] = "2026-11-25T00:00:02Z"
        facts, _ = self.read(self.source("claude", [claude(), newer, claude()]),
                             budget={"max_rows": 1, "max_bytes": 1024})
        last = facts[-1]
        self.assertEqual(len({f["event_key"] for f in facts}), 1)
        self.assertEqual((last["tokens_total"], last["first_observed_at"], last["last_observed_at"]),
                         (24, EPOCH, EPOCH + 2))

    def test_durable_owner_after_revision_window_eviction_and_restart(self):
        def response(output, stamp):
            item = claude("target", output_tokens=output, cache_read_input_tokens=0,
                          cache_creation_input_tokens=0, cache_creation=None)
            item["timestamp"] = stamp
            return item

        strong = response(100, TS)
        stale = response(2, "2026-11-26T00:00:00Z")
        pair = self.source("claude", [strong] + [claude(str(i)) for i in range(40)])
        target_key = self.read(pair)[0][0]["event_key"]
        path = Path(pair[1]["path"])

        def scan():
            # Reopen SQLite and reconstruct the provider: no process-local revision history.
            provider = Provider("claude", lambda: [{"id": "default", "path": self.root}])
            with closing(AnalyticsStore(self.root / "analytics.db", [provider])) as store:
                with closing(store._writer()) as db:
                    store._scan(db)
                    self.assertEqual(store.health()["errors"], 0)
                    rows = list(db.execute("SELECT k,ts,body FROM facts"))
                    match, = [r for r in rows if json.loads(r["k"]) == ["claude", target_key]]
                    return len(rows), match["ts"], json.loads(match["body"])

        self.assertEqual(scan()[2]["tokens_total"], 102)
        with path.open("a") as stream:
            stream.write(json.dumps(stale) + "\n")
        n, stamp, fact = scan()
        self.assertEqual((n, fact["calls"], fact["tokens_total"], fact["output_tokens"],
                          stamp, fact["first_observed_at"], fact["last_observed_at"]),
                         (41, 1, 102, 100, EPOCH, EPOCH, EPOCH + 86400))
        # Replacing the source is not an append; the new generation may legitimately shrink.
        path.write_text(json.dumps(stale) + "\n")
        n, stamp, fact = scan()
        self.assertEqual((n, stamp, fact["tokens_total"]), (1, EPOCH + 86400, 4))

    def test_codex_fork_replay_and_repeated_cumulative(self):
        records = [meta("child", source={"subagent": {"thread_spawn": {"parent_thread_id": "parent"}}}),
                   meta("parent"), event("task_started", started_at=0), count(usage(100, 50)),
                   event("task_started", started_at=EPOCH, turn_id="t"),
                   row("turn_context", dict(model="model-b", turn_id="t", cwd="/workspace/b")),
                   count(usage(120, 60, 10, 3)), count(usage(120, 60, 10, 3)),
                   event("token_usage_record", turn_id="t", turn_token_usage=usage(20, 10, 10, 3)),
                   event("task_complete", turn_id="t", duration_ms=1500)]
        pair = self.source("codex", records)
        facts, _ = self.read(pair)
        self.assertEqual(facts, self.read(pair, budget={"max_bytes": 1024, "max_rows": 1})[0])
        d, summary = facts
        self.assertEqual((d["kind"], d["session_id"], d["parent_session_id"], d["calls"]),
                         ("usage_delta", "child", "parent", None))
        self.assertEqual((d["input_tokens"], d["input_uncached_tokens"], d["reasoning_output_tokens"],
                          d["tokens_total"], d["observed_at"]), (20, 10, 3, 30, EPOCH))
        self.assertEqual((d["model"], d["project"]), ("model-b", "/workspace/b"))
        self.assertEqual((summary["kind"], summary["tokens_total"], summary["duration_secs"]),
                         ("turn_summary", 30, 1.5))

    def test_unknown_baseline_reset_and_ambiguous_context(self):
        facts, _ = self.read(self.source("codex", [meta(), row("turn_context", {"model": "a"}),
            count(usage(100, 50)), count(usage(110, 60)), count(usage(100, 50)),
            row("turn_context", {"model": "b"}), count(usage(110, 60))]))
        self.assertEqual([x["tokens_total"] for x in facts], [20, 20])
        self.assertNotEqual(facts[0]["event_key"], facts[1]["event_key"])
        self.assertEqual(facts[0]["model"], "a")
        self.assertIsNone(facts[1]["model"])

    def test_gap_and_partial_line_restart(self):
        pair = self.source("codex", [meta(), count(usage(10, 3), usage(10, 3))])
        path = Path(pair[1]["path"])
        with path.open("ab") as f:
            f.write(b"x" * (MAX_LINE + 50) + b"\n")
            f.write(json.dumps(count(usage(100, 40))).encode() + b"\n")
            f.write(json.dumps(count(usage(104, 41))).encode()[:-1])
        facts, cursor = self.read(pair)
        self.assertEqual([x["tokens_total"] for x in facts], [13])
        self.assertEqual(self.read(pair, cursor)[0], [])
        with path.open("ab") as f:
            f.write(b"}\n")
        after, _ = self.read(pair, cursor)
        self.assertEqual([x["tokens_total"] for x in after], [5])
        self.assertEqual(self.read(pair)[0], facts + after)

    def test_discovery_does_not_declare_missing_scope_complete(self):
        p, _ = self.source("claude", [])
        self.assertEqual(p.discover()["complete_scopes"], ["claude:default"])
        missing = Provider("claude", lambda: [{"id": "missing", "path": self.root / "missing"}])
        self.assertEqual(missing.discover(), {"sources": [], "complete_scopes": []})
