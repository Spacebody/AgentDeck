"""Read-only transcript adapters for the analytics store; no prompts in cursors or facts."""
import hashlib
import json
import math
import os
import stat
from datetime import datetime
from pathlib import Path


MAX_LINE = 256 * 1024


def _obj(x):
    return x if isinstance(x, dict) else {}


def _label(x):
    return x if isinstance(x, str) and 0 < len(x) <= 4096 and not any(ord(c) < 32 for c in x) else None


def _number(x):
    return x if type(x) is int and 0 <= x <= 2**53 else None


def _time(x):
    if isinstance(x, str):
        try:
            dt = datetime.fromisoformat(x.replace("Z", "+00:00"))
            return dt.timestamp() if dt.tzinfo else None
        except (ValueError, OverflowError, OSError):
            pass
    return None


def _key(*parts):
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode()).hexdigest()


def _project(x):
    return x if _label(x) and os.path.isabs(x) else None


def _fact(src, s, ts, kind, identity, **values):
    return dict(event_key=_key(src["agent"], src["account_id"], kind, identity),
                agent=src["agent"], account_id=src["account_id"], source_kind="transcript",
                kind=kind, basis="recorded", observed_at=ts, session_id=s.get("sid"),
                parent_session_id=s.get("parent"), project=s.get("project"), model=s.get("model"),
                turn_id=s.get("turn"), cost_usd=None, calls=1 if kind == "call" else None,
                **values)


def _summary(src, s, ts, duration):
    if not s.get("turn") or not s.get("sid"):
        return
    start = s.get("start")
    seconds = duration / 1000 if _number(duration) is not None else (
        ts - start if ts is not None and start is not None and ts >= start else None)
    return _fact(src, s, ts, "turn_summary", [s["sid"], s["turn"]],
                 started_at=start, ended_at=ts, duration_secs=seconds, **s.get("turn_usage", {}))


def _claude(src, s, e, ts):
    msg, kind = _obj(e.get("message")), e.get("type")
    sid = _label(e.get("sessionId"))
    child = _label(e.get("agentId")) or src.get("child")
    if child:
        s.update(sid=child, parent=src.get("parent") or (sid if sid != child else None))
    else:
        s["sid"] = sid or s.get("sid") or Path(src["path"]).stem
        s["parent"] = None
    if _project(e.get("cwd")):
        s["project"] = e["cwd"]
    if kind == "user" and not e.get("isMeta"):
        content = msg.get("content")
        if not isinstance(content, list) or not any(_obj(x).get("type") == "tool_result" for x in content):
            s.update(turn=_label(e.get("uuid")), start=ts, model=None)
    if kind == "system" and e.get("subtype") == "turn_duration":
        return _summary(src, s, ts, e.get("durationMs"))
    usage = _obj(msg.get("usage"))
    mid, rid = _label(msg.get("id")), _label(e.get("requestId"))
    if kind != "assistant" or not usage or not (mid or rid):
        return
    s["model"] = _label(msg.get("model"))
    inp, out, read, write = (_number(usage.get(k)) for k in
                             ("input_tokens", "output_tokens", "cache_read_input_tokens",
                              "cache_creation_input_tokens"))
    cache = _obj(usage.get("cache_creation"))
    short, long = (_number(cache.get(k)) for k in ("ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens"))
    created = write if write is not None else short + long if None not in (short, long) else None
    if all(x is None for x in (inp, out, read, created, short, long)):
        return
    fact = _fact(src, s, ts, "call", ["message", mid] if mid else ["request", rid],
                 input_basis="uncached", input_tokens=inp, input_uncached_tokens=inp,
                 output_tokens=out, cache_read_tokens=read, cache_write_tokens=created,
                 cache_write_5m_tokens=short, cache_write_1h_tokens=long)
    # Streaming content blocks can repeat a response or report an earlier snapshot.
    # Keep a bounded revision window, not an unbounded set of historical IDs.
    recent = s.setdefault("responses", {})
    key = fact["event_key"]
    old = recent.pop(key, {})
    stamps = [x for x in (ts, old.get("first_observed_at"), old.get("last_observed_at")) if x is not None]
    fact["observed_at"] = fact["first_observed_at"] = min(stamps, default=None)
    fact["last_observed_at"] = max(stamps, default=None)
    for field in ("input_tokens", "input_uncached_tokens", "output_tokens", "cache_read_tokens",
                  "cache_write_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens"):
        values = [x for x in (old.get(field), fact[field]) if x is not None]
        fact[field] = max(values, default=None)
    primary = [fact[k] for k in ("input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens")]
    fact["tokens_total"] = sum(primary) if None not in primary else None
    if len(recent) >= 32:
        del recent[next(iter(recent))]
    recent[key] = {k: v for k, v in fact.items() if k.endswith("_tokens") or k.endswith("_observed_at")}
    return fact


