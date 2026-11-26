"""Incremental local usage analytics. Providers never run on a request thread."""

import base64
import csv
import hashlib
import io
import json
import math
import os
import sqlite3
import stat
import threading
import time
import uuid
from collections import deque
from contextlib import ExitStack, closing
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


class GenerationConflict(Exception):
    pass


class StoreNotReady(Exception):
    pass


BUDGET = {"max_rows": 256, "max_bytes": 256 * 1024}
EXPORT_MAX_BYTES = 8 * 1024 * 1024
# Bump for incompatible collector cursor, identity, attribution, or normalization changes.
PARSER_REVISION = 3
APPLICATION_ID = 0x41443441
SCOPE_FIELDS = ("agent", "account_id", "source_kind", "session_id", "model", "project")
COUNTS = ("tokens_total", "input_tokens", "output_tokens", "calls", "cache_read_tokens",
          "cache_write_tokens", "cache_write_5m_tokens", "cache_write_1h_tokens",
          "input_uncached_tokens", "reasoning_output_tokens")
VALUES = COUNTS + ("cost_usd", "credits", "latency_ms", "ttft_ms", "api_equivalent_usd")
ALIASES = {"cache_read_tokens": ("cache_read_input_tokens", "cached_input_tokens"),
           "cache_write_tokens": ("cache_creation_input_tokens",),
           "cache_write_5m_tokens": ("cache_creation_5m_input_tokens",),
           "cache_write_1h_tokens": ("cache_creation_1h_input_tokens",)}


