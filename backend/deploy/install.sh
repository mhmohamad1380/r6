#!/usr/bin/env bash
# Installs the R6 replay server on Ubuntu/Debian.
#   bash install.sh                 service on 127.0.0.1:8090 behind Caddy with automatic HTTPS
#   bash install.sh --domain NAME   use your own domain (its DNS must point at this server)
#   bash install.sh --no-tls        no Caddy: the service listens on 0.0.0.0:8090 over plain HTTP
#   bash install.sh --bind IP       no Caddy: listen only on IP:8090, for a reverse proxy you already run
#                                   (for example the Docker gateway address an nginx container can reach)
# Run as a normal user that has sudo. Safe to run again: it updates the code and keeps your data and tokens.
set -euo pipefail

APP=/opt/r6-replay-server
DATA=/var/lib/r6-replay
USER_NAME=r6replay
PORT=8090
DISSECT_VER=v0.24.0
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TLS=1
DOMAIN=""
BIND=""

while [ $# -gt 0 ]; do
  case "$1" in
    --no-tls) TLS=0 ;;
    --bind) BIND="${2:?--bind needs an IP address}"; TLS=0; shift ;;
    --domain) DOMAIN="${2:?--domain needs a name}"; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '\n==> %s\n' "$*"; }

[ -d "$HERE/app" ] || { echo "Run this from the unpacked server folder (it must contain app/)." >&2; exit 1; }

say "Installing packages"
sudo apt-get update -y -q
sudo apt-get install -y -q python3 python3-venv curl ca-certificates

say "Creating the service user and folders"
id "$USER_NAME" >/dev/null 2>&1 || sudo useradd --system --home "$DATA" --shell /usr/sbin/nologin "$USER_NAME"
sudo mkdir -p "$APP/bin" "$DATA"
sudo chown "$USER_NAME:$USER_NAME" "$DATA"
sudo chmod 750 "$DATA"

say "Copying the code"
sudo rm -rf "$APP/app"
sudo cp -r "$HERE/app" "$APP/app"
sudo cp "$HERE/requirements.txt" "$APP/requirements.txt"

say "Installing the replay parser (r6-dissect $DISSECT_VER)"
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/redraskal/r6-dissect/releases/download/$DISSECT_VER/r6-dissect-$DISSECT_VER-linux-$ARCH.tar.gz"
curl -fsSL "$BASE" -o "$TMP/d.tgz"
curl -fsSL "$BASE.md5" -o "$TMP/d.md5"
[ "$(md5sum "$TMP/d.tgz" | cut -d' ' -f1)" = "$(cut -d' ' -f1 "$TMP/d.md5")" ] || { echo "r6-dissect download failed its checksum." >&2; exit 1; }
tar -xzf "$TMP/d.tgz" -C "$TMP"
sudo install -m 755 "$TMP/r6-dissect" "$APP/bin/r6-dissect"
"$APP/bin/r6-dissect" --help >/dev/null 2>&1 || echo "(note: r6-dissect printed no help, continuing)"

say "Installing Python dependencies"
sudo python3 -m venv "$APP/venv"
sudo "$APP/venv/bin/pip" install -q --upgrade pip
sudo "$APP/venv/bin/pip" install -q -r "$APP/requirements.txt"

say "Setting up the service"
[ -f /etc/r6-replay.env ] || { echo "# Optional. Set R6_ARENYZE_KEY=... to let the server fall back to Arenyze's parser for replays r6-dissect cannot read." | sudo tee /etc/r6-replay.env >/dev/null; sudo chmod 640 /etc/r6-replay.env; sudo chown root:"$USER_NAME" /etc/r6-replay.env; }
if [ -n "$BIND" ]; then HOST="$BIND"; elif [ "$TLS" = 1 ]; then HOST=127.0.0.1; else HOST=0.0.0.0; fi
FWD=127.0.0.1; [ -n "$BIND" ] && FWD="*"   # bound to a private address, so only the local proxy can reach it
sudo tee /etc/systemd/system/r6-replay.service >/dev/null <<UNIT
[Unit]
Description=R6 replay server
After=network-online.target docker.service
Wants=network-online.target

[Service]
User=$USER_NAME
WorkingDirectory=$APP
Environment=R6_DATA_DIR=$DATA
EnvironmentFile=-/etc/r6-replay.env
ExecStart=$APP/venv/bin/uvicorn app.server:app --host $HOST --port $PORT --proxy-headers --forwarded-allow-ips=$FWD
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$DATA
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable r6-replay >/dev/null
sudo systemctl restart r6-replay

for i in $(seq 1 30); do
  curl -fsS "http://$HOST:$PORT/health" >/dev/null 2>&1 && break
  sleep 1
  [ "$i" = 30 ] && { echo "The service did not start. See: sudo journalctl -u r6-replay -n 50" >&2; exit 1; }
done

URL="http://$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}'):$PORT"
[ -n "$BIND" ] && URL="http://$BIND:$PORT (private, behind your HTTPS proxy)"
if [ "$TLS" = 1 ]; then
  say "Setting up HTTPS (Caddy)"
  if [ -z "$DOMAIN" ]; then
    IP="$(curl -fsS https://api.ipify.org)"
    DOMAIN="$(echo "$IP" | tr . -).sslip.io"   # sslip.io turns an IP address into a real name, so HTTPS works without a domain
  fi
  sudo apt-get install -y -q caddy
  sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
$DOMAIN {
    request_body {
        max_size 1GB
    }
    reverse_proxy 127.0.0.1:$PORT
}
CADDY
  sudo systemctl enable caddy >/dev/null
  sudo systemctl restart caddy
  URL="https://$DOMAIN"
  echo "Caddy needs ports 80 and 443 open to get the certificate (also in your cloud provider's firewall)."
fi

say "Done"
echo "Server address : $URL"
echo "Health check   : curl $URL/health"
echo
echo "Access tokens (also in $DATA/tokens.json):"
sudo cat "$DATA/tokens.json"
echo
echo "PC uploader uses the upload_token. The phone app uses the read_token."
