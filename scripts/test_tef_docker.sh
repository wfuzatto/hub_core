#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
LIST="$ROOT/modules/modules.list"
COMPOSE=(docker compose -f compose.yml -f compose.tef-test.yml)

fail(){ echo "ERRO: $*" >&2; exit 1; }
log(){ printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

[[ -f .env ]] || fail ".env ausente. Use o .env normal do HUB; o override TEF usa credenciais próprias de teste."
[[ -f "$LIST" ]] || fail "modules/modules.list ausente"
command -v git >/dev/null 2>&1 || fail "git não encontrado"
command -v docker >/dev/null 2>&1 || fail "docker não encontrado"
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"

diagnostics(){
  echo
  echo "================ TEF TEST DIAGNOSTICS ================" >&2
  "${COMPOSE[@]}" ps >&2 || true
  "${COMPOSE[@]}" logs --tail=180 tef-agent api-payment >&2 || true
}
trap diagnostics ERR

sync_module(){
  local module="$1" line dest repo ref dir
  line="$(awk -F'|' -v m="$module" '$1==m {print; exit}' "$LIST")"
  [[ -n "$line" ]] || fail "módulo $module não encontrado em modules.list"
  IFS='|' read -r dest repo ref <<< "$line"
  dir="$ROOT/modules/$dest"
  if [[ ! -d "$dir/.git" ]]; then
    rm -rf "$dir"
    git clone "$repo" "$dir"
  fi
  if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    git -C "$dir" status --short >&2
    fail "$module possui alterações locais; teste não sobrescreveu nada"
  fi
  git -C "$dir" fetch --prune origin
  git -C "$dir" fetch origin "$ref" >/dev/null 2>&1 || true
  git -C "$dir" cat-file -e "${ref}^{commit}" 2>/dev/null || fail "ref $ref não encontrada para $module"
  git -C "$dir" checkout --detach "$ref"
  echo "$module -> $(git -C "$dir" rev-parse --short HEAD)"
}

log "Sincronizando commits TEF fixados"
sync_module api_pagamento
sync_module totem_food

log "Validando Compose TEF"
"${COMPOSE[@]}" config >/dev/null

log "Build do agente e gateway"
"${COMPOSE[@]}" build tef-agent api-payment

log "Teste unitário do agente mock"
"${COMPOSE[@]}" run --rm --no-deps tef-agent node --test test/mock.test.js

log "Validação sintática da API Pagamento"
"${COMPOSE[@]}" run --rm --no-deps api-payment npm run check

log "Subindo MySQL + API Pagamento + TEF Agent"
"${COMPOSE[@]}" up -d --build tef-agent api-payment

log "Aguardando healthchecks"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${TEF_AGENT_LOCAL_PORT:-8766}/health" >/dev/null 2>&1 \
    && curl -fsS "http://127.0.0.1:${PAYMENT_TEF_TEST_LOCAL_PORT:-3090}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:${TEF_AGENT_LOCAL_PORT:-8766}/health"; echo
curl -fsS "http://127.0.0.1:${PAYMENT_TEF_TEST_LOCAL_PORT:-3090}/health"; echo

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

  const authB=await waitFor(b.id,'AUTHORIZED',45000);
  const approvedB=await confirm(b.id);
  if(approvedB.status!=='APPROVED')throw new Error(`confirm B retornou ${approvedB.status}`);

  const eventsA=await request(`/api/v1/payment-intents/${a.id}/events`);
  const eventStatuses=(eventsA.events||[]).map(e=>e.to_status);
  if(!eventStatuses.includes('AUTHORIZED')||!eventStatuses.includes('APPROVED'))throw new Error(`eventos A incompletos: ${eventStatuses.join(',')}`);

  console.log(JSON.stringify({
    result:'PASS',terminal,
    payment_a:{id:a.id,status:approvedA.status},
    payment_b:{id:b.id,status:approvedB.status},
    second_payment_while_busy:bWhileBusy.status,
    events_a:eventStatuses
  },null,2));
})().catch(error=>{console.error(error);process.exit(1)});
NODE

log "TEF Docker V1 passou"
echo "Agente:    http://127.0.0.1:${TEF_AGENT_LOCAL_PORT:-8766}/health"
echo "Gateway:   http://127.0.0.1:${PAYMENT_TEF_TEST_LOCAL_PORT:-3090}/health"
echo "Containers foram mantidos no ar para inspeção."
echo "Para encerrar somente o teste: docker compose -f compose.yml -f compose.tef-test.yml stop tef-agent api-payment"
