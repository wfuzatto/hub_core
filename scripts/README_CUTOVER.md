# Cutover do stack antigo para HUB Core

O primeiro cutover usa `scripts/cutover_from_hub_hotelaria.sh`.

Execute somente após:

1. `hub_core` estar sincronizado com `origin/main`;
2. os backups da migração existirem e estarem válidos;
3. o stack antigo `hub-hotelaria` estar saudável.

Comandos:

```bash
cd /home/luisnasc/hub_core
git pull --ff-only origin main
bash scripts/cutover_from_hub_hotelaria.sh
```

O script mantém os volumes antigos e, em caso de falha crítica durante o cutover, o operador deve reativar o stack antigo conforme o relatório da execução.

Depois que `hub_core` estiver oficialmente ativo, as atualizações normais passam a ser:

```bash
cd /home/luisnasc/hub_core
bash scripts/update_docker.sh
```

Não execute `docker compose down -v`, `docker volume prune` ou `docker system prune --volumes` como parte da atualização normal.
