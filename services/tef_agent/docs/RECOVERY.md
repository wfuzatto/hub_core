# Recovery TEF

Regras de segurança:

1. Sessão interativa interrompida por restart entra em `RECOVERY_REQUIRED`.
2. Sessão `AUTHORIZED` nunca vira `APPROVED` automaticamente após restart.
3. `AUTHORIZED` permanece pendente até `confirm` ou cancelamento/não-confirmação explícitos.
4. `payment_id` permanece idempotente durante e depois do recovery.
5. O terminal permanece associado à transação ambígua até resolução segura.
6. No driver SiTef real, o recovery deve consultar as pendências pelo mecanismo oficial da biblioteca/servidor antes de qualquer decisão.

Teste obrigatório antes de produção: autorizar uma transação de homologação, interromper o processo antes do confirm, reiniciar e provar que não existe segunda cobrança nem aprovação automática.
