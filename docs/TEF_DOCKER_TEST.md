# TEF Docker V1

Esta branch adiciona uma integração TEF em formato próximo de produção, porém usando `TEF_DRIVER=mock`. Nenhum cartão real é cobrado e o PPC930 ainda não é acessado nesta etapa.

## Isolamento

O teste roda em um projeto Compose próprio chamado `hub_core_tef_test`. Ele possui MySQL, rede e volumes próprios e não reutiliza os containers nem o banco do projeto oficial `hub_core`.

Os repositórios `api_pagamento` e `totem_food` também são clonados em `.tef-test/`, nos SHAs fixados em `modules/modules.list`; portanto o script não muda o checkout que está em `modules/` e não recria os containers oficiais.

## Arquitetura do teste

```text
api_pagamento (provider=tef)
        -> tef-agent (driver=mock)
             -> WAITING_CARD
             -> WAITING_PIN
             -> AUTHORIZED
        <- callback HMAC
   -> POST /payment-intents/:id/confirm
        -> tef-agent /confirm
             -> APPROVED
```

A integração correspondente do `totem_food` é validada sintaticamente no mesmo script e está preparada para enviar `terminal_id` e confirmar um pagamento `AUTHORIZED` antes de marcá-lo como pago.

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

1. cria checkouts isolados de `api_pagamento` e `totem_food` em `.tef-test/` usando os commits fixados;
2. valida os arquivos alterados do Totem Food;
3. recria somente o laboratório `hub_core_tef_test`;
4. valida o Compose isolado;
5. builda `tef-agent` e `api-payment`;
6. executa o teste unitário do agente e os testes/checks do gateway;
7. sobe um MySQL exclusivo do laboratório;
8. cria duas cobranças no mesmo terminal;
9. testa replay idempotente da primeira;
10. exige que a segunda não assuma o terminal enquanto a primeira está em `AUTHORIZED`;
11. confirma a primeira;
12. aguarda a segunda assumir o terminal;
13. confirma a segunda;
14. valida os eventos `AUTHORIZED` e `APPROVED` e a capability de confirmação do provider TEF.

Ao final, somente os containers do laboratório ficam no ar para inspeção.

## Endpoints locais do laboratório

```text
http://127.0.0.1:18766/health  # TEF Agent mock
http://127.0.0.1:13090/health  # API Pagamento do laboratório
```

As portas podem ser alteradas por `TEF_AGENT_LOCAL_PORT` e `PAYMENT_TEF_TEST_LOCAL_PORT`.

## Encerrar o laboratório

```bash
docker compose -p hub_core_tef_test -f compose.tef-test.yml stop
```

Para apagar somente o laboratório e seus volumes de teste:

```bash
docker compose -p hub_core_tef_test -f compose.tef-test.yml down -v
```

O `-p hub_core_tef_test` é obrigatório nesse comando: ele garante que o projeto oficial `hub_core` não seja alvo da remoção. Não execute `down -v` no stack oficial.

## Próxima etapa: PPC930 real

O driver real (`sitef` ou `gertef`) será implementado atrás do mesmo contrato do driver `mock`. A camada real deverá receber SDK/bibliotecas e parâmetros do fornecedor TEF. PAN, CVV, trilhas e PIN não entram no `api_pagamento` nem no journal do agente.
