#!/usr/bin/env bash
set -u
systemctl --no-pager status vale-tef-agent.service || true
curl -fsS http://127.0.0.1:8766/health || true
echo
