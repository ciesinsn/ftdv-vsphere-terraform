#!/usr/bin/env python3
"""Wait for the FTD CLI and its expected manager before SCC onboarding."""
import os
from pathlib import Path
import socket
import shutil
import subprocess
import sys
import time


def main():
    address = os.environ["FTD_ADDRESS"]
    manager = os.environ["FTD_MANAGER"].strip()
    if not manager:
        raise ValueError("SCC returned an empty manager hostname")
    if not shutil.which("expect") or not shutil.which("ssh"):
        raise RuntimeError("FTD readiness requires both Expect and OpenSSH on the Terraform runner")
    deadline = time.monotonic() + int(os.environ["FTD_TIMEOUT"])
    known_hosts = Path(os.environ["FTD_KNOWN_HOSTS"])
    known_hosts.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        try:
            with socket.create_connection((address, 22), timeout=min(5, remaining)):
                pass
            result = subprocess.run(["expect", os.environ["FTD_EXPECT_SCRIPT"]], timeout=max(1, min(50, remaining)), check=False)
            if result.returncode == 0:
                print(f"FTD {address}: SSH is available and the SCC manager is configured.")
                return
            if result.returncode == 2:
                raise RuntimeError("SSH authentication failed or the FTD requires a password change")
            if result.returncode == 3:
                raise RuntimeError("SSH host key changed; verify the device identity and known_hosts file")
        except (OSError, subprocess.TimeoutExpired):
            pass
        time.sleep(max(0, min(10, deadline - time.monotonic())))
    raise TimeoutError(f"FTD {address} did not become ready before the timeout; check SSH, manager configuration, and connectivity")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, TimeoutError, KeyError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
