"""Local Qoder analytics inputs. No IPC, network, credentials, or content estimates."""

import hashlib
import json
import math
import os
import sqlite3
import stat
import uuid
from contextlib import closing, contextmanager
from datetime import datetime
from pathlib import Path


SESSION_SOURCE_KINDS = {"qoder_app": "qoder_desktop"}


def _key(*parts):
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode()).hexdigest()


def _text(value, limit=256):
    if isinstance(value, str) and 0 < len(value) <= limit and value.isprintable():
        return value
    return None


def _int(value):
    return value if type(value) is int and 0 <= value < 2**63 else None


def _stamp(path):
    s = path.lstat()
    if not stat.S_ISREG(s.st_mode):
        raise OSError("not a regular source")
    return [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def _db_version(path):
    main = _stamp(path)
    try:
        wal = _stamp(Path(str(path) + "-wal"))
    except FileNotFoundError:
        wal = None
    return [main, wal]


def _source(kind, agent, account, root, path, mode):
    return dict(scope=f"{kind}:{account}", source_id=_key(str(path)), path=str(path),
                root=str(root), mode=mode, agent=agent, account_id=account, source_kind=kind)


def discover(cli_sources=None, cn_sources=None, desktop_db=None):
    """Inject daemon account roots as [{id, path}]; defaults never inspect settings/auth."""
    home = Path.home()
    db = Path(desktop_db or home / "Library/Application Support/Qoder/SharedClientCache/cache/db/local.db")
    sources, scopes = [], []
    try:
        _stamp(db)
    except OSError:
        pass
    else:
        src = _source("qoder_desktop", "qoder", "default", db.parent, db, "snapshot")
        src["pinned_snapshot"] = True
        sources.append(src)
        scopes.append(src["scope"])

    def roots(items, env, name):
        return list(items) if items is not None else [
            {"id": "default", "path": os.environ.get(env) or home / name}]

    cn = roots(cn_sources, "QODERCN_CONFIG_DIR", ".qoder-cn")
    intl = roots(cli_sources, "QODER_CONFIG_DIR", ".qoder")
    cn_roots = {os.path.realpath(s["path"]) for s in cn}
    seen = set()
    for kind, agent, configs in (("qoder_cn_cli", "qoder_cn", cn), ("qoder_cli", "qoder", intl)):
        for config in configs:
            config_path = Path(config["path"]).absolute()
            if kind == "qoder_cli" and os.path.realpath(config_path) in cn_roots:
                continue
            root = config_path / "projects"
            account = config["id"]
            if str(root) in seen:
                continue
            seen.add(str(root))
            def fail(exc):
                raise exc
            try:
                if not stat.S_ISDIR(root.lstat().st_mode):
                    continue
                for directory, dirs, files in os.walk(root, onerror=fail, followlinks=False):
                    dirs[:] = sorted(d for d in dirs if not (Path(directory) / d).is_symlink())
                    for name in sorted(files):
                        p = Path(directory) / name
                        if name.endswith(".jsonl") and stat.S_ISREG(p.lstat().st_mode):
                            sources.append(_source(kind, agent, account, root, p, "append"))
            except OSError:
                continue
            scopes.append(f"{kind}:{account}")
    return {"sources": sources, "complete_scopes": scopes}


def _fact(src, stamp, session, model, kind, identity):
    return dict(event_key=_key(src["scope"], kind, *identity), agent=src["agent"],
                account_id=src["account_id"], source_kind=src["source_kind"], kind=kind,
                basis="recorded", observed_at=stamp, first_observed_at=stamp, last_observed_at=stamp,
                session_id=session, project=None, model=model, input_basis="unknown",
                input_tokens=None, output_tokens=None, cache_read_tokens=None, cache_write_tokens=None,
                tokens_total=None, cost_usd=None, credits=None, calls=None)


def _events(src, stamp, session, model, message, request, usage, desktop=False):
    if not request and not message:
        return []
    result = []
    if request:
        call = _fact(src, stamp, session, model, "call", ["request", request])
        call["calls"] = 1
        result.append(call)
    identity = ["message", session, message] if message else ["request", request]
    event = _fact(src, stamp, session, model, "usage_delta", identity)
    event["call_observed"] = bool(request)
    inp, out, read = (_int(usage.get(k)) for k in (
        ("prompt_tokens", "completion_tokens", "cached_tokens") if desktop else
        ("input_tokens", "output_tokens", "cache_read_input_tokens")))
    write = _int(usage.get("cache_creation_input_tokens"))
    cc = usage.get("cache_creation")
    pieces = [_int(cc.get(k)) if isinstance(cc, dict) else None
              for k in ("ephemeral_5m_input_tokens", "ephemeral_1h_input_tokens")]
    if write is None and None not in pieces:
        write = _int(sum(pieces))
    credits = usage.get("credits")
    if credits is None:
        credits = usage.get("original_credits")
    if type(credits) in (int, float) and 0 <= credits <= 2**53 and math.isfinite(credits):
        event["credits"] = credits
    total = _int(usage.get("total_tokens"))
    # CLI builtin routes sometimes report all zero, even for a real billed response.
    if desktop or any((inp, out, read, write, total, *pieces)):
        event.update(input_tokens=inp, output_tokens=out, cache_read_tokens=read,
                     cache_write_5m_tokens=pieces[0], cache_write_1h_tokens=pieces[1],
                     cache_write_tokens=write, tokens_total=total)
        if desktop:
            event["input_basis"] = "includes_cache"
        if total is None and inp is not None and out is not None and (desktop or read == write == 0):
            event["tokens_total"] = _int(inp + out)
    result.append(event)
    return result


@contextmanager
def _read_transaction(path):
    with closing(sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=.2)) as db:
        db.execute("PRAGMA query_only=ON")
        db.execute("BEGIN")
        # BEGIN is deferred: anchor the WAL read mark before yielding control.
        db.execute("SELECT rowid FROM chat_message LIMIT 1").fetchone()
        yield db


