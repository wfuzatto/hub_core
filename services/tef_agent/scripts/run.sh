#!/usr/bin/env bash
set -a
cd "$(dirname "$0")/.."
[[ -f .env ]] && source .env
set +a
exec python3 tef_agent.py
