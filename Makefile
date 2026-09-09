.PHONY: bootstrap preflight up up-gpu up-docker-edge up-docker-edge-gpu ps logs health backup update down

bootstrap:
	./scripts/bootstrap.sh

preflight:
	EDGE_MODE=host ./scripts/preflight.sh

up:
	./scripts/update.sh --host-edge

up-gpu:
	./scripts/update.sh --host-edge --gpu

up-docker-edge:
	./scripts/update.sh --docker-edge

up-docker-edge-gpu:
	./scripts/update.sh --docker-edge --gpu

ps:
	docker compose -f compose.yml -f compose.host-edge.yml ps

logs:
	docker compose -f compose.yml -f compose.host-edge.yml logs -f --tail=200

health:
	@docker compose -f compose.yml -f compose.host-edge.yml ps
	@echo "\nHUB:"
	@docker compose -f compose.yml -f compose.host-edge.yml exec -T hub-core php -r 'echo file_get_contents("http://127.0.0.1/health.php"), PHP_EOL;'
	@echo "\nTotem:"
	@docker compose -f compose.yml -f compose.host-edge.yml exec -T totem-api node -e 'fetch("http://127.0.0.1:3080/api/health").then(r=>r.text()).then(console.log)'
	@echo "\nFace Scanner:"
	@docker compose -f compose.yml -f compose.host-edge.yml exec -T face-scanner python -c 'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8091/api/v1/health").read().decode())'

backup:
	./scripts/backup.sh

update:
	./scripts/update.sh --host-edge

down:
	docker compose -f compose.yml -f compose.host-edge.yml down
