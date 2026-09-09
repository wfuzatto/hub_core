# Deploy de produção

## Host

Instale somente o necessário no host:

- Ubuntu Server;
- Docker Engine / Compose;
- Git;
- SSH;
- driver NVIDIA e NVIDIA Container Toolkit quando houver GPU.

Não instalar XAMPP, PHP, MySQL, Python, Node ou Tesseract diretamente no host para atender os serviços do stack.

## Fluxo

```bash
git clone git@github.com:wfuzatto/hub_core.git
cd hub_core
cp .env.example .env
nano .env
./scripts/bootstrap.sh
./scripts/preflight.sh
make up
```

Para GPU:

```bash
make up-gpu
```

## Versões

Os módulos são fixados em `modules/modules.list`. O servidor nunca acompanha `main` automaticamente. Uma atualização de produção exige alterar explicitamente o commit/tag aprovado no repositório do HUB.

As imagens-base também usam tags de versão fixas. Após o primeiro ciclo de homologação no hardware definitivo, registre também os digests SHA-256 das imagens aprovadas.

## Firewall

Externamente, libere somente o estritamente necessário:

- TCP 80 — ACME/redirecionamento;
- TCP 443 — HTTPS;
- UDP 443 — HTTP/3 opcional;
- SSH — preferencialmente restrito por IP/VPN.

Não liberar 3080, 3306 ou 8091.

## Atualização

Nunca editar arquivos dentro do container.

```bash
make backup
make update
make health
```

`make update` instala somente os refs definidos no orquestrador e não executa `git pull main` dos módulos.

## Backup

`make backup` gera dump MySQL e arquivo do volume persistente do Totem em `backups/`. Produção deve copiar estes arquivos para armazenamento externo ao servidor.

## Logs

Todos os serviços usam o driver Docker `local`, com rotação. Isso evita crescimento ilimitado dos arquivos de log no disco do host.
