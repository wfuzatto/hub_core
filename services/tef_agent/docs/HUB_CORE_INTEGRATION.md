# Integração com hub_core

O `hub_core` apenas distribui configuração, executa preflight e homologa versões. O hardware continua fora dos containers. O `api_pagamento` chama `TEF_AGENT_URL`; consumidores enviam `terminal_id` nos metadados. Produção não deve trocar débito/crédito para `tef` até homologação.
