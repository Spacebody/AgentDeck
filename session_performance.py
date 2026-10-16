"""Bounded, local-only session throughput summaries. Never stores chat content.

Transcript usage is batched, not a token stream. These adapters intentionally
report turn averages, including thinking/tools/waiting, never generation TPS.
"""
import json
import math
import logging
import os
import sqlite3
import stat as stat_module
import threading
import time
from datetime import datetime
from pathlib import Path


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value if 0 <= value <= 2**53 and math.isfinite(value) else None


def timestamp(value):
    try:
        if isinstance(value, str):
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (ValueError, OverflowError):
        pass
    return None


def consume(state, event, tool):
    """Update one transcript's numeric state, returning a completed summary."""
    if not isinstance(event, dict) or event.get("isSidechain"):
        return None
    ts = timestamp(event.get("timestamp"))
    if ts is None or ts < state.get("born", 0) or ts <= state.get("finished_at", 0):
        return None
    payload = event.get("payload")
    payload = payload if isinstance(payload, dict) else {}
    kind = payload.get("type") if event.get("type") == "event_msg" else event.get("type")
    if tool == "codex":
        if kind in ("task_started", "turn_started"):
            turn = str(payload.get("turn_id") or ts)[:160]
            if turn in state.get("finished_turns", []):
                return None
            if state.get("turn") != turn:
                state.update(turn=turn, start=ts, output=0, valid=True,
                             current=True, updated=ts, turn_counter=False, counter_invalid=False, gap=False)
        elif kind == "token_count":
            info = payload.get("info")
            usage = info.get("total_token_usage") if isinstance(info, dict) else None
            count = number(usage.get("output_tokens")) if isinstance(usage, dict) else None
            if count is not None:
                previous = state.get("counter")
                if state.get("current") and not state.get("turn_counter"):
                    if previous is None or count < previous:
                        state["valid"] = False
                    else:
                        state["output"] += count - previous
                state.update(counter=count, updated=ts)
        elif kind == "token_usage_record":
            record_turn = payload.get("turn_id")
            usage = payload.get("turn_token_usage")
            count = number(usage.get("output_tokens")) if isinstance(usage, dict) else None
            if count is None:
                return None
            if record_turn in state.get("finished_turns", []):
                return None
            if record_turn and not state.get("current") and record_turn != state.get("turn"):
                # A bounded tail can start mid-turn. Keep its explicit per-turn
                # counter, but wait for a trustworthy duration before showing TPS.
                state.update(turn=str(record_turn)[:160], start=None, current=True,
                             output=0, valid=True, turn_counter=False, counter_invalid=False)
            if record_turn and record_turn != state.get("turn"):
                return None
            # New Codex provides a per-turn counter; don't add it to token_count.
            if state.get("current") and count is not None:
                if state.get("turn_counter") and count < state.get("output", 0):
                    state["valid"] = False
                    state["counter_invalid"] = True
                else:
                    state.update(output=count, valid=not (state.get("counter_invalid") or state.get("gap")),
                                 turn_counter=True, updated=ts)
        elif kind in ("task_complete", "turn_complete", "turn_aborted"):
            turn = payload.get("turn_id")
            if turn and turn != state.get("turn"):
                return None
            duration = number(payload.get("duration_ms"))
            return finish(state, ts, duration, aborted=kind == "turn_aborted")
    else:
        msg = event.get("message")
        msg = msg if isinstance(msg, dict) else {}
        content = msg.get("content")
        is_tool_result = isinstance(content, list) and any(
            isinstance(item, dict) and item.get("type") == "tool_result" for item in content)
        if kind == "user" and not is_tool_result and not event.get("isMeta"):
            turn = str(event.get("uuid") or ts)[:160]
            if turn == state.get("turn") or turn in state.get("finished_turns", []):
                return None
            state.update(turn=turn, start=ts, output=0, valid=True,
                         current=True, updated=ts, seen={}, gap=False)
        elif kind == "assistant" and state.get("current"):
            usage = msg.get("usage")
            count = number(usage.get("output_tokens")) if isinstance(usage, dict) else None
            mid = msg.get("id") or event.get("uuid")
            if count is not None and isinstance(mid, str):
                seen = state.setdefault("seen", {})
                key = mid[:160]
                if key not in seen and len(seen) >= 256:
                    state["valid"] = False
                    return None
                previous = seen.get(key, 0)
                state["output"] += max(0, count - previous)
                seen[key] = max(count, previous)
                state["updated"] = ts
        elif kind == "system" and event.get("subtype") == "turn_duration":
            return finish(state, ts, number(event.get("durationMs")))
    return None


