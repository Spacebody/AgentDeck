import unittest
from unittest.mock import Mock, patch

import agentdeckd as daemon


class AnalyticsHTTPTests(unittest.TestCase):
    def get(self, path, store=None, origin=None):
        handler = object.__new__(daemon.Handler)
        handler.path = path
        handler.headers = {"Host": "127.0.0.1:7777"}
        if origin:
            handler.headers["Origin"] = origin
        handler._send = Mock()
        with patch.object(daemon, "_analytics_store", store):
            handler.do_GET()
        return handler._send.call_args.args

    def test_no_index_never_delays_health(self):
        self.assertEqual(self.get("/api/health")[1]["ok"], True)
        self.assertEqual(self.get("/api/analytics")[0], 503)

    def test_export_and_page_forward_the_same_scope(self):
        store = Mock()
        store.export_csv.return_value = "model,tokens\n测试,1\n"
        query = "?agents=codex&period=7d&project=%2Ftmp%2Fexample"
        self.assertEqual(self.get("/api/analytics" + query, store)[0], 200)
        status, body, mime = self.get("/api/analytics/export" + query, store)
        self.assertEqual((status, body.decode(), mime),
                         (200, store.export_csv.return_value, "text/csv; charset=utf-8"))
        self.assertEqual(store.query.call_args, store.export_csv.call_args)
        self.assertEqual(store.query.call_args.args[0]["project"], "/tmp/example")

    def test_rejects_cross_origin_and_ambiguous_query(self):
        store = Mock()
        self.assertEqual(self.get("/api/analytics/export", store, "https://example.org")[0], 403)
        self.assertEqual(self.get("/api/analytics?agents=claude&agents=codex", store)[0], 400)
        self.assertFalse(store.mock_calls)

    def test_large_export_is_rejected_without_returning_partial_data(self):
        store = Mock()
        store.export_csv.side_effect = ValueError("export too large")
        self.assertEqual(self.get("/api/analytics/export", store)[0], 413)
