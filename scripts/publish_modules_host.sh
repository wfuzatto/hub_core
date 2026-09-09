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

[[ -f .env ]] || fail ".env ausente em $ROOT"
[[ "${EUID}" -eq 0 ]] || fail "execute com sudo: sudo bash scripts/publish_modules_host.sh"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"
command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado"
command -v caddy >/dev/null 2>&1 || fail "Caddy não encontrado no host"
[[ -f /etc/caddy/Caddyfile ]] || fail "/etc/caddy/Caddyfile não encontrado"

HUB_PORT="${HUB_LOCAL_PORT:-$(get_env HUB_LOCAL_PORT)}"; HUB_PORT="${HUB_PORT:-3083}"
PMS_PORT="${PMS_LOCAL_PORT:-$(get_env PMS_LOCAL_PORT)}"; PMS_PORT="${PMS_PORT:-3084}"
TOTEM_PORT="${TOTEM_LOCAL_PORT:-$(get_env TOTEM_LOCAL_PORT)}"; TOTEM_PORT="${TOTEM_PORT:-3080}"
FACE_PORT="8092"
PUBLIC_HOST="$(get_env PMS_PUBLIC_HOST)"; PUBLIC_HOST="${PUBLIC_HOST:-192.168.51.135}"
BASE_URL="https://${PUBLIC_HOST}"

log "Validando pontes locais antes do cutover"
curl -fsS "http://127.0.0.1:${HUB_PORT}/health.php" >/dev/null || fail "HUB não respondeu em 127.0.0.1:${HUB_PORT}"
curl -fsS "http://127.0.0.1:${PMS_PORT}/health.php" >/dev/null || fail "PMS não respondeu em 127.0.0.1:${PMS_PORT}"
curl -fsS "http://127.0.0.1:${TOTEM_PORT}/api/health" >/dev/null || fail "Totem não respondeu em 127.0.0.1:${TOTEM_PORT}"
curl -fsS "http://127.0.0.1:${FACE_PORT}/api/v1/health" >/dev/null || fail "Face Scanner não respondeu em 127.0.0.1:${FACE_PORT}"
echo "HUB/PMS/Totem/Face locais: OK"

CADDYFILE="/etc/caddy/Caddyfile"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP="/etc/caddy/Caddyfile.hub_core_modules_${STAMP}.bak"
cp -a "$CADDYFILE" "$BACKUP"
echo "Backup do Caddy: $BACKUP"

export CADDYFILE HUB_PORT PMS_PORT TOTEM_PORT FACE_PORT
python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ['CADDYFILE'])
hub = os.environ['HUB_PORT']
pms = os.environ['PMS_PORT']
totem = os.environ['TOTEM_PORT']
face = os.environ['FACE_PORT']
text = path.read_text(encoding='utf-8')


def block(indent: str) -> str:
    i = indent
    return f'''{i}# HUB_CORE_MODULES_BEGIN
{i}route {{
{i}    redir /pms /pms/ 308
{i}    handle_path /pms/* {{
{i}        reverse_proxy 127.0.0.1:{pms} {{
{i}            header_up X-Forwarded-Prefix /pms
{i}        }}
{i}    }}

{i}    redir /totem /totem/ 308
{i}    handle /totem/* {{
{i}        reverse_proxy 127.0.0.1:{totem} {{
{i}            header_up X-Forwarded-Prefix /totem
{i}        }}
{i}    }}

{i}    redir /face-scanner /face-scanner/ 308
{i}    handle_path /face-scanner/* {{
{i}        reverse_proxy 127.0.0.1:{face} {{
{i}            header_up X-Forwarded-Prefix /face-scanner
{i}        }}
{i}    }}

{i}    handle {{
{i}        reverse_proxy 127.0.0.1:{hub}
{i}    }}
{i}}}
{i}# HUB_CORE_MODULES_END'''

patterns = [
    re.compile(r'(?ms)^(?P<indent>[ \t]*)# HUB_CORE_MODULES_BEGIN\n.*?^(?P=indent)# HUB_CORE_MODULES_END[ \t]*$'),
    re.compile(r'(?ms)^(?P<indent>[ \t]*)# HUB_CORE_PMS_BEGIN\n.*?^(?P=indent)# HUB_CORE_PMS_END[ \t]*$'),
]

for pattern in patterns:
    match = pattern.search(text)
    if match:
        text = text[:match.start()] + block(match.group('indent')) + text[match.end():]
        path.write_text(text, encoding='utf-8')
        raise SystemExit(0)

simple = re.compile(
    rf'^(?P<indent>[ \t]*)reverse_proxy[ \t]+(?:http://)?(?:127\.0\.0\.1|localhost):{re.escape(totem)}[ \t]*$',
    re.MULTILINE,
)
matches = list(simple.finditer(text))
if len(matches) != 1:
    raise SystemExit(
        f'Não foi possível localizar a regra antiga do Totem com segurança; encontrados={len(matches)}. Backup preservado e nada foi aplicado.'
    )
match = matches[0]
text = text[:match.start()] + block(match.group('indent')) + text[match.end():]
path.write_text(text, encoding='utf-8')
PY

log "Validando Caddyfile"
if ! caddy validate --config "$CADDYFILE" --adapter caddyfile; then
  echo "Configuração inválida; restaurando backup." >&2
  cp -a "$BACKUP" "$CADDYFILE"
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null || true
  exit 1
fi

log "Recarregando Caddy"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet caddy; then
  systemctl reload caddy
else
  caddy reload --config "$CADDYFILE" --adapter caddyfile
fi

log "Testando URLs públicas"
HUB_CODE="$(curl -kLsS -o /tmp/hub_core_public.$$ -w '%{http_code}' "${BASE_URL}/")"
PMS_RESULT="$(curl -kLsS -o /tmp/hub_core_pms.$$ -w '%{http_code}|%{url_effective}' "${BASE_URL}/pms/")"
TOTEM_CODE="$(curl -kLsS -o /tmp/hub_core_totem.$$ -w '%{http_code}' "${BASE_URL}/totem/")"
TOTEM_HEALTH="$(curl -kfsS "${BASE_URL}/totem/api/health")"
FACE_HEALTH="$(curl -kfsS "${BASE_URL}/face-scanner/api/v1/health")"
trap 'rm -f /tmp/hub_core_public.$$ /tmp/hub_core_pms.$$ /tmp/hub_core_totem.$$' EXIT

[[ "$HUB_CODE" == "200" ]] || fail "HUB público respondeu HTTP $HUB_CODE"
[[ "${PMS_RESULT%%|*}" == "200" ]] || fail "PMS público respondeu ${PMS_RESULT%%|*}"
[[ "$TOTEM_CODE" == "200" ]] || fail "Totem público respondeu HTTP $TOTEM_CODE"
grep -q '/totem/' /tmp/hub_core_totem.$$ || fail "Totem respondeu 200, mas os assets não estão prefixados com /totem/"

echo "HUB:          ${BASE_URL}/ -> HTTP $HUB_CODE"
echo "PMS:          ${BASE_URL}/pms/ -> ${PMS_RESULT#*|}"
echo "Totem:        ${BASE_URL}/totem/ -> HTTP $TOTEM_CODE"
echo "Totem health: $TOTEM_HEALTH"
echo "Face health:  $FACE_HEALTH"
echo
echo "PUBLICAÇÃO POR MÓDULOS CONCLUÍDA"
echo "  ${BASE_URL}/"
echo "  ${BASE_URL}/pms/"
echo "  ${BASE_URL}/totem/"
echo "  ${BASE_URL}/face-scanner/"
