# Integração TEF
`hub_core` é apenas orquestrador. `api_pagamento` é o dono lógico da transação e chama o `tef_agent` autenticado. O agente nativo controla o ciclo interativo e mantém o journal SQLite. A ausência de SDK SiTef não é erro em modo mock.
