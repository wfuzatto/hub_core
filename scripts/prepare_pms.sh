#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/hotelaria_github"
PUB="$KEY.pub"
SSH_CONFIG="$SSH_DIR/config"
ALIAS="github-hotelaria"
REPO="git@${ALIAS}:wfuzatto/hotelaria.git"
PMS_VOLUME="hub_core_pms_storage"

PMS_DB_HOST="mysql"
PMS_DB_PORT="3306"
PMS_DB_NAME="hotel_reservas"
PMS_DB_USER="pms_app"
PMS_LOCAL_BIND="127.0.0.1"
PMS_LOCAL_PORT="3084"
PMS_ADMIN_EMAIL="admin@pms.local"

log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail(){ echo "ERRO: $*" >&2; exit 1; }

for cmd in docker git ssh ssh-keygen openssl awk grep sed; do
  command -v "$cmd" >/dev/null 2>&1 || fail "comando ausente: $cmd"
done

[[ -f .env ]] || fail ".env ausente em $ROOT"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY" ]]; then
  log "Criando deploy key somente leitura para o PMS privado"
  ssh-keygen -q -t ed25519 -N '' -C "hotelaria@$(hostname)" -f "$KEY"
  chmod 600 "$KEY"
  chmod 644 "$PUB"
fi

if ! grep -q '^Host github-hotelaria$' "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

Host github-hotelaria
    HostName github.com
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
EOF
fi
chmod 600 "$SSH_CONFIG"

log "Validando acesso ao repositório privado wfuzatto/hotelaria"
if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes" git ls-remote "$REPO" HEAD >/dev/null 2>&1; then
  echo
  echo "A deploy key do PMS ainda não está autorizada no GitHub."
  echo "Adicione a chave abaixo em:"
  echo "  wfuzatto/hotelaria -> Settings -> Deploy keys -> Add deploy key"
  echo "Título sugerido: PMS Hotelaria - $(hostname)"
  echo "NÃO marque Allow write access; esta chave deve ser somente leitura."
  echo
  cat "$PUB"
  echo
  echo "Depois execute novamente:"
  echo "  cd $ROOT && bash scripts/update_docker.sh"
  exit 2
fi

echo "Acesso privado ao PMS: OK"

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

get_env(){
  local key="$1"
  grep -E "^${key}=" .env | tail -1 | cut -d= -f2- || true
}

log "Configurando banco interno do PMS automaticamente"
PMS_DB_PASSWORD="$(get_env PMS_DB_PASSWORD)"
if [[ -z "$PMS_DB_PASSWORD" || "$PMS_DB_PASSWORD" == CHANGE_ME* ]]; then
  PMS_DB_PASSWORD="$(openssl rand -hex 24)"
fi

PMS_ADMIN_PASSWORD="$(get_env PMS_ADMIN_PASSWORD)"
if [[ -z "$PMS_ADMIN_PASSWORD" || "$PMS_ADMIN_PASSWORD" == CHANGE_ME* ]]; then
  PMS_ADMIN_PASSWORD="$(openssl rand -hex 12)"
fi

upsert_env PMS_DB_HOST "$PMS_DB_HOST"
upsert_env PMS_DB_PORT "$PMS_DB_PORT"
upsert_env PMS_DB_NAME "$PMS_DB_NAME"
upsert_env PMS_DB_USER "$PMS_DB_USER"
upsert_env PMS_DB_PASSWORD "$PMS_DB_PASSWORD"
upsert_env PMS_LOCAL_BIND "$PMS_LOCAL_BIND"
upsert_env PMS_LOCAL_PORT "$PMS_LOCAL_PORT"
upsert_env PMS_ADMIN_EMAIL "$PMS_ADMIN_EMAIL"
upsert_env PMS_ADMIN_PASSWORD "$PMS_ADMIN_PASSWORD"

log "Preparando storage persistente do PMS"
if ! docker volume inspect "$PMS_VOLUME" >/dev/null 2>&1; then
  docker volume create "$PMS_VOLUME" >/dev/null
  echo "Volume criado: $PMS_VOLUME"
else
  echo "Volume existente: $PMS_VOLUME"
fi

log "Preparando módulos homologados"
./scripts/bootstrap.sh

COMPOSE=(docker compose -f compose.yml -f compose.host-edge.yml)
"${COMPOSE[@]}" config >/dev/null

log "Garantindo MySQL do HUB Core"
mysql_cid="$("${COMPOSE[@]}" ps -q mysql 2>/dev/null || true)"
if [[ -z "$mysql_cid" ]]; then
  "${COMPOSE[@]}" up -d mysql
  mysql_cid="$("${COMPOSE[@]}" ps -q mysql)"
