import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agentdeckd as daemon


class DashboardExportTests(unittest.TestCase):
    def test_range_visibility_missing_cost_and_unique_files(self):
        days = [f'2026-11-{day:02d}' for day in range(1, 31)]
        usage = {'days': days, 'claude_daily': {},
                 'codex_daily': {day: 100 for day in days},
                 'qoder_daily': {day: 50 for day in days},
                 'qoder_cn_daily': {day: 32 for day in days}, 'cost_daily': {},
                 'costs_by_agent_daily': {'codex': {day: 1 for day in days},
                                         'qoder': {day: None for day in days}}}
        with tempfile.TemporaryDirectory() as directory, \
                mock.patch.object(Path, 'home', return_value=Path(directory)), \
                mock.patch.object(daemon, 'api_usage', return_value=usage), \
                mock.patch.object(daemon.subprocess, 'run'):
            first = daemon.api_data({'action': 'export', 'days': 7, 'agents': ['codex']})
            second = daemon.api_data({'action': 'export', 'days': 7, 'agents': ['qoder']})
            month = daemon.api_data({'action': 'export', 'days': 30, 'agents': ['codex']})
            legacy = daemon.api_data({'action': 'export'})
            header, row, *_ = Path(legacy['path']).read_text().splitlines()
            self.assertEqual(dict(zip(header.split(','), row.split(',')))['qoder_cn_tokens'], '32')
            cn = daemon.api_data({'action': 'export', 'days': 7, 'agents': ['qoder_cn']})
            self.assertIn(',qoder_cn,32,', Path(cn['path']).read_text())
            self.assertNotEqual(first['path'], second['path'])
            rows = Path(first['path']).read_text().splitlines()
            self.assertEqual(len(rows), 8)
            self.assertTrue(rows[1].startswith('2026-11-24,codex,'))
            self.assertTrue(Path(second['path']).read_text().splitlines()[1].endswith(','))
            self.assertEqual(len(Path(month['path']).read_text().splitlines()), 31)
            self.assertFalse(daemon.api_data({'action': 'export', 'days': 90})['ok'])
