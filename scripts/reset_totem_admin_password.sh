#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ -f .env ]] || fail ".env ausente em $ROOT"
command -v docker >/dev/null 2>&1 || fail "docker não encontrado"
command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado"

docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 não disponível"

printf 'Nova senha administrativa do Totem: '
IFS= read -r -s NEW_PASSWORD
echo
printf 'Confirme a nova senha: '
IFS= read -r -s CONFIRM_PASSWORD
echo

[[ -n "$NEW_PASSWORD" ]] || fail "senha vazia não é permitida"
[[ "$NEW_PASSWORD" == "$CONFIRM_PASSWORD" ]] || fail "as senhas não conferem"
[[ ${#NEW_PASSWORD} -ge 10 ]] || fail "use pelo menos 10 caracteres"
[[ "$NEW_PASSWORD" != "251933" ]] || fail "a senha legada 251933 não deve ser reutilizada"

COMPOSE=(docker compose -f compose.yml -f compose.host-edge.yml)
CID="$("${COMPOSE[@]}" ps -q totem-api 2>/dev/null || true)"
[[ -n "$CID" ]] || fail "container totem-api não está em execução"

STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$ROOT/backups/totem_admin_reset_${STAMP}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
cp -a .env "$BACKUP_DIR/.env.before"
chmod 600 "$BACKUP_DIR/.env.before"

log "Criando backup do SQLite do Totem"
"${COMPOSE[@]}" cp totem-api:/app/data/totem.sqlite "$BACKUP_DIR/totem.sqlite.before"
chmod 600 "$BACKUP_DIR/totem.sqlite.before"

echo "Backup: $BACKUP_DIR"

log "Atualizando segredo local do HUB Core"
RESET_PASSWORD="$NEW_PASSWORD" python3 <<'PY'
import os
from pathlib import Path

path = Path('.env')
password = os.environ['RESET_PASSWORD']
lines = path.read_text(encoding='utf-8').splitlines()
out = []
seen = False
for line in lines:
    if line.startswith('TOTEM_ADMIN_PASSWORD='):
        out.append('TOTEM_ADMIN_PASSWORD=' + password)
        seen = True
    else:
        out.append(line)
if not seen:
    out.append('TOTEM_ADMIN_PASSWORD=' + password)
path.write_text('\n'.join(out) + '\n', encoding='utf-8')
PY
chmod 600 .env

log "Recriando somente o Totem para carregar o novo segredo"
"${COMPOSE[@]}" up -d --no-deps --force-recreate totem-api

DEADLINE=$((SECONDS + 90))
while true; do
  CID="$("${COMPOSE[@]}" ps -q totem-api 2>/dev/null || true)"
  STATE="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CID" 2>/dev/null || true)"
  [[ "$STATE" == "healthy" ]] && break
  (( SECONDS < DEADLINE )) || fail "timeout aguardando Totem saudável; backup preservado em $BACKUP_DIR"
  sleep 2
done

log "Sincronizando hash administrativo persistente"
"${COMPOSE[@]}" exec -T totem-api node - <<'NODE'
const crypto = require('crypto');
const Database = require('better-sqlite3');

const password = process.env.ADMIN_PASSWORD || '';
if (!password) {
  console.error('ADMIN_PASSWORD ausente no container');
  process.exit(1);
}

const salt = crypto.randomBytes(16).toString('hex');
const hash = crypto.scryptSync(password, salt, 64).toString('hex');
const stored = `${salt}:${hash}`;

const db = new Database('/app/data/totem.sqlite');
db.pragma('busy_timeout = 5000');
const result = db.prepare(`
  INSERT INTO settings(key, value, updated_at)
  VALUES('admin_password_hash', ?, CURRENT_TIMESTAMP)
  ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=CURRENT_TIMESTAMP
`).run(stored);
db.close();

if (!result.changes) {
  console.error('hash administrativo não foi atualizado');
  process.exit(1);
}
console.log('Hash administrativo atualizado: OK');
NODE

log "Validando login pela API real do Totem"
"${COMPOSE[@]}" exec -T totem-api node - <<'NODE'
(async () => {
  const response = await fetch('http://127.0.0.1:3080/api/admin/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ password: process.env.ADMIN_PASSWORD || '' })
  });
  if (!response.ok) {
    console.error(`LOGIN ADMIN: FALHOU (HTTP ${response.status})`);
    process.exit(1);
  }
  const data = await response.json().catch(() => ({}));
  if (!data.token) {
    console.error('LOGIN ADMIN: FALHOU (token ausente)');
    process.exit(1);
  }
  console.log('LOGIN ADMIN: OK');
})().catch(err => {
  console.error('LOGIN ADMIN: FALHOU', err.message);
  process.exit(1);
});
NODE

unset NEW_PASSWORD CONFIRM_PASSWORD RESET_PASSWORD || true

echo
echo "Senha do Totem redefinida e sincronizada com segurança."
echo "Nenhuma senha foi exibida."
echo "Backup de rollback: $BACKUP_DIR"
