# Testes obrigatórios

Antes de habilitar TEF real: idempotência, terminal ocupado, dois pagamentos concorrentes, autorizado+confirm, autorizado+cancel/non-confirm, negada, timeout, desconexão, restart durante interação, restart depois de autorização, confirmação duplicada e recuperação sem segunda cobrança.

No mock: `python -m unittest -v test_tef_agent.py` e `python scripts/test_mock.py` com o agente em execução.
