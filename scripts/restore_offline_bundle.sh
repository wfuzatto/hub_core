#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:-}"
TARGET="${2:-/home/luisnasc/hub_core}"
STACK_NAME="${STACK_NAME:-hub_core}"

if [[ -z "$BUNDLE" || ! -d "$BUNDLE" ]]; then
  echo "Uso: $0 /caminho/do/bundle [/caminho/destino]" >&2
  exit 2
fi

for file in SHA256SUMS docker-images.tar.gz project-source.tar.gz; do
  [[ -f "$BUNDLE/$file" ]] || { echo "ERRO: arquivo ausente no bundle: $file" >&2; exit 1; }
done

command -v docker >/dev/null 2>&1 || { echo "ERRO: Docker ausente" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERRO: sha256sum ausente" >&2; exit 1; }

echo "[1/4] Verificando integridade..."
(cd "$BUNDLE" && sha256sum -c SHA256SUMS)

echo "[2/4] Carregando imagens Docker locais..."
gzip -dc "$BUNDLE/docker-images.tar.gz" | docker load

echo "[3/4] Restaurando código/configuração..."
mkdir -p "$TARGET"
tar -xzf "$BUNDLE/project-source.tar.gz" -C "$TARGET"

COMPOSE=(-f "$TARGET/compose.yml")
if [[ -f "$TARGET/compose.host-edge.yml" ]]; then
  COMPOSE+=(-f "$TARGET/compose.host-edge.yml")
fi

if [[ ! -f "$TARGET/.env" && -f "$BUNDLE/.env" ]]; then
  cp "$BUNDLE/.env" "$TARGET/.env"
  chmod 600 "$TARGET/.env"
fi

if [[ ! -f "$TARGET/.env" ]]; then
  echo "ERRO: .env não foi restaurado." >&2
  exit 1
fi

echo "[4/4] Subindo stack sem build e sem downloads..."
(
  cd "$TARGET"
  STACK_NAME="$STACK_NAME" docker compose "${COMPOSE[@]}" up -d --no-build
)

echo "Recuperação offline concluída em: $TARGET"
