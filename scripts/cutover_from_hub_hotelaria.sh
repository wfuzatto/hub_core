#!/usr/bin/env bash
set -euo pipefail

NEW_ROOT="${NEW_ROOT:-/home/luisnasc/hub_core}"
OLD_PROJECT="${OLD_PROJECT:-hub-hotelaria}"
NEW_PROJECT="${NEW_PROJECT:-hub_core}"
BACKUP_DIR="${BACKUP_DIR:-/home/luisnasc/backups/hub_core_migration_20260909_162248}"
EXPECTED_COMMIT_PREFIX="${EXPECTED_COMMIT_PREFIX:-b09e99d}"

log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail(){ echo "ERRO: $*" >&2; exit 1; }

require_cmd(){ command -v "$1" >/dev/null 2>&1 || fail "comando ausente: $1"; }
for c in docker git awk grep sed tar; do require_cmd "$c"; done

docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 não disponível"
docker info >/dev/null 2>&1 || fail "Docker daemon não acessível"

[[ -d "$NEW_ROOT/.git" ]] || fail "checkout novo ausente: $NEW_ROOT"
[[ -d "$BACKUP_DIR" ]] || fail "backup não encontrado: $BACKUP_DIR"
cd "$NEW_ROOT"

log "Validando Git do hub_core"
HEAD_SHA="$(git rev-parse HEAD)"
[[ "$HEAD_SHA" == ${EXPECTED_COMMIT_PREFIX}* ]] || fail "HEAD inesperado: $HEAD_SHA"
git diff --quiet || fail "working tree possui alterações"
git diff --cached --quiet || fail "há alterações staged"

git fetch origin main >/dev/null 2>&1 || fail "git fetch falhou; valide autenticação SSH"
REMOTE_SHA="$(git rev-parse origin/main)"
[[ "$HEAD_SHA" == "$REMOTE_SHA" ]] || fail "HEAD ($HEAD_SHA) diferente de origin/main ($REMOTE_SHA)"

log "Localizando containers antigos"
OLD_MYSQL_CID="$(docker ps -aq --filter "name=^/${OLD_PROJECT}-mysql-1$")"
OLD_HUB_CID="$(docker ps -aq --filter "name=^/${OLD_PROJECT}-hub-core-1$")"
OLD_TOTEM_CID="$(docker ps -aq --filter "name=^/${OLD_PROJECT}-totem-api-1$")"
OLD_FACE_CID="$(docker ps -aq --filter "name=^/${OLD_PROJECT}-face-scanner-1$")"

for spec in \
  "mysql:$OLD_MYSQL_CID" \
  "hub-core:$OLD_HUB_CID" \
  "totem-api:$OLD_TOTEM_CID" \
  "face-scanner:$OLD_FACE_CID"; do
  svc="${spec%%:*}"; cid="${spec#*:}"
  [[ -n "$cid" ]] || fail "container antigo ausente: $svc"
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
  [[ "$state" == "healthy" || "$state" == "running" ]] || fail "container antigo $svc não está saudável: $state"
done

OLD_WORKDIR="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$OLD_MYSQL_CID")"
OLD_CONFIG_FILES="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.config_files" }}' "$OLD_MYSQL_CID")"
[[ -n "$OLD_WORKDIR" ]] || fail "não foi possível descobrir working_dir do Compose antigo"
[[ -n "$OLD_CONFIG_FILES" ]] || fail "não foi possível descobrir config_files do Compose antigo"

IFS=',' read -r -a OLD_FILES <<< "$OLD_CONFIG_FILES"
OLD_COMPOSE=(docker compose -p "$OLD_PROJECT")
for f in "${OLD_FILES[@]}"; do
  [[ -f "$f" ]] || fail "arquivo Compose antigo não encontrado: $f"
  OLD_COMPOSE+=( -f "$f" )
done

log "Descobrindo volumes antigos reais"
volume_for(){
  local cid="$1" dest="$2"
  docker inspect --format '{{range .Mounts}}{{if eq .Destination "'"$dest"'"}}{{.Name}}{{end}}{{end}}' "$cid"
}
OLD_MYSQL_VOLUME="$(volume_for "$OLD_MYSQL_CID" /var/lib/mysql)"
OLD_TOTEM_VOLUME="$(volume_for "$OLD_TOTEM_CID" /app/data)"
OLD_FACE_VOLUME="$(volume_for "$OLD_FACE_CID" /app/data)"

[[ -n "$OLD_MYSQL_VOLUME" ]] || fail "volume MySQL antigo não encontrado"
[[ -n "$OLD_TOTEM_VOLUME" ]] || fail "volume Totem antigo não encontrado"
[[ -n "$OLD_FACE_VOLUME" ]] || fail "volume Face antigo não encontrado"

printf 'MySQL antigo: %s\nTotem antigo: %s\nFace antigo: %s\n' "$OLD_MYSQL_VOLUME" "$OLD_TOTEM_VOLUME" "$OLD_FACE_VOLUME"

log "Validando Compose novo"
NEW_COMPOSE=(docker compose -p "$NEW_PROJECT" -f compose.yml -f compose.host-edge.yml)
"${NEW_COMPOSE[@]}" config >/dev/null

NEW_MYSQL_VOLUME="${NEW_PROJECT}_mysql_data"
NEW_TOTEM_VOLUME="${NEW_PROJECT}_totem_data"
NEW_FACE_VOLUME="${NEW_PROJECT}_face_scanner_data"

