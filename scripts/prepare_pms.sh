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

log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail(){ echo "ERRO: $*" >&2; exit 1; }

[[ -f .env ]] || fail ".env ausente em $ROOT"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ ! -f "$KEY" ]]; then
  log "Criando deploy key somente para leitura do PMS privado"
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
  echo "Depois de cadastrar a chave, execute novamente:"
  echo "  cd $ROOT && bash scripts/prepare_pms.sh"
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

log "Configurando conexão do PMS"
PMS_DB_HOST="$(get_env PMS_DB_HOST)"
PMS_DB_PORT="$(get_env PMS_DB_PORT)"
PMS_DB_NAME="$(get_env PMS_DB_NAME)"
PMS_DB_USER="$(get_env PMS_DB_USER)"
PMS_DB_PASSWORD="$(get_env PMS_DB_PASSWORD)"

if [[ -z "$PMS_DB_HOST" || "$PMS_DB_HOST" == CHANGE_ME* ]]; then
  read -r -p "Host atual do banco do PMS: " PMS_DB_HOST
fi
if [[ -z "$PMS_DB_PORT" ]]; then
  PMS_DB_PORT=3306
fi
if [[ -z "$PMS_DB_NAME" || "$PMS_DB_NAME" == CHANGE_ME* ]]; then
  read -r -p "Nome do banco do PMS: " PMS_DB_NAME
fi
if [[ -z "$PMS_DB_USER" || "$PMS_DB_USER" == CHANGE_ME* ]]; then
  read -r -p "Usuário do banco do PMS: " PMS_DB_USER
fi
if [[ -z "$PMS_DB_PASSWORD" || "$PMS_DB_PASSWORD" == CHANGE_ME* ]]; then
  read -r -s -p "Senha do banco do PMS: " PMS_DB_PASSWORD
  printf '\n'
fi

[[ -n "$PMS_DB_HOST" ]] || fail "PMS_DB_HOST vazio"
[[ -n "$PMS_DB_NAME" ]] || fail "PMS_DB_NAME vazio"
[[ -n "$PMS_DB_USER" ]] || fail "PMS_DB_USER vazio"
[[ -n "$PMS_DB_PASSWORD" ]] || fail "PMS_DB_PASSWORD vazio"

upsert_env PMS_DB_HOST "$PMS_DB_HOST"
upsert_env PMS_DB_PORT "$PMS_DB_PORT"
upsert_env PMS_DB_NAME "$PMS_DB_NAME"
upsert_env PMS_DB_USER "$PMS_DB_USER"
upsert_env PMS_DB_PASSWORD "$PMS_DB_PASSWORD"
upsert_env PMS_LOCAL_BIND "$(get_env PMS_LOCAL_BIND | grep . || echo 127.0.0.1)"
upsert_env PMS_LOCAL_PORT "$(get_env PMS_LOCAL_PORT | grep . || echo 3084)"

log "Preparando storage persistente do PMS"
if ! docker volume inspect "$PMS_VOLUME" >/dev/null 2>&1; then
  docker volume create "$PMS_VOLUME" >/dev/null
  echo "Volume criado: $PMS_VOLUME"
else
  echo "Volume existente: $PMS_VOLUME"
fi

log "Validando configuração Compose"
docker compose -f compose.yml -f compose.host-edge.yml config >/dev/null

echo
cat <<EOF
PMS preparado para o HUB Core.

Próximo comando:
  cd $ROOT
  bash scripts/update_docker.sh

Após o deploy:
  curl -fsS http://127.0.0.1:3084/health.php
  docker compose -f compose.yml -f compose.host-edge.yml ps pms
EOF