def _dump(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def _stamp(path):
    s = os.lstat(path)
    if not stat.S_ISREG(s.st_mode):
        raise ValueError("unexpected source file type")
    return [s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def _signature(source):
    p = source["path"]
    sig = [_stamp(p)]
    if source["mode"] == "snapshot":
        try:
            sig.append(_stamp(str(p) + "-wal"))
        except FileNotFoundError:
            sig.append(None)
    return sig


def _anchor(path, length):
    # Detect truncate-and-regrow/replacement across restarts without a full hash.
    fd = os.open(path,os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError("unexpected source file type")
        first = stream.read(min(length, 1024))
        stream.seek(max(0, length - 2048))
        return hashlib.sha256(first + stream.read(min(length, 2048))).hexdigest()


def _num(value):
    return type(value) in (float, int) and 0 <= value <= 2**63-1 and math.isfinite(value)


def _fact(raw):
    if raw.get("kind") not in ("call", "usage_delta", "turn_summary"):
        raise ValueError("invalid fact kind")
    for name in ("agent", "event_key", "source_kind"):
        if not isinstance(raw.get(name), str) or not 0 < len(raw[name]) <= 1024:
            raise ValueError("invalid fact identity")
    if raw.get("basis") not in ("recorded", "sampled"):
        raise ValueError("invalid measurement basis")
    payload = {k:raw.get(k) for k in (*SCOPE_FIELDS, "kind", "basis", "input_basis",
                                        "parent_session_id", "turn_id")}
    if any(v is not None and (not isinstance(v, str) or len(v) > 8192)
           for v in payload.values()):
        raise ValueError("invalid fact dimension")
    for k in VALUES + ("observed_at", "first_observed_at", "last_observed_at", "generation_ms"):
        value = raw.get(k)
        for alias in ALIASES.get(k, ()):
            if value is None:
                value = raw.get(alias)
        payload[k] = value if _num(value) else None
    if payload["input_uncached_tokens"] is None:
        basis, total, cache = payload["input_basis"], payload["input_tokens"], payload["cache_read_tokens"]
        if basis in ("uncached", "exclusive", "excludes_cache", "uncached_input"):
            payload["input_uncached_tokens"] = total
        elif (basis in ("inclusive", "includes_cache", "includes_cached_input")
              and total is not None and cache is not None and cache <= total):
            payload["input_uncached_tokens"] = total-cache
    payload.pop("api_equivalent_usd", None)
    flag = raw.get("speed_includes_wait")
    payload["speed_includes_wait"] = flag if type(flag) is bool else None
    if "speed_output_tokens" in raw:
        matched = raw["speed_output_tokens"]
        payload["speed_output_tokens"] = matched if type(matched) is int and _num(matched) else None
    payload["call_observed"] = raw.get("call_observed") is True
    if payload["agent"] == "claude" and payload["kind"] == "call":
        # A collapsed stream's first/last timestamps need not identify this counter.
        end = raw.get("output_observed_at")
        if "output_observed_at" not in raw and payload["last_observed_at"] in (None,payload["observed_at"]):
            end = payload["observed_at"]
        payload["output_observed_at"] = end if _num(end) else None
    return _dump([raw["agent"], raw["event_key"]]), payload


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY, epoch TEXT, rev INTEGER, stamp REAL, status TEXT);
CREATE TABLE IF NOT EXISTS sources(id TEXT PRIMARY KEY, scope TEXT NOT NULL, live TEXT NOT NULL,
    work TEXT NOT NULL, signature TEXT NOT NULL, anchor TEXT, cursor TEXT, done INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS owners(src TEXT, gen TEXT, k TEXT, body TEXT NOT NULL, stamp REAL,
    PRIMARY KEY(src,gen,k)) WITHOUT ROWID;
CREATE INDEX IF NOT EXISTS owners_lookup ON owners(k,src,gen);
CREATE TABLE IF NOT EXISTS facts(k TEXT PRIMARY KEY, ts REAL, body TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS facts_time ON facts(ts);
"""


def _dirty_source(db,key):
    db.execute("INSERT OR IGNORE INTO dirty SELECT k FROM owners WHERE src=?", (key,))


def _publish(db):
    # TEMP is file-backed; wholesale source replacement must not materialize its keys in RAM.
    db.execute("""INSERT INTO facts
        SELECT k,json_extract(body,'$.observed_at'),body FROM (
            SELECT o.k,owner_fact(o.body,o.stamp,o.src) AS body
            FROM dirty d CROSS JOIN owners o ON o.k=d.k
            JOIN sources s ON s.id=o.src AND s.live=o.gen GROUP BY o.k
        ) WHERE true ON CONFLICT(k) DO UPDATE SET ts=excluded.ts,body=excluded.body
        WHERE facts.body<>excluded.body""")
    db.execute("""DELETE FROM facts WHERE k IN (SELECT k FROM dirty) AND NOT EXISTS
        (SELECT 1 FROM owners o JOIN sources s ON s.id=o.src AND s.live=o.gen WHERE o.k=facts.k)""")
    db.execute("DELETE FROM dirty")


_TIMING = ("output_observed_at","generation_ms","latency_ms","ttft_ms","speed_includes_wait","speed_output_tokens")


def _counter_rank(f):
    count, end = f.get("output_tokens"), f.get("output_observed_at")
    return (-(count if count is not None else -1), end if end is not None else math.inf,
            -sum(f.get(k) is not None for k in ("generation_ms","latency_ms","ttft_ms")))


class _OwnerFact:
    """Keep a single owner's evidence bundle. Decode only when a second live copy exists."""
    def __init__(self):
        self.body = self.rank = None
        self.claude = False
        self.first = math.inf
        self.last = -math.inf

    def _consider(self, body, stamp, src):
        f = json.loads(body) if self.claude else None
        if self.claude:
            rank = (*_counter_rank(f),src)
            for key in ("first_observed_at","observed_at"):
                if f.get(key) is not None:
                    self.first = min(self.first,f[key])
            for key in ("last_observed_at","observed_at"):
                if f.get(key) is not None:
                    self.last = max(self.last,f[key])
        else:
            rank = (-(stamp if stamp is not None else -math.inf),src)
        if self.rank is None or rank < self.rank:
            self.rank,self.body = rank,body

    def step(self, body, stamp, src):
        if self.body is None:
            self.body,self.stamp,self.src = body,stamp,src
            return
        if self.rank is None:
            f = json.loads(self.body)
            self.claude = f.get("agent") == "claude" and f.get("kind") == "call"
            self._consider(self.body,self.stamp,self.src)
        self._consider(body,stamp,src)

    def finalize(self):
        if not self.claude:
            return self.body
        winner = json.loads(self.body)
        if math.isfinite(self.first):
            winner["observed_at"] = winner["first_observed_at"] = self.first
        if math.isfinite(self.last):
            winner["last_observed_at"] = self.last
        return _dump(winner)


def _merge_claude(old,new):
    a,b = old.get("observed_at"),new.get("observed_at")
    time_fields = [x for x in (a,b,old.get("first_observed_at"),new.get("first_observed_at")) if x is not None]
    latest = [x for x in (a,b,old.get("last_observed_at"),new.get("last_observed_at")) if x is not None]
    result = {**old,**{k:v for k,v in new.items() if v is not None}}
    paired = min((old,new),key=_counter_rank)
    for k in _TIMING:
        if k in paired:
            result[k] = paired[k]
        else:
            result.pop(k,None)
    for k in COUNTS:
        vs = [v for v in (old.get(k),new.get(k)) if v is not None]
        result[k] = max(vs,default=None)
    result["observed_at"] = result["first_observed_at"] = min(time_fields,default=None)
    result["last_observed_at"] = max(latest,default=None)
    counts = [result.get(k) for k in ("input_uncached_tokens","output_tokens","cache_read_tokens","cache_write_tokens")]
    if None not in counts:
        result["tokens_total"] = sum(counts)
    return result


def _revision(db):
    db.execute("UPDATE meta SET rev=rev+1,stamp=?", (time.time(),))


class AnalyticsStore:
    def __init__(self, path, providers):
        self.path = Path(path)
        self.providers = tuple(providers)
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread = None
        self._last_scan_request = None
        self._state = {"status":"cold", "scanning":False, "batches":0, "errors":0}

    def health(self):
        with self._lock:
            return dict(self._state)

    def request_scan(self, *, min_interval=0):
        with self._lock:
            if self._stop.is_set():
                return
            now = time.monotonic()
            if (min_interval and self._last_scan_request is not None
                    and now - self._last_scan_request < min_interval):
                return
            self._last_scan_request = now
            self._wake.set()
            if self._thread is None:
                self._thread = threading.Thread(target=self._worker, name="v4-analytics", daemon=True)
                self._thread.start()

    def close(self):
        with self._lock:
            self._stop.set()
            self._wake.set()
            thread = self._thread
        if thread and thread != threading.current_thread():
            thread.join(timeout=2)

    def _writer(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
                raise PermissionError("unsafe analytics database")
            if info.st_mode & 0o077:
                os.fchmod(fd,0o600)
        finally:
            os.close(fd)
        db = sqlite3.connect(self.path, timeout=1)
        try:
            db.row_factory = sqlite3.Row
            db.create_aggregate("owner_fact",3,_OwnerFact)
            app_id = db.execute("PRAGMA application_id").fetchone()[0]
            revision = db.execute("PRAGMA user_version").fetchone()[0]
            if app_id not in (0,APPLICATION_ID) or revision > PARSER_REVISION:
                raise ValueError("unrecognized analytics database version")
            if not app_id:
                tables = {r[0] for r in db.execute("SELECT name FROM sqlite_schema WHERE type='table'")}
                if tables and not {"meta","sources","owners","facts"}.issubset(tables):
                    raise ValueError("not a legacy analytics store")
            db.execute("PRAGMA journal_mode=WAL")
            db.execute("PRAGMA temp_store=FILE")
            db.execute("CREATE TEMP TABLE dirty(k TEXT PRIMARY KEY) WITHOUT ROWID")
            db.executescript(SCHEMA)
            with db:
                if revision != PARSER_REVISION:
                    for table in ("facts","owners","sources","meta"):
                        db.execute("DELETE FROM "+table)
                    db.execute(f"PRAGMA user_version={PARSER_REVISION}")
                db.execute(f"PRAGMA application_id={APPLICATION_ID}")
                db.execute("INSERT OR IGNORE INTO meta VALUES(1,?,0,?,'partial')",
                           (uuid.uuid4().hex, time.time()))
            return db
        except BaseException:
            db.close()
            raise

    def _worker(self):
        while not self._stop.is_set():
            self._wake.wait()
            self._wake.clear()
            if self._stop.is_set():
                break
            with self._lock:
                self._state["scanning"] = True
            try:
                with closing(self._writer()) as db:
                    self._scan(db)
            except Exception as exc:
                self._error(exc)
            finally:
                with self._lock:
                    self._state["scanning"] = False

    def _error(self, exc):
        with self._lock:
            self._state.update(status="partial", errors=self._state["errors"]+1,
                               last_error=type(exc).__name__)

    def _scan(self, db):
        initial_errors = self.health()["errors"]
        inventory, complete = {}, set()
        for provider in self.providers:
            try:
                result = provider.discover()
                found = {}
                for src in result["sources"]:
                    if src["mode"] not in ("append","snapshot"):
                        raise ValueError("invalid source mode")
                    key = _dump([src["scope"],src["source_id"]])
                    if key in found or key in inventory:
                        raise ValueError("duplicate source")
                    found[key] = (provider,src)
                inventory.update(found)
                complete.update(result["complete_scopes"])
            except Exception as exc:
                self._error(exc)
        for row in db.execute("SELECT id,scope FROM sources").fetchall():
            if row["scope"] not in complete and row["id"] not in inventory:
                self._error(FileNotFoundError())
            if row["scope"] in complete and row["id"] not in inventory:
                with db:
                    _dirty_source(db,row["id"])
                    db.execute("DELETE FROM owners WHERE src=?", (row["id"],))
                    db.execute("DELETE FROM sources WHERE id=?", (row["id"],))
                    _publish(db)
                    _revision(db)
        jobs = []
        for key,(provider,src) in inventory.items():
            if self._stop.is_set():
                return
            try:
                sig = _signature(src)
                old = db.execute("SELECT * FROM sources WHERE id=?", (key,)).fetchone()
                if old and old["signature"] == _dump(sig) and old["done"]:
                    continue
                jobs.append((max(s[3] for s in sig if s),key,provider,src,sig))
            except Exception as exc:
                self._error(exc)
        jobs = deque(sorted(jobs, key=lambda j:-j[0]))
        if jobs:
            self._status(db,"partial")
        # A wake during discovery cannot cancel the first round of useful work.
        first_round = len(jobs)
        rescan_after = time.monotonic()+15
        with ExitStack() as cleanup:
            pinned = {}
            while jobs and not self._stop.is_set():
                if (not first_round and not pinned and self._wake.is_set()
                        and time.monotonic() >= rescan_after):
                    return
                first_round = max(0,first_round-1)
                job = jobs.popleft()
                _,key,provider,src,sig = job
                pin = None
                try:
                    if src["mode"] == "snapshot" and hasattr(provider,"open_snapshot"):
                        if pinned and key not in pinned:
                            jobs.append(job)
                            continue
                        if key not in pinned:
                            stack = ExitStack()
                            cleanup.callback(stack.close)
                            # Fingerprint immediately before establishing the immutable read view.
                            sig = _signature(src)
                            page = stack.enter_context(provider.open_snapshot(src))
                            pinned[key] = (stack,page,sig,True)
                        pin = pinned[key]
                        sig = pin[2]
                    with db:
                        done = self._batch(db,key,provider,src,sig,pin)
                    with self._lock:
                        self._state["batches"] += 1
                    if not done:
                        jobs.append(job)
                        if pin:
                            pinned[key] = (*pin[:3],False)
                    elif pin:
                        pinned.pop(key)[0].close()
                    self._stop.wait(0.002)
                except Exception as exc:
                    if key in pinned:
                        pinned.pop(key)[0].close()
                    self._error(exc)
        if not self._stop.is_set():
            self._status(db,"ready" if self.health()["errors"] == initial_errors else "partial")

    def _status(self, db, status):
        with db:
            changed = db.execute("UPDATE meta SET status=? WHERE status<>?", (status,status))
            if changed.rowcount:
                _revision(db)
        with self._lock:
            self._state["status"] = status

    def _batch(self, db, key, provider, src, sig, pin=None):
        old = db.execute("SELECT * FROM sources WHERE id=?", (key,)).fetchone()
        signature = _dump(sig)
        changed = old is None or old["signature"] != signature or bool(pin and pin[3])
        live = old["live"] if old else uuid.uuid4().hex
        work = old["work"] if old else live
        cursor = json.loads(old["cursor"]) if old and old["cursor"] else None
        anchor = old["anchor"] if old else None
        if changed:
            append = False
            if old and src["mode"] == "append":
                before = json.loads(old["signature"])[0]
                append = (before[:2] == sig[0][:2] and before[2] < sig[0][2]
                          and _anchor(src["path"],before[2]) == anchor)
            if not append and (old or src["mode"] == "snapshot"):
                if work != live:
                    db.execute("DELETE FROM owners WHERE src=? AND gen=?", (key,work))
                work, cursor = uuid.uuid4().hex, None
            if src["mode"] == "append":
                anchor = _anchor(src["path"],sig[0][2])
        def verify():
            now = _signature(src)
            if now == sig:
                return
            if (src["mode"] == "append" and now[0][:2] == sig[0][:2]
                    and now[0][2] > sig[0][2] and _anchor(src["path"],sig[0][2]) == anchor):
                return
            raise ValueError("source changed during read")
        if pin:
            page = pin[1](cursor,dict(BUDGET))
        else:
            verify()
            page = provider.read_batch(src,cursor,dict(BUDGET))
            verify()
        next_cursor,done = page["next_cursor"],page["done"]
        if not done and _dump(next_cursor) == _dump(cursor):
            raise ValueError("adapter cursor did not advance")
        db.execute("INSERT OR REPLACE INTO sources VALUES(?,?,?,?,?,?,?,?)",
                   (key,src["scope"],live,work,signature,anchor,_dump(next_cursor),int(done)))
        keys = set()
        for raw in page["facts"]:
            k, payload = _fact(raw)
            keys.add(k)
            if payload["agent"]=="claude" and payload["kind"]=="call":
                prior = db.execute("SELECT body FROM owners WHERE src=? AND gen=? AND k=?",
                                   (key,work,k)).fetchone()
                if prior:
                    payload = _merge_claude(json.loads(prior[0]),payload)
            body = _dump(payload)
            stamp = payload.get("last_observed_at") or payload["observed_at"]
            db.execute("INSERT INTO owners VALUES(?,?,?,?,?) ON CONFLICT(src,gen,k) DO UPDATE SET "
                       "body=excluded.body,stamp=excluded.stamp", (key,work,k,body,stamp))
        if done and live != work:
            _dirty_source(db,key)
            db.execute("UPDATE sources SET live=? WHERE id=?", (work,key))
            db.execute("DELETE FROM owners WHERE src=? AND gen<>?", (key,work))
            live = work
        if work == live and (keys or done and db.execute("SELECT 1 FROM dirty LIMIT 1").fetchone()):
            db.executemany("INSERT OR IGNORE INTO dirty VALUES(?)",((k,) for k in keys))
            _publish(db)
            _revision(db)
        return done

    def query(self, params):
        return self._query(params, False)

    def export_csv(self, params):
        return self._query(params, True)

    def _query(self, params, export):
        p = _parameters(params)
        try:
            db = sqlite3.connect(self.path.absolute().as_uri()+"?mode=ro", uri=True, timeout=0.25)
        except sqlite3.OperationalError as exc:
            raise StoreNotReady("analytics unavailable") from exc
        with closing(db):
            db.execute("BEGIN")
            try:
                if db.execute("PRAGMA user_version").fetchone()[0] != PARSER_REVISION:
                    raise StoreNotReady("analytics parser upgrade pending")
                epoch,rev,stamp,status = db.execute("SELECT epoch,rev,stamp,status FROM meta").fetchone()
            except (sqlite3.OperationalError,TypeError) as exc:
                raise StoreNotReady("analytics not initialized") from exc
            from v4_pricing import PRICE_SNAPSHOT, api_equivalent_usd
            # Price-table updates and midnight on a relative interval invalidate old exports too.
            bounds = hashlib.sha256(_dump([p["start"],p["end"],p["timezone"]]).encode()).hexdigest()[:16]
            generation = f"{epoch}:{rev}:{PRICE_SNAPSHOT}:{bounds}"
            if p.get("generation") is not None and p["generation"] != generation:
                raise GenerationConflict("analytics changed; refresh the selection")
            signature = hashlib.sha256(_dump({k:v for k,v in p.items()
                if k not in ("generation","cursor","limit")}).encode()).hexdigest()
            offset = 0
            if p.get("cursor"):
                try:
                    gen,scope,offset = json.loads(base64.urlsafe_b64decode(p["cursor"]).decode())
                    if scope != signature or type(offset) is not int or not 0 <= offset < 2**63:
                        raise ValueError()
                except (ValueError,TypeError,UnicodeError) as exc:
                    raise ValueError("invalid analytics cursor") from exc
                if gen != generation:
                    raise GenerationConflict("analytics page expired")
            where,args = ["ts>=?", "ts<?", "json_extract(body,'$.kind') <> 'turn_summary'"], [p["start"],p["end"]]
            for name in (*SCOPE_FIELDS,"basis"):
                if name in p:
                    where.append(f"json_extract(body,'$.{name}')=?")
                    args.append(p[name])
            for name,value in p.get("group_filters", ()):
                # IS supports bound NULL without sacrificing literal string identities.
                where.append(f"json_extract(body,'$.{name}') IS ?")
                args.append(value)
            if "agents" in p:
                where.append("json_extract(body,'$.agent') IN ("+",".join("?" for _ in p["agents"])+")")
                args.extend(p["agents"])
            zone = ZoneInfo(p["timezone"])
            db.create_function("local_day",1,lambda ts: datetime.fromtimestamp(ts,zone).date().isoformat())
            # Unsupported prices are null, never substituted with provider bills or credits.
            class Aggregate(_Aggregate):
                price = staticmethod(api_equivalent_usd)
            db.create_aggregate("fold_usage",1,Aggregate)
            base = " FROM facts WHERE " + " AND ".join(where)
            basis = "json_extract(body,'$.basis')"
            def slices(group):
                if group == "day":
                    fields = ["local_day(ts)"]
                else:
                    fields = [f"json_extract(body,'$.{x}')" for x in group]
                dims = ",".join([basis]+fields)
                sql = f"SELECT {dims},fold_usage(body) AS payload" + base + " GROUP BY " + dims
                return sql,dims
            dimension = p["dimension"]
            fields = ("agent","account_id","source_kind","session_id") if dimension == "session" else (dimension,)
            sql,dims = slices(fields)
            sort = p["sort"]
            if sort == "key":
                order = dims
            else:
                order = f"json_extract(payload,'$.metrics.{sort}') DESC,"+dims
            sql += " ORDER BY "+order
            def group_rows():
                for item in db.execute(sql+("" if export else " LIMIT ? OFFSET ?"),
                                       args+([] if export else [p["limit"]+1,offset])):
                    values = item[1:-1]
                    row = {**json.loads(item[-1]),"basis":item[0],**dict(zip(fields,values))}
                    row.pop("_agents")
                    label = values[-1]
                    if dimension == "project" and label:
                        label = Path(label).name or label
                    row.update(key=_dump([item[0],*values]),label=label)
                    yield row
            if export:
                return _csv(group_rows())
            rows = list(group_rows())
            more = len(rows) > p["limit"]
            # A ranked group covers matching facts, just like its row and CSV export.
            # Only an ungrouped overview promises coverage of every selected agent.
            group_scoped = p.get("group_filters") or any(k in p for k in ("agent","model","project","session_id"))
            expected_agents = set() if group_scoped else set(p.get("agents",()))
            def collect(group):
                stmt,order_by = slices(group)
                result = []
                for row in db.execute(stmt+" ORDER BY "+order_by,args):
                    item = json.loads(row[-1])
                    observed = set(item.pop("_agents"))
                    if expected_agents-observed:
                        for m in ("cost_usd","api_equivalent_usd"):
                            if item["metrics"][m] is not None:
                                item["metrics"][m],item["quality"][m] = None,"partial"
                    result.append(dict(item,basis=row[0],**({"day":row[1]} if group=="day" else {})))
                return result
            undated = db.execute("SELECT COUNT(*) FROM facts WHERE ts IS NULL").fetchone()[0]
            return dict(start=p["start"],end=p["end"],timezone=p["timezone"],as_of=stamp,
                        coverage={"store_undated_facts":undated},
                        generation=generation,status=status,summary=collect(()),series=collect("day"),
                        rows=rows[:p["limit"]],next_cursor=base64.urlsafe_b64encode(
                            _dump([generation,signature,offset+p["limit"]]).encode()).decode() if more else None)


def _parameters(params):
    if not isinstance(params,dict) or any(not isinstance(v,(int,float,str)) or isinstance(v,bool)
                                          for v in params.values()):
        raise ValueError("expected scalar analytics parameters")
    p = params.copy()
    allowed = set(SCOPE_FIELDS) | {"timezone","start","end","period","dimension","sort","generation",
                                   "cursor","limit","agents","basis","group_filters"}
    if p.keys()-allowed:
        raise ValueError("unexpected analytics parameter")
    if "group_filters" in p:
        raw = p["group_filters"]
        if not isinstance(raw,str):
            raise ValueError("invalid analytics group filters")
        items = json.loads(raw)
        if (not isinstance(items,list) or not 1 <= len(items) <= 16
                or any(not isinstance(item,list) or len(item)!=2
                       or item[0] not in ("agent","model","project")
                       or not (item[1] is None or isinstance(item[1],str)) for item in items)):
            raise ValueError("invalid analytics group filters")
        p["group_filters"] = items
    p.setdefault("timezone","UTC")
    try:
        zone = ZoneInfo(p["timezone"])
    except (ZoneInfoNotFoundError,TypeError,ValueError) as exc:
        raise ValueError("unknown timezone") from exc
    if "start" in p or "end" in p:
        try:
            start,end = float(p["start"]),float(p["end"])
        except (KeyError,ValueError,OverflowError) as exc:
            raise ValueError("invalid time interval") from exc
    else:
        days = {"today":1,"7d":7,"30d":30}.get(p.get("period","7d"))
        if not days:
            raise ValueError("unknown period")
        end_day = datetime.now(zone).date()+timedelta(days=1)
        start,end = (datetime.combine(d,datetime.min.time(),zone).timestamp()
                     for d in (end_day-timedelta(days=days),end_day))
    if not (0 <= start < end <= 253402214400 and end-start <= 366*86400):
        raise ValueError("invalid time interval")
    p.update(start=start,end=end)
    if "agents" in p:
        p["agents"] = sorted(set(str(p["agents"]).split(","))-{""})
        if len(p["agents"])>32:
            raise ValueError("too many agents")
    if p.setdefault("dimension","agent") not in ("agent","model","project","session"):
        raise ValueError("unknown dimension")
    if p.setdefault("sort","tokens_total") not in ("tokens_total","cost_usd","calls","key"):
        raise ValueError("unknown sort")
    if "basis" in p and p["basis"] not in ("recorded","sampled"):
        raise ValueError("unknown basis")
    p["limit"] = int(p.get("limit",100))
    if not 1 <= p["limit"] <= 500:
        raise ValueError("invalid page size")
    return p


def _speed_sample(f):
    n = f.get("speed_output_tokens", f["output_tokens"])
    if type(n) is not int or n < 20 or (f["output_tokens"] is not None and n > f["output_tokens"]):
        return None
    ms = f.get("generation_ms")
    wait = f.get("speed_includes_wait") is True
    if ms is None:
        latency, ttft = f["latency_ms"], f["ttft_ms"]
        if latency is None:
            return None
        if ttft is not None and 0 < ttft < latency:
            ms, wait = latency - ttft, False
        elif wait:
            ms = latency
        else:
            return None
    # Reject an implausible measured interval; do not rescue it with a slower fallback.
    if not 200 < ms <= 1_800_000 or n * 1000 > 3000 * ms:
        return None
    return n, ms, wait


class _Aggregate:
    def __init__(self):
        self.sums = {}
        self.known = {}
        self.expected = {}
        self.agents = set()
        self.qoder_sources = set()
        self.paired_output = self.paired_ms = self.pairs = self.wait_pairs = 0

    def step(self, body):
        f = json.loads(body)
        self.agents.add(f["agent"])
        if f["agent"] == "qoder":
            self.qoder_sources.add(f["source_kind"])
        if f["kind"] == "call" and f["basis"] == "recorded":
            short,long = f["cache_write_5m_tokens"],f["cache_write_1h_tokens"]
            if f["cache_write_tokens"] == 0 and short in (0,None) and long in (0,None):
                short = long = 0
            if short is not None and long is not None and f["cache_write_tokens"] in (None,short+long):
                f["api_equivalent_usd"] = self.price(f["agent"],f["model"],dict(
                    input_tokens=f["input_uncached_tokens"],output_tokens=f["output_tokens"],
                    cache_read_tokens=f["cache_read_tokens"],cache_write_5m_tokens=short,
                    cache_write_1h_tokens=long))
        for k in VALUES:
            # Qoder emits distinct request-count and token observations, not two calls.
            if f["source_kind"] in ("qoder_desktop","qoder_cli","qoder_cn_cli"):
                if (k != "calls" and f["kind"] == "call"):
                    continue
                if k == "calls" and f["kind"] == "usage_delta" and f.get("call_observed"):
                    continue
            self.expected[k] = self.expected.get(k,0)+1
            v = f.get(k)
            if v is not None:
                self.known[k] = self.known.get(k,0)+1
                self.sums[k] = self.sums.get(k,0)+v
        pair = _speed_sample(f)
        if pair is not None:
            n, ms, wait = pair
            self.paired_output += n
            self.paired_ms += ms
            self.pairs += 1
            self.wait_pairs += wait

    def finalize(self):
        metrics,quality,subs = {},{},{}
        for k in VALUES:
            n = self.known.get(k,0)
            val = self.sums.get(k)
            if n and k in ("latency_ms","ttft_ms"):
                val /= n
            q = "unknown" if not n else "complete" if n == self.expected[k] else "partial"
            quality[k],metrics[k],subs[k] = q,val if q=="complete" else None,val
        for k,n in (("latency_samples",self.known.get("latency_ms",0)),
                    ("ttft_samples",self.known.get("ttft_ms",0)),("speed_samples",self.pairs),
                    ("speed_wait_samples",self.wait_pairs)):
            metrics[k],quality[k],subs[k] = n,"complete",n
        speed = self.paired_output*1000/self.paired_ms if self.pairs else None
        speed_q = "unknown" if not self.pairs else "complete" if self.pairs == self.expected.get("latency_ms") else "partial"
        metrics["speed_output_tps"] = speed if speed_q=="complete" else None
        quality["speed_output_tps"],subs["speed_output_tps"] = speed_q,speed
        overlap = {"qoder_desktop","qoder_cli"} <= self.qoder_sources
        if overlap:
            for k in metrics:
                metrics[k],quality[k],subs[k] = None,"unknown",None
        return _dump(dict(metrics=metrics,quality=quality,known_subtotals=subs,
                          possible_overlap=overlap,_agents=sorted(self.agents)))


def _csv(rows):
    out = io.StringIO(newline="")
    size = 0
    class Limited:
        def write(self, line):
            nonlocal size
            size += len(line.encode("utf-8"))
            if size > EXPORT_MAX_BYTES:
                raise ValueError("export too large")
            return out.write(line)
    writer = csv.writer(Limited())
    dims = ("basis","key","label",*SCOPE_FIELDS)
    metrics = (*VALUES,"latency_samples","ttft_samples","speed_samples","speed_output_tps","speed_wait_samples")
    writer.writerow([*dims,*metrics,*("quality_"+k for k in metrics),*("known_"+k for k in metrics)])
    def safe(v):
        if isinstance(v,str) and (v.startswith(("\t","\r","\n")) or v.lstrip().startswith(("=","+","-","@"))):
            return "'"+v
        return v
    for row in rows:
        writer.writerow([*(safe(row.get(k)) for k in dims),
                         *(row[a][k] for a in ("metrics","quality","known_subtotals") for k in metrics)])
    return out.getvalue()
