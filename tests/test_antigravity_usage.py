import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor

import antigravity_usage as usage


class StatusLineTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name) / "store"

    def record(self, now, **payload):
        usage.record(payload, directory=self.directory, now=now)

    def read(self, now):
        return usage.read_usage(directory=self.directory, now=now)

    def counts(self, now, sid, i, o):
        self.record(now, session_id=sid, context_window=dict(total_input_tokens=i,
                                                             total_output_tokens=o))

    def test_baseline_resume_and_concurrent_replays(self):
        self.counts(3, "a", 500, 90)
        self.counts(5, "b", 60, 7)
        self.assertEqual(self.read(5)["hourly"], [])
        self.counts(3599, "a", 504, 91)
        self.counts(3601, "b", 80, 20)
        self.counts(3601, "a", 400, 80)
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda _: self.counts(3602, "a", 509, 94), range(8)))
        self.assertEqual(self.read(3603)["hourly"], [
            dict(hour=0, input_tokens=4, output_tokens=1),
            dict(hour=3600, input_tokens=25, output_tokens=16)])
        self.assertEqual(len(self.read(usage.HOURS * 3600)["hourly"]), 1)
        self.assertEqual(self.read((usage.HOURS+1) * 3600)["hourly"], [])

    def test_quota_snapshot_expiration_replacement_and_throttle(self):
        quota = {"gemini-weekly": dict(remaining_fraction=0, reset_time="1970-01-01T00:03:00Z"),
                 "credits": dict(remaining_amount=2, reset_in_seconds=100),
                 "off": dict(remaining_fraction=1, disabled=True)}
        self.record(60, quota=quota)
        self.record(61, quota=quota)
        seen = self.read(159)["quota"]
        self.assertEqual(set(seen), {"credits", "gemini-weekly"})
        self.assertEqual(seen["credits"]["observed_at"], 60)
        self.assertEqual(seen["gemini-weekly"]["remaining_fraction"], 0)
        self.assertEqual(set(self.read(160)["quota"]), {"gemini-weekly"})
        self.assertEqual(self.read(180)["quota"], {})
        self.record(181, quota={"new": dict(remaining_amount=7)})
        self.record(70, quota=quota)
        self.assertEqual(set(self.read(181)["quota"]), {"new"})
        self.record(182, quota={})
        self.assertEqual(self.read(182)["quota"], {})

    def test_unknown_and_invalid_data(self):
        self.assertEqual(self.read(1), {"quota": {}, "hourly": []})
        self.counts(1, "", 10, 10)
        self.counts(2, "a", True, 10)
        self.record(3, context_window={"remaining_percentage": 10})
        self.assertFalse(self.directory.exists())
        self.record(4, quota={"bad": {"remaining_fraction": 99},
                              "bad2": {"remaining_amount": float("nan")}})
        self.assertEqual(self.read(4)["quota"], {})

    def test_corrupt_rows_do_not_hide_valid_history_or_leak_extra_fields(self):
        self.record(0, quota={})
        good_hour = dict(hour=0, input_tokens=1, output_tokens=2)
        db = sqlite3.connect(self.directory / "usage.sqlite3")
        self.addCleanup(db.close)
        with db:
            db.executemany("INSERT INTO hourly VALUES (?,?,?)",
                           [(0, 1, 2), (3600, "invalid", 2), (7200, 4, -1), (7201, 2, 3)])
        for raw, seen in [("[]", 1), ("{", 1), ('{"model":{"remaining_amount":2}}', "bad")]:
            with self.subTest(raw=raw, seen=seen), db:
                db.execute("UPDATE snapshot SET buckets=?, seen=?", (raw, seen))
                db.commit()
                self.assertEqual(self.read(10800), dict(quota={}, hourly=[good_hour]))
        with db:
            db.execute("UPDATE snapshot SET buckets=?, seen=42",
                       (json.dumps({"model": dict(remaining_amount=2, private="ignore"),
                                    "other": ["unexpected"]}),))
        self.assertEqual(self.read(10800)["quota"], {"model": dict(remaining_amount=2, observed_at=42)})

    def test_cli_privacy_and_modes(self):
        root = self.directory.parent
        sentinel = "private-do-not-store"
        payload = dict(product="antigravity", conversation_id=sentinel, email=sentinel,
                       conversation_title=sentinel, transcript_path=sentinel,
                       context_window=dict(total_input_tokens=42, total_output_tokens=9),
                       quota={"example": dict(remaining_amount=1, unexpected=sentinel)})
        for raw, code in [(json.dumps(payload), 0), (sentinel, 1), ("x"*(usage.LIMIT+1), 1)]:
            proc = subprocess.run([sys.executable, "-B", usage.__file__], input=raw, text=True,
                                  capture_output=True, env=dict(os.environ, HOME=str(root)))
            self.assertEqual((proc.returncode, proc.stdout, proc.stderr),
                             (code, "Antigravity CLI\n" if code == 0 else "", ""))
        db, = root.rglob("usage.sqlite3")
        self.assertEqual(db.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(db.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(sentinel.encode(), db.read_bytes())
        db.chmod(0o644)
        self.assertEqual(usage.read_usage(directory=db.parent), {"quota": {}, "hourly": []})
        with self.assertRaises(PermissionError):
            usage.record(payload, directory=db.parent)


if __name__ == "__main__":
    unittest.main()
