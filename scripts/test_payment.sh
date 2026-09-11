#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail(){ echo "ERRO: $*" >&2; exit 1; }
for cmd in curl python3 grep; do command -v "$cmd" >/dev/null 2>&1 || fail "comando ausente: $cmd"; done
[[ -f .env ]] || fail ".env ausente"

get_env(){ grep -E "^${1}=" .env | tail -1 | cut -d= -f2- || true; }
API_KEY="$(get_env PAYMENT_API_KEY)"
PORT="$(get_env PAYMENT_LOCAL_PORT)"
PORT="${PORT:-3086}"
[[ -n "$API_KEY" ]] || fail "PAYMENT_API_KEY ausente; rode scripts/prepare_payment.sh"
BASE="http://127.0.0.1:${PORT}"

printf '[1/4] health... '
curl -fsS "$BASE/health" >/tmp/payment-health.$$
echo OK

printf '[2/4] providers... '
curl -fsS -H "X-Api-Key: $API_KEY" "$BASE/api/v1/providers" >/tmp/payment-providers.$$
echo OK

IDEM="smoke-$(date +%s)-$$"
printf '[3/4] criando PIX mock idempotente... '
curl -fsS -X POST "$BASE/api/v1/payment-intents" \
  -H 'Content-Type: application/json' \
  -H "X-Api-Key: $API_KEY" \
  -H "Idempotency-Key: $IDEM" \
  -d '{"source_module":"hub_smoke_test","source_reference":"SMOKE","merchant_id":"smoke","method":"PIX","amount_cents":100}' \
  >/tmp/payment-create.$$

PAYMENT_ID="$(python3 - /tmp/payment-create.$$ <<'PY'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: data=json.load(f)
p=data.get('payment',data)
print(p.get('id',''))
if p.get('status') != 'APPROVED':
    raise SystemExit('status esperado APPROVED; recebido '+str(p.get('status')))
PY
)"
[[ -n "$PAYMENT_ID" ]] || fail "resposta sem payment id"
echo "OK ($PAYMENT_ID)"

printf '[4/4] consultando transação/conciliação... '
curl -fsS -H "X-Api-Key: $API_KEY" "$BASE/api/v1/payment-intents/$PAYMENT_ID" >/tmp/payment-get.$$
curl -fsS -H "X-Api-Key: $API_KEY" "$BASE/api/v1/reconciliation/summary?provider=mock" >/tmp/payment-summary.$$
python3 - /tmp/payment-get.$$ <<'PY'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: p=json.load(f)
if p.get('status') != 'APPROVED':
    raise SystemExit('pagamento não ficou aprovado')
PY
echo OK

rm -f /tmp/payment-health.$$ /tmp/payment-providers.$$ /tmp/payment-create.$$ /tmp/payment-get.$$ /tmp/payment-summary.$$
echo 'Smoke test da API Pagamento concluído com sucesso.'
