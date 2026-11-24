"""Read-only acceptance check of the installed loopback daemon; never prints project data."""
import csv
import io
import json
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import ProxyHandler, build_opener


def main():
    client = build_opener(ProxyHandler({}))

    def get(path, params=None):
        url = "http://127.0.0.1:7777/api/" + path
        with client.open(url + ("?" + urlencode(params) if params else ""), timeout=30) as r:
            return r.read()

    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        health = json.loads(get("health"))
        if not health["version"].startswith("4."):
            raise SystemExit("Installed daemon is not v4")
        if health.get("analytics", {}).get("status") != "ready":
            time.sleep(2)
            continue
        try:
            for basis in ("recorded", "sampled"):
                params = dict(period="7d", dimension="agent", basis=basis, limit=100)
                page = json.loads(get("analytics", params))
                data = get("analytics/export", dict(params, generation=page["generation"]))
                rows = {r["key"]: r for r in csv.DictReader(io.StringIO(data.decode()))}
                if page["next_cursor"] or len(rows) != len(page["rows"]):
                    raise SystemExit("Page and CSV group counts differ")
                for row in page["rows"]:
                    export = rows[row["key"]]
                    for key, value in row["metrics"].items():
                        raw = export[key]
                        if (float(raw) if raw else None) != value or export["quality_" + key] != row["quality"][key]:
                            raise SystemExit("Page and CSV disagree on " + key)
                print(f"{basis}: {len(rows)} agent groups; matching CSV values and coverage")
            print("Installed", health["version"], "analytics", health["analytics"])
            return
        except HTTPError as exc:
            if exc.code not in (409, 503):
                raise
            time.sleep(1)
    raise SystemExit("No stable query/export pair before deadline")


if __name__ == "__main__":
    main()
