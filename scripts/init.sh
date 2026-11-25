#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -e .env ]]; then
  echo ".env already exists; leaving it untouched."
  exit 0
fi

cp .env.example .env
python3 - <<'PY'
from pathlib import Path
import secrets
import uuid
p = Path('.env')
s = p.read_text()
s = s.replace('CLIENT_UUID=REPLACE_ME', f'CLIENT_UUID={uuid.uuid4()}')
s = s.replace('REALITY_SHORT_ID=REPLACE_ME', f'REALITY_SHORT_ID={secrets.token_hex(8)}')
p.write_text(s)
p.chmod(0o600)
PY

mkdir -p runtime/xray
chmod 700 runtime runtime/xray
echo "Created .env with a fresh UUID and REALITY short ID."
echo "Next: run ./scripts/keygen.sh and copy PrivateKey/Password into .env."
echo "Then set ENTRY_IP, EXIT_IP, ENTRY_ADDRESS, REALITY_TARGET and REALITY_SERVER_NAME."
