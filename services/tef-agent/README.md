# TEF Agent

Agente local/edge responsável por uma sessão TEF e pelo terminal físico. Nesta primeira versão o driver `mock` permite testar todo o ciclo no Docker sem SDK proprietário nem cobrança real.

## Estados do mock

`QUEUED -> WAITING_CARD -> CARD_READ -> WAITING_PIN -> AUTHORIZED -> APPROVED`

`AUTHORIZED` significa que a adquirente/TEF autorizou, porém a aplicação ainda precisa confirmar a transação. O `POST /v1/transactions/{session}/confirm` transforma a sessão em `APPROVED`.

## Segurança

- `TEF_AGENT_TOKEN` protege a API.
- `TEF_CALLBACK_SECRET` assina callbacks HMAC-SHA256 em `X-Webhook-Signature`.
- PAN, CVV, trilhas e PIN são rejeitados pela API.

## Endpoints

- `GET /health`
- `GET /v1/device`
- `GET /v1/status`
- `POST /v1/transactions`
- `GET /v1/transactions/:id`
- `POST /v1/transactions/:id/confirm`
- `POST /v1/transactions/:id/cancel`
- `POST /v1/transactions/:id/refund`

O journal fica em `TEF_DATA_DIR` e é persistido em volume Docker. O driver real SiTef/GerTEF entrará atrás do mesmo contrato.
