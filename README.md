# HUB Core — Plataforma Docker

Repositório pai de **infraestrutura e orquestração** do ecossistema hoteleiro.

Produção não depende de XAMPP. O padrão oficial é **Ubuntu + Docker Engine + Docker Compose**. Cada módulo continua em seu próprio repositório e é incorporado ao stack como um serviço isolado e versionado.

## Serviços atuais

- `hub-core` — núcleo PHP/Apache do HUB em container, preparado para MySQL.
- `mysql` — banco central do HUB e base para novos módulos; somente rede privada Docker.
- `totem-api` — backend do `totem_autoatendimento`, Node.js 22 LTS, com dados persistidos em volume.
- `face-scanner` — FastAPI/Python, OCR e processamento de documentos; porta `8091` somente interna.
- `gateway` — Caddy Docker opcional, ativado somente com o profile `docker-edge`.
- `backup-helper` — utilitário sob demanda para backup do volume do Totem.

## Dois modos de edge

### 1. `host-edge` — padrão e modo seguro de migração

Use quando o Ubuntu já possui Caddy/NGINX atendendo outros sistemas. O stack **não ocupa 80/443**.

```text
Caddy/NGINX do host :80/:443
        |
        +---- 127.0.0.1:3080 -> totem-api Docker
        +---- 127.0.0.1:3083 -> hub-core Docker

Docker backend
        +---- face-scanner:8091
        +---- mysql:3306
```

Somente `127.0.0.1:3080` e `127.0.0.1:3083` são publicados. Face Scanner e MySQL continuam exclusivamente na rede Docker.

Esse é o modo padrão de `scripts/update.sh`.

### 2. `docker-edge` — edge 100% containerizado

Use somente quando 80/443 estiverem livres no host e todo o tráfego legado já tiver sido migrado.

```text
Internet
   |
   | 80/443
   v
Caddy Docker
   |
   +---- hub-core:80
   +---- totem-api:3080
   +---- face-scanner:8091

mysql:3306  <---- rede Docker privada
```

Ative explicitamente com:

```bash
./scripts/update.sh --docker-edge
```

## Primeiro deploy em servidor que já possui Caddy/NGINX

```bash
git clone git@github.com:wfuzatto/hub_core.git
cd hub_core
cp .env.example .env
# configure senhas e TOTEM_DOMAIN
chmod +x scripts/*.sh
./scripts/update.sh --host-edge
```

O modo `host-edge` preserva Caddy, NGINX, MariaDB e outros serviços instalados diretamente no Ubuntu.

## GPU

O stack base funciona em CPU. Para liberar uma GPU NVIDIA ao Face Scanner, o host precisa ter **NVIDIA Container Toolkit** configurado.

```bash
./scripts/update.sh --host-edge --gpu
```

Se o toolkit não estiver disponível, o preflight aborta antes do deploy e não altera os containers.

## Atualização de produção

O HUB é o **único ponto de atualização**. O script:

1. atualiza o próprio `hub_core` por fast-forward;
2. posiciona Totem e Face Scanner nos commits homologados de `modules/modules.list`;
3. executa preflight;
4. cria backup pré-update quando o MySQL Docker já está saudável;
5. reconstrói as imagens locais;
6. aplica o Compose;
7. aguarda os healthchecks antes de informar sucesso.

Atualização normal no modo seguro:

```bash
./scripts/update.sh
```

Forma universal para checkout antigo:

```bash
git pull --ff-only origin main && chmod +x scripts/*.sh && ./scripts/update.sh --host-edge
```

## Portas

| Porta | Uso | Exposição |
|---|---|---|
| 80/443 | Edge | somente Caddy/NGINX existente ou gateway Docker opcional |
| 3080 | Totem | `127.0.0.1` em host-edge; interna em docker-edge |
| 3083 | HUB | `127.0.0.1` somente em host-edge |
| 8091 | Face Scanner | somente rede Docker |
| 3306 | MySQL HUB | somente rede Docker |

Uma aplicação já existente no host pode usar a porta 8091 sem conflito, pois o Face Scanner Docker não publica 8091 no host.

## Comandos úteis

```bash
make bootstrap
make up
make up-gpu
make ps
make logs
make health
make backup
make update
make down
```

## Novos módulos

1. O módulo continua em repositório próprio.
2. Adicione o repositório em `modules/modules.list`.
3. Adicione o serviço ao `compose.yml` ou a um override específico.
4. Prefira `expose`; publique no host somente quando o edge externo realmente precisar.
5. Adicione healthcheck, política de restart e persistência explícita.

Veja `docs/ADDING_MODULE.md`.

## Regras de produção

- nada de XAMPP como runtime da plataforma nova;
- serviços legados do host não são removidos durante a migração sem validação específica;
- nada de `latest` nos componentes de aplicação;
- banco do HUB nunca exposto na Internet;
- segredos ficam em `.env`/secret store, nunca no Git;
- `restart: unless-stopped` em serviços críticos;
- healthcheck em todos os módulos;
- backups fora do servidor são obrigatórios;
- atualização automática de containers é proibida em produção;
- módulos usam commits explicitamente aprovados;
- rollback é feito por versão/commit, não por edição manual no servidor.

## Desenvolvimento

XAMPP pode continuar temporariamente em alguma estação antiga apenas para compatibilidade, mas **não faz parte da arquitetura oficial**. A direção do projeto é usar Docker também no desenvolvimento para manter o ambiente o mais próximo possível da produção.
