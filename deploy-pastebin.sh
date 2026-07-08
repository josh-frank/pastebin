#!/usr/bin/env bash
#
# deploy-pastebin.sh
# Deploys pastebin on a freshly baked Linode (Ubuntu 22.04/24.04), fronts
# it with nginx, and issues a Let's Encrypt cert via certbot.
#
# Usage:
#   sudo DOMAIN=p.example.com EMAIL=you@example.com ./deploy-pastebin.sh
#
# Requirements before running:
#   - DNS A/AAAA record for DOMAIN already pointing at this Linode's IP
#     (certbot's http-01 challenge will fail otherwise)
#   - Run as root (or via sudo) on a fresh box
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Config — override via env vars, e.g.:
#   sudo DOMAIN=paste.mydomain.com EMAIL=me@mydomain.com ./deploy-pastebin.sh
# ---------------------------------------------------------------------------
DOMAIN="${DOMAIN:?Set DOMAIN, e.g. DOMAIN=p.example.com}"
EMAIL="${EMAIL:?Set EMAIL for the Lets Encrypt registration/renewal notices}"
REPO_URL="${REPO_URL:-https://github.com/josh-frank/pastebin.git}"
APP_DIR="/opt/pastebin"
APP_USER="pastebin"
GUNICORN_PORT="8000"

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo $0)" >&2
  exit 1
fi

echo "==> Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "==> Installing dependencies"
apt-get install -y \
  git \
  python3 \
  python3-venv \
  python3-pip \
  sqlite3 \
  nginx \
  certbot \
  python3-certbot-nginx \
  ufw

echo "==> Creating dedicated system user '${APP_USER}'"
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --create-home --shell /usr/sbin/nologin "${APP_USER}"
fi

echo "==> Fetching pastebin source into ${APP_DIR}"
if [[ -d "${APP_DIR}/.git" ]]; then
  git -C "${APP_DIR}" pull
else
  rm -rf "${APP_DIR}"
  git clone "${REPO_URL}" "${APP_DIR}"
fi

echo "==> Setting up Python virtualenv + deps"
python3 -m venv "${APP_DIR}/venv"
"${APP_DIR}/venv/bin/pip" install --upgrade pip
"${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
"${APP_DIR}/venv/bin/pip" install gunicorn

echo "==> Initializing SQLite database (idempotent)"
if [[ ! -f "${APP_DIR}/pastebin.db" ]]; then
  sqlite3 "${APP_DIR}/pastebin.db" < "${APP_DIR}/schema.sql"
fi

echo "==> Fixing ownership"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

echo "==> Installing systemd units"
cp "${APP_DIR}/pastebin.service" /etc/systemd/system/pastebin.service
cp "${APP_DIR}/pastebin-cleanup.service" /etc/systemd/system/pastebin-cleanup.service
cp "${APP_DIR}/pastebin-cleanup.timer" /etc/systemd/system/pastebin-cleanup.timer

systemctl daemon-reload
systemctl enable --now pastebin.service
systemctl enable --now pastebin-cleanup.timer

echo "==> Configuring nginx site"
# Add the rate-limit zone to the main http{} block once, if not already present.
if ! grep -q "limit_req_zone.*pastebin_zone" /etc/nginx/nginx.conf; then
  sed -i '/http {/a \\tlimit_req_zone $binary_remote_addr zone=pastebin_zone:10m rate=5r/s;' /etc/nginx/nginx.conf
fi

sed "s/p\.example\.com/${DOMAIN}/" "${APP_DIR}/nginx.conf" > /etc/nginx/sites-available/pastebin
ln -sf /etc/nginx/sites-available/pastebin /etc/nginx/sites-enabled/pastebin
# Remove the default site so it doesn't clash on port 80
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

echo "==> Configuring firewall (OpenSSH, HTTP, HTTPS only)"
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "==> Requesting Let's Encrypt certificate for ${DOMAIN}"
certbot --nginx \
  -d "${DOMAIN}" \
  --non-interactive \
  --agree-tos \
  --email "${EMAIL}" \
  --redirect

echo "==> Verifying service health"
sleep 2
if systemctl is-active --quiet pastebin.service; then
  echo "pastebin.service is running"
else
  echo "WARNING: pastebin.service is not active — check: journalctl -u pastebin -n 50" >&2
fi

cat <<EOF

Deploy complete.

  https://${DOMAIN}

Test it:
  curl --data-binary @somefile.txt https://${DOMAIN}/
  curl https://${DOMAIN}/<returned-id>

Useful commands:
  systemctl status pastebin
  systemctl status pastebin-cleanup.timer
  journalctl -u pastebin -f
  certbot renew --dry-run

EOF
