#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LIST="$ROOT/modules/modules.list"
TEST_ROOT="$ROOT/.tef-test"
COMPOSE=(docker compose -p hub_core_tef_test -f compose.tef-test.yml)

fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ -f "$LIST" ]] || fail "modules/modules.list ausente"
command -v git >/dev/null 2>&1 || fail "git não encontrado"
command -v docker >/dev/null 2>&1 || fail "docker não encontrado"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"
docker compose version >/dev/null 2>&1 || fail "docker compose não encontrado"

diagnostics(){
  echo
  echo "================ TEF TEST DIAGNOSTICS ================" >&2
  "${COMPOSE[@]}" ps >&2 || true
  "${COMPOSE[@]}" logs --tail=180 tef-agent api-payment mysql >&2 || true
}
trap diagnostics ERR

sync_test_module(){
  local module="$1" line dest repo ref dir
  line="$(awk -F'|' -v m="$module" '$1==m {print; exit}' "$LIST")"
  [[ -n "$line" ]] || fail "módulo $module não encontrado em modules.list"
  IFS='|' read -r dest repo ref <<< "$line"
  [[ -n "$repo" && -n "$ref" ]] || fail "entrada inválida para $module em modules.list"
  dir="$TEST_ROOT/$dest"
  mkdir -p "$TEST_ROOT"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    git clone "$repo" "$dir"
  fi
  if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    rm -rf "$dir"
    git clone "$repo" "$dir"
  fi
  git -C "$dir" fetch --prune origin
  git -C "$dir" fetch origin "$ref" >/dev/null 2>&1 || true
  git -C "$dir" cat-file -e "${ref}^{commit}" 2>/dev/null || fail "ref $ref não encontrada para $module"
  git -C "$dir" checkout --detach "$ref" >/dev/null
  echo "$module (lab) -> $(git -C "$dir" rev-parse --short HEAD)"
}

log "Preparando checkouts isolados do laboratório"
sync_test_module api_pagamento
sync_test_module totem_food

log "Validando alterações do Totem Food sem tocar no container oficial"
docker run --rm -v "$TEST_ROOT/totem_food:/app:ro" -w /app node:22-alpine \
  sh -ec 'node --check src/config.js && node --check src/payment.js && node --check src/order-service.js'

log "Recriando somente o projeto Docker isolado hub_core_tef_test"
# Este projeto/volumes têm nomes exclusivos do laboratório. Nenhum container ou
# volume do projeto oficial hub_core é referenciado por este comando.
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true

log "Validando Compose TEF isolado"
"${COMPOSE[@]}" config >/dev/null

log "Build do agente e gateway"
"${COMPOSE[@]}" build tef-agent api-payment

log "Teste unitário do agente mock"
"${COMPOSE[@]}" run --rm --no-deps tef-agent node --test test/mock.test.js

log "Validação sintática da API Pagamento"
"${COMPOSE[@]}" run --rm --no-deps api-payment npm run check

log "Testes unitários da API Pagamento"
"${COMPOSE[@]}" run --rm --no-deps api-payment npm test

log "Subindo MySQL + API Pagamento + TEF Agent isolados"
"${COMPOSE[@]}" up -d --build mysql tef-agent api-payment

log "Aguardando healthchecks"
READY=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${TEF_AGENT_LOCAL_PORT:-18766}/health" >/dev/null 2>&1 \
    && curl -fsS "http://127.0.0.1:${PAYMENT_TEF_TEST_LOCAL_PORT:-13090}/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
[[ "$READY" == "1" ]] || fail "healthchecks do laboratório TEF não ficaram prontos"
curl -fsS "http://127.0.0.1:${TEF_AGENT_LOCAL_PORT:-18766}/health"; echo
curl -fsS "http://127.0.0.1:${PAYMENT_TEF_TEST_LOCAL_PORT:-13090}/health"; echo

