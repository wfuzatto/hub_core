#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Compatibilidade: a flag antiga e aceita, mas o stack novo sempre centraliza pagamentos.
for arg in "$@"; do
  case "$arg" in
    --activate-food) ;;
    *) echo "Uso: $0 [--activate-food]" >&2; exit 2 ;;
  esac
done

fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
for cmd in openssl awk grep mktemp; do command -v "$cmd" >/dev/null 2>&1 || fail "comando ausente: $cmd"; done
[[ -f .env ]] || fail ".env ausente em $ROOT"

get_env(){ local key="$1"; grep -E "^${key}=" .env | tail -1 | cut -d= -f2- || true; }
upsert_env(){
  local key="$1" value="$2" tmp; tmp="$(mktemp)"
  awk -v k="$key" -v v="$value" 'BEGIN{found=0}$0~"^"k"="{print k"="v;found=1;next}{print}END{if(!found)print k"="v}' .env > "$tmp"
  mv "$tmp" .env; chmod 600 .env
}
ensure_env(){ local key="$1" default="$2" current; current="$(get_env "$key")"; [[ -n "$current" ]] || upsert_env "$key" "$default"; }

log "Preparando gateway central de pagamentos"
PAYMENT_API_KEY="$(get_env PAYMENT_API_KEY)"
if [[ -z "$PAYMENT_API_KEY" || "$PAYMENT_API_KEY" == CHANGE_ME* ]]; then
  PAYMENT_API_KEY="$(openssl rand -hex 32)"; upsert_env PAYMENT_API_KEY "$PAYMENT_API_KEY"; echo "PAYMENT_API_KEY gerada e armazenada em .env"
else echo "PAYMENT_API_KEY existente preservada"; fi

PAYMENT_MOCK_WEBHOOK_SECRET="$(get_env PAYMENT_MOCK_WEBHOOK_SECRET)"
if [[ -z "$PAYMENT_MOCK_WEBHOOK_SECRET" || "$PAYMENT_MOCK_WEBHOOK_SECRET" == CHANGE_ME* ]]; then
  PAYMENT_MOCK_WEBHOOK_SECRET="$(openssl rand -hex 32)"; upsert_env PAYMENT_MOCK_WEBHOOK_SECRET "$PAYMENT_MOCK_WEBHOOK_SECRET"; echo "PAYMENT_MOCK_WEBHOOK_SECRET gerado e armazenado em .env"
fi

ensure_env PAYMENT_LOCAL_BIND 127.0.0.1
ensure_env PAYMENT_LOCAL_PORT 3086
ensure_env PAYMENT_PROVIDER_CASH cash
ensure_env PAYMENT_PROVIDER_PIX mock
ensure_env PAYMENT_PROVIDER_DEBIT mock
ensure_env PAYMENT_PROVIDER_CREDIT mock
ensure_env PAYMENT_MOCK_AUTO_APPROVE true
ensure_env PAYMENT_JOB_POLL_MS 250
ensure_env PAYMENT_JOB_CONCURRENCY 8
ensure_env PAYMENT_JOB_MAX_ATTEMPTS 12
ensure_env PAYMENT_JOB_STALE_SECONDS 120
ensure_env PAYMENT_JOB_MAX_BACKOFF_SECONDS 300
ensure_env PAYMENT_UI_WAIT_MS 90000
ensure_env PAYMENT_UI_POLL_MS 750
ensure_env TOTEM_PAYMENT_MERCHANT_ID totem_hotel
ensure_env TOTEM_PAYMENT_TERMINAL_ID totem-hotel-01
ensure_env TOTEM_FOOD_PAYMENT_SYNC_INTERVAL_MS 1000
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

# Mantido apenas para instalações antigas; compose.yml força api_pagamento no Totem Food.
upsert_env TOTEM_FOOD_PAYMENT_PROVIDER api_pagamento
chmod 600 .env

cat <<EOF

Gateway central preparado.
Host-edge local: http://127.0.0.1:$(get_env PAYMENT_LOCAL_PORT)
PMS, Totem Hotel e Totem Food: api_pagamento.
PIX/debito/credito: mock ate configurar uma adquirente real.
Dinheiro: cash centralizado.
Fila: $(get_env PAYMENT_JOB_CONCURRENCY) workers; terminais iguais sao serializados.
Nenhum segredo foi exibido no terminal.
EOF
