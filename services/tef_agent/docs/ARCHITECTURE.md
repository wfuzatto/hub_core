# Arquitetura

```text
módulos consumidores -> api_pagamento -> tef_agent nativo -> stack TEF oficial -> PPC930/adquirentes
```

O `api_pagamento` é o dono lógico da transação. O `tef_agent` é o dono da sessão física e do journal local. Consumidores nunca acessam o PIN pad diretamente.

O driver `mock` permite testar máquina de estados, idempotência, concorrência e recovery. O driver `sitef` somente será habilitado quando a biblioteca oficial estiver instalada e o ambiente comercial de homologação estiver disponível.
