# Instalação local

## Windows

1. Copie `.env.example` para `.env` e gere um token forte.
2. Rode `powershell -ExecutionPolicy Bypass -File scripts/diagnose_ppc930.ps1`.
3. Para desenvolvimento: `powershell -ExecutionPolicy Bypass -File scripts/run.ps1`.
4. Abra `http://127.0.0.1:8766/`.
5. Rode `python scripts/test_mock.py` com `TEF_AGENT_TOKEN` no ambiente.
6. Para autostart: execute `scripts/install-windows.ps1` como Administrador.

## Linux

1. Copie `.env.example` para `.env` e gere um token forte.
2. `bash scripts/diagnose_ppc930.sh`.
3. `bash scripts/run-tests.sh`.
4. `bash scripts/run.sh` ou `sudo bash scripts/install-linux.sh`.

O modo padrão é `mock`. Não altere `TEF_REAL_PAYMENTS_ENABLED=false` até existir ambiente TEF homologado.
