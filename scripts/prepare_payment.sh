#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ACTIVATE_FOOD=0
for arg in "$@"; do
  case "$arg" in
    --activate-food) ACTIVATE_FOOD=1 ;;
    *) echo "Uso: $0 [--activate-food]" >&2; exit 2 ;;
  esac
done

fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

for cmd in openssl awk grep mktemp; do
  command -v "$cmd" >/dev/null 2>&1 || fail "comando ausente: $cmd"
done
[[ -f .env ]] || fail ".env ausente em $ROOT"

get_env(){
  local key="$1"
  grep -E "^${key}=" .env | tail -1 | cut -d= -f2- || true
}

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

ensure_env(){
  local key="$1" default="$2" current
  current="$(get_env "$key")"
  if [[ -z "$current" ]]; then upsert_env "$key" "$default"; fi
}

log "Preparando segredos e defaults da API Pagamento"
PAYMENT_API_KEY="$(get_env PAYMENT_API_KEY)"
if [[ -z "$PAYMENT_API_KEY" || "$PAYMENT_API_KEY" == CHANGE_ME* ]]; then
  PAYMENT_API_KEY="$(openssl rand -hex 32)"
  upsert_env PAYMENT_API_KEY "$PAYMENT_API_KEY"
  echo "PAYMENT_API_KEY gerada e armazenada em .env"
else
  echo "PAYMENT_API_KEY existente preservada"
fi

PAYMENT_MOCK_WEBHOOK_SECRET="$(get_env PAYMENT_MOCK_WEBHOOK_SECRET)"
if [[ -z "$PAYMENT_MOCK_WEBHOOK_SECRET" || "$PAYMENT_MOCK_WEBHOOK_SECRET" == CHANGE_ME* ]]; then
  PAYMENT_MOCK_WEBHOOK_SECRET="$(openssl rand -hex 32)"
  upsert_env PAYMENT_MOCK_WEBHOOK_SECRET "$PAYMENT_MOCK_WEBHOOK_SECRET"
  echo "PAYMENT_MOCK_WEBHOOK_SECRET gerado e armazenado em .env"
fi

ensure_env PAYMENT_LOCAL_BIND 127.0.0.1
ensure_env PAYMENT_LOCAL_PORT 3086
ensure_env PAYMENT_PROVIDER_CASH cash
ensure_env PAYMENT_PROVIDER_PIX mock
ensure_env PAYMENT_PROVIDER_DEBIT mock
ensure_env PAYMENT_PROVIDER_CREDIT mock
ensure_env PAYMENT_MOCK_AUTO_APPROVE true
ensure_env PAYMENT_GETNET_BRIDGE_URL ''
ensure_env PAYMENT_GETNET_BRIDGE_TOKEN ''
ensure_env PAYMENT_GETNET_WEBHOOK_SECRET ''
ensure_env PAYMENT_REDE_BRIDGE_URL ''
ensure_env PAYMENT_REDE_BRIDGE_TOKEN ''
ensure_env PAYMENT_REDE_WEBHOOK_SECRET ''
ensure_env PAYMENT_PAGBANK_BRIDGE_URL ''
ensure_env PAYMENT_PAGBANK_BRIDGE_TOKEN ''
ensure_env PAYMENT_PAGBANK_WEBHOOK_SECRET ''
ensure_env PAYMENT_BACKOFFICE_WEBHOOK_URL ''
ensure_env PAYMENT_BACKOFFICE_WEBHOOK_SECRET ''
ensure_env PAYMENT_OUTBOX_POLL_MS 5000
ensure_env PAYMENT_OUTBOX_MAX_ATTEMPTS 20
ensure_env PAYMENT_HTTP_TIMEOUT_MS 15000

if [[ "$ACTIVATE_FOOD" == "1" ]]; then
  upsert_env TOTEM_FOOD_PAYMENT_PROVIDER api_pagamento
  echo "Totem Food configurado para PAYMENT_PROVIDER=api_pagamento"
else
  echo "Totem Food não foi alterado. Para ativar depois: bash scripts/prepare_payment.sh --activate-food"
fi

chmod 600 .env

echo
cat <<EOF
API Pagamento preparada.
Host-edge local: http://127.0.0.1:$(get_env PAYMENT_LOCAL_PORT)
PIX/débito/crédito: mock até configurar uma adquirente real.
Dinheiro: cash.
Nenhum segredo foi exibido no terminal.
EOF