def _desktop_page(db, src, cur, rows):
    facts = []
    last = cur.get("rowid", 0)
    batch = db.execute("""
        SELECT rowid,id,session_id,request_id,role,gmt_create,
            CASE WHEN length(token_info)<=8192 THEN token_info END,
            CASE WHEN length(model_info)<=8192 THEN model_info END
        FROM chat_message WHERE rowid>? ORDER BY rowid LIMIT ?
    """, (last, rows)).fetchall()
    for last, mid, sid, rid, role, ms, tokens, model in batch:
        usage = _object(tokens)
        if role != "assistant" and not usage:
            continue
        stamp = ms / 1000 if type(ms) is int and 10**12 <= ms < 10**13 else None
        facts.extend(_events(src, stamp, _text(sid), _text(_object(model).get("model_key")),
                             _text(mid), _text(rid), usage, desktop=True))
    return dict(facts=facts, next_cursor=dict(rowid=last), done=len(batch) < rows)


def _desktop(src, cur, rows):
    path = Path(src["path"])
    before = _db_version(path)
    if cur and cur.get("version") != before:
        raise ValueError("desktop snapshot changed; restart generation")
    with _read_transaction(path) as db:
        result = _desktop_page(db, src, cur, rows)
    if _db_version(path) != before:
        raise ValueError("desktop snapshot changed; restart generation")
    result["next_cursor"]["version"] = before
    return result


def _object(raw):
    if not raw:
        return {}
    try:
        value = json.loads(raw)
    except (ValueError, RecursionError, TypeError):
        return {}
    return value if isinstance(value, dict) else {}


