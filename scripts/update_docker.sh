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

# O PMS faz parte do stack oficial. Esta etapa é idempotente e prepara
# automaticamente acesso ao módulo privado, banco, usuário, administrador
# e storage persistente.
echo "[pms] preparando PMS automaticamente..."
bash scripts/prepare_pms.sh

# Baixa e fixa todos os módulos homologados antes de validar o Compose.
# Isso inclui o Totem Food em instalações onde ele ainda não existe localmente.
echo "[modules] preparando módulos homologados..."
bash scripts/bootstrap.sh

# O Totem Food é novo no stack. Seu volume pode ser criado automaticamente
# porque ainda não existia nas instalações anteriores. Os volumes antigos
# continuam obrigatórios e nunca são recriados silenciosamente.
echo "[totem-food] garantindo volume persistente..."
if ! docker volume inspect hub_core_totem_food_uploads >/dev/null 2>&1; then
  docker volume create hub_core_totem_food_uploads >/dev/null
  echo "[totem-food] volume hub_core_totem_food_uploads criado"
fi

REQUIRED_VOLUMES=(
  hub_core_mysql_data
  hub_core_pms_storage
  hub_core_totem_data
  hub_core_face_scanner_data
  hub_core_totem_food_uploads
)

echo "[storage] validando volumes persistentes..."
for volume in "${REQUIRED_VOLUMES[@]}"; do
  if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    echo "ERRO: volume persistente obrigatório ausente: $volume" >&2
    echo "Atualização abortada para evitar inicialização com dados vazios." >&2
    exit 1
  fi
done

# O deploy oficial usa o provider biométrico interno SFace com os thresholds
# homologados em compose.face-real-test.yml. Esse override precisa vir depois
# do host-edge, que mantém um mock apenas como fallback de arquivo isolado.
COMPOSE=(docker compose -f compose.yml -f compose.host-edge.yml -f compose.face-real-test.yml)
"${COMPOSE[@]}" config >/dev/null

# Este script já atualizou o hub_core acima. Evita um segundo git fetch dentro
# de update.sh, que além de ser redundante pode pedir a passphrase SSH novamente.
ARGS=(--no-pull --host-edge)
if [[ "${USE_GPU:-0}" == "1" ]]; then
  ARGS+=(--gpu)
fi

echo "[deploy] executando atualização oficial..."
bash scripts/update.sh "${ARGS[@]}"

echo "[status]"
"${COMPOSE[@]}" ps

echo "[test] Face Scanner config efetiva"
FACE_PROVIDER="$("${COMPOSE[@]}" config | awk '/face-scanner:/{f=1} f&&/FACE_VERIFICATION_PROVIDER:/{print $2; exit}' | tr -d '"')"
FACE_REVIEW="$("${COMPOSE[@]}" config | awk '/face-scanner:/{f=1} f&&/FACE_REVIEW_THRESHOLD:/{print $2; exit}' | tr -d '"')"
FACE_MATCH="$("${COMPOSE[@]}" config | awk '/face-scanner:/{f=1} f&&/FACE_MATCH_THRESHOLD:/{print $2; exit}' | tr -d '"')"
echo "provider=${FACE_PROVIDER:-unknown} review=${FACE_REVIEW:-unknown} match=${FACE_MATCH:-unknown}"
[[ "${FACE_PROVIDER:-}" == "internal" ]] || { echo "ERRO: provider facial efetivo não é internal" >&2; exit 1; }
[[ "${FACE_REVIEW:-}" == "0.363" ]] || { echo "ERRO: FACE_REVIEW_THRESHOLD efetivo inesperado" >&2; exit 1; }
[[ "${FACE_MATCH:-}" == "0.500" || "${FACE_MATCH:-}" == "0.5" ]] || { echo "ERRO: FACE_MATCH_THRESHOLD efetivo inesperado" >&2; exit 1; }

echo "[test] PMS"
curl -fsS "http://127.0.0.1:${PMS_LOCAL_PORT:-3084}/health.php"
printf '\n'

echo "[test] Totem Hotel"
curl -fsS "http://127.0.0.1:${TOTEM_LOCAL_PORT:-3080}/api/health"
printf '\n'

echo "[test] Totem Food"
curl -fsS "http://127.0.0.1:${TOTEM_FOOD_LOCAL_PORT:-3085}/api/health"
printf '\n'

echo "[test] HUB"
curl -fsSI "http://127.0.0.1:${HUB_LOCAL_PORT:-3083}/" | head -n 1

echo "[test] HTTPS"
curl -kfsSI https://192.168.51.135/ | head -n 1

echo "Atualização do HUB Core concluída."
