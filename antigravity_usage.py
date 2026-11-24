"""Opt-in Antigravity CLI status-line receiver. No network or account access."""

import hashlib
import json
import math
import os
import re
import sqlite3
import stat
import sys
import time
from contextlib import closing
from datetime import datetime
from pathlib import Path


STORE = Path.home() / "Library/Application Support/AgentDeck/antigravity-usage"
LIMIT = 1024 * 1024
MAX_INT = (1 << 63) - 1
HOURS = 31 * 24


def _database(directory, write):
    directory = Path(directory)
    if write:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    db = directory / "usage.sqlite3"
    for path, kind in ((directory, stat.S_ISDIR), (db, stat.S_ISREG)):
        if path == db and write:
            try:
                os.close(os.open(db, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
            except FileExistsError:
                pass
        info = path.lstat()
        if (not kind(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & 0o077 or (path == db and info.st_nlink != 1)):
            raise PermissionError("unsafe usage store")
    return sqlite3.connect(db.absolute().as_uri() + ("?mode=rw" if write else "?mode=ro"),
                           uri=True, timeout=2)


def _integer(n):
    return type(n) is int and 0 <= n <= MAX_INT


def _epoch(value):
    if not isinstance(value, str) or len(value) > 40:
        return None
    try:
        dt = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
        return dt.timestamp() if dt.tzinfo else None
    except (ValueError, OverflowError, OSError):
        return None


def _quotas(items):
    result = {}
    for key, item in items.items():
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", key) or not isinstance(item, dict):
            continue
        if item.get("disabled", False) is not False:
            continue
        row = {}
        for name in ("remaining_fraction", "remaining_amount"):
            n = item.get(name)
            if (_integer(n) or type(n) is float and math.isfinite(n) and n >= 0):
                if name == "remaining_amount" or n <= 1:
                    row[name] = n
        if not row:
            continue
        if _epoch(item.get("reset_time")) is not None:
            row["reset_time"] = item["reset_time"]
        if _integer(item.get("reset_in_seconds")):
            row["reset_in_seconds"] = item["reset_in_seconds"]
        result[key] = row
    return result


def record(payload, *, directory=None, now=None):
    """Store only validated observations; never serialize the input envelope."""
    if not isinstance(payload, dict) or payload.get("product", "antigravity") != "antigravity":
        return
    now = int(time.time() if now is None else now)
    quota = payload.get("quota")
    quota = _quotas(quota) if isinstance(quota, dict) else None
    sid = payload.get("conversation_id") or payload.get("session_id")
    ctx = payload.get("context_window")
    pair = None
    if isinstance(sid, str) and 0 < len(sid) <= 256 and isinstance(ctx, dict):
        counts = (ctx.get("total_input_tokens"), ctx.get("total_output_tokens"))
        if all(_integer(n) for n in counts):
            pair = counts
    if quota is None and pair is None:
        return

    with closing(_database(directory or STORE, True)) as db, db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY, seen INTEGER, buckets TEXT)")
        db.execute("CREATE TABLE IF NOT EXISTS baseline (session TEXT PRIMARY KEY, i INTEGER, o INTEGER)")
        db.execute("CREATE TABLE IF NOT EXISTS hourly (hour INTEGER PRIMARY KEY, i INTEGER, o INTEGER)")
        if quota is not None:
            db.execute("INSERT INTO snapshot VALUES (1,?,?) ON CONFLICT(id) DO UPDATE SET "
                       "seen=excluded.seen,buckets=excluded.buckets WHERE excluded.seen>=seen "
                       "AND (excluded.buckets!=buckets OR excluded.seen-seen>=?)",
                       (now, json.dumps(quota, sort_keys=True),
                        min([60] + [max(1, row["reset_in_seconds"]) for row in quota.values()
                                    if "reset_in_seconds" in row])))
        if pair is None:
            return
        key = hashlib.sha256(sid.encode()).hexdigest()
        old = db.execute("SELECT i,o FROM baseline WHERE session=?", (key,)).fetchone()
        # A regressing cumulative counter is ambiguous (e.g. out-of-order callbacks).
        if old and (pair == old or any(a < b for a, b in zip(pair, old))):
            return
        db.execute("INSERT OR REPLACE INTO baseline VALUES (?,?,?)", (key, *pair))
        if old:
            hour = now - now % 3600
            db.execute("INSERT INTO hourly VALUES (?,?,?) ON CONFLICT(hour) DO UPDATE SET "
                       "i=i+excluded.i,o=o+excluded.o",
                       (hour, pair[0] - old[0], pair[1] - old[1]))
            db.execute("DELETE FROM hourly WHERE hour < ?", (hour - (HOURS-1)*3600,))


def read_usage(*, directory=None, now=None):
    """Return the latest unexpired quota observations and observed hourly increases."""
    now = time.time() if now is None else now
    try:
        with closing(_database(directory or STORE, False)) as db:
            db.execute("BEGIN")
            snap = db.execute("SELECT buckets,seen FROM snapshot WHERE id=1").fetchone()
            quota = {}
            if snap and _integer(snap[1]) and isinstance(snap[0], str) and len(snap[0]) <= LIMIT:
                try:
                    items = json.loads(snap[0])
                except (ValueError, RecursionError):
                    items = None
                if isinstance(items, dict):
                    quota = _quotas(items)
            for key, row in list(quota.items()):
                row["observed_at"] = snap[1]
                deadlines = [_epoch(row.get("reset_time"))]
                if "reset_in_seconds" in row:
                    deadlines.append(row["observed_at"] + row["reset_in_seconds"])
                if any(t is not None and now >= t for t in deadlines):
                    del quota[key]
            hour = int(now) // 3600 * 3600
            hourly = [dict(hour=h, input_tokens=i, output_tokens=o) for h, i, o in
                      db.execute("SELECT hour,i,o FROM hourly WHERE hour BETWEEN ? AND ? ORDER BY hour",
                                 (hour - (HOURS-1)*3600, hour))
                      if _integer(h) and h % 3600 == 0 and _integer(i) and _integer(o)]
            return {"quota": quota, "hourly": hourly}
    except (OSError, sqlite3.Error, ValueError):
        return {"quota": {}, "hourly": []}


def main():
    try:
        data = sys.stdin.buffer.read(LIMIT + 1)
        if len(data) > LIMIT:
            return 1
        record(json.loads(data))
        print("Antigravity CLI")
        return 0
    except (OSError, ValueError, RecursionError, sqlite3.Error):
        return 1


if __name__ == "__main__":
    sys.exit(main())
