"""Read-only v4 analytics provider. AG's generation wire layout is not a public API."""

from contextlib import closing, contextmanager
import hashlib
import os
from pathlib import Path
import re
import sqlite3
import stat

import antigravity_usage


name = "antigravity_generations"
APP = "antigravity_app_db"
CLI = "antigravity_cli_db"
SAMPLE = "antigravity_cli_statusline"
UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", re.I)
MAX_BLOB = 8 * 1024 * 1024
MAX_COUNT = 100_000_000


def discover(*, home=None):
    home = Path(home or Path.home())
    scopes = [(APP, home / ".gemini/antigravity/conversations"),
              (CLI, home / ".gemini/antigravity-cli/conversations"),
              (SAMPLE, home / "Library/Application Support/AgentDeck/antigravity-usage")]
    sources, complete = [], []
    for scope, root in scopes:
        try:
            if not stat.S_ISDIR(root.lstat().st_mode):
                continue
            with os.scandir(root) as entries:
                for entry in entries:
                    sid, ext = os.path.splitext(entry.name)
                    if not (entry.name == "usage.sqlite3" if scope == SAMPLE
                            else ext == ".db" and UUID.fullmatch(sid)):
                        continue
                    if entry.is_file(follow_symlinks=False):
                        sources.append(dict(scope=scope, source_id=entry.name, path=entry.path,
                                            source_kind=scope, mode="snapshot"))
            complete.append(scope)
        except OSError:
            continue
    return {"sources": sorted(sources, key=lambda s: (s["scope"], s["source_id"])),
            "complete_scopes": complete}


def _var(data, pos):
    value = 0
    for shift in range(0, 70, 7):
        if pos >= len(data):
            break
        b = data[pos]
        pos += 1
        if shift == 63 and b > 1:
            break
        value |= (b & 127) << shift
        if b < 128:
            return value, pos
    raise ValueError("invalid varint")


def _fields(data, pos=0):
    while pos < len(data):
        tag, pos = _var(data, pos)
        field, wire = divmod(tag, 8)
        if not field or field >= 1 << 29:
            raise ValueError("invalid field")
        if wire == 0:
            value, pos = _var(data, pos)
        else:
            if wire == 2:
                length, pos = _var(data, pos)
            elif wire in (1, 5):
                length = 8 if wire == 1 else 4
            else:
                raise ValueError("unsupported wire type")
            if length > len(data) - pos:
                raise ValueError("truncated field")
            value = data[pos:pos + length]
            pos += length
        yield field, wire, value, pos


def _first(data, field, wire):
    return next((v for f, w, v, _ in _fields(data) if (f, w) == (field, wire)), None)


def _timestamp(data):
    seconds = _first(data, 1, 0) if data is not None else None
    return seconds if seconds is not None and 1577836800 <= seconds <= 1 << 34 else None


def _fallback(db, data):
    remaining_refs, remaining_bytes = 128, MAX_BLOB
    for f, w, packed, _ in _fields(data):
        if (f, w) != (2, 2):
            continue
        pos = 0
        while pos < len(packed):
            if remaining_refs == 0 or remaining_bytes == 0:
                return None
            remaining_refs -= 1
            ref, pos = _var(packed, pos)
            if ref > 2**63-1:
                continue
            row = db.execute("SELECT metadata FROM steps WHERE idx=? AND length(metadata)<=?",
                             (ref, remaining_bytes)).fetchone()
            if row and isinstance(row[0], bytes):
                remaining_bytes -= len(row[0])
                try:
                    stamp = _timestamp(_first(memoryview(row[0]), 1, 2))
                except ValueError:
                    continue
                if stamp is not None:
                    return stamp
    return None


def _duration_ms(data):
    parts = {}
    try:
        for f, w, v, _ in _fields(data):
            if f not in (1, 2) or w != 0 or f in parts:
                return None
            parts[f] = v
    except ValueError:
        return None
    sec, ns = parts.get(1, 0), parts.get(2, 0)
    if sec < 86400 and ns < 10**9:
        return sec * 1000 + ns / 10**6
    return None


def _generation(data):
    counts, model, stamp = {}, None, None
    timings = {}
    for field, wire, value, _ in _fields(data):
        if field in (11, 12):
            timings[field] = _duration_ms(value) if wire == 2 and field not in timings else None
            continue
        if wire != 2:
            continue
        if field == 4:
            for f, w, v, _ in _fields(value):
                if w == 0 and f in (2, 3, 5, 9, 10):
                    if v > MAX_COUNT or f in counts:
                        raise ValueError("ambiguous counter")
                    counts[f] = v
        elif field == 9:
            stamp = _timestamp(_first(value, 4, 2))
        elif field == 19 and len(value) <= 120:
            candidate = bytes(value)
            if re.fullmatch(rb"[A-Za-z0-9][A-Za-z0-9._:/+() -]*", candidate):
                model = candidate.decode("ascii")
    if not counts:
        return None
    inp = counts.get(2, 0) + counts.get(5, 0) if 2 in counts or 5 in counts else None
    out = counts.get(3)
    if out is None and 9 in counts and 10 in counts:
        out = counts[9] + counts[10]
    if out is not None and any(counts.get(k, 0) > out for k in (9, 10)):
        raise ValueError("inconsistent output")
    first, stream = timings.get(11), timings.get(12)
    # Output includes reasoning; field 12 times only the streamed reply.
    reply = counts.get(10)
    if out is not None and 9 in counts:
        derived = out - counts[9]
        reply = derived if reply is None or reply == derived else None
    return dict(observed_at=stamp, input_tokens=inp, input_uncached_tokens=counts.get(2),
                cache_read_tokens=counts.get(5), output_tokens=out,
                reasoning_output_tokens=counts.get(9), model=model, calls=1,
                tokens_total=inp + out if inp is not None and out is not None else None,
                latency_ms=first + stream if first is not None and stream is not None else None,
                ttft_ms=first, generation_ms=stream if stream and reply is not None else None,
                speed_output_tokens=reply)


