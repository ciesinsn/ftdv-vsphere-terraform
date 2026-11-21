import importlib.util
import io
import os
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location("scc_wait", Path(__file__).with_name("wait-for-scc-online.py"))
waiter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waiter)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class OnlineTest(unittest.TestCase):
    def test_polls_pending_until_online(self):
        env = {"SCC_BASE_URL": "https://example.test", "SCC_API_TOKEN": "secret", "SCC_DEVICE_UID": "abc", "SCC_TIMEOUT": "30"}
        responses = [Response(b'{"connectivityState":"PENDING"}'), Response(b'{"connectivityState":"ONLINE"}')]
        with patch.dict(os.environ, env), patch.object(waiter, "urlopen", side_effect=responses) as open_url, patch.object(waiter.time, "sleep"):
            waiter.main()
        request = open_url.call_args[0][0]
        self.assertEqual(request.full_url, "https://example.test/api/rest/v1/inventory/devices/abc")
        self.assertEqual(open_url.call_count, 2)

    def test_unauthorized_fails_without_exposing_response(self):
        env = {"SCC_BASE_URL": "https://example.test/api/rest", "SCC_API_TOKEN": "secret", "SCC_DEVICE_UID": "abc", "SCC_TIMEOUT": "30"}
        error = HTTPError("https://example.test", 401, "no", {}, None)
        with patch.dict(os.environ, env), patch.object(waiter, "urlopen", side_effect=error):
            with self.assertRaisesRegex(RuntimeError, "HTTP 401"):
                waiter.main()