_COUNTERS = ("input_tokens", "output_tokens", "cached_input_tokens", "reasoning_output_tokens", "total_tokens")


def _snapshot(value):
    row = _obj(value)
    counts = {k: _number(row.get(k)) for k in _COUNTERS}
    if any(k in row and counts[k] is None for k in counts):
        return None
    return counts if counts["total_tokens"] is not None or None not in (
        counts["input_tokens"], counts["output_tokens"]) else None


def _gap(s):
    s.update(previous=None, model=None, project=None, turn=None, start=None, turn_usage={},
             epoch=s.get("epoch", 0) + 1, gap=True)


def _codex(src, s, e, ts):
    p, kind = _obj(e.get("payload")), e.get("type")
    if not s.get("sid"):
        if not s.get("gap") and kind == "session_meta" and _label(p.get("id")):
            child = _obj(_obj(p.get("source")).get("subagent"))
            fork = _obj(child.get("thread_spawn"))
            parent = _label(fork.get("parent_thread_id")) or _label(p.get("forked_from_id"))
            s.update(sid=p["id"], parent=parent,
                     replay="thread_spawn" in child or bool(parent), born=_time(p.get("timestamp")) or ts,
                     project=_project(p.get("cwd")))
        return
    event = p.get("type") if kind == "event_msg" else None
    info = _obj(p.get("info"))
    current = _snapshot(info.get("total_token_usage")) if event == "token_count" else None
    if s.get("replay"):
        started = p.get("started_at")
        if not (event in ("task_started", "turn_started") and type(started) in (float, int)
                and math.isfinite(started) and s.get("born") is not None
                and started >= int(s["born"])):
            if current is not None:
                s["previous"] = current
            return
        s["replay"] = False
    if event in ("task_started", "turn_started"):
        turn = _label(p.get("turn_id"))
        if not turn or turn != s.get("turn") or not s.get("open"):
            s.update(turn=turn, start=ts, model=None, turn_usage={}, open=True)
    elif kind == "turn_context":
        turn = _label(p.get("turn_id"))
        if turn and turn != s.get("turn"):
            s.update(turn=turn, start=None, turn_usage={})
        s.update(model=_label(p.get("model")), project=_project(p.get("cwd")) or s.get("project"))
    elif event in ("task_complete", "turn_complete", "turn_aborted"):
        if p.get("turn_id") and p["turn_id"] != s.get("turn"):
            return
        result = _summary(src, s, ts, p.get("duration_ms"))
        s.update(turn=None, start=None, model=None, turn_usage={}, open=False)
        return result
    elif event == "token_usage_record" and p.get("turn_id") and p["turn_id"] == s.get("turn"):
        counts = _obj(p.get("turn_token_usage"))
        names = {"total_tokens": "tokens_total", "cached_input_tokens": "cache_read_tokens"}
        s["turn_usage"] = {names.get(k, k): _number(counts.get(k))
                           for k in _COUNTERS}
    elif event == "token_count":
        if current is None:
            if info.get("total_token_usage") is not None:
                _gap(s)
            return
        previous = s.get("previous")
        context = [s.get("model"), s.get("turn"), s.get("project")]
        old_context = s.get("baseline_context")
        s["baseline_context"] = context
        s["previous"] = current
        if previous is None:
            # Only an explicit matching last-call vector proves a first positive delta.
            if s.get("gap") or _snapshot(info.get("last_token_usage")) != current:
                return
            previous = {k: 0 for k in current}
        if any(current[k] < previous[k] for k in current if None not in (current[k], previous[k])):
            s["epoch"] = s.get("epoch", 0) + 1
            return
        delta = {k: current[k] - previous[k] if None not in (current[k], previous[k]) else None
                 for k in current}
        last_matches = _snapshot(info.get("last_token_usage")) == delta
        total = delta.pop("total_tokens")
        if total is None and None not in (delta["input_tokens"], delta["output_tokens"]):
            total = delta["input_tokens"] + delta["output_tokens"]
        if not total:
            return
        owner = s
        if old_context and old_context != context and not last_matches:
            owner = dict(s)
            for i, field in enumerate(("model", "turn", "project")):
                if context[i] != old_context[i]:
                    owner[field] = None
        cached = delta.pop("cached_input_tokens")
        inp = delta["input_tokens"]
        uncached = inp - cached if None not in (inp, cached) and inp >= cached else None
        return _fact(src, owner, ts, "usage_delta", [s["sid"], s.get("epoch", 0), list(current.values())],
                     tokens_total=total, input_basis="includes_cache", input_uncached_tokens=uncached,
                     cache_read_tokens=cached, **delta)


