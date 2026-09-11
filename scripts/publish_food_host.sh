#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

get_env(){
  local key="$1"
  grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true
}
fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ "${EUID}" -eq 0 ]] || fail "execute com sudo: sudo bash scripts/publish_food_host.sh"
[[ -f .env ]] || fail ".env ausente em $ROOT"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"
command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado"
command -v caddy >/dev/null 2>&1 || fail "Caddy não encontrado no host"
[[ -f /etc/caddy/Caddyfile ]] || fail "/etc/caddy/Caddyfile não encontrado"

FOOD_PORT="${TOTEM_FOOD_LOCAL_PORT:-$(get_env TOTEM_FOOD_LOCAL_PORT)}"; FOOD_PORT="${FOOD_PORT:-3085}"
PUBLIC_HOST="$(get_env PMS_PUBLIC_HOST)"; PUBLIC_HOST="${PUBLIC_HOST:-192.168.51.135}"
BASE_URL="https://${PUBLIC_HOST}"

log "Validando somente o Totem Food local"
curl -fsS "http://127.0.0.1:${FOOD_PORT}/api/health" >/dev/null || fail "Totem Food não respondeu em 127.0.0.1:${FOOD_PORT}"

CADDYFILE="/etc/caddy/Caddyfile"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/etc/caddy/Caddyfile.food_${STAMP}.bak"
cp -a "$CADDYFILE" "$BACKUP"
echo "Backup do Caddy: $BACKUP"

export CADDYFILE FOOD_PORT
python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ['CADDYFILE'])
food = os.environ['FOOD_PORT']
text = path.read_text(encoding='utf-8')

food_block = f'''        # HUB_CORE_FOOD_BEGIN
        redir /food /food/ 308
        handle_path /food/* {{
            reverse_proxy 127.0.0.1:{food} {{
                header_up X-Forwarded-Prefix /food
            }}
        }}
        # HUB_CORE_FOOD_END
'''

# Se já existe bloco isolado, apenas atualiza.
pattern = re.compile(r'(?ms)^\s*# HUB_CORE_FOOD_BEGIN\n.*?^\s*# HUB_CORE_FOOD_END\n?')
if pattern.search(text):
    text = pattern.sub(food_block, text, count=1)
    path.write_text(text, encoding='utf-8')
    raise SystemExit(0)

# Se a regra /food já estiver dentro do bloco global antigo, atualiza somente a porta.
food_existing = re.compile(
    r'(?ms)(\s*redir /food /food/ 308\n\s*handle_path /food/\* \{\n\s*reverse_proxy 127\.0\.0\.1:)(\d+)(\s*\{\n\s*header_up X-Forwarded-Prefix /food\n\s*\}\n\s*\})'
)
if food_existing.search(text):
    text = food_existing.sub(lambda m: m.group(1) + food + m.group(3), text, count=1)
    path.write_text(text, encoding='utf-8')
    raise SystemExit(0)

# Preferência: inserir dentro do route oficial do HUB, antes do handle fallback.
start = text.find('# HUB_CORE_MODULES_BEGIN')
end = text.find('# HUB_CORE_MODULES_END')
if start != -1 and end != -1 and end > start:
    segment = text[start:end]
    fallback = re.search(r'(?m)^\s{8}handle \{\s*$', segment)
    if fallback:
        pos = start + fallback.start()
        text = text[:pos] + food_block + '\n' + text[pos:]
        path.write_text(text, encoding='utf-8')
        raise SystemExit(0)

raise SystemExit('Não foi possível localizar com segurança o bloco de rotas do HUB Core. Backup preservado; nenhuma publicação aplicada.')
PY

log "Validando Caddyfile"
if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
  echo "Configuração inválida; restaurando backup." >&2
  cp -a "$BACKUP" "$CADDYFILE"
  exit 1
fi

log "Recarregando Caddy"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
  systemctl reload caddy
else
  caddy reload --config "$CADDYFILE" --adapter caddyfile
fi

log "Testando somente /food/"
FOOD_CODE="$(curl -kLsS -o /tmp/hub_core_food.$$ -w '%{http_code}' "${BASE_URL}/food/")"
trap 'rm -f /tmp/hub_core_food.$$' EXIT
[[ "$FOOD_CODE" == "200" ]] || fail "Totem Food público respondeu HTTP $FOOD_CODE"
curl -kfsS "${BASE_URL}/food/api/health" >/dev/null || fail "health público do Food falhou"
curl -kfsS "${BASE_URL}/food/styles.css" >/dev/null || fail "CSS público do Food falhou"
curl -kfsS "${BASE_URL}/food/app.js" >/dev/null || fail "JavaScript público do Food falhou"

echo "Totem Food publicado sem alterar os outros módulos:"
echo "  ${BASE_URL}/food/"
