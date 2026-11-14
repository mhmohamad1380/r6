#!/usr/bin/env bash
# Builds r6-replay-server.tar.gz: the code and installer, without data, samples, venv or binaries.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-r6-replay-server.tar.gz}"
tar --exclude='__pycache__' --exclude='*.pyc' -czf "$OUT" app requirements.txt deploy/install.sh README.md
echo "$OUT  $(du -h "$OUT" | cut -f1)"
