#!/usr/bin/env bash
set -euo pipefail
sudo systemctl disable --now vale-tef-agent.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/vale-tef-agent.service
sudo systemctl daemon-reload
