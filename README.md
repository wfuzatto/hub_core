# HUB Core — Plataforma Docker

Repositório central de **infraestrutura, orquestração e integração** do ecossistema hoteleiro.

Produção usa **Ubuntu + Docker Engine + Docker Compose**. Cada módulo funcional permanece em seu próprio repositório e é incorporado ao stack em uma versão explicitamente homologada.

## Responsabilidades

- `hub_core` — core/orquestrador da plataforma;
- `hotelaria` — PMS, mantido em repositório separado e montado como `modules/hotelaria`;
- `totem_autoatendimento` — Totem hoteleiro;
- `totem_food` — Totem de alimentação;
- `face_scanner` — validação documental/facial.

## Serviços atuais

- `hub-core` — núcleo PHP/Apache do HUB;
- `mysql` — banco central, somente rede Docker privada;
- `pms` — módulo `hotelaria`;
- `totem-api` — backend + interface web do Totem hoteleiro;
- `totem-food` — autoatendimento de alimentação, KDS e painel de pedidos;
- `totem-food-db-init` — inicialização idempotente do schema `totem_food`;
- `face-scanner` — FastAPI/Python, OCR e pipeline facial;
- `gateway` — Caddy Docker opcional, apenas no profile `docker-edge`;
- `backup-helper` — utilitário sob demanda para backups de volumes.

## Stack oficial

Nome do projeto Compose:

```text
hub_core
```

Containers principais:

```text
hub_core-mysql-1
hub_core-hub-core-1
hub_core-pms-1
hub_core-totem-api-1
hub_core-totem-food-1
hub_core-face-scanner-1
```

O serviço `totem-food-db-init` é de execução única: cria/garante o schema `totem_food`, concede acesso ao usuário MySQL do HUB e termina com sucesso antes de `totem-food` iniciar.

## Banco de dados

Existe **um único servidor MySQL Docker**.

- `hub-core` + `pms`: schema `hotel_reservas`;
- `totem-food`: schema `totem_food`.

O Totem Food não cria um segundo MySQL. A separação por schema evita misturar pedidos, pagamentos, produtos e dados fiscais de alimentação com as tabelas operacionais do PMS.

## Persistência

Os volumes de produção são **externos e explicitamente nomeados** para ficarem desacoplados do ciclo de vida do Compose:

```text
hub_core_mysql_data
hub_core_pms_storage
hub_core_totem_data
hub_core_face_scanner_data
hub_core_totem_food_uploads
```

Uma atualização normal nunca deve remover esses volumes. O atualizador cria automaticamente apenas `hub_core_totem_food_uploads` quando ele ainda não existe, pois é um volume introduzido pelo módulo novo. Os volumes históricos continuam sendo validados e sua ausência aborta o deploy.

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
        +---- 127.0.0.1:3084 -> pms Docker
        +---- 127.0.0.1:3085 -> totem-food Docker

Docker backend
        +---- face-scanner:8091
        +---- mysql:3306
```

No ambiente atual de homologação, o Face Scanner também pode ser publicado em `127.0.0.1:8092 -> 8091` pelo override `compose.host-edge.yml`.

### docker-edge — opcional

Use apenas quando 80/443 estiverem livres no host e o gateway Docker for deliberadamente escolhido.

## Primeiro deploy

Em uma instalação nova, crie primeiro os volumes históricos persistentes:

```bash
docker volume create hub_core_mysql_data
docker volume create hub_core_pms_storage
docker volume create hub_core_totem_data
docker volume create hub_core_face_scanner_data
```

O volume `hub_core_totem_food_uploads` é criado automaticamente pelo atualizador.

Depois:

```bash
git clone git@github.com:wfuzatto/hub_core.git
cd hub_core
cp .env.example .env
# configure o .env
chmod 600 .env
bash scripts/update_docker.sh
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
3. prepara o PMS privado;
4. cria o novo volume do Totem Food caso ainda não exista;
5. valida os volumes persistentes;
6. posiciona `hotelaria`, Totem hoteleiro, Totem Food e Face Scanner nos SHAs homologados de `modules/modules.list`;
7. executa o preflight;
8. cria backup pré-update quando o MySQL está saudável;
9. reconstrói/aplica o stack;
10. cria/valida o schema `totem_food` pelo serviço de init;
11. aguarda os healthchecks;
12. testa PMS, Totem Hotel, Totem Food, HUB e HTTPS.

GPU opcional:

```bash
USE_GPU=1 bash scripts/update_docker.sh
```

## Portas

| Porta | Uso | Exposição |
|---|---|---|
| 80/443 | Edge | Caddy/NGINX do host ou gateway Docker opcional |
| 3080 | Totem Hotel | `127.0.0.1` em host-edge |
| 3083 | HUB | `127.0.0.1` em host-edge |
| 3084 | PMS | `127.0.0.1` em host-edge |
| 3085 | Totem Food | `127.0.0.1` em host-edge |
| 8091 | Face Scanner | rede Docker interna |
| 8092 | Face Scanner | homologação atual, loopback |
| 3306 | MySQL | somente rede Docker |

## Módulos homologados

Produção não acompanha automaticamente o `main` dos módulos. Os SHAs aprovados ficam em:

```text
modules/modules.list
```

O fluxo correto para atualizar um módulo é: testar no repositório próprio, aprovar um commit e só então alterar o SHA no `hub_core`.

## Totem Food

O módulo inicia por padrão com:

```text
PAYMENT_PROVIDER=mock
FISCAL_PROVIDER=mock
```

Portanto o primeiro deploy não executa TEF real nem emissão fiscal real. Essas integrações devem ser homologadas antes de alterar os providers.

O backup MySQL usa `--all-databases`, portanto inclui `hotel_reservas` e `totem_food`. O backup de volumes também inclui `hub_core_totem_food_uploads`.

## Regras de produção

- `hub_core` é o core/orquestrador; o PMS continua em `wfuzatto/hotelaria`;
- nenhum segredo deve ser commitado;
- `.env` de produção deve permanecer com permissão restrita;
- banco nunca deve ser publicado na Internet;
- serviços críticos usam healthcheck e `restart: unless-stopped`;
- módulos usam commits explicitamente aprovados;
- persistência é externa ao ciclo de vida do Compose;
- rollback é feito por versão/commit e backups, nunca por edição manual em container.