def finish(state, ts, duration_ms=None, aborted=False):
    if not state.get("current"):
        return None
    state["current"] = False
    state["finished_at"] = max(ts, state.get("finished_at", 0))
    state["finished_turns"] = (state.get("finished_turns", []) + [state["turn"]])[-64:]
    start = state.get("start")
    if start is None:
        if duration_ms is None or not state.get("turn_counter"):
            return None
        start = ts - duration_ms / 1000
    duration = duration_ms / 1000 if duration_ms is not None else ts - start
    if aborted or state.get("gap") or not state.get("valid") or duration <= 0 or ts <= start:
        return None
    output = state.get("output", 0)
    if output <= 0:
        return None
    result = dict(state="completed", mode="turn_average", output_tokens=output,
                  duration_secs=duration, tokens_per_second=output / duration,
                  started_at=start, sampled_at=ts, turn_id=state["turn"])
    state["last"] = result
    return result


def snapshot(state, now):
    if state.get("catching_up"):
        return {"state": "sampling"}
    if state.get("current"):
        updated = state.get("updated", 0)
        result = dict(state="sampling", mode="turn_average", sampled_at=updated)
        # A silent log is not evidence that generation continues. Keep old data
        # only in completed summaries; never present it as a live measurement.
        if now - updated > 15 or updated > now + 5:
            result["state"] = "stale"
        elif state.get("valid") and state.get("output", 0) > 0:
            duration = now - (state.get("start") or now)
            if duration > 0:
                result.update(state="active", output_tokens=state["output"],
                              duration_secs=duration,
                              tokens_per_second=state["output"] / duration,
                              started_at=state["start"])
        return result
    return state.get("last") or {"state": "unavailable", "mode": "turn_average"}


