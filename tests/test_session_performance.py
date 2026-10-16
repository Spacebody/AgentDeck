import json
import tempfile
import unittest
import sqlite3
from unittest import mock
from pathlib import Path

from session_performance import PerformanceCollector, consume, snapshot
import agentdeckd as daemon


def event(kind, second, **fields):
    return {"timestamp": f"2026-10-16T00:00:{second:02d}Z", "type": "event_msg",
            "payload": {"type": kind, **fields}}


def usage(second, count):
    return event("token_count", second, info={"total_token_usage": {"output_tokens": count}})


class TurnSpeedTests(unittest.TestCase):
    def test_endpoint_account_ambiguity_and_app_fallback(self):
        db = sqlite3.connect(":memory:")
        db.row_factory = sqlite3.Row
        db.execute("CREATE TABLE session_index(tool, account_id, session_id, source_present, path)")
        for account in ["default", "other"]:
            db.execute("INSERT INTO session_index VALUES ('codex',?,'abc12345',1,'/safe/transcript.jsonl')", (account,))
        requests = [{"tool": "codex", "account": a, "id": "abc12345"} for a in ["*", "default"]]
        requests.append({"tool": "qoder", "id": "abc12345", "source": "qoder_app"})
        collector = mock.Mock()
        collector.request.side_effect = lambda rows: {r[0]: {"state": "sampling"} for r in rows}
        with mock.patch.object(daemon, '_session_db_connect', return_value=db), mock.patch.object(daemon, '_performance', collector):
            result = daemon.api_session_performance({"sessions": [json.dumps(requests)]})
        self.assertEqual(result['metrics']['codex|*|transcript|abc12345']['state'], 'unavailable')
        self.assertEqual(result['metrics']['codex|default|transcript|abc12345']['state'], 'sampling')
        self.assertEqual(result['metrics']['qoder|default|qoder_app|abc12345']['state'], 'unavailable')
        self.assertEqual(len(collector.request.call_args.args[0]), 1)

    def test_endpoint_bounds_and_cross_origin(self):
        for raw in ['{}', '{bad', json.dumps([{}] * 233), 'x' * 65537]:
            self.assertFalse(daemon.api_session_performance({'sessions': [raw]})['ok'])
        handler = object.__new__(daemon.Handler)
        handler.path = '/api/session-performance'
        handler.headers = {'Host': '127.0.0.1:7777', 'Origin': 'https://attacker.example'}
        handler._send = mock.Mock()
        with mock.patch.object(daemon, 'api_session_performance') as call:
            handler.do_GET()
            self.assertEqual(handler._send.call_args.args[0], 403)
            call.assert_not_called()

    def test_replayed_turn_and_sidechain_are_ignored(self):
        state = {}
        def user(second, uid):
            return {"type": "user", "timestamp": f"2026-10-16T00:00:{second:02d}Z", "uuid": uid}
        def assistant(second, mid, count, **extra):
            return {"type": "assistant", "timestamp": f"2026-10-16T00:00:{second:02d}Z",
                    "message": {"id": mid, "usage": {"output_tokens": count}}, **extra}
        def end(second):
            return {"type": "system", "subtype": "turn_duration",
                    "timestamp": f"2026-10-16T00:00:{second:02d}Z", "durationMs": 10000}
        first = [user(1, "a"), assistant(4, "a1", 100), end(11)]
        second = [user(20, "b"), assistant(24, "b1", 200),
                  assistant(25, "side", 900, isSidechain=True), end(30)]
        for e in first + second + first:
            consume(state, e, "claude")
        self.assertEqual(state["last"]["turn_id"], "b")
        self.assertEqual(state["last"]["output_tokens"], 200)
        # Even replay with rewritten timestamps cannot reopen a completed ID.
        consume(state, user(40, "a"), "claude")
        self.assertFalse(state["current"])

    def test_lost_long_or_malformed_line_invalidates_turn(self):
        for bad in ["x" * (PerformanceCollector.MAX_LINE + 100), "{broken"]:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "test.jsonl"
                events = [usage(0, 0), event("task_started", 1), usage(3, 100)]
                path.write_text("\n".join(json.dumps(e) for e in events) + "\n" + bad + "\n" + json.dumps(event("task_complete", 11)) + "\n")
                c = PerformanceCollector(Path(tmp) / "perf.sqlite3", lambda: [])
                db = c._connect()
                for _ in range(3):
                    c._sample(db, "key", "codex", str(path))
                self.assertNotIn("last", c.cache["key"])
                db.close()

    def test_midturn_tail_waits_for_explicit_duration(self):
        state = {}
        consume(state, {"timestamp": "2026-10-16T00:00:04Z", "type": "token_usage_record",
                        "payload": {"turn_id": "a", "turn_token_usage": {"output_tokens": 100}}}, "codex")
        self.assertNotIn("tokens_per_second", snapshot(state, state["updated"] + 1))
        result = consume(state, event("task_complete", 11, turn_id="a", duration_ms=10000), "codex")
        self.assertEqual(result["tokens_per_second"], 10)

    def test_midturn_record_without_turn_usage_cannot_restore(self):
        state = {}
        consume(state, usage(0, 100), "codex")
        consume(state, {"timestamp": "2026-10-16T00:00:04Z", "type": "token_usage_record",
                        "payload": {"turn_id": "a"}}, "codex")
        consume(state, usage(5, 200), "codex")
        self.assertIsNone(consume(state, event("task_complete", 11, turn_id="a", duration_ms=10000), "codex"))

    def test_gap_invalidates_next_turn_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.jsonl"
            lines = [usage(0, 100), event("task_started", 1, turn_id="a"), usage(3, 150)]
            path.write_text("\n".join(json.dumps(e) for e in lines) + "\n{broken\n" +
                            "\n".join(json.dumps(e) for e in [event("task_started", 10, turn_id="b"),
                            usage(15, 300), event("task_complete", 20, turn_id="b", duration_ms=10000)]) + "\n")
            c = PerformanceCollector(Path(tmp) / "perf.sqlite3", lambda: [])
            db = c._connect()
            c._sample(db, "key", "codex", str(path))
            self.assertNotIn("last", c.cache["key"])
            db.close()

    def test_codex_baseline_duplicates_and_completion(self):
        state = {}
        for e in [usage(0, 1000), event("task_started", 1, turn_id="a"),
                  usage(3, 1100), usage(3, 1100), usage(5, 1200)]:
            consume(state, e, "codex")
        result = consume(state, event("task_complete", 11, turn_id="a", duration_ms=10000), "codex")
        self.assertEqual(result["tokens_per_second"], 20)
        self.assertEqual(result["output_tokens"], 200)
        self.assertEqual(snapshot(state, result["sampled_at"] + 100)["state"], "completed")
        self.assertIsNone(consume(state, event("task_complete", 11, turn_id="a"), "codex"))

    def test_new_turn_counter_not_added_to_legacy_usage(self):
        state = {}
        consume(state, event("task_started", 1, turn_id="a"), "codex")
        consume(state, usage(3, 999999), "codex")
        record = {"timestamp": "2026-10-16T00:00:04Z", "type": "token_usage_record",
                  "payload": {"turn_id": "a", "turn_token_usage": {"output_tokens": 100}}}
        consume(state, record, "codex")
        consume(state, record, "codex")
        consume(state, usage(5, 1000099), "codex")
        result = consume(state, event("task_complete", 11, turn_id="a"), "codex")
        self.assertEqual(result["output_tokens"], 100)
        self.assertEqual(result["tokens_per_second"], 10)

    def test_missing_baseline_reset_abort_and_wrong_turn(self):
        for events in [
            [event("task_started", 1), usage(2, 100)],
            [usage(0, 100), event("task_started", 1), usage(2, 10)],
            [usage(0, 0), event("task_started", 1), usage(2, 100), event("turn_aborted", 3)],
        ]:
            state = {}
            for e in events:
                consume(state, e, "codex")
            self.assertIsNone(consume(state, event("task_complete", 11), "codex"))
        state = {}
        consume(state, event("task_started", 1, turn_id="a"), "codex")
        self.assertIsNone(consume(state, event("task_complete", 11, turn_id="b"), "codex"))
        self.assertTrue(state["current"])

    def test_stale_and_clock_skew_do_not_display_rate(self):
        state = {"current": True, "valid": True, "output": 100, "start": 10, "updated": 20}
        self.assertEqual(snapshot(state, 25)["state"], "active")
        self.assertEqual(snapshot(state, 40)["state"], "stale")
        self.assertNotIn("tokens_per_second", snapshot(state, 40))
        self.assertEqual(snapshot(state, 0)["state"], "stale")

    def test_claude_qoder_message_dedup_and_tool_result(self):
        for tool in ("claude", "qoder"):
            state = {}
            consume(state, {"type": "user", "timestamp": "2026-10-16T00:00:01Z",
                            "uuid": "a", "message": {"content": "hello"}}, tool)
            for count in (50, 50, 100):
                consume(state, {"type": "assistant", "timestamp": "2026-10-16T00:00:04Z",
                                "message": {"id": "m1", "usage": {"output_tokens": count}}}, tool)
            consume(state, {"type": "user", "timestamp": "2026-10-16T00:00:05Z",
                            "message": {"content": [{"type": "tool_result"}]}}, tool)
            result = consume(state, {"type": "system", "subtype": "turn_duration",
                                     "timestamp": "2026-10-16T00:00:11Z", "durationMs": 10000}, tool)
            self.assertEqual(result["tokens_per_second"], 10)

    def test_malformed_and_replayed_parent_events(self):
        state = {"born": 9999999999}
        consume(state, event("task_started", 1), "codex")
        self.assertNotIn("current", state)
        for item in [None, [], {}, {"timestamp": "bad"}, {"timestamp": []}]:
            self.assertIsNone(consume({}, item, "codex"))

    def test_collector_partial_restart_truncate_and_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test.jsonl"
            collector = PerformanceCollector(Path(tmp) / "perf.sqlite3", lambda: [])
            conn = collector._connect()
            path.write_text("\n".join(json.dumps(e) for e in [usage(0, 0), event("task_started", 1), usage(3, 100)]) + "\n")
            collector._sample(conn, "codex|a|id", "codex", str(path))
            end = json.dumps(event("task_complete", 11))
            with path.open("a") as f:
                f.write(end[:20])
            collector._sample(conn, "codex|a|id", "codex", str(path))
            with path.open("a") as f:
                f.write(end[20:] + "\n")
            restarted = PerformanceCollector(Path(tmp) / "perf.sqlite3", lambda: [])
            restarted._sample(conn, "codex|a|id", "codex", str(path))
            result = restarted.request([("codex|a|id", "codex", str(path))])
            self.assertEqual(result["codex|a|id"]["tokens_per_second"], 10)
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM turns").fetchone()[0], 1)
            restarted._sample(conn, "codex|b|id", "codex", str(path))
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM turns").fetchone()[0], 2)
            path.write_text("{}\n")
            restarted._sample(conn, "codex|a|id", "codex", str(path))
            self.assertEqual(restarted.request([("codex|a|id", "codex", str(path))])["codex|a|id"]["state"], "unavailable")
            conn.close()


if __name__ == "__main__":
    unittest.main()
