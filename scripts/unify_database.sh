#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TARGET_DB="hotel_reservas"
LEGACY_DB="hub_hotelaria"
COMPOSE=(docker compose -f compose.yml -f compose.host-edge.yml)

log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail(){ echo "ERRO: $*" >&2; exit 1; }

[[ -f .env ]] || fail ".env ausente em $ROOT"
command -v docker >/dev/null 2>&1 || fail "docker não encontrado"
command -v gzip >/dev/null 2>&1 || fail "gzip não encontrado"

upsert_env(){
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" '
    BEGIN { found=0 }
    $0 ~ "^" k "=" { print k "=" v; found=1; next }
    { print }
    END { if (!found) print k "=" v }
  ' .env > "$tmp"
  mv "$tmp" .env
  chmod 600 .env
}

mysql_root(){
  "${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$@"' sh "$@"
}

log "Validando MySQL"
mysql_cid="$("${COMPOSE[@]}" ps -q mysql 2>/dev/null || true)"
[[ -n "$mysql_cid" ]] || fail "container MySQL não está em execução"
state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$mysql_cid" 2>/dev/null || true)"
[[ "$state" == "healthy" ]] || fail "MySQL não está healthy (estado=$state)"

echo "MySQL: healthy"

log "Criando backup completo antes da unificação"
BACKUP_OUTPUT="$(bash scripts/backup.sh)"
printf '%s\n' "$BACKUP_OUTPUT"
BACKUP_DIR="$(printf '%s\n' "$BACKUP_OUTPUT" | sed -n 's/^Backup concluído: //p' | tail -1)"
[[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || fail "não foi possível identificar o diretório do backup"

log "Garantindo banco de destino $TARGET_DB"
mysql_root -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

LEGACY_EXISTS="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$LEGACY_DB';" | tr -d '\r')"
if [[ "$LEGACY_EXISTS" == "1" ]]; then
  log "Auditando banco legado $LEGACY_DB"
  TABLE_COUNT="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$LEGACY_DB' AND TABLE_TYPE='BASE TABLE';" | tr -d '\r')"
  VIEW_COUNT="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$LEGACY_DB' AND TABLE_TYPE='VIEW';" | tr -d '\r')"
  echo "Tabelas legadas: $TABLE_COUNT"
  echo "Views legadas:   $VIEW_COUNT"

  if [[ "$TABLE_COUNT" != "0" ]]; then
    echo "Inventário de tabelas do legado:"
    mysql_root -e "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$LEGACY_DB' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;"
  fi

  log "Salvando dump dedicado do banco legado"
  "${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -uroot --single-transaction --routines --events --triggers --databases hub_hotelaria' \
    | gzip > "$BACKUP_DIR/mysql-hub_hotelaria-before-unify.sql.gz"
  [[ -s "$BACKUP_DIR/mysql-hub_hotelaria-before-unify.sql.gz" ]] || fail "dump dedicado do banco legado ficou vazio"
  sha256sum "$BACKUP_DIR/mysql-hub_hotelaria-before-unify.sql.gz" >> "$BACKUP_DIR/SHA256SUMS"

  log "Removendo schema legado após backup confirmado"
  mysql_root -e "DROP DATABASE \`$LEGACY_DB\`;"
else
  echo "Banco legado $LEGACY_DB já não existe."
fi

log "Sincronizando configuração para banco único"
upsert_env MYSQL_DATABASE "$TARGET_DB"
upsert_env PMS_DB_HOST "mysql"
upsert_env PMS_DB_PORT "3306"
upsert_env PMS_DB_NAME "$TARGET_DB"

log "Validando resultado da unificação"
LEGACY_AFTER="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$LEGACY_DB';" | tr -d '\r')"
TARGET_AFTER="$(mysql_root -Nse "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$TARGET_DB';" | tr -d '\r')"
[[ "$LEGACY_AFTER" == "0" ]] || fail "$LEGACY_DB ainda existe"
[[ "$TARGET_AFTER" == "1" ]] || fail "$TARGET_DB não existe"

echo
mysql_root -e "SHOW DATABASES;"
echo
printf 'BANCO ÚNICO CONFIGURADO: %s\n' "$TARGET_DB"
printf 'Backup de rollback: %s\n' "$BACKUP_DIR"
echo "Agora execute o atualizador oficial para recriar os serviços com a configuração unificada."
