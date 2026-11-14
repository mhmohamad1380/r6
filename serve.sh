#!/bin/sh
# Serves ./dist on the local network. Usage: ./serve.sh [port]
PORT="${1:-8080}"
cd "$(dirname "$0")/dist" || exit 1
IP=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
echo "Open on another device on the same Wi-Fi: http://$IP:$PORT/"
exec python3 -I -m http.server "$PORT" --bind 0.0.0.0