class PerformanceCollector:
    """One bounded worker; HTTP only queues indexed paths and reads snapshots."""
    MAX_BYTES = 512 * 1024
    MAX_LINE = 256 * 1024

    def __init__(self, database, candidates):
        self.database = Path(database)
        self.candidates = candidates
        self.lock = threading.Lock()
        self.pending = {}
        self.cache = {}
        self.stop_event = threading.Event()
        self.thread = None

    def start(self):
        with self.lock:
            if self.thread is None:
                self.thread = threading.Thread(target=self._run, daemon=True,
                                               name="agentdeck-performance")
                self.thread.start()

    def stop(self):
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=3)

    def request(self, rows):
        now = time.time()
        with self.lock:
            result = {}
            for key, tool, path in rows:
                if len(self.pending) < 256:
                    self.pending[key] = (tool, path)
                entry = self.cache.get(key)
                result[key] = snapshot(entry, now) if entry else {"state": "sampling"}
            return result

    def _connect(self):
        self.database.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(self.database, timeout=1)
        os.chmod(self.database, 0o600)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, data TEXT, touched REAL)")
        conn.execute("CREATE TABLE IF NOT EXISTS turns (key TEXT, turn TEXT, data TEXT, ended REAL, PRIMARY KEY(key,turn))")
        return conn

    def _sample(self, conn, key, tool, path):
        stat = Path(path).stat()
        if not stat_module.S_ISREG(stat.st_mode):
            raise ValueError("Not a regular transcript")
        row = conn.execute("SELECT data FROM state WHERE key=?", (key,)).fetchone()
        state = json.loads(row[0]) if row else {}
        identity = [stat.st_dev, stat.st_ino]
        if (state.get("version") != 1 or state.get("identity") != identity
                or stat.st_size < state.get("offset", 0) or state.get("path") != path):
            state = {}
        elif state.get("file_size") == stat.st_size and state.get("mtime_ns") == stat.st_mtime_ns:
            with self.lock:
                self.cache[key] = state
            return
        offset = state.get("offset")
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            opened = os.fstat(stream.fileno())
            if (not stat_module.S_ISREG(opened.st_mode)
                    or [opened.st_dev, opened.st_ino] != identity):
                raise ValueError("Transcript replaced during read")
            if offset is None:
                if tool == "codex":
                    try:
                        first = json.loads(stream.readline(self.MAX_LINE))
                        if first.get("type") == "session_meta":
                            state["born"] = timestamp(first.get("timestamp")) or 0
                    except (ValueError, UnicodeDecodeError, AttributeError):
                        pass
                # Historical content is not rescanned in full. Start at a bounded
                # tail; a missing turn start/baseline produces no invented rate.
                offset = max(0, stat.st_size - self.MAX_BYTES)
                stream.seek(offset)
                if offset:
                    stream.readline(self.MAX_LINE)
                    offset = stream.tell()
            stream.seek(offset)
            budget = self.MAX_BYTES
            while budget > 0:
                line = stream.readline(min(self.MAX_LINE, budget))
                if not line:
                    break
                budget -= len(line)
                if not line.endswith(b"\n"):
                    if len(line) == self.MAX_LINE or state.get("skipping"):
                        state["skipping"] = True
                        state.update(valid=False, gap=True)
                        state.pop("counter", None)
                        offset = stream.tell()
                    break
                offset = stream.tell()
                if state.pop("skipping", False):
                    continue
                try:
                    event = json.loads(line)
                except (ValueError, UnicodeDecodeError):
                    state.update(valid=False, gap=True)
                    state.pop("counter", None)
                    continue
                completed = consume(state, event, tool)
                if completed:
                    conn.execute("INSERT OR REPLACE INTO turns VALUES (?,?,?,?)",
                                 (key, completed["turn_id"], json.dumps(completed), completed["sampled_at"]))
            state.update(version=1, identity=identity, offset=offset, path=path,
                         file_size=stat.st_size if offset == stat.st_size else -1,
                         mtime_ns=stat.st_mtime_ns, catching_up=offset < stat.st_size)
        conn.execute("INSERT OR REPLACE INTO state VALUES (?,?,?)", (key, json.dumps(state), time.time()))
        conn.execute("DELETE FROM turns WHERE key=? AND turn NOT IN (SELECT turn FROM turns WHERE key=? ORDER BY ended DESC LIMIT 32)", (key, key))
        conn.commit()
        with self.lock:
            self.cache[key] = state
            while len(self.cache) > 512:
                del self.cache[next(iter(self.cache))]

    def _run(self):
        while not self.stop_event.is_set():
            try:
                self._run_connected()
            except (OSError, sqlite3.Error, ValueError):
                logging.warning("Session performance storage unavailable; retrying")
                with self.lock:
                    self.cache.clear()
                self.stop_event.wait(5)

    def _run_connected(self):
        conn = None
        next_discovery = 0
        next_cleanup = 0
        try:
            conn = self._connect()
            while not self.stop_event.is_set():
                now = time.time()
                if now >= next_cleanup:
                    conn.execute("DELETE FROM state WHERE touched<?", (now - 30 * 86400,))
                    conn.execute("DELETE FROM state WHERE key NOT IN (SELECT key FROM state ORDER BY touched DESC LIMIT 10000)")
                    conn.execute("DELETE FROM turns WHERE key NOT IN (SELECT key FROM state)")
                    conn.commit()
                    next_cleanup = now + 3600
                if now >= next_discovery:
                    try:
                        self.request(self.candidates())
                    except (OSError, sqlite3.Error):
                        pass
                    next_discovery = now + 5
                with self.lock:
                    jobs = list(self.pending.items())[:32]
                    for key, _ in jobs:
                        self.pending.pop(key, None)
                for key, (tool, path) in jobs:
                    if self.stop_event.is_set():
                        break
                    try:
                        self._sample(conn, key, tool, path)
                    except (OSError, ValueError, sqlite3.Error):
                        with self.lock:
                            self.cache[key] = {}
                self.stop_event.wait(1)
        finally:
            if conn:
                conn.close()
