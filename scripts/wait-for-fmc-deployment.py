#!/usr/bin/env python3
"""Wait until cdFMC reports no active deployments for the selected devices."""
import json
import os
import ssl
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request, urlopen


def page_next_offset(items, paging, offset, requested_limit):
    """Return the next offset, or None for a complete response."""
    if paging is None:
        if len(items) >= requested_limit:
            raise ValueError("Missing pagination metadata in cdFMC response")
        return None
    if not isinstance(paging, dict):
        raise ValueError("Invalid cdFMC pagination metadata")

    def number(value, name):
        if isinstance(value, str) and value.isdecimal():
            value = int(value)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"Invalid cdFMC pagination {name}: {value!r}")
        return value

    count = paging.get("count")
    if count is not None:
        count = number(count, "count")
        if not items and count > offset:
            raise ValueError("Incomplete cdFMC paginated response")
        if offset + len(items) >= count:
            return None

    actual_limit = number(paging.get("limit", requested_limit), "limit")
    if actual_limit == 0:
        if not items and (count is None or count == 0):
            return None
        raise ValueError("cdFMC returned a zero page size with items or remaining results")
    if count is None and len(items) < actual_limit:
        return None
    if not items:
        raise ValueError("Incomplete cdFMC paginated response")
    return offset + len(items)


def main():
    base = os.environ["FMC_URL"].rstrip("/")
    parsed = urlsplit(base)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment or parsed.username:
        raise ValueError("FMC_URL must be an HTTPS URL without credentials, query, or fragment")
    ids = set(json.loads(os.environ["FMC_DEVICE_IDS"]))
    if not ids or not all(isinstance(item, str) and item for item in ids):
        raise ValueError("Expected at least one cdFMC device ID")
    timeout = int(os.environ["FMC_TIMEOUT"])
    if timeout <= 0:
        raise ValueError("FMC_TIMEOUT must be positive")
    context = ssl._create_unverified_context() if os.environ.get("FMC_INSECURE") == "true" else ssl.create_default_context()
    deadline = time.monotonic() + timeout

    def get(path, params):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Timed out waiting for cdFMC deployments")
        url = base + path + "?" + urlencode(params)
        request = Request(url, headers={"Authorization": "Bearer " + os.environ["FMC_TOKEN"], "Accept": "application/json"})
        with urlopen(request, timeout=min(15, remaining), context=context) as response:
            data = json.load(response)
        if not isinstance(data, dict):
            raise ValueError("Unexpected cdFMC API response")
        return data

    def pages(path, params):
        offset, limit = 0, 100
        while True:
            data = get(path, {**params, "offset": offset, "limit": limit})
            items = data.get("items", [])
            if not isinstance(items, list):
                raise ValueError("Unexpected cdFMC API items")
            yield from items
            next_offset = page_next_offset(items, data.get("paging"), offset, limit)
            if next_offset is None:
                break
            offset = next_offset

    last = None
    while time.monotonic() < deadline:
        try:
            managers = list(pages("/v1/inventory/managers", {"q": "deviceType:CDFMC"}))
            if len(managers) != 1 or not managers[0].get("fmcDomainUid"):
                raise ValueError("Expected exactly one cdFMC manager with a domain ID")
            domain = managers[0]["fmcDomainUid"]
            import uuid
            domain = str(uuid.UUID(domain))
            path = f"/v1/cdfmc/api/fmc_config/v1/domain/{domain}/deployment/jobhistories"
            busy = set()
            for job in pages(path, {"filter": "jobType:DEPLOYMENT;status:DEPLOYING", "expanded": "true"}):
                devices = job.get("deviceList")
                if not isinstance(devices, list):
                    raise ValueError("Active deployment has no usable deviceList")
                for device in devices:
                    if not isinstance(device, dict) or not isinstance(device.get("deviceUUID"), str):
                        raise ValueError("Active deployment has no usable deviceUUID")
                    if device["deviceUUID"] in ids:
                        busy.add(device["deviceUUID"])
            if not busy:
                print("cdFMC reports no active deployment for the selected cluster devices.", flush=True)
                return
            state = ", ".join(sorted(busy))
            if state != last:
                print(f"Waiting for cdFMC deployments on device IDs: {state}", flush=True)
                last = state
        except HTTPError as exc:
            if exc.code != 429 and exc.code < 500:
                raise RuntimeError(f"cdFMC API request failed with HTTP {exc.code}") from None
            last = f"HTTP {exc.code}"
        except (URLError, TimeoutError) as exc:
            last = type(exc).__name__
        time.sleep(max(0, min(10, deadline - time.monotonic())))
    raise TimeoutError(f"Timed out waiting for cdFMC deployments (last status: {last})")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, TypeError, RuntimeError, TimeoutError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
