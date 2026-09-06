import copy
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agentdeckd as daemon


class AuditBoundaryTests(unittest.TestCase):
    def test_manifest_rejects_mismatched_release_and_url_authority(self):
        for url in [
            'https://github.com/Spacebody/AgentDeck/releases/download/v2.8.2/AgentDeck-2.8.2.dmg',
            'https://user@github.com/Spacebody/AgentDeck/releases/download/v2.8.3/AgentDeck-2.8.3.dmg',
        ]:
            with self.assertRaises(ValueError):
                daemon._normalize_update_manifest({'version': '2.8.3', 'dmg': url})

    def test_invalid_disk_setting_types_and_ranges_are_normalized(self):
        result = daemon._clean_settings({'font_scale': 9999, 'refresh_interval': 'bad',
                                         'show_codex': [], 'quota_interval': float('inf')})
        self.assertEqual(result, {'font_scale': daemon.SETTING_RANGES['font_scale'][1]})

    def test_codex_stdio_rejects_unbounded_or_expired_buffer(self):
        client = daemon._CodexAppServerClient('/tmp')
        client._buffer = b'x' * (4 * 1024 * 1024 + 1)
        with self.assertRaisesRegex(RuntimeError, 'size limit'):
            client._read_message_locked(float('inf'))
        client._buffer = b'{}\n'
        with self.assertRaises(TimeoutError):
            client._read_message_locked(0)

    def test_invalid_http_bodies_never_reach_settings(self):
        for raw, length, expected in [
            (b'[]', '2', 400), (b'null', '4', 400),
            (b'{', '1', 400), (b'', '-1', 400),
            (b'', 'invalid', 400), (b'', str(1024 * 1024 + 1), 413),
        ]:
            with self.subTest(raw=raw, length=length):
                handler = object.__new__(daemon.Handler)
                handler.path = '/api/settings'
                handler.headers = {'Host': '127.0.0.1:7777',
                                   'Content-Type': 'application/json',
                                   'Content-Length': length}
                handler.rfile = io.BytesIO(raw)
                handler._send = mock.Mock()
                with mock.patch.object(daemon, 'api_settings_save') as save:
                    handler.do_POST()
                self.assertEqual(handler._send.call_args.args[0], expected)
                save.assert_not_called()

    def test_non_object_settings_are_recoverable(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'settings.json'
            path.write_text('[]')
            with mock.patch.object(daemon, 'SETTINGS_FILE', path), \
                    mock.patch.object(daemon, '_settings_cache', None):
                self.assertEqual(daemon.get_settings(), daemon.DEFAULT_SETTINGS)
                daemon.api_settings_save({'font_scale': 120})
                self.assertEqual(daemon.get_settings()['font_scale'], 120)

    def test_cache_ttl_starts_after_slow_computation(self):
        clock = [100.0]
        def compute():
            clock[0] += 20
            return 'result'
        with mock.patch.object(daemon, '_ttl_cache', {}), \
                mock.patch.object(daemon.time, 'time', side_effect=lambda: clock[0]):
            self.assertEqual(daemon.cached('slow-audit', 10, compute), 'result')
            clock[0] += 1
            fail = mock.Mock(side_effect=AssertionError('cache prematurely expired'))
            self.assertEqual(daemon.cached('slow-audit', 10, fail), 'result')


class AuditUsageTests(unittest.TestCase):
    def test_invalid_codex_snapshot_preserves_cumulative_baseline(self):
        valid = {'input_tokens': 100, 'cached_input_tokens': 50,
                 'output_tokens': 10, 'total_tokens': 110}
        def event(usage):
            return json.dumps({'type': 'event_msg', 'timestamp': '2026-09-06T01:00:00Z',
                               'payload': {'type': 'token_count',
                                           'info': {'total_token_usage': usage}}}) + '\n'
        invalid = [dict(valid, cached_input_tokens=value)
                   for value in ['bad', None, -1, float('inf'), True]]
        invalid += [{}, {key: value for key, value in valid.items()
                         if key != 'cached_input_tokens'}]
        for malformed in invalid:
            with self.subTest(malformed=malformed), tempfile.TemporaryDirectory() as td:
                path = Path(td) / 'rollout.jsonl'
                path.write_text(event(valid))
                state = daemon._parse_codex_usage_state(path)
                with path.open('a') as f:
                    f.write(event(malformed))
                    f.write(event(valid))
                incremental = daemon._parse_codex_usage_state(path, state)
                full = daemon._parse_codex_usage_state(path)
                self.assertEqual(incremental['agg'], full['agg'])
                self.assertEqual(full['agg']['2026-09-06T01'][0], 110)

    def test_empty_fork_replay_snapshot_does_not_replace_parent_baseline(self):
        usage = {'input_tokens': 100, 'cached_input_tokens': 50,
                 'output_tokens': 10, 'total_tokens': 110}
        def token(value):
            return {'type': 'event_msg', 'timestamp': '2026-07-10T10:00:00Z',
                    'payload': {'type': 'token_count', 'info': {'total_token_usage': value}}}
        events = [
            {'type': 'session_meta', 'payload': {
                'timestamp': '2026-07-10T10:00:00Z',
                'source': {'subagent': {'thread_spawn': {}}}}},
            token(usage), token({}),
            {'type': 'event_msg', 'payload': {'type': 'task_started', 'started_at': 1783677600}},
            token(usage),
        ]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'rollout.jsonl'
            path.write_text(''.join(json.dumps(e) + '\n' for e in events))
            self.assertEqual(daemon._parse_codex_usage_state(path)['agg'], {})

    def claude_event(self, count):
        return {'type': 'assistant', 'timestamp': '2026-09-06T01:00:00Z',
                'message': {'model': 'test', 'usage': {'input_tokens': count}}}

    def test_malformed_records_do_not_hide_later_claude_usage(self):
        events = [['usage'], {'message': ['usage']},
                  {'type': 'assistant', 'message': {'usage': ['invalid']}},
                  self.claude_event('12'), self.claude_event(None),
                  self.claude_event(-10)]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'transcript.jsonl'
            path.write_text(''.join(json.dumps(e) + '\n' for e in events))
            result = daemon._parse_claude_file_usage(path)
            self.assertEqual(result['2026-09-06T01']['test'][0], 12)

    def test_same_size_rewrite_replaces_cached_usage(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'transcript.jsonl'
            path.write_text(json.dumps(self.claude_event(10)) + '\n')
            cache = {}
            daemon._cached_claude_file_usage(path, cache)
            old = path.stat()
            path.write_text(json.dumps(self.claude_event(20)) + '\n')
            os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns + 1000000))
            result, changed = daemon._cached_claude_file_usage(path, cache)
            self.assertTrue(changed)
            self.assertEqual(result['2026-09-06T01']['test'][0], 20)

    def test_incremental_parser_does_not_mutate_committed_state(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / 'transcript.jsonl'
            path.write_text(json.dumps(self.claude_event(10)) + '\n')
            state = daemon._parse_claude_usage_state(path)
            snapshot = copy.deepcopy(state)
            with path.open('a') as f:
                f.write(json.dumps(self.claude_event(20)) + '\n')
            result = daemon._parse_claude_usage_state(path, state)
            self.assertEqual(state, snapshot)
            self.assertEqual(result['agg']['2026-09-06T01']['test'][0], 30)