def _line_events(src, row, state):
    if row.get("type") == "runtime-config":
        state["configured_model"] = _text(row.get("model"))
        return []
    msg = row.get("message")
    if row.get("type") != "assistant" or not isinstance(msg, dict):
        return []
    raw = _text(row.get("timestamp"), 48)
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00")) if raw else None
        stamp = dt.timestamp() if dt and dt.tzinfo else None
    except (ValueError, OverflowError, OSError):
        stamp = None
    usage = msg.get("usage")
    usage = usage if isinstance(usage, dict) else {}
    model = _text(msg.get("model"))
    # A configured model is not proof of the upstream model used by this call.
    request = _text(row.get("requestId")) or _text(usage.get("request_id"))
    mid = _text(msg.get("id")) or (None if request else _text(row.get("uuid")))
    facts = _events(src, stamp, _text(row.get("sessionId")), model, mid, request, usage)
    for fact in facts:
        fact["configured_model"] = state.get("configured_model")
        cwd = _text(row.get("cwd"), 4096)
        if cwd and cwd.startswith("/") and not cwd.startswith("//"):
            fact["project"] = os.path.normpath(cwd)
    return facts


def _append(src, cur, rows, size):
    path, root = Path(src["path"]), Path(src["root"])
    if root.is_symlink() or path.resolve() != root.resolve() / path.relative_to(root):
        raise OSError("symlink transcript")
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    facts = []
    with os.fdopen(fd, "rb") as f:
        st = os.fstat(fd)
        ident = [st.st_dev, st.st_ino]
        if not stat.S_ISREG(st.st_mode) or (cur and (cur["identity"] != ident or cur["offset"] > st.st_size)):
            raise ValueError("transcript replaced or truncated; restart generation")
        state = dict(cur) if cur else dict(identity=ident, offset=0)
        f.seek(state["offset"])
        remaining = size
        for _ in range(rows):
            if remaining <= 0:
                break
            line = f.readline(min(remaining, size))
            remaining -= len(line)
            if not line:
                break
            if not line.endswith(b"\n"):
                if len(line) < size and not state.get("discard"):
                    break  # retry incomplete line (or remaining batch budget) from its start
                if not state.get("discard"):
                    state["oversized_records"] = state.get("oversized_records", 0) + 1
                state["discard"] = True  # oversized record; never persist raw text in cursor
            elif not state.pop("discard", False):
                facts.extend(_line_events(src, _object(line), state))
            state["offset"] = f.tell()
        return dict(facts=facts, next_cursor=state, done=f.tell() >= st.st_size)


def _limits(budget):
    budget = budget or {}
    rows = max(1, min(int(budget.get("max_rows", 256)), 4096))
    size = max(1, min(int(budget.get("max_bytes", 262144)), 4 * 1024 * 1024))
    return rows, size


def read_batch(source, cursor=None, budget=None):
    rows, size = _limits(budget)
    if source["mode"] == "snapshot":
        return _desktop(source, cursor or {}, min(rows, max(1, size // 20480)))
    return _append(source, cursor or {}, rows, size)


class Provider:
    name = "qoder"

    def __init__(self, qoder_sources, qoder_cn_sources, home):
        self.cli_sources = qoder_sources
        self.cn_sources = qoder_cn_sources
        self.desktop_db = Path(home) / "Library/Application Support/Qoder/SharedClientCache/cache/db/local.db"

    def discover(self):
        return discover(self.cli_sources(), self.cn_sources(), self.desktop_db)

    read_batch = staticmethod(read_batch)

    @contextmanager
    def open_snapshot(self, source):
        if source["source_kind"] != "qoder_desktop":
            raise ValueError("not a desktop snapshot")
        token = uuid.uuid4().hex
        with _read_transaction(Path(source["path"])) as db:
            def read_page(cursor, budget):
                if cursor is not None and cursor.get("snapshot") != token:
                    raise ValueError("cursor belongs to another read transaction")
                rows, size = _limits(budget)
                result = _desktop_page(db, source, cursor or {}, min(rows, max(1, size // 20480)))
                result["next_cursor"]["snapshot"] = token
                return result
            yield read_page
