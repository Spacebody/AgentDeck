#!/usr/bin/env python3
"""Read-only runtime smoke check; report timings and counts, never transcript data."""
import concurrent.futures
import json
import time
import urllib.request
from pathlib import Path


def request(path, timeout=15):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    started = time.monotonic()
    with opener.open('http://127.0.0.1:7777' + path, timeout=timeout) as response:
        result = json.load(response)
    return result, (time.monotonic() - started) * 1000


def main():
    expected = (Path(__file__).resolve().parents[1] / 'VERSION').read_text().strip()
    initial, _ = request('/api/health')
    assert initial['version'] == expected, 'installed version mismatch'
    timings = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        work = {path: pool.submit(request, path, 240) for path in (
            '/api/usage', '/api/sessions?limit=20', '/api/quota?cached=1')}
        for _ in range(30):
            health, elapsed = request('/api/health')
            assert health['ok'] and health['instance_id'] == initial['instance_id'], \
                'backend restarted during runtime check'
            timings.append(elapsed)
            time.sleep(1)
        summaries = {}
        for path, future in work.items():
            result, elapsed = future.result()
            assert isinstance(result, dict), 'invalid API response'
            summaries[path] = {'milliseconds': round(elapsed, 1)}
        sessions, _ = request('/api/sessions?limit=20')
        assert len(sessions['sessions']) <= 20
        summaries['sessions_total'] = sessions['total']
    print(json.dumps({'version': expected, 'health_samples': len(timings),
                      'health_max_ms': round(max(timings), 1),
                      'health_mean_ms': round(sum(timings) / len(timings), 1),
                      'endpoints': summaries}, indent=2))


if __name__ == '__main__':
    main()
