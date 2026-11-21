#!/usr/bin/env python3
"""Compare SCC provider name lookup with stored FTD UIDs; never print secrets."""
import json
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode, urlsplit
from urllib.request import Request, urlopen


def terraform_json(args, stdin=None):
    result = subprocess.run(["terraform", *args], input=stdin, text=True, capture_output=True, check=False)
    if result.returncode:
        raise RuntimeError(f"terraform {args[0]} failed; run it separately to inspect the error")
    return json.loads(result.stdout)


def variables():
    # One expression avoids multiple Terraform state lock acquisitions.
    data = terraform_json(["console", "-no-color"], 'jsonencode({url=var.scc_base_url, token=nonsensitive(var.scc_api_token)})\n')
    return json.loads(data)


def node_resources(module):
    for resource in module.get("resources", []):
        if resource.get("type") == "sccfm_ftd_device" and resource.get("mode") == "managed":
            values = resource.get("values", {})
            if values.get("id") and values.get("name"):
                yield values["name"], values["id"]
    for child in module.get("child_modules", []):
        yield from node_resources(child)


def request(base, token, path):
    req = Request(base + path, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    try:
        with urlopen(req, timeout=20) as response:
            return response.status, json.load(response)
    except HTTPError as exc:
        return exc.code, None
    except URLError:
        raise RuntimeError("Could not reach SCC; verify DNS and HTTPS connectivity") from None


def main():
    config = variables()
    base = config["url"].rstrip("/")
    parsed = urlsplit(base)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query or parsed.fragment:
        raise ValueError("scc_base_url must be an HTTPS origin without a path")
    state = terraform_json(["show", "-json"])
    nodes = list(node_resources(state.get("values", {}).get("root_module", {})))
    if not nodes:
        raise RuntimeError("No sccfm_ftd_device resources with name and ID found in the current state")
    for name, uid in nodes:
        query = urlencode({"q": f'name:"{name}" AND deviceType:FTDC'})
        status, data = request(base, config["token"], "/aegis/rest/v1/services/targets/devices?" + query)
        count = len(data) if isinstance(data, list) else "unknown"
        by_uid, _ = request(base, config["token"], "/api/rest/v1/inventory/devices/" + quote(uid, safe=""))
        print(f"{name}: provider name lookup HTTP {status}, matches {count}; inventory UID lookup HTTP {by_uid}")
        if isinstance(data, list) and len(data) == 1:
            current_uid = data[0].get("uid")
            if current_uid:
                print(f"  stored SCC UID:  {uid}\n  current SCC UID: {current_uid}\n  UID changed:     {current_uid != uid}")
    print("Read-only diagnostic: no infrastructure or Terraform state was changed.")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"Diagnostic failed: {exc}", file=sys.stderr)
        sys.exit(1)
