import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("wait_for_ftd", ROOT / "wait-for-ftd.py")
waiter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(waiter)


class ReadinessTest(unittest.TestCase):
    def test_ssh_conversation_requires_expected_manager(self):
        with tempfile.TemporaryDirectory() as tmp:
            ssh = Path(tmp) / "ssh"
            ssh.write_text('#!/bin/sh\nprintf "Password: "\nread password\nprintf "\\r\\n> "\nread command\nprintf "\\r\\nType : Manager\\r\\nHost : manager.example\\r\\n> "\nsleep 1\n')
            ssh.chmod(0o700)
            env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"], FTD_ADDRESS="192.0.2.10", FTD_USERNAME="admin", FTD_PASSWORD="test-password", FTD_MANAGER="manager.example", FTD_KNOWN_HOSTS=tmp + "/known_hosts")
            ok = subprocess.run(["expect", str(ROOT / "check-ftd-ssh.exp")], env=env, capture_output=True, timeout=10)
            self.assertEqual(ok.returncode, 0, ok.stderr.decode())
            self.assertNotIn(b"test-password", ok.stdout + ok.stderr)
            env["FTD_MANAGER"] = "other.example"
            wrong = subprocess.run(["expect", str(ROOT / "check-ftd-ssh.exp")], env=env, capture_output=True, timeout=10)
            self.assertNotEqual(wrong.returncode, 0)

    def test_authentication_failure_does_not_retry(self):
        env = {"FTD_ADDRESS": "192.0.2.10", "FTD_MANAGER": "manager.example", "FTD_TIMEOUT": "30", "FTD_KNOWN_HOSTS": "/tmp/ftd-test/known_hosts", "FTD_EXPECT_SCRIPT": "script"}
        with patch.dict(os.environ, env), patch.object(waiter.socket, "create_connection"), patch.object(waiter.subprocess, "run", return_value=subprocess.CompletedProcess([], 2)), patch.object(waiter.shutil, "which", return_value="/bin/tool"):
            with self.assertRaisesRegex(RuntimeError, "authentication"):
                waiter.main()


if __name__ == "__main__":
    unittest.main()
