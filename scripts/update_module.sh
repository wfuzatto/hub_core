#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODULE="${1:-}"
LIST="$ROOT/modules/modules.list"

fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ -n "$MODULE" ]] || fail "uso: bash scripts/update_module.sh <totem_food|totem_autoatendimento|face_scanner|hotelaria>"
[[ -f .env ]] || fail ".env ausente em $ROOT"
[[ -f "$LIST" ]] || fail "modules/modules.list ausente"
command -v git >/dev/null 2>&1 || fail "git não encontrado"
command -v docker >/dev/null 2>&1 || fail "docker não encontrado"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"

case "$MODULE" in
  totem_food)
    SERVICE="totem-food"
    HEALTH_URL="http://127.0.0.1:${TOTEM_FOOD_LOCAL_PORT:-3085}/api/health"
    ;;
  totem_autoatendimento)
    SERVICE="totem-api"
    HEALTH_URL="http://127.0.0.1:${TOTEM_LOCAL_PORT:-3080}/api/health"
    ;;
  face_scanner)
    SERVICE="face-scanner"
    HEALTH_URL="http://127.0.0.1:8092/api/v1/health"
    ;;
  hotelaria)
    SERVICE="pms"
    HEALTH_URL="http://127.0.0.1:${PMS_LOCAL_PORT:-3084}/health.php"
    ;;
  *) fail "módulo inválido: $MODULE" ;;
esac

LINE="$(awk -F'|' -v m="$MODULE" '$1==m {print; exit}' "$LIST")"
[[ -n "$LINE" ]] || fail "módulo $MODULE não encontrado em modules/modules.list"
IFS='|' read -r DEST REPO REF <<< "$LINE"
[[ -n "$DEST" && -n "$REPO" && -n "$REF" ]] || fail "entrada inválida para $MODULE em modules/modules.list"

MODULE_DIR="$ROOT/modules/$DEST"

log "Atualização isolada: $MODULE"
echo "Serviço Docker: $SERVICE"
echo "Ref aprovada:   $REF"
echo "Nenhum outro módulo será atualizado."

if [[ ! -d "$MODULE_DIR/.git" ]]; then
  log "Clonando somente $MODULE"
  rm -rf "$MODULE_DIR"
  git clone "$REPO" "$MODULE_DIR"
fi

if [[ -n "$(git -C "$MODULE_DIR" status --porcelain)" ]]; then
  echo "ERRO: o módulo $MODULE possui alterações locais; nada foi sobrescrito." >&2
  git -C "$MODULE_DIR" status --short >&2
  exit 1
fi

log "Buscando somente $MODULE"
git -C "$MODULE_DIR" fetch --prune origin
git -C "$MODULE_DIR" fetch origin "$REF" >/dev/null 2>&1 || true
git -C "$MODULE_DIR" cat-file -e "${REF}^{commit}" 2>/dev/null || fail "ref $REF não encontrada em $MODULE"
git -C "$MODULE_DIR" checkout --detach "$REF"

echo "HEAD $MODULE: $(git -C "$MODULE_DIR" rev-parse --short HEAD)"

COMPOSE=(docker compose -f compose.yml -f compose.host-edge.yml)
if [[ "$MODULE" == "face_scanner" && -f compose.face-real-test.yml ]]; then
  COMPOSE+=( -f compose.face-real-test.yml )
fi

"${COMPOSE[@]}" config >/dev/null

if [[ "$MODULE" == "totem_food" ]]; then
  log "Preparando apenas dependências próprias do Totem Food"
  if ! docker volume inspect hub_core_totem_food_uploads >/dev/null 2>&1; then
    docker volume create hub_core_totem_food_uploads >/dev/null
    echo "Criado volume hub_core_totem_food_uploads"
  fi

  MYSQL_CID="$("${COMPOSE[@]}" ps -q mysql)"
  [[ -n "$MYSQL_CID" ]] || fail "MySQL do HUB não está em execução; atualização do Food abortada"
  MYSQL_HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$MYSQL_CID")"
  [[ "$MYSQL_HEALTH" == "healthy" || "$MYSQL_HEALTH" == "running" ]] || fail "MySQL não está pronto: $MYSQL_HEALTH"

  "${COMPOSE[@]}" run --rm --no-deps totem-food-db-init
  "${COMPOSE[@]}" rm -f -s totem-food-db-init >/dev/null 2>&1 || true
fi

log "Build somente de $SERVICE"
"${COMPOSE[@]}" build "$SERVICE"

log "Recriando somente $SERVICE"
"${COMPOSE[@]}" up -d --no-deps "$SERVICE"

log "Aguardando health do $MODULE"
OK=0
for _ in $(seq 1 45); do
  if curl -fsS "$HEALTH_URL" >/tmp/hub_core_module_health.$$ 2>/dev/null; then
    cat /tmp/hub_core_module_health.$$
    echo
    OK=1
    break
  fi
  sleep 2
done
rm -f /tmp/hub_core_module_health.$$

if [[ "$OK" != "1" ]]; then
  echo "ERRO: $MODULE não ficou saudável no tempo esperado." >&2
  "${COMPOSE[@]}" ps "$SERVICE" >&2 || true
  "${COMPOSE[@]}" logs --tail=120 "$SERVICE" >&2 || true
  exit 1
fi

log "Atualização isolada concluída"
"${COMPOSE[@]}" ps "$SERVICE"
echo "Health: $HEALTH_URL"
