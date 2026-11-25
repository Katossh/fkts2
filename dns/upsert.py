#!/usr/bin/env python3
"""Create or update only fkts2's dedicated Cloudflare A record."""
from __future__ import annotations

import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.cloudflare.com/client/v4"


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value or value == "REPLACE_ME" or "CHANGE_ME" in value:
        raise ValueError(f"Set {name} before running the Cloudflare DNS module")
    return value


def api_request(method: str, path: str, token: str, payload: dict | None = None) -> dict:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        API + path,
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "fkts2-cloudflare-dns/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            detail = json.loads(body).get("errors", [])
        except (ValueError, AttributeError):
            detail = body.decode("utf-8", "replace")[:500]
        raise RuntimeError(f"Cloudflare API returned HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Cannot reach Cloudflare API: {exc.reason}") from exc

    try:
        result = json.loads(body)
    except ValueError as exc:
        raise RuntimeError("Cloudflare API returned invalid JSON") from exc
    if not result.get("success"):
        raise RuntimeError(f"Cloudflare API error: {result.get('errors', 'unknown error')}")
    return result


def main() -> int:
    token = required("CF_API_TOKEN")
    zone_id = required("CF_ZONE_ID")
    zone_name = required("CF_ZONE_NAME").rstrip(".").lower()
    record_name = required("CF_RECORD_NAME").rstrip(".").lower()

    # The deployment is intentionally limited to a dedicated hostname in this zone.
    if not zone_name or not record_name.endswith("." + zone_name):
        raise ValueError(
            f"CF_RECORD_NAME must be a subdomain of CF_ZONE_NAME ({zone_name}); "
            "fkts2 will not modify the zone apex or unrelated records"
        )
    if len(zone_id) < 16 or any(ch not in "0123456789abcdefABCDEF-" for ch in zone_id):
        raise ValueError("CF_ZONE_ID does not look like a Cloudflare zone ID")

    entry_ip = ipaddress.ip_address(required("ENTRY_IP"))
    if entry_ip.version != 4:
        raise ValueError("The current fkts2 Cloudflare module manages an A record; ENTRY_IP must be IPv4")

    allow_existing_update = os.environ.get("CF_ALLOW_EXISTING_RECORD_UPDATE", "false").strip().lower() == "true"

    query = urllib.parse.urlencode({"type": "A", "name": record_name, "per_page": "100"})
    zone_path = "/zones/" + urllib.parse.quote(zone_id, safe="") + "/dns_records"
    found = api_request("GET", zone_path + "?" + query, token).get("result", [])

    if len(found) > 1:
        raise RuntimeError(
            f"Found {len(found)} A records for {record_name}; refusing to choose one automatically"
        )

    payload = {
        "type": "A",
        "name": record_name,
        "content": str(entry_ip),
        "ttl": 1,
        "proxied": False,
        "comment": "Managed by fkts2 (DNS-only Xray entry)",
    }

    if found:
        record = found[0]
        record_id = record.get("id")
        if not record_id:
            raise RuntimeError("Cloudflare returned an A record without an ID")
        if (
            record.get("content") == payload["content"]
            and record.get("proxied") is False
            and record.get("ttl") == 1
        ):
            print(f"No change: {record_name} already points to {entry_ip} (DNS-only, automatic TTL).")
            return 0

        managed_by_fkts2 = (record.get("comment") or "").startswith("Managed by fkts2")
        if not managed_by_fkts2 and not allow_existing_update:
            raise RuntimeError(
                f"{record_name} already has an A record pointing to {record.get('content')} "
                f"(proxied={record.get('proxied')}). Refusing to overwrite an existing service. "
                "Inspect the record first; set CF_ALLOW_EXISTING_RECORD_UPDATE=true only if you "
                "intentionally want fkts2 to repurpose it."
            )

        result = api_request(
            "PUT",
            zone_path + "/" + urllib.parse.quote(record_id, safe=""),
            token,
            payload,
        )["result"]
        action = "Updated"
    else:
        result = api_request("POST", zone_path, token, payload)["result"]
        action = "Created"

    print(f"{action} Cloudflare DNS record:")
    print(f"  Name:    {result.get('name', record_name)}")
    print(f"  Type:    A")
    print(f"  Content: {result.get('content', entry_ip)}")
    print(f"  Proxy:   {'enabled' if result.get('proxied') else 'DNS-only'}")
    print(f"  TTL:     {result.get('ttl', 1)} (1 = automatic)")
    print("Only this dedicated A record was modified.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
