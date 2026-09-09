#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Atualizador operacional oficial do HUB Core.
# Uso normal:
#   bash scripts/update_docker.sh
# GPU opcional:
#   USE_GPU=1 bash scripts/update_docker.sh

if [[ ! -f .env ]]; then
  echo "ERRO: .env ausente em $ROOT" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "ERRO: há alterações locais versionadas. Faça commit/stash antes de atualizar." >&2
  git status --short
  exit 1
fi

echo "[git] atualizando hub_core..."
git fetch --prune origin main
LOCAL_SHA="$(git rev-parse HEAD)"
REMOTE_SHA="$(git rev-parse origin/main)"

if ! git merge-base --is-ancestor "$LOCAL_SHA" "$REMOTE_SHA"; then
  echo "ERRO: checkout local divergiu de origin/main." >&2
  echo "local=$LOCAL_SHA" >&2
  echo "origin/main=$REMOTE_SHA" >&2
  exit 1
fi

if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  git merge --ff-only origin/main
fi

chmod 600 .env
chmod +x scripts/*.sh 2>/dev/null || true

# Os volumes de produção são externos de propósito: isso impede que um
# `docker compose down` comum controle/remova a persistência da plataforma.
# Em uma instalação já existente, volume ausente é tratado como falha crítica
# para evitar subir MySQL/Totem/Face Scanner com dados vazios por engano.
REQUIRED_VOLUMES=(
  hub_core_mysql_data
  hub_core_totem_data
  hub_core_face_scanner_data
)

echo "[storage] validando volumes persistentes..."
for volume in "${REQUIRED_VOLUMES[@]}"; do
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "ERRO: volume persistente obrigatório ausente: $volume" >&2
    echo "Atualização abortada para evitar inicialização com dados vazios." >&2
    exit 1
  fi
done

COMPOSE=(docker compose -f compose.yml -f compose.host-edge.yml)
"${COMPOSE[@]}" config >/dev/null

ARGS=(--host-edge)
if [[ "${USE_GPU:-0}" == "1" ]]; then
  ARGS+=(--gpu)
fi

echo "[deploy] executando atualização oficial..."
./scripts/update.sh "${ARGS[@]}"

echo "[status]"
"${COMPOSE[@]}" ps

echo "[test] Totem"
curl -fsS http://127.0.0.1:3080/api/health
printf '\n'

echo "[test] HUB"
curl -fsSI http://127.0.0.1:3083/ | head -n 1

echo "[test] HTTPS"
curl -kfsSI https://192.168.51.135/ | head -n 1

echo "Atualização do HUB Core concluída."
