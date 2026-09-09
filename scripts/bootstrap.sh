#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIST="$ROOT/modules/modules.list"

mkdir -p "$ROOT/modules"

while IFS='|' read -r dest repo ref; do
  [[ -z "${dest:-}" || "$dest" =~ ^[[:space:]]*# ]] && continue
  dest="${dest//[[:space:]]/}"
  repo="${repo//[[:space:]]/}"
  ref="${ref//[[:space:]]/}"

  if [[ -z "$dest" || -z "$repo" || -z "$ref" ]]; then
    echo "ERRO: linha inválida em modules.list: $dest|$repo|$ref"
    exit 1
  fi

  target="$ROOT/modules/$dest"

  if [[ -d "$target/.git" ]]; then
    if [[ -n "$(git -C "$target" status --porcelain)" ]]; then
      echo "ERRO: módulo $dest possui alterações/arquivos locais. Não sobrescrevendo."
      git -C "$target" status --short
      exit 1
    fi
    echo "[fetch] $dest"
    git -C "$target" fetch --prune --tags origin
  else
    echo "[clone] $dest"
    git clone --no-checkout "$repo" "$target"
    git -C "$target" fetch --prune --tags origin
  fi

  echo "[pin] $dest -> $ref"
  git -C "$target" checkout --detach "$ref"

  actual="$(git -C "$target" rev-parse HEAD)"
  expected="$(git -C "$target" rev-parse "${ref}^{commit}")"
  if [[ "$actual" != "$expected" ]]; then
    echo "ERRO: $dest ficou em $actual, esperado $expected"
    exit 1
  fi
done < "$LIST"

echo "Módulos preparados nas versões aprovadas."
