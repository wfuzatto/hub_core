#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-$(command -v python3)}"
[[ -n "$PY" ]] || { echo 'python3 ausente'; exit 1; }
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || cp "$ROOT/.env.example" "$ENV_FILE"
SERVICE=/etc/systemd/system/vale-tef-agent.service
sudo tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=Vale Mantiqueira TEF Agent
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
WorkingDirectory=$ROOT
EnvironmentFile=$ENV_FILE
ExecStart=$PY $ROOT/tef_agent.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now vale-tef-agent.service
sudo systemctl --no-pager status vale-tef-agent.service
