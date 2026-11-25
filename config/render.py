#!/usr/bin/env python3
"""Render modular Xray JSON files from the local .env file."""
from __future__ import annotations

import ipaddress
import json
import os
import re
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / ".env"
RUNTIME = ROOT / "runtime"
XRAY_DIR = RUNTIME / "xray"


def load_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_no, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].strip()
        if "=" not in line:
            raise ValueError(f"{path}:{line_no}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    return values


def required(env: dict[str, str], key: str) -> str:
    value = env.get(key, "").strip()
    if not value or value == "REPLACE_ME" or "CHANGE_ME" in value:
        raise ValueError(f"Set {key} in .env before rendering the Xray configuration")
    return value


def valid_reality_key(value: str, name: str) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,64}", value):
        raise ValueError(f"{name} does not look like an Xray X25519 key; generate it with ./scripts/keygen.sh")


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n")
    path.chmod(0o600)


def main() -> int:
    if not ENV_FILE.is_file():
        raise ValueError("Missing .env; run ./scripts/init.sh first")

    env = load_env(ENV_FILE)
    entry_ip = ipaddress.ip_address(required(env, "ENTRY_IP"))
    exit_ip = ipaddress.ip_address(required(env, "EXIT_IP"))

    single_ip_raw = env.get("SINGLE_IP_MODE", "false").strip().lower()
    if single_ip_raw not in {"true", "false"}:
        raise ValueError("SINGLE_IP_MODE must be either true or false")
    single_ip_mode = single_ip_raw == "true"

    if entry_ip.version != exit_ip.version:
        raise ValueError("ENTRY_IP and EXIT_IP must use the same address family for this initial setup")
    if single_ip_mode and entry_ip != exit_ip:
        raise ValueError("SINGLE_IP_MODE=true requires ENTRY_IP and EXIT_IP to be identical")
    if not single_ip_mode and entry_ip == exit_ip:
        raise ValueError(
            "ENTRY_IP and EXIT_IP are identical. Set SINGLE_IP_MODE=true for temporary single-IP deployment, "
            "or configure a distinct EXIT_IP."
        )

    entry_address = required(env, "ENTRY_ADDRESS")
    port_text = required(env, "INBOUND_PORT")
    if not port_text.isdigit() or not 1 <= int(port_text) <= 65535:
        raise ValueError("INBOUND_PORT must be an integer from 1 to 65535")
    port = int(port_text)

    server_name = required(env, "REALITY_SERVER_NAME")
    if "://" in server_name or "/" in server_name or " " in server_name:
        raise ValueError("REALITY_SERVER_NAME must be a hostname, not a URL")
    target = required(env, "REALITY_TARGET")
    if ":" not in target or target.startswith(":") or target.endswith(":"):
        raise ValueError("REALITY_TARGET must be host:port (for example, www.example.com:443)")
    target_host, target_port = target.rsplit(":", 1)
    if not target_port.isdigit() or not 1 <= int(target_port) <= 65535 or not target_host:
        raise ValueError("REALITY_TARGET must be host:port with a valid port")

    client_id = required(env, "CLIENT_UUID")
    try:
        client_id = str(uuid.UUID(client_id))
    except ValueError as exc:
        raise ValueError("CLIENT_UUID must be a valid UUID") from exc

    short_id = required(env, "REALITY_SHORT_ID")
    if len(short_id) > 16 or len(short_id) % 2 or not re.fullmatch(r"[0-9a-fA-F]*", short_id):
        raise ValueError("REALITY_SHORT_ID must contain 0–16 hexadecimal characters in an even length")

    private_key = required(env, "REALITY_PRIVATE_KEY")
    public_key = required(env, "REALITY_PUBLIC_KEY")
    valid_reality_key(private_key, "REALITY_PRIVATE_KEY")
    valid_reality_key(public_key, "REALITY_PUBLIC_KEY")

    XRAY_DIR.mkdir(parents=True, exist_ok=True)
    RUNTIME.mkdir(parents=True, exist_ok=True)
    RUNTIME.chmod(0o700)
    XRAY_DIR.chmod(0o700)

    modules = {
        "00-log.json": {
            "log": {"logLevel": "warning", "access": "none"}
        },
        "10-inbounds.json": {
            "inbounds": [
                {
                    "tag": "vless-reality-in",
                    "listen": str(entry_ip),
                    "port": port,
                    "protocol": "vless",
                    "settings": {
                        "clients": [{"id": client_id, "flow": "xtls-rprx-vision"}],
                        "decryption": "none",
                    },
                    "streamSettings": {
                        "network": "raw",
                        "security": "reality",
                        "realitySettings": {
                            "show": False,
                            "target": target,
                            "xver": 0,
                            "serverNames": [server_name],
                            "privateKey": private_key,
                            "shortIds": [short_id],
                        },
                    },
                    "sniffing": {
                        "enabled": True,
                        "destOverride": ["http", "tls", "quic"],
                    },
                }
            ]
        },
        "20-outbounds.json": {
            "outbounds": [
                {
                    "tag": "exit-ip-2",
                    "protocol": "freedom",
                    "sendThrough": str(exit_ip),
                    "settings": {},
                },
                {"tag": "block", "protocol": "blackhole", "settings": {}},
            ]
        },
        "30-routing.json": {
            "routing": {
                "domainStrategy": "IPIfNonMatch",
                "rules": [
                    {
                        "type": "field",
                        "ip": ["geoip:private"],
                        "outboundTag": "block",
                    }
                ],
            }
        },
    }
    for name, payload in modules.items():
        write_json(XRAY_DIR / name, payload)

    client_config = {
        "log": {"loglevel": "warning"},
        "outbounds": [
            {
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": entry_address,
                            "port": port,
                            "users": [
                                {"id": client_id, "encryption": "none", "flow": "xtls-rprx-vision"}
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "raw",
                    "security": "reality",
                    "realitySettings": {
                        "serverName": server_name,
                        "fingerprint": "chrome",
                        "password": public_key,
                        "shortId": short_id,
                        "spiderX": "/",
                    },
                },
            }
        ],
    }
    write_json(RUNTIME / "client-config.json", client_config)

    print("Rendered Xray modules:")
    for name in modules:
        print(f"  runtime/xray/{name}")
    print(f"Client profile: runtime/client-config.json")
    print(f"Entry: {entry_ip}:{port}; egress source: {exit_ip}")
    print(f"Mode: {'single-IP staging' if single_ip_mode else 'separate entry/exit IPs'}")
    print("No service was started or host network settings were changed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
