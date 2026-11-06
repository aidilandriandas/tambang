#!/usr/bin/env bash
# Installer NOC Tambang untuk VM baru (Ubuntu 22.04/24.04 atau Debian 12).
# Pemakaian:  sudo bash install.sh
# Jalankan dari dalam folder noc-tambang (yang berisi server.py dan folder static).
# Bisa juga tanpa pertanyaan:
#   sudo LIBRENMS_URL=http://10.10.0.50 LIBRENMS_TOKEN=xxx WEB_USER=admin WEB_PASS=rahasia bash install.sh
set -euo pipefail

APP_DIR=/opt/noc-tambang
DATA_DIR=/var/lib/noc-tambang
ENV_FILE=/etc/noc-tambang.env
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Jalankan dengan sudo: sudo bash install.sh"; exit 1; }
[ -f "$SRC/server.py" ] && [ -f "$SRC/static/index.html" ] || { echo "server.py / static/index.html tidak ditemukan di $SRC"; exit 1; }
command -v apt-get >/dev/null || { echo "Script ini untuk Ubuntu/Debian (apt)."; exit 1; }

ask() { # ask VAR "pertanyaan" [default] [secret]
  local var="$1" q="$2" def="${3:-}" secret="${4:-}" val
  if [ -n "${!var:-}" ]; then return; fi
  if [ -t 0 ]; then
    if [ -n "$secret" ]; then read -r -s -p "$q: " val; echo; else read -r -p "$q${def:+ [$def]}: " val; fi
  fi
  printf -v "$var" '%s' "${val:-$def}"
}

echo "== Konfigurasi =="
ask LIBRENMS_URL   "URL LibreNMS (kosongkan untuk mode demo dulu), mis. http://10.10.0.50" ""
LIBRENMS_URL="${LIBRENMS_URL%/}"
LIBRENMS_TOKEN="${LIBRENMS_TOKEN:-}"
if [ -n "$LIBRENMS_URL" ]; then ask LIBRENMS_TOKEN "API token LibreNMS" "" secret; fi
LIBRENMS_VERIFY_TLS="${LIBRENMS_VERIFY_TLS:-1}"
ask WEB_USER "Username login dashboard" "admin"
ask WEB_PASS "Password login dashboard (kosong = dibuatkan acak)" "" secret
GEN_PASS=0
if [ -z "${WEB_PASS:-}" ]; then WEB_PASS="$(head -c 18 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 14)"; GEN_PASS=1; fi

echo "== Install paket sistem =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip nginx apache2-utils curl ca-certificates

echo "== Pasang aplikasi di $APP_DIR =="
id noc >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin noc
mkdir -p "$APP_DIR" "$DATA_DIR"
cp -r "$SRC/server.py" "$SRC/requirements.txt" "$SRC/static" "$APP_DIR/"
# bawa data IPAM lama jika ada, tanpa menimpa data di VM
[ -f "$SRC/data/ipam.json" ] && [ ! -f "$DATA_DIR/ipam.json" ] && cp "$SRC/data/ipam.json" "$DATA_DIR/ipam.json"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet -r "$APP_DIR/requirements.txt"
chown -R noc:noc "$APP_DIR" "$DATA_DIR"

echo "== Simpan konfigurasi =="
umask 077
cat > "$ENV_FILE" <<ENV
LIBRENMS_URL=$LIBRENMS_URL
LIBRENMS_TOKEN=$LIBRENMS_TOKEN
LIBRENMS_VERIFY_TLS=$LIBRENMS_VERIFY_TLS
IPAM_FILE=$DATA_DIR/ipam.json
ENV
chown root:noc "$ENV_FILE"; chmod 640 "$ENV_FILE"
umask 022

echo "== Service systemd =="
cat > /etc/systemd/system/noc-tambang.service <<UNIT
[Unit]
Description=NOC Tambang dashboard
After=network-online.target
Wants=network-online.target

[Service]
User=noc
Group=noc
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/venv/bin/gunicorn -w 2 -b 127.0.0.1:8080 server:app
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now noc-tambang
systemctl restart noc-tambang

echo "== Nginx + login =="
htpasswd -bc /etc/nginx/.noc-htpasswd "$WEB_USER" "$WEB_PASS" >/dev/null
chmod 640 /etc/nginx/.noc-htpasswd; chgrp www-data /etc/nginx/.noc-htpasswd
cat > /etc/nginx/sites-available/noc-tambang <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    auth_basic "NOC Tambang";
    auth_basic_user_file /etc/nginx/.noc-htpasswd;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 60s;
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/noc-tambang /etc/nginx/sites-enabled/noc-tambang
nginx -t
systemctl enable nginx
systemctl restart nginx

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow 80/tcp >/dev/null; fi

echo "== Cek =="
sleep 2
CODE="$(curl -s -o /dev/null -w '%{http_code}' -u "$WEB_USER:$WEB_PASS" http://127.0.0.1/ || true)"
IP="$(hostname -I | awk '{print $1}')"
echo
if [ "$CODE" = "200" ]; then echo "SELESAI. Dashboard berjalan."; else echo "PERINGATAN: respons HTTP $CODE. Cek: journalctl -u noc-tambang -n 50"; fi
echo "  Alamat   : http://$IP/"
echo "  Username : $WEB_USER"
[ "$GEN_PASS" = 1 ] && echo "  Password : $WEB_PASS   (catat sekarang)"
[ -z "$LIBRENMS_URL" ] && echo "  Mode     : DEMO. Isi LIBRENMS_URL dan LIBRENMS_TOKEN di $ENV_FILE lalu: sudo systemctl restart noc-tambang"
echo "  Log      : journalctl -u noc-tambang -f"
