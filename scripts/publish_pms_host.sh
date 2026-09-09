#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "publish_pms_host.sh foi substituído pela publicação unificada por módulos."
echo "Aplicando /, /pms/, /totem/ e /face-scanner/ no mesmo HTTPS."
exec bash scripts/publish_modules_host.sh
