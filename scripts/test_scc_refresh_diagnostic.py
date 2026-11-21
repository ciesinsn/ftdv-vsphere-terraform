import importlib.util
import io
from pathlib import Path
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("diagnostic", Path(__file__).with_name("diagnose-scc-cluster-refresh.py"))
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class DiagnosticTest(unittest.TestCase):
    def test_reports_lookup_counts_without_printing_credentials(self):
        state = {"values": {"root_module": {"resources": [{"mode": "managed", "type": "sccfm_ftd_device", "values": {"name": "node-1", "id": "uid-1"}}]}}}
        output = io.StringIO()
        with patch.object(diagnostic, "variables", return_value={"url": "https://scc.example", "token": "secret"}), patch.object(diagnostic, "terraform_json", return_value=state), patch.object(diagnostic, "request", side_effect=[(200, []), (404, None)]) as request, redirect_stdout(output):
            diagnostic.main()
        self.assertIn("matches 0", output.getvalue())
        self.assertIn("UID lookup HTTP 404", output.getvalue())
        self.assertNotIn("secret", output.getvalue())
        self.assertIn("deviceType%3AFTDC", request.call_args_list[0].args[2])

    def test_rejects_url_with_path(self):
        with patch.object(diagnostic, "variables", return_value={"url": "https://scc.example/path", "token": "secret"}):
            with self.assertRaisesRegex(ValueError, "origin"):
                diagnostic.main()

    def test_reports_changed_uid_without_device_metadata(self):
        state = {"values": {"root_module": {"resources": [{"mode": "managed", "type": "sccfm_ftd_device", "values": {"name": "node-3", "id": "old-uid"}}]}}}
        output = io.StringIO()
        with patch.object(diagnostic, "variables", return_value={"url": "https://scc.example", "token": "secret"}), patch.object(diagnostic, "terraform_json", return_value=state), patch.object(diagnostic, "request", side_effect=[(200, [{"uid": "new-uid", "metadata": {"regKey": "private-key"}}]), (404, None)]), redirect_stdout(output):
            diagnostic.main()
        self.assertIn("UID changed:     True", output.getvalue())
        self.assertNotIn("private-key", output.getvalue())