for v in "$NEW_MYSQL_VOLUME" "$NEW_TOTEM_VOLUME" "$NEW_FACE_VOLUME"; do
  if ! docker volume inspect "$v" >/dev/null 2>&1; then
    docker volume create "$v" >/dev/null
  fi
  count="$(docker run --rm -v "$v:/v:ro" alpine:3.23 sh -c 'find /v -mindepth 1 -maxdepth 1 | wc -l')"
  [[ "$count" == "0" ]] || fail "volume novo não está vazio: $v"
done

log "Validando backup existente"
find "$BACKUP_DIR" -maxdepth 2 -type f | sed 's#^#  #' | head -50
if find "$BACKUP_DIR" -maxdepth 2 -type f \( -iname '*sha256*' -o -iname '*checksum*' \) | grep -q .; then
  while IFS= read -r chk; do
    (cd "$(dirname "$chk")" && sha256sum -c "$(basename "$chk")") || fail "checksum inválido: $chk"
  done < <(find "$BACKUP_DIR" -maxdepth 2 -type f \( -iname '*sha256*' -o -iname '*checksum*' \))
fi

df -h "$NEW_ROOT"

log "Parando stack antigo de forma controlada"
(cd "$OLD_WORKDIR" && "${OLD_COMPOSE[@]}" stop)

for cid in "$OLD_MYSQL_CID" "$OLD_HUB_CID" "$OLD_TOTEM_CID" "$OLD_FACE_CID"; do
  state="$(docker inspect --format '{{.State.Status}}' "$cid")"
  [[ "$state" == "exited" || "$state" == "created" ]] || fail "container antigo ainda ativo: $cid ($state)"
done

copy_volume(){
  local src="$1" dst="$2"
  log "Copiando volume $src -> $dst"
  docker run --rm \
    -v "$src:/from:ro" \
    -v "$dst:/to" \
    alpine:3.23 \
    sh -c 'set -e; cd /from; tar cpf - . | tar xpf - -C /to'

  src_kb="$(docker run --rm -v "$src:/v:ro" alpine:3.23 sh -c "du -sk /v | awk '{print \$1}'")"
  dst_kb="$(docker run --rm -v "$dst:/v:ro" alpine:3.23 sh -c "du -sk /v | awk '{print \$1}'")"
  src_files="$(docker run --rm -v "$src:/v:ro" alpine:3.23 sh -c 'find /v -type f | wc -l')"
  dst_files="$(docker run --rm -v "$dst:/v:ro" alpine:3.23 sh -c 'find /v -type f | wc -l')"
  echo "  size_kb: $src_kb -> $dst_kb"
  echo "  files:   $src_files -> $dst_files"
  [[ "$src_files" == "$dst_files" ]] || fail "divergência na quantidade de arquivos $src -> $dst"
}

copy_volume "$OLD_MYSQL_VOLUME" "$NEW_MYSQL_VOLUME"
copy_volume "$OLD_TOTEM_VOLUME" "$NEW_TOTEM_VOLUME"
copy_volume "$OLD_FACE_VOLUME" "$NEW_FACE_VOLUME"

rollback(){
  log "ROLLBACK: parando hub_core e reativando stack antigo"
  (cd "$NEW_ROOT" && "${NEW_COMPOSE[@]}" stop) || true
  (cd "$OLD_WORKDIR" && "${OLD_COMPOSE[@]}" start) || true
  sleep 8
  docker ps --filter "name=${OLD_PROJECT}"
  exit 1
}
trap 'echo "Falha durante cutover." >&2; rollback' ERR

log "Executando preflight novo"
EDGE_MODE=host USE_GPU=0 ./scripts/preflight.sh

log "Build e deploy do hub_core"
./scripts/update.sh --host-edge --no-pull

log "Validando health dos containers novos"
for svc in mysql hub-core totem-api face-scanner; do
  cid="$("${NEW_COMPOSE[@]}" ps -q "$svc")"
  [[ -n "$cid" ]] || fail "serviço novo ausente: $svc"
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid")"
  [[ "$state" == "healthy" || "$state" == "running" ]] || fail "serviço novo $svc inválido: $state"
done

log "Testes HTTP"
curl -fsS http://127.0.0.1:3080/ >/dev/null
curl -fsS http://127.0.0.1:3080/api/health >/dev/null
curl -fsS http://127.0.0.1:3083/ >/dev/null

log "Teste HTTPS"
curl -kfsS https://192.168.51.135/ >/dev/null

log "Logs recentes"
for svc in mysql hub-core totem-api face-scanner; do
  echo "===== $svc ====="
  "${NEW_COMPOSE[@]}" logs --tail=80 "$svc" | tail -80
 done

trap - ERR

log "CUTOVER CONCLUÍDO"
echo "Git:          $HEAD_SHA"
echo "Docker:       $NEW_PROJECT"
echo "MySQL volume: $NEW_MYSQL_VOLUME"
echo "Totem volume: $NEW_TOTEM_VOLUME"
echo "Face volume:  $NEW_FACE_VOLUME"
echo "Volumes antigos preservados: $OLD_MYSQL_VOLUME | $OLD_TOTEM_VOLUME | $OLD_FACE_VOLUME"
echo
"${NEW_COMPOSE[@]}" ps

echo
printf 'Stack antigo permanece parado para rollback: %s\n' "$OLD_PROJECT"
