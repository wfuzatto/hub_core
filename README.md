# HUB Core — Plataforma Docker

Repositório central de **infraestrutura, orquestração e integração** do ecossistema hoteleiro.

Produção usa **Ubuntu + Docker Engine + Docker Compose**. Cada módulo funcional permanece em seu próprio repositório e é incorporado ao stack em uma versão explicitamente homologada.

## Responsabilidades

- `hub_core` — core/orquestrador da plataforma;
- `hotelaria` — PMS, mantido em repositório separado;
- `totem_autoatendimento` — Totem;
- `face_scanner` — validação documental/facial.

## Serviços atuais

- `hub-core` — núcleo PHP/Apache do HUB;
- `mysql` — banco central do HUB, somente rede Docker privada;
- `totem-api` — backend + interface web do Totem;
- `face-scanner` — FastAPI/Python, OCR e pipeline facial;
- `gateway` — Caddy Docker opcional, apenas no profile `docker-edge`;
- `backup-helper` — utilitário sob demanda para backup do Totem.

## Stack oficial

Nome do projeto Compose:

```text
hub_core
```

Containers principais:

```text
hub_core-mysql-1
hub_core-hub-core-1
hub_core-totem-api-1
hub_core-face-scanner-1
```

## Persistência

Os volumes de produção são **externos e explicitamente nomeados** para ficarem desacoplados do ciclo de vida do Compose:

```text
hub_core_mysql_data
hub_core_totem_data
hub_core_face_scanner_data
```

Uma atualização normal nunca deve remover esses volumes. Se qualquer um deles estiver ausente em uma instalação já existente, `scripts/update_docker.sh` aborta antes do deploy para evitar inicialização acidental com dados vazios.

Nunca use em produção:

```bash
docker compose down -v
docker volume prune
docker system prune --volumes
```

## Modo de edge

### host-edge — padrão atual

Use quando Caddy/NGINX já roda no host:

```text
Caddy/NGINX do host :80/:443
        |
        +---- 127.0.0.1:3080 -> totem-api Docker
        +---- 127.0.0.1:3083 -> hub-core Docker

Docker backend
        +---- face-scanner:8091
        +---- mysql:3306
```

No ambiente atual de homologação, o Face Scanner também pode ser publicado em `8092 -> 8091` pelo override `compose.host-edge.yml`.

### docker-edge — opcional

Use apenas quando 80/443 estiverem livres no host e o gateway Docker for deliberadamente escolhido.

## Primeiro deploy

Em uma instalação nova, crie primeiro os volumes persistentes:

```bash
docker volume create hub_core_mysql_data
docker volume create hub_core_totem_data
docker volume create hub_core_face_scanner_data
```

Depois:

```bash
git clone git@github.com:wfuzatto/hub_core.git
cd hub_core
cp .env.example .env
# configure o .env
chmod 600 .env
./scripts/update.sh --host-edge
```

## Atualização oficial

O comando operacional padrão é:

```bash
cd /home/luisnasc/hub_core
bash scripts/update_docker.sh
```

Esse script:

1. valida que o checkout não possui alterações locais versionadas;
2. faz fast-forward de `origin/main`;
3. valida a presença dos volumes persistentes externos;
4. valida o Compose;
5. posiciona Totem e Face Scanner nos SHAs homologados de `modules/modules.list`;
6. executa o preflight;
7. cria backup pré-update quando o MySQL está saudável;
8. reconstrói/aplica o stack;
9. aguarda os healthchecks;
10. testa Totem, HUB e HTTPS.

GPU opcional:

```bash
USE_GPU=1 bash scripts/update_docker.sh
```

## Portas

| Porta | Uso | Exposição |
|---|---|---|
| 80/443 | Edge | Caddy/NGINX do host ou gateway Docker opcional |
| 3080 | Totem | `127.0.0.1` em host-edge |
| 3083 | HUB | `127.0.0.1` em host-edge |
| 8091 | Face Scanner | rede Docker interna |
| 8092 | Face Scanner | homologação atual, quando habilitado no override |
| 3306 | MySQL | somente rede Docker |

## Módulos homologados

Produção não acompanha automaticamente o `main` dos módulos. Os SHAs aprovados ficam em:

```text
modules/modules.list
```

O fluxo correto para atualizar um módulo é: testar no repositório próprio, aprovar um commit e só então alterar o SHA no `hub_core`.

## Regras de produção

- `hub_core` é o core/orquestrador; o PMS continua em `wfuzatto/hotelaria`;
- nenhum segredo deve ser commitado;
- `.env` de produção deve permanecer com permissão restrita;
- banco nunca deve ser publicado na Internet;
- serviços críticos usam healthcheck e `restart: unless-stopped`;
- módulos usam commits explicitamente aprovados;
- persistência é externa ao ciclo de vida do Compose;
- rollback é feito por versão/commit e backups, nunca por edição manual em container.
