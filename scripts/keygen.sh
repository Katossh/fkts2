#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ ! -f .env ]]; then
  echo "Missing .env; run ./scripts/init.sh first." >&2
  exit 1
fi

XRAY_VERSION="$(sed -n 's/^XRAY_VERSION=//p' .env | tail -n1)"
XRAY_VERSION="${XRAY_VERSION:-26.10.31}"
IMAGE="ghcr.io/xtls/xray-core:${XRAY_VERSION}"

echo "Pulling ${IMAGE}..."
docker pull "$IMAGE"
echo "Generate a REALITY key pair. Keep PrivateKey secret; put Password into .env as REALITY_PUBLIC_KEY."
docker run --rm --entrypoint /usr/local/bin/xray "$IMAGE" x25519
