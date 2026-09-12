#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

EDGE_MODE="${EDGE_MODE:-host}"
USE_GPU="${USE_GPU:-0}"
fail=0

for cmd in docker git; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERRO: comando ausente: $cmd"
    fail=1
  fi
done

if command -v docker >/dev/null 2>&1; then
  if ! docker info >/dev/null 2>&1; then
    echo "ERRO: Docker daemon não está acessível"
    fail=1
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "ERRO: Docker Compose v2 não disponível"
    fail=1
  fi
fi

read_env() {
  local key="$1"
  grep -E "^${key}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true
}

if [[ ! -f .env ]]; then
  echo "ERRO: .env ausente. Execute: cp .env.example .env"
  fail=1
else
  chmod 600 .env
  if grep -q 'CHANGE_ME' .env; then
    echo "ERRO: .env ainda contém valores CHANGE_ME"
    fail=1
  fi

  if grep -Eq '^TOTEM_DOMAIN=(totem\.example\.com)?$' .env; then
    echo "ERRO: configure TOTEM_DOMAIN no .env (domínio ou IP usado no Totem)"
    fail=1
  fi

  for key in PMS_DB_HOST PMS_DB_NAME PMS_DB_USER PMS_DB_PASSWORD PAYMENT_API_KEY; do
    value="$(read_env "$key")"
    if [[ -z "$value" ]]; then
      echo "ERRO: configure $key no .env"
      fail=1
    fi
  done

  MYSQL_DATABASE_VALUE="$(read_env MYSQL_DATABASE)"
  PMS_DB_NAME_VALUE="$(read_env PMS_DB_NAME)"
  if [[ "$MYSQL_DATABASE_VALUE" != "hotel_reservas" || "$PMS_DB_NAME_VALUE" != "hotel_reservas" ]]; then
    echo "ERRO: HUB Core e PMS devem usar o banco único hotel_reservas"
    echo "MYSQL_DATABASE=$MYSQL_DATABASE_VALUE PMS_DB_NAME=$PMS_DB_NAME_VALUE"
    fail=1
  fi

  HOTEL_CARD_PROVIDER_VALUE="$(read_env HOTEL_CARD_PROVIDER)"
  HOTEL_CARD_PROVIDER_VALUE="${HOTEL_CARD_PROVIDER_VALUE:-mock}"
  if [[ "$HOTEL_CARD_PROVIDER_VALUE" != "mock" && "$HOTEL_CARD_PROVIDER_VALUE" != "bis_api" ]]; then
    echo "ERRO: HOTEL_CARD_PROVIDER deve ser mock ou bis_api"
    fail=1
  fi

  if [[ "$HOTEL_CARD_PROVIDER_VALUE" == "bis_api" ]]; then
    for key in BIS_API_URL BIS_API_WRITE_CONFIRMATION HOTEL_ACCESS_CHECKIN_TIME HOTEL_ACCESS_CHECKOUT_TIME HOTEL_ACCESS_UTC_OFFSET; do
      value="$(read_env "$key")"
      if [[ -z "$value" ]]; then
        echo "ERRO: $key é obrigatório quando HOTEL_CARD_PROVIDER=bis_api"
        fail=1
      fi
    done

    BIS_API_URL_VALUE="$(read_env BIS_API_URL)"
    CHECKIN_TIME_VALUE="$(read_env HOTEL_ACCESS_CHECKIN_TIME)"
    CHECKOUT_TIME_VALUE="$(read_env HOTEL_ACCESS_CHECKOUT_TIME)"
    UTC_OFFSET_VALUE="$(read_env HOTEL_ACCESS_UTC_OFFSET)"

    if [[ -n "$BIS_API_URL_VALUE" && ! "$BIS_API_URL_VALUE" =~ ^https?://[^[:space:]]+$ ]]; then
      echo "ERRO: BIS_API_URL deve começar com http:// ou https://"
      fail=1
    fi
    if [[ -n "$CHECKIN_TIME_VALUE" && ! "$CHECKIN_TIME_VALUE" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      echo "ERRO: HOTEL_ACCESS_CHECKIN_TIME deve usar HH:MM"
      fail=1
    fi
    if [[ -n "$CHECKOUT_TIME_VALUE" && ! "$CHECKOUT_TIME_VALUE" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      echo "ERRO: HOTEL_ACCESS_CHECKOUT_TIME deve usar HH:MM"
      fail=1
    fi
    if [[ -n "$UTC_OFFSET_VALUE" && ! "$UTC_OFFSET_VALUE" =~ ^(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$ ]]; then
      echo "ERRO: HOTEL_ACCESS_UTC_OFFSET deve usar Z ou ±HH:MM"
      fail=1
    fi
  fi

  if [[ "$EDGE_MODE" == "docker" ]]; then
    if grep -Eq '^(HUB_DOMAIN|FACE_SCANNER_DOMAIN)=.*example\.com$' .env; then
      echo "ERRO: troque os domínios example.com antes de usar o gateway Docker"
      fail=1
    fi
    if grep -Eq '^ACME_EMAIL=.*@example\.com$' .env; then
      echo "ERRO: troque o ACME_EMAIL antes de usar o gateway Docker"
      fail=1
    fi
  fi
fi

while IFS='|' read -r dest repo ref; do
  [[ -z "${dest:-}" || "$dest" =~ ^[[:space:]]*# ]] && continue
  dest="${dest//[[:space:]]/}"
  ref="${ref//[[:space:]]/}"
  dir="modules/$dest"
  if [[ ! -d "$dir/.git" ]]; then
    echo "ERRO: módulo ausente: $dir (rode ./scripts/bootstrap.sh)"
    fail=1
    continue
  fi
  actual="$(git -C "$dir" rev-parse HEAD)"
  expected="$(git -C "$dir" rev-parse "${ref}^{commit}" 2>/dev/null || true)"
  if [[ -z "$expected" || "$actual" != "$expected" ]]; then
    echo "ERRO: versão de $dest divergente. atual=$actual esperado=${expected:-$ref}"
    fail=1
  fi
done < modules/modules.list

if [[ "$EDGE_MODE" == "host" ]] && command -v ss >/dev/null 2>&1; then
  for spec in \
    "totem-api:${TOTEM_LOCAL_PORT:-3080}" \
    "hub-core:${HUB_LOCAL_PORT:-3083}" \
    "pms:${PMS_LOCAL_PORT:-3084}" \
    "totem-food:${TOTEM_FOOD_LOCAL_PORT:-3085}" \
    "api-payment:${PAYMENT_LOCAL_PORT:-3086}"; do
    service="${spec%%:*}"
    port="${spec##*:}"
    cid="$(docker compose -f compose.yml -f compose.host-edge.yml ps -q "$service" 2>/dev/null || true)"
    if ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$port$" && [[ -z "$cid" ]]; then
      echo "ERRO: porta local $port já está em uso e não pertence ao serviço Docker $service"
      fail=1
    fi
  done
fi

if [[ "$EDGE_MODE" == "docker" ]] && command -v ss >/dev/null 2>&1; then
  gateway_cid="$(docker compose --profile docker-edge -f compose.yml ps -q gateway 2>/dev/null || true)"
  if [[ -z "$gateway_cid" ]]; then
    for port in 80 443; do
      if ss -ltnH | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
        echo "ERRO: porta $port já está ocupada no host; não é seguro iniciar o gateway Docker"
        fail=1
      fi
    done
  fi
fi

if [[ "$USE_GPU" == "1" ]]; then
  if ! command -v nvidia-container-cli >/dev/null 2>&1; then
    echo "ERRO: --gpu solicitado, mas NVIDIA Container Toolkit não está instalado"
    fail=1
  fi
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "ERRO: --gpu solicitado, mas nvidia-smi não está disponível"
    fail=1
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

COMPOSE=(docker compose -f compose.yml)
if [[ "$EDGE_MODE" == "host" ]]; then
  COMPOSE+=( -f compose.host-edge.yml )
else
  COMPOSE+=( --profile docker-edge )
fi
COMPOSE+=( -f compose.nfc-bis.yml )
if [[ "$USE_GPU" == "1" ]]; then
  COMPOSE+=( -f compose.gpu.yml )
fi

"${COMPOSE[@]}" config >/dev/null

echo "Preflight OK. edge=$EDGE_MODE gpu=$USE_GPU nfc=${HOTEL_CARD_PROVIDER_VALUE:-mock} banco_pms=hotel_reservas banco_food=totem_food banco_pagamentos=api_pagamento"
