#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${ROOT}/scripts/internal/dependencies.sh"
fkts2_require_root
fkts2_install_dependencies
