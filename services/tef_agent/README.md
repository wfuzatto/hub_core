# tef_agent (bootstrap)

Agente local de borda para integração de PIN pads TEF, inicialmente Gertec PPC930.

Este diretório é um bootstrap versionado no `hub_core` enquanto o repositório dedicado `wfuzatto/tef_agent` não estiver disponível no conector de automação. A intenção é promovê-lo para repositório independente e adicioná-lo a `modules/modules.list` após os testes.

Regras:

- roda nativamente no computador onde o PPC930 está conectado;
- não acessa PAN, CVV, PIN, track1/track2;
- mantém journal SQLite e idempotência por `payment_id`;
- serializa uma transação por `terminal_id`;
- possui driver `mock` completo e contrato `sitef` sem inventar SDK proprietário;
- pagamento real permanece desabilitado até homologação.
