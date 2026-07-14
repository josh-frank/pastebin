#!/usr/bin/env bash
#
# deploy-pastebin.sh
# Deploys pastebin on a freshly baked Linode (Ubuntu 22.04/24.04), fronts
# it with nginx, and issues a Let's Encrypt cert via certbot.
#
# Usage:
#   sudo DOMAIN=p.example.com EMAIL=you@example.com ./deploy-pastebin.sh
#
#   Optionally also host the static frontend (pastebin.html/view.html) on
#   this same box:
#   sudo DOMAIN=p.example.com FRONTEND_DOMAIN=paste.example.com \
#        EMAIL=you@example.com ./deploy-pastebin.sh
#
# Requirements before running:
#   - DNS A/AAAA record for DOMAIN (and FRONTEND_DOMAIN, if set) already
#     pointing at this Linode's IP (certbot's http-01 challenge will fail
#     otherwise)
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

# Optional: the domain serving pastebin.html/view.html (the static frontend
# that does the actual encrypt/decrypt). Set this ONLY if that frontend is
# also being hosted on this same box via nginx.conf's second server block.
# If your frontend is hosted elsewhere (its own static host, a CDN, etc. —
# e.g. a separate paste.example.com deployment), leave this unset: this
# script will skip installing that server block entirely and you configure
# PASTEBIN_FRONTEND_ORIGIN / BACKEND_URL by hand to point at wherever it
# actually lives.
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-}"

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
if [[ -n "${FRONTEND_DOMAIN}" ]]; then
  FRONTEND_ORIGIN="https://${FRONTEND_DOMAIN}"
else
  # No frontend hosted here -- fall back to the API's own origin so the app
  # still starts and returns *something* usable, but flag it loudly since
  # it's almost certainly not what you want in this case.
  FRONTEND_ORIGIN="https://${DOMAIN}"
  echo "WARNING: FRONTEND_DOMAIN not set. pastebin.service will use" >&2
  echo "  PASTEBIN_FRONTEND_ORIGIN=${FRONTEND_ORIGIN}" >&2
  echo "  Edit /etc/systemd/system/pastebin.service and 'systemctl daemon-reload" >&2
  echo "  && systemctl restart pastebin' once you know where the frontend" >&2
  echo "  (pastebin.html / view.html) actually lives." >&2
fi
sed "s#https://paste.example.com#${FRONTEND_ORIGIN}#" "${APP_DIR}/pastebin.service" > /etc/systemd/system/pastebin.service
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

if [[ -n "${FRONTEND_DOMAIN}" ]]; then
  echo "==> Deploying static frontend (pastebin.html, view.html) to /var/www/pastebin"
  mkdir -p /var/www/pastebin
  cp "${APP_DIR}/pastebin.html" "${APP_DIR}/view.html" /var/www/pastebin/
  chown -R www-data:www-data /var/www/pastebin

  # Both server blocks from nginx.conf: API (DOMAIN) + static frontend (FRONTEND_DOMAIN).
  sed -e "s/p\.example\.com/${DOMAIN}/" \
      -e "s/paste\.example\.com/${FRONTEND_DOMAIN}/" \
      "${APP_DIR}/nginx.conf" > /etc/nginx/sites-available/pastebin
  CERT_DOMAINS=(-d "${DOMAIN}" -d "${FRONTEND_DOMAIN}")
else
  # FRONTEND_DOMAIN unset: install only the API server block (everything
  # through the first unindented closing brace). Installing the static
  # block as-is would point nginx at an empty /var/www/pastebin on an
  # uncertified domain -- worse than not having it.
  awk '{print} /^}/{exit}' "${APP_DIR}/nginx.conf" \
    | sed "s/p\.example\.com/${DOMAIN}/" > /etc/nginx/sites-available/pastebin
  CERT_DOMAINS=(-d "${DOMAIN}")
fi

ln -sf /etc/nginx/sites-available/pastebin /etc/nginx/sites-enabled/pastebin
# Remove the default site so it doesn't clash on port 80
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

echo "==> Configuring firewall (OpenSSH, HTTP, HTTPS only)"
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "==> Requesting Let's Encrypt certificate for: ${CERT_DOMAINS[*]}"
certbot --nginx \
  "${CERT_DOMAINS[@]}" \
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

  API:      https://${DOMAIN}
$(if [[ -n "${FRONTEND_DOMAIN}" ]]; then echo "  Frontend: https://${FRONTEND_DOMAIN}"; else echo "  Frontend: not deployed here -- host pastebin.html/view.html elsewhere,"
echo "            pointing BACKEND_URL at https://${DOMAIN}/"; fi)

Test the API is up (this only proves connectivity -- it posts/reads raw
bytes, not an actual encrypted paste; use the frontend for a real paste):
  curl --data-binary @somefile.txt https://${DOMAIN}/
  curl https://${DOMAIN}/<returned-id>

Peek at the database (content is encrypted, so this shows opaque bytes,
not the actual paste text -- see README for more sqlite3 examples):
  sqlite3 ${APP_DIR}/pastebin.db "SELECT id, length(ciphertext), datetime(expires_at, 'unixepoch') FROM pastes;"

Useful commands:
  systemctl status pastebin
  systemctl status pastebin-cleanup.timer
  journalctl -u pastebin -f
  certbot renew --dry-run

EOF