log "Teste E2E: idempotência, serialização do terminal, AUTHORIZED e CONFIRM"
"${COMPOSE[@]}" exec -T api-payment node <<'NODE'
const base='http://127.0.0.1:3090';
const apiKey=process.env.PAYMENT_API_KEY;
const terminal=process.env.PAYMENT_TEF_DEFAULT_TERMINAL_ID || 'TEF-DOCKER-01';
if(!apiKey) throw new Error('PAYMENT_API_KEY ausente no container');
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function request(path,{method='GET',body,idempotencyKey}={}){
  const headers={accept:'application/json','x-api-key':apiKey};
  if(body!==undefined)headers['content-type']='application/json';
  if(idempotencyKey)headers['idempotency-key']=idempotencyKey;
  const r=await fetch(base+path,{method,headers,body:body===undefined?undefined:JSON.stringify(body)});
  const data=await r.json().catch(()=>({}));
  if(!r.ok)throw new Error(`${method} ${path}: HTTP ${r.status} ${JSON.stringify(data)}`);
  return data;
}
async function create(tag,key){
  const result=await request('/api/v1/payment-intents',{method:'POST',idempotencyKey:key,body:{
    source_module:'tef_docker_test',source_reference:tag,merchant_id:'docker-test',method:'CREDIT',amount_cents:1234,currency:'BRL',installments:1,metadata:{terminal_id:terminal,test_run:tag}
  }});
  return result.payment||result;
}
async function get(id){return request(`/api/v1/payment-intents/${encodeURIComponent(id)}`)}
async function waitFor(id,status,timeoutMs=30000){
  const deadline=Date.now()+timeoutMs; let last;
  while(Date.now()<deadline){
    last=await get(id);
    if(last.status===status)return last;
    if(['DECLINED','CANCELED','EXPIRED','ERROR','APPROVED','REFUNDED'].includes(last.status)&&last.status!==status)throw new Error(`payment ${id} terminou em ${last.status}, esperado ${status}`);
    await sleep(250);
  }
  throw new Error(`timeout aguardando ${status}; último=${last?.status}`);
}
async function confirm(id){return request(`/api/v1/payment-intents/${encodeURIComponent(id)}/confirm`,{method:'POST',body:{}})}

(async()=>{
  const stamp=Date.now();
  const keyA=`tef-e2e-a-${stamp}`;
  const a=await create(`TEF-A-${stamp}`,keyA);
  const replay=await create(`TEF-A-${stamp}`,keyA);
  if(a.id!==replay.id)throw new Error('idempotência falhou: IDs diferentes');

  const b=await create(`TEF-B-${stamp}`,`tef-e2e-b-${stamp}`);
  const authA=await waitFor(a.id,'AUTHORIZED');
  if(authA.next_action?.type!=='CONFIRM_PAYMENT')throw new Error(`A sem next_action CONFIRM_PAYMENT: ${JSON.stringify(authA.next_action)}`);

  const bWhileBusy=await get(b.id);
  if(['AUTHORIZED','APPROVED'].includes(bWhileBusy.status))throw new Error('serialização falhou: segundo pagamento usou o terminal enquanto A aguardava confirmação');

  const approvedA=await confirm(a.id);
  if(approvedA.status!=='APPROVED')throw new Error(`confirm A retornou ${approvedA.status}`);

  await waitFor(b.id,'AUTHORIZED',45000);
  const approvedB=await confirm(b.id);
  if(approvedB.status!=='APPROVED')throw new Error(`confirm B retornou ${approvedB.status}`);

  const eventsA=await request(`/api/v1/payment-intents/${a.id}/events`);
  const eventStatuses=(eventsA.events||[]).map(e=>e.to_status);
  if(!eventStatuses.includes('AUTHORIZED')||!eventStatuses.includes('APPROVED'))throw new Error(`eventos A incompletos: ${eventStatuses.join(',')}`);

  const providers=await request('/api/v1/providers');
  const tef=(providers.providers||[]).find(p=>p.name==='tef');
  if(!tef?.configured||!tef?.confirmation)throw new Error(`provider TEF não está pronto: ${JSON.stringify(tef)}`);

  console.log(JSON.stringify({
    result:'PASS',terminal,
    payment_a:{id:a.id,status:approvedA.status},
    payment_b:{id:b.id,status:approvedB.status},
    second_payment_while_busy:bWhileBusy.status,
    events_a:eventStatuses,
    provider_tef:tef
  },null,2));
})().catch(error=>{console.error(error);process.exit(1)});
NODE

log "TEF Docker V1 passou"
echo "Projeto Docker isolado: hub_core_tef_test"
echo "Agente:  http://127.0.0.1:${TEF_AGENT_LOCAL_PORT:-18766}/health"
echo "Gateway: http://127.0.0.1:${PAYMENT_TEF_TEST_LOCAL_PORT:-13090}/health"
echo "Containers do laboratório foram mantidos no ar para inspeção."
echo "Encerrar laboratório: docker compose -p hub_core_tef_test -f compose.tef-test.yml stop"
echo "Remover laboratório e seus volumes: docker compose -p hub_core_tef_test -f compose.tef-test.yml down -v"
