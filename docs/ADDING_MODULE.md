# Adicionando um módulo

Todo complemento novo do Totem/HUB deve nascer desacoplado e pronto para Docker.

## Contrato mínimo

Cada repositório de módulo deve conter:

- `Dockerfile`;
- `.dockerignore`;
- `.env.example` sem segredos;
- endpoint de healthcheck;
- README com API/integração;
- persistência documentada;
- processo único em foreground (PID 1);
- logs em stdout/stderr;
- encerramento gracioso quando aplicável.

## Incorporação

1. Adicione em `modules/modules.list` usando uma **tag ou commit aprovado**, nunca `main` em produção:

```text
meu_modulo|git@github.com:wfuzatto/meu_modulo.git|<commit-ou-tag-homologada>
```

2. Rode `./scripts/bootstrap.sh`. O módulo será deixado em detached HEAD exatamente no ref aprovado.

3. Adicione serviço no `compose.yml`:

```yaml
  meu-modulo:
    build:
      context: ./modules/meu_modulo
    restart: unless-stopped
    expose:
      - "8080"
    networks:
      - backend
    healthcheck:
      test: ["CMD", "...health..."]
    logging: *default-logging
```

4. Se precisar ser acessado externamente, crie hostname no `Caddyfile`. **Não use `ports:` no módulo.**

5. Dados persistentes devem usar volume próprio.

6. Se usar banco, crie usuário e permissões exclusivos para o módulo quando ele entrar em produção.

7. Se usar GPU, mantenha um override separado e fallback CPU sempre que tecnicamente possível.

8. Para promover uma versão nova, teste-a primeiro e só depois altere o ref em `modules/modules.list`. Isso transforma a mudança de produção em uma decisão explícita e auditável.
