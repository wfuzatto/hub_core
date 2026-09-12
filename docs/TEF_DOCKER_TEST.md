# TEF Docker V1

Esta branch adiciona uma integração TEF em formato de produção, porém usando `TEF_DRIVER=mock`. Nenhum cartão real é cobrado e o PPC930 ainda não é acessado nesta etapa.

## Arquitetura do teste

```text
totem_food
   -> api_pagamento (provider=tef)
        -> tef-agent (driver=mock)
             -> WAITING_CARD
             -> WAITING_PIN
             -> AUTHORIZED
        <- callback HMAC
   -> POST /payment-intents/:id/confirm
        -> tef-agent /confirm
             -> APPROVED
```

O agente mantém o terminal ocupado desde o início da sessão até `confirm`/`cancel`. O `api_pagamento` também mantém fila durável e idempotência.

## Executar

No servidor do HUB:

```bash
cd /home/luisnasc/hub_core
git fetch origin
git checkout feature/tef-docker-v1
git pull --ff-only origin feature/tef-docker-v1
bash scripts/test_tef_docker.sh
```

O script:

1. posiciona `api_pagamento` e `totem_food` exatamente nos commits fixados em `modules/modules.list`;
2. valida o Compose;
3. builda `tef-agent` e `api-payment`;
4. executa o teste unitário do agente;
5. executa `npm run check` na API Pagamento;
6. sobe MySQL, agente e gateway;
7. cria duas cobranças no mesmo terminal;
8. testa replay idempotente da primeira;
9. exige que a segunda não assuma o terminal enquanto a primeira está em `AUTHORIZED`;
10. confirma a primeira;
11. aguarda a segunda assumir o terminal;
12. confirma a segunda;
13. valida os eventos `AUTHORIZED` e `APPROVED`.

Ao final os containers ficam no ar para inspeção.

## Endpoints locais do teste

```text
http://127.0.0.1:8766/health  # TEF Agent
http://127.0.0.1:3090/health  # API Pagamento
```

## Encerrar o teste

```bash
docker compose -f compose.yml -f compose.tef-test.yml stop tef-agent api-payment
```

Não use `down -v` no stack oficial do HUB.

## Próxima etapa: PPC930 real

O driver real (`sitef` ou `gertef`) será implementado atrás do mesmo contrato do driver `mock`. A camada real deverá receber SDK/bibliotecas e parâmetros do fornecedor TEF. PAN, CVV, trilhas e PIN não entram no `api_pagamento` nem no journal do agente.
