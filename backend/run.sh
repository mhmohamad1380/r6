#!/bin/sh
# Runs the server for local use: listens on all interfaces, port 8090 (or $1).
cd "$(dirname "$0")" || exit 1
exec .venv/bin/uvicorn app.server:app --host 0.0.0.0 --port "${1:-8090}"