fi

DEADLINE=$((SECONDS + 120))
while true; do
  state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$mysql_cid" 2>/dev/null || true)"
  [[ "$state" == "healthy" ]] && break
  (( SECONDS < DEADLINE )) || fail "timeout aguardando MySQL saudável (estado=$state)"
  sleep 2
done

echo "MySQL: healthy"

log "Criando banco e usuário dedicados do PMS"
"${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot' <<SQL
CREATE DATABASE IF NOT EXISTS hotel_reservas CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'pms_app'@'%' IDENTIFIED BY '${PMS_DB_PASSWORD}';
ALTER USER 'pms_app'@'%' IDENTIFIED BY '${PMS_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON hotel_reservas.* TO 'pms_app'@'%';
FLUSH PRIVILEGES;
SQL

PMS_ROOT="$ROOT/modules/hotelaria/sistema"
[[ -f "$PMS_ROOT/banco.sql" ]] || fail "schema PMS ausente: $PMS_ROOT/banco.sql"

apply_sql(){
  local file="$1"
  [[ -f "$file" ]] || return 0
  echo "[schema] $(basename "$file")"
  "${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot hotel_reservas' < "$file"
}

log "Aplicando schema idempotente do PMS"
apply_sql "$PMS_ROOT/banco.sql"
apply_sql "$PMS_ROOT/sql/usuarios.sql"
apply_sql "$PMS_ROOT/sql/fnrh_links.sql"
apply_sql "$PMS_ROOT/sql/pdv.sql"

log "Garantindo primeiro administrador do PMS"
USER_COUNT="$("${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -Nse "SELECT COUNT(*) FROM hotel_reservas.usuarios" -uroot' | tr -d '\r')"
if [[ "$USER_COUNT" == "0" ]]; then
  hub_cid="$("${COMPOSE[@]}" ps -q hub-core 2>/dev/null || true)"
  if [[ -n "$hub_cid" ]]; then
    ADMIN_HASH="$("${COMPOSE[@]}" exec -T -e PMS_ADMIN_PASSWORD="$PMS_ADMIN_PASSWORD" hub-core php -r 'echo password_hash(getenv("PMS_ADMIN_PASSWORD"), PASSWORD_BCRYPT);')"
  else
    ADMIN_HASH="$(docker run --rm -e PMS_ADMIN_PASSWORD="$PMS_ADMIN_PASSWORD" php:8.3-cli-alpine php -r 'echo password_hash(getenv("PMS_ADMIN_PASSWORD"), PASSWORD_BCRYPT);')"
  fi

  "${COMPOSE[@]}" exec -T mysql sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot hotel_reservas' <<SQL
INSERT INTO clientes (nome, status)
SELECT 'Administracao PMS', 'ativo'
WHERE NOT EXISTS (SELECT 1 FROM clientes);

SET @cliente_id := (SELECT id FROM clientes ORDER BY id LIMIT 1);

INSERT INTO hoteis (cliente_id, codigo, nome, status)
SELECT @cliente_id, 'HOTEL-001', 'Hotel Principal', 'ativo'
WHERE NOT EXISTS (SELECT 1 FROM hoteis WHERE cliente_id = @cliente_id);

SET @hotel_id := (SELECT id FROM hoteis WHERE cliente_id = @cliente_id ORDER BY id LIMIT 1);

INSERT INTO usuarios (cliente_id, hotel_id, nome, email, senha_hash, role, status)
SELECT @cliente_id, @hotel_id, 'Administrador', '${PMS_ADMIN_EMAIL}', '${ADMIN_HASH}', 'super_admin', 'ativo'
WHERE NOT EXISTS (SELECT 1 FROM usuarios);
SQL
  echo "Administrador inicial criado. Credenciais armazenadas somente em .env (chmod 600)."
else
  echo "Usuários PMS existentes: $USER_COUNT (nenhum usuário foi alterado)."
fi

log "Validando acesso do usuário da aplicação"
"${COMPOSE[@]}" exec -T \
  -e PMS_DB_PASSWORD="$PMS_DB_PASSWORD" \
  mysql sh -c 'MYSQL_PWD="$PMS_DB_PASSWORD" mysql -h127.0.0.1 -upms_app -Dhotel_reservas -Nse "SELECT 1"' >/dev/null

echo
cat <<EOF
PMS preparado automaticamente para o HUB Core.
Banco:      mysql:3306/$PMS_DB_NAME
Usuário:    $PMS_DB_USER
Storage:    $PMS_VOLUME
Host-edge:  http://127.0.0.1:$PMS_LOCAL_PORT

Nenhuma senha foi exibida. Segredos permanecem apenas no .env local.
EOF
