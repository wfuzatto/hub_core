# Segurança

O `tef_agent` aceita somente identificadores da venda e dados operacionais não sensíveis. Requisições contendo chaves conhecidas de PAN, CVV/CVC, PIN, track1/track2, trilha magnética ou raw card são rejeitadas.

A API `/v1/*` exige bearer token (ou `X-Tef-Agent-Key`). Em LAN, use token forte e firewall permitindo somente o host do gateway. O token nunca deve ser commitado.

O agente armazena apenas informações de conciliação permitidas, como `payment_id`, `terminal_id`, valor, método, NSU, código de autorização, rede e bandeira. Logs não devem incluir segredos nem dados crus do cartão.
