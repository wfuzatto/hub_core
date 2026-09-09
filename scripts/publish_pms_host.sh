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
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"
command -v python3 >/dev/null 2>&1 || fail "python3 não encontrado"

PMS_LOCAL_PORT="$(get_env PMS_LOCAL_PORT)"
PMS_LOCAL_PORT="${PMS_LOCAL_PORT:-3084}"
TOTEM_LOCAL_PORT="$(get_env TOTEM_LOCAL_PORT)"
TOTEM_LOCAL_PORT="${TOTEM_LOCAL_PORT:-3080}"
PMS_PUBLIC_PATH="$(get_env PMS_PUBLIC_PATH)"
PMS_PUBLIC_PATH="${PMS_PUBLIC_PATH:-/pms}"
PMS_PUBLIC_PATH="/${PMS_PUBLIC_PATH#/}"
PMS_PUBLIC_PATH="${PMS_PUBLIC_PATH%/}"
PUBLIC_HOST="$(get_env PMS_PUBLIC_HOST)"
PUBLIC_HOST="${PUBLIC_HOST:-192.168.51.135}"
PMS_PUBLIC_URL="https://${PUBLIC_HOST}${PMS_PUBLIC_PATH}/"

log "Validando PMS local antes de publicar"
curl -fsS "http://127.0.0.1:${PMS_LOCAL_PORT}/health.php" >/dev/null \
  || fail "PMS não respondeu em 127.0.0.1:${PMS_LOCAL_PORT}"
echo "PMS local: OK"

if command -v caddy >/dev/null 2>&1 && [[ -f /etc/caddy/Caddyfile ]]; then
  [[ "${EUID}" -eq 0 ]] || fail "execute este script com sudo: sudo bash scripts/publish_pms_host.sh"

  CADDYFILE="/etc/caddy/Caddyfile"
  STAMP="$(date +%Y%m%d_%H%M%S)"
  BACKUP="/etc/caddy/Caddyfile.hub_core_pms_${STAMP}.bak"

  log "Publicando PMS no Caddy do host em ${PMS_PUBLIC_PATH}/"
  cp -a "$CADDYFILE" "$BACKUP"
  echo "Backup do Caddy: $BACKUP"

  if grep -q '# HUB_CORE_PMS_BEGIN' "$CADDYFILE"; then
    echo "Regra HUB Core PMS já existe; mantendo configuração atual."
  else
    export CADDYFILE PMS_PUBLIC_PATH PMS_LOCAL_PORT TOTEM_LOCAL_PORT
    python3 <<'PY'
import os
import re
from pathlib import Path

path = Path(os.environ['CADDYFILE'])
public_path = os.environ['PMS_PUBLIC_PATH']
pms_port = os.environ['PMS_LOCAL_PORT']
totem_port = os.environ['TOTEM_LOCAL_PORT']
text = path.read_text(encoding='utf-8')

pattern = re.compile(
    rf'^(?P<indent>[ \t]*)reverse_proxy[ \t]+(?:http://)?(?:127\.0\.0\.1|localhost):{re.escape(totem_port)}[ \t]*$',
    re.MULTILINE,
)
matches = list(pattern.finditer(text))
if len(matches) != 1:
    raise SystemExit(
        f'Não foi possível localizar exatamente um reverse_proxy simples para 127.0.0.1:{totem_port}; encontrados={len(matches)}. Nada foi aplicado.'
    )

m = matches[0]
i = m.group('indent')
block = f'''{i}# HUB_CORE_PMS_BEGIN
{i}route {{
{i}    redir {public_path} {public_path}/ 308

{i}    handle_path {public_path}/* {{
{i}        reverse_proxy 127.0.0.1:{pms_port} {{
{i}            header_up X-Forwarded-Prefix {public_path}
{i}        }}
{i}    }}

{i}    handle {{
{i}        reverse_proxy 127.0.0.1:{totem_port}
{i}    }}
{i}}}
{i}# HUB_CORE_PMS_END'''

new_text = text[:m.start()] + block + text[m.end():]
path.write_text(new_text, encoding='utf-8')
PY
  fi

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

elif command -v nginx >/dev/null 2>&1; then
  fail "NGINX detectado no host. A publicação automática atual é protegida para Caddy; nenhuma configuração foi alterada."
else
  fail "não foi encontrado Caddy em /etc/caddy/Caddyfile nem NGINX no host"
fi

log "Testando publicação HTTPS"
TMP_BODY="$(mktemp)"
trap 'rm -f "$TMP_BODY"' EXIT
RESULT="$(curl -kLsS -o "$TMP_BODY" -w '%{http_code}|%{url_effective}' "$PMS_PUBLIC_URL")"
HTTP_CODE="${RESULT%%|*}"
FINAL_URL="${RESULT#*|}"

[[ "$HTTP_CODE" == "200" ]] || fail "publicação respondeu HTTP $HTTP_CODE em $FINAL_URL"

echo "PMS público: OK"
echo "URL: $PMS_PUBLIC_URL"
echo "URL final: $FINAL_URL"

if grep -Eq "(/pms/assets/|${PMS_PUBLIC_PATH#/}/assets/)" "$TMP_BODY"; then
  echo "Prefixo de assets: OK"
else
  echo "AVISO: login respondeu 200, mas não foi possível confirmar referência de asset prefixado no HTML."
fi

echo
printf 'PUBLICAÇÃO PMS CONCLUÍDA: %s\n' "$PMS_PUBLIC_URL"
