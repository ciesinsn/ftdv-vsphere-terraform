#!/usr/bin/env python3
"""Wait for SCC inventory to report a device ONLINE; never print credentials."""
import json
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


def main():
    base = os.environ["SCC_BASE_URL"].rstrip("/")
    parsed = urlsplit(base)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        raise ValueError("SCC_BASE_URL must be an HTTPS URL without a query or fragment")
    if not parsed.path or parsed.path == "/":
        base += "/api/rest"
    uid = os.environ["SCC_DEVICE_UID"]
    url = base + "/v1/inventory/devices/" + quote(uid, safe="")
    request = Request(url, headers={"Authorization": "Bearer " + os.environ["SCC_API_TOKEN"], "Accept": "application/json"})
    deadline = time.monotonic() + int(os.environ["SCC_TIMEOUT"])
    last_status = "not yet checked"
    while time.monotonic() < deadline:
        try:
            with urlopen(request, timeout=max(1, min(15, deadline - time.monotonic()))) as response:
                data = json.load(response)
            state = data.get("connectivityState")
            if state != last_status:
                last_status = state
                print(f"SCC device {uid}: connectivity state {state or 'unavailable'}", flush=True)
            if state == "ONLINE":
                return
        except HTTPError as exc:
            if exc.code not in (404, 429) and exc.code < 500:
                raise RuntimeError(f"SCC inventory request failed with HTTP {exc.code}") from None
            last_status = f"HTTP {exc.code}"
        except (URLError, TimeoutError) as exc:
            last_status = type(exc).__name__
        time.sleep(max(0, min(10, deadline - time.monotonic())))
    raise TimeoutError(f"SCC device {uid} did not become ONLINE before timeout (last state: {last_status})")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError, TimeoutError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
