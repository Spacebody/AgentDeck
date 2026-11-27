import tempfile
import unittest
from pathlib import Path
from unittest import mock

import agentdeckd as daemon


class SettingsRoundTripTests(unittest.TestCase):
    def test_panel_preferences_survive_save_and_cold_reload(self):
        choices = {"language": "ja", "terminal": "copy",
                   "menubar_color_dim": "weekly", "menubar_value_dim": "max"}
        choices.update({f"menubar_window_{agent}": f"pct:{agent}_weekly" for agent in daemon.AGENT_IDS})
        patch = {}
        for key, default in daemon.DEFAULT_SETTINGS.items():
            if isinstance(default, bool):
                patch[key] = not default
            elif isinstance(default, int):
                patch[key] = daemon.SETTING_RANGES[key][0]
            elif isinstance(default, str):
                patch[key] = "#aabbcc" if key.startswith("color_") else choices[key]
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(daemon, "SETTINGS_FILE", Path(tmp) / "settings.json"), \
                mock.patch.object(daemon, "_settings_cache", None), \
                mock.patch.object(daemon, "_ttl_cache", {}), \
                mock.patch.object(daemon, "_bump_quota_revision"), \
                mock.patch.object(daemon, "_update_keepawake"), \
                mock.patch.object(daemon._codex_quota_manager, "request_reconcile"):
            self.assertTrue(daemon.api_settings_save(patch)["ok"])
            daemon._settings_cache = None
            saved = daemon.get_settings()
            self.assertEqual({key: saved[key] for key in patch}, patch)

    def test_menubar_window_reset_amount_and_invalid_ids(self):
        key = "menubar_window_antigravity"
        for valid in ("", "amount:credits", "pct:seven_day"):
            self.assertEqual(daemon._clean_settings({key: valid}), {key: valid})
        for bad in ("amount:", "seven_day", "pct:bad\n", "pct:" + "a" * 512):
            self.assertNotIn(key, daemon._clean_settings({key: bad}))