def _recorded(db, scope, sid, cursor, rows, byte_limit):
    idx, offset, ordinal = (cursor.get(k, 0) for k in ("idx", "offset", "ordinal"))
    facts, work, nbytes = [], 0, 0
    has_steps = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='steps'").fetchone()
    lineage = hashlib.sha256(sid.encode("ascii")).hexdigest()
    while work < rows and nbytes < byte_limit:
        row = db.execute("SELECT idx,CASE WHEN length(data)<=? THEN data END FROM gen_metadata "
                         "WHERE idx>=? ORDER BY idx LIMIT 1", (MAX_BLOB, idx)).fetchone()
        if row is None:
            return facts, {}, True
        current, blob = row
        if current != idx:
            offset = ordinal = 0
        if not isinstance(blob, bytes):
            raise ValueError("oversized or invalid generation metadata")
        view = memoryview(blob)
        nbytes += len(view)
        fallback = None
        needs_lookup = bool(has_steps)
        work_before = work
        try:
            for f, w, val, end in _fields(view, offset):
                if (f, w) != (1, 2):
                    continue
                key = f"{scope}:{lineage}:{current}:{ordinal}"
                ordinal += 1
                work += 1
                try:
                    fact = _generation(val)
                    if fact and fact["observed_at"] is None:
                        if needs_lookup:
                            needs_lookup = False
                            fallback = _fallback(db, view)
                        fact["observed_at"] = fallback
                    if fact and fact["observed_at"] is not None:
                        facts.append(dict(fact, event_key=key, agent="antigravity", account_id=None,
                                          source_kind=scope, kind="call", basis="recorded",
                                          project=None, cost_usd=None, session_id=sid))
                except ValueError:
                    pass
                if work >= rows and end < len(view):
                    return facts, dict(idx=current, offset=end, ordinal=ordinal), False
        except ValueError:
            pass  # A malformed outer field cannot be resynchronized within this row.
        work += work_before == work
        idx, offset, ordinal = current + 1, 0, 0
    return facts, dict(idx=idx, offset=offset, ordinal=ordinal), False


def _sampled(db, cursor, rows):
    after = cursor.get("hour", -1)
    facts = []
    batch = db.execute("SELECT hour,i,o FROM hourly WHERE hour>? ORDER BY hour LIMIT ?",
                       (after, rows)).fetchall()
    for hour, inp, out in batch:
        after = hour
        if not all(type(n) is int and n >= 0 for n in (hour, inp, out)) or hour % 3600:
            continue
        if inp + out >= 2**63:
            continue
        facts.append(dict(event_key=f"{SAMPLE}:{hour}", agent="antigravity", account_id=None,
                          source_kind=SAMPLE, kind="usage_delta", basis="sampled", observed_at=hour,
                          input_tokens=inp, output_tokens=out, tokens_total=inp+out, calls=None,
                          session_id=None, model=None, project=None, cost_usd=None))
    return facts, dict(hour=after), len(batch) < rows


def _identity(path):
    info = path.stat()
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


@contextmanager
def open_snapshot(source):
    """Yield a page reader on one snapshot; consume and close it on the opening thread."""
    path, scope = Path(source["path"]), source["scope"]
    immutable_id = None
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("not a regular source")
    if scope == SAMPLE and path.name == "usage.sqlite3":
        conn = antigravity_usage._database(path.parent, False)
    elif scope in (APP, CLI) and path.suffix == ".db" and UUID.fullmatch(path.stem):
        wal_present = Path(str(path) + "-wal").exists()
        if wal_present and not Path(str(path) + "-shm").is_file():
            raise OSError("WAL not ready for read-only access")
        # A closed WAL-mode DB may have neither sidecar. Avoid creating either.
        # No WAL frames are included in this view; invalidate it if the base changes.
        if not wal_present:
            with path.open("rb") as stream:
                wal_mode = stream.read(20)[18:20] == b"\x02\x02"
            if wal_mode:
                immutable_id = _identity(path)
                if Path(str(path) + "-wal").exists():
                    raise OSError("WAL appeared while opening snapshot")
        opt = "?mode=ro&immutable=1" if immutable_id is not None else "?mode=ro"
        conn = sqlite3.connect(path.absolute().as_uri() + opt, uri=True, timeout=0.25)
    else:
        raise ValueError("invalid source")
    with closing(conn) as db:
        db.execute("PRAGMA trusted_schema=OFF")
        db.execute("PRAGMA query_only=ON")
        db.execute("BEGIN")
        db.execute("SELECT count(*) FROM sqlite_master").fetchone()  # BEGIN alone is deferred.

        def check_base():
            if immutable_id is not None and _identity(path) != immutable_id:
                raise OSError("base changed during immutable snapshot")

        def read_page(cursor=None, budget=None):
            check_base()
            budget, cursor = budget or {}, cursor or {}
            rows = max(1, min(4096, budget.get("max_rows", 256)))
            byte_limit = max(1, budget.get("max_bytes", 262144))
            if scope == SAMPLE:
                result = _sampled(db, cursor, min(rows, max(1, byte_limit // 24)))
            else:
                result = _recorded(db, scope, path.stem.lower(), cursor, rows, byte_limit)
            check_base()
            facts, next_cursor, done = result
            return {"facts": facts, "next_cursor": next_cursor or None, "done": done}

        yield read_page


def read_batch(source, cursor=None, budget=None):
    """Single-page compatibility API. The byte budget is soft for indivisible blobs."""
    with open_snapshot(source) as page:
        return page(cursor, budget)