class Provider:
    def __init__(self, agent, sources_callback):
        if agent not in ("claude", "codex"):
            raise ValueError("unsupported transcript provider")
        self.name, self._sources = agent, sources_callback

    def discover(self):
        sources, complete = [], []
        for account in self._sources():
            root = Path(account["path"]) / ("projects" if self.name == "claude" else "sessions")
            scope = f"{self.name}:{account['id']}"
            failed = []
            for base, dirs, files in os.walk(root, onerror=failed.append):
                parts = Path(base).relative_to(root).parts
                for name in sorted(files):
                    if not name.endswith(".jsonl"):
                        continue
                    sub = self.name == "claude" and len(parts) >= 3 and parts[-1] == "subagents"
                    if self.name == "claude" and len(parts) != 1 and not sub:
                        continue
                    if self.name == "codex" and (len(parts) != 3 or not name.startswith("rollout-")):
                        continue
                    path = Path(base) / name
                    try:
                        if not stat.S_ISREG(path.lstat().st_mode):
                            continue
                    except OSError as exc:
                        failed.append(exc)
                        continue
                    sources.append(dict(scope=scope, source_id=str(path.relative_to(root)), path=str(path),
                                        mode="append", agent=self.name, account_id=account["id"],
                                        child=path.stem.removeprefix("agent-") if sub or self.name == "claude" and name.startswith("agent-") else None,
                                        parent=parts[-2] if sub else None))
                if self.name == "codex" and len(parts) >= 3:
                    dirs.clear()
            if not failed:
                complete.append(scope)
        return {"sources": sources, "complete_scopes": complete}

    def read_batch(self, source, cursor, budget):
        s = dict(cursor or {})
        facts = []
        remaining = max(1, int(budget["max_bytes"]))
        cap = min(MAX_LINE, remaining)
        rows = max(1, int(budget["max_rows"]))
        fd = os.open(source["path"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as f:
            st = os.fstat(f.fileno())
            if not stat.S_ISREG(st.st_mode):
                raise ValueError("not a regular transcript")
            f.seek(s.get("offset", 0))
            done = False
            while remaining and rows:
                raw = f.readline(min(remaining, cap))
                remaining -= len(raw)
                if not raw:
                    done = True
                    break
                if not raw.endswith(b"\n"):
                    if s.get("skipping") or len(raw) == cap:
                        if not s.get("skipping"):
                            _gap(s)
                        s.update(skipping=True, offset=f.tell())
                    else:
                        done = f.tell() >= st.st_size
                    break
                rows -= 1
                s["offset"] = f.tell()
                if s.pop("skipping", False):
                    continue
                try:
                    e = json.loads(raw)
                except (ValueError, RecursionError):
                    _gap(s)
                    continue
                if not isinstance(e, dict):
                    _gap(s)
                    continue
                parser = _claude if self.name == "claude" else _codex
                fact = parser(source, s, e, _time(e.get("timestamp")))
                if fact:
                    facts.append(fact)
            done = done or s.get("offset", 0) >= st.st_size
        return dict(facts=facts, next_cursor=s, done=done)
