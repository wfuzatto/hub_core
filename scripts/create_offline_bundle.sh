#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_NAME="${STACK_NAME:-hub_core}"
STAMP="$(date +%Y%m%d_%H%M%S)"
DEST="${1:-$ROOT/offline-bundles/$STAMP}"

COMPOSE=(-f "$ROOT/compose.yml")
if [[ -f "$ROOT/compose.host-edge.yml" ]]; then
  COMPOSE+=(-f "$ROOT/compose.host-edge.yml")
fi

mkdir -p "$DEST"
chmod 700 "$DEST"

if [[ ! -f "$ROOT/.env" ]]; then
  echo "ERRO: $ROOT/.env ausente; bundle offline ficaria incompleto." >&2
  exit 1
fi

for cmd in docker tar gzip sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERRO: comando obrigatório ausente: $cmd" >&2; exit 1; }
done

docker compose version >/dev/null

echo "[1/5] Registrando metadados..."
{
  echo "created_at=$(date -Iseconds)"
  echo "stack_name=$STACK_NAME"
  echo "host=$(hostname)"
  echo "docker=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  echo "compose=$(docker compose version --short 2>/dev/null || echo unknown)"
  echo "hub_commit=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unavailable)"
  echo "totem_commit=$(git -C "$ROOT/modules/totem_autoatendimento" rev-parse HEAD 2>/dev/null || echo unavailable)"
  echo "face_scanner_commit=$(git -C "$ROOT/modules/face_scanner" rev-parse HEAD 2>/dev/null || echo unavailable)"
} > "$DEST/METADATA.txt"
cp "$ROOT/modules/modules.list" "$DEST/modules.list"

# O arquivo contém segredos operacionais e por isso fica com permissão restrita.
cp "$ROOT/.env" "$DEST/.env"
chmod 600 "$DEST/.env"

echo "[2/5] Arquivando código, configurações e artefatos locais..."
# Inclui os repositórios .git dos módulos para permitir recuperação sem GitHub.
# Backups de dados são tratados separadamente por scripts/backup.sh para evitar duplicação pesada.
tar \
  --exclude='./offline-bundles' \
  --exclude='./backups' \
  -C "$ROOT" \
  -czf "$DEST/project-source.tar.gz" \
  .
chmod 600 "$DEST/project-source.tar.gz"

echo "[3/5] Localizando todas as imagens Docker necessárias..."
declare -A seen=()
images=()
add_image() {
  local image="${1:-}"
  [[ -z "$image" || "$image" == "<none>:<none>" ]] && return 0
  if [[ -z "${seen[$image]+x}" ]]; then
    seen[$image]=1
    images+=("$image")
  fi
}

# Inclui imagens declaradas explicitamente e os nomes gerados para serviços com build:.
while IFS= read -r image; do
  add_image "$image"
done < <(cd "$ROOT" && STACK_NAME="$STACK_NAME" docker compose "${COMPOSE[@]}" config --images 2>/dev/null || true)

# Inclui exatamente as imagens dos containers do stack, inclusive imagens locais geradas pelo Compose.
while IFS= read -r cid; do
  [[ -z "$cid" ]] && continue
  add_image "$(docker inspect --format '{{.Config.Image}}' "$cid")"
done < <(docker ps -aq --filter "label=com.docker.compose.project=$STACK_NAME")

if (( ${#images[@]} == 0 )); then
  echo "ERRO: nenhuma imagem Docker do stack foi localizada. Suba/construa o stack antes de criar o bundle." >&2
  exit 1
fi

missing=0
: > "$DEST/IMAGES.txt"
for image in "${images[@]}"; do
  echo "$image" >> "$DEST/IMAGES.txt"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    echo "ERRO: imagem necessária não está disponível localmente: $image" >&2
    missing=1
  fi
done
if (( missing != 0 )); then
  echo "Aborto: primeiro construa/puxe todas as imagens enquanto ainda houver conectividade." >&2
  exit 1
fi

echo "[4/5] Salvando imagens Docker completas..."
docker save "${images[@]}" | gzip -1 > "$DEST/docker-images.tar.gz"
chmod 600 "$DEST/docker-images.tar.gz"

echo "[5/5] Gerando checksums..."
(
  cd "$DEST"
  sha256sum METADATA.txt modules.list .env project-source.tar.gz IMAGES.txt docker-images.tar.gz > SHA256SUMS
)
chmod 600 "$DEST/SHA256SUMS"

cat > "$DEST/README-RESTORE.txt" <<'TXT'
Este bundle foi criado para recuperação sem acesso a GitHub, Docker Hub, npm, PyPI,
APT ou às URLs dos modelos.

1. Verifique: sha256sum -c SHA256SUMS
2. Carregue as imagens: gzip -dc docker-images.tar.gz | docker load
3. Extraia project-source.tar.gz no caminho desejado.
4. Use Docker Compose com --no-build. As dependências de runtime já estão dentro das imagens.

ATENÇÃO: .env está incluído e contém segredos. Proteja este bundle como backup confidencial.
TXT
chmod 600 "$DEST/README-RESTORE.txt"

echo "Bundle offline concluído: $DEST"
echo "Copie esse diretório também para mídia/servidor de backup independente."
