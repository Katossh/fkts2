#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

bash ./scripts/preflight.sh

echo "Validating the rendered Xray configuration..."
docker compose run --rm --no-deps xray run -test -confdir /usr/local/etc/xray

echo "Starting fkts2-xray..."
docker compose up -d --remove-orphans
docker compose ps
