#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail(){ echo "ERRO: $*" >&2; exit 1; }
for cmd in curl python3 grep; do command -v "$cmd" >/dev/null 2>&1 || fail "comando ausente: $cmd"; done
[[ -f .env ]] || fail ".env ausente"
get_env(){ grep -E "^${1}=" .env | tail -1 | cut -d= -f2- || true; }
API_KEY="$(get_env PAYMENT_API_KEY)"; PORT="$(get_env PAYMENT_LOCAL_PORT)"; PORT="${PORT:-3086}"
[[ -n "$API_KEY" ]] || fail "PAYMENT_API_KEY ausente; rode scripts/prepare_payment.sh"
BASE="http://127.0.0.1:${PORT}"
TMP_PREFIX="/tmp/payment-smoke.$$"; trap 'rm -f "${TMP_PREFIX}"*' EXIT

printf '[1/5] health... '; curl -fsS "$BASE/health" >"${TMP_PREFIX}.health"; echo OK
printf '[2/5] providers... '; curl -fsS -H "X-Api-Key: $API_KEY" "$BASE/api/v1/providers" >"${TMP_PREFIX}.providers"; echo OK

IDEM="smoke-$(date +%s)-$$"
printf '[3/5] enfileirando PIX mock idempotente... '
curl -fsS -X POST "$BASE/api/v1/payment-intents" -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -H "Idempotency-Key: $IDEM" \
  -d '{"source_module":"hub_smoke_test","source_reference":"SMOKE","merchant_id":"smoke","method":"PIX","amount_cents":100}' >"${TMP_PREFIX}.create"
PAYMENT_ID="$(python3 - "${TMP_PREFIX}.create" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding='utf-8')).get('payment',{})
print(p.get('id',''))
PY
)"
[[ -n "$PAYMENT_ID" ]] || fail "resposta sem payment id"
echo "OK ($PAYMENT_ID)"

printf '[4/5] aguardando worker... '
STATUS=""
for _ in $(seq 1 80); do
  curl -fsS -H "X-Api-Key: $API_KEY" "$BASE/api/v1/payment-intents/$PAYMENT_ID" >"${TMP_PREFIX}.get"
  STATUS="$(python3 - "${TMP_PREFIX}.get" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8')).get('status',''))
PY
)"
  [[ "$STATUS" == "APPROVED" ]] && break
  [[ "$STATUS" =~ ^(DECLINED|CANCELED|EXPIRED|ERROR)$ ]] && fail "pagamento terminou em $STATUS"
  sleep 0.25
done
[[ "$STATUS" == "APPROVED" ]] || fail "timeout aguardando aprovacao; ultimo status=$STATUS"
echo APPROVED

printf '[5/5] idempotencia/conciliação... '
curl -fsS -X POST "$BASE/api/v1/payment-intents" -H 'Content-Type: application/json' -H "X-Api-Key: $API_KEY" -H "Idempotency-Key: $IDEM" \
  -d '{"source_module":"hub_smoke_test","source_reference":"SMOKE","merchant_id":"smoke","method":"PIX","amount_cents":100}' >"${TMP_PREFIX}.replay"
python3 - "${TMP_PREFIX}.replay" "$PAYMENT_ID" <<'PY'
import json,sys
x=json.load(open(sys.argv[1],encoding='utf-8')); p=x.get('payment',x)
assert p.get('id')==sys.argv[2], 'replay criou outro pagamento'
assert x.get('idempotent_replay') is True, 'replay nao foi marcado idempotente'
PY
curl -fsS -H "X-Api-Key: $API_KEY" "$BASE/api/v1/reconciliation/summary?provider=mock" >"${TMP_PREFIX}.summary"
echo OK

echo 'Smoke test da API Pagamento concluído com sucesso.'
