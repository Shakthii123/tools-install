#!/usr/bin/env bash
#
# setup_nginx.sh - install nginx and create a site (static or reverse proxy).
#
# Usage (run as root or with sudo):
#   sudo ./setup_nginx.sh <domain> static
#   sudo ./setup_nginx.sh <domain> proxy <upstream>
#
# Examples:
#   sudo ./setup_nginx.sh example.com static
#   sudo ./setup_nginx.sh api.example.com proxy http://127.0.0.1:8000
#
# Supported: Ubuntu/Debian (apt) and Amazon Linux 2 / Amazon Linux 2023.
# On Amazon Linux, open ports 80/443 in the EC2 security group.

set -euo pipefail

# ---------- helpers ----------
log()  { echo -e "\e[32m[+]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*" >&2; }
die()  { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

usage() {
  echo "Usage: $0 <domain> static"
  echo "       $0 <domain> proxy <upstream-url>"
  exit 1
}

# ---------- arguments ----------
[[ $EUID -eq 0 ]] || die "Run as root (use sudo)."
[[ $# -ge 2 ]] || usage

DOMAIN="$1"
MODE="$2"
UPSTREAM="${3:-}"

[[ "$MODE" == "static" || "$MODE" == "proxy" ]] || usage
[[ "$MODE" == "proxy" && -z "$UPSTREAM" ]] && usage

WEB_ROOT="/var/www/${DOMAIN}"

# ---------- detect OS ----------
[[ -r /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"

case "$OS_ID" in
  ubuntu|debian)
    OS_FAMILY="debian"
    LAYOUT="sites"                 # sites-available / sites-enabled
    WEB_USER="www-data"
    CONF_FILE="/etc/nginx/sites-available/${DOMAIN}"
    ;;
  amzn)
    OS_FAMILY="amazon"
    LAYOUT="confd"                 # conf.d/*.conf
    WEB_USER="nginx"
    CONF_FILE="/etc/nginx/conf.d/${DOMAIN}.conf"
    ;;
  *)
    die "Unsupported OS '${OS_ID}'. This script supports Ubuntu/Debian and Amazon Linux."
    ;;
esac

# ---------- install nginx ----------
install_nginx() {
  if command -v nginx >/dev/null 2>&1; then
    log "nginx already installed: $(nginx -v 2>&1)"
    return
  fi
  log "Installing nginx on ${OS_ID} ${OS_VERSION}..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y nginx
  else
    if [[ "$OS_VERSION" == "2" ]]; then
      # Amazon Linux 2 ships nginx through amazon-linux-extras
      amazon-linux-extras install -y nginx1
    else
      # Amazon Linux 2023
      dnf install -y nginx
    fi
  fi
}

echo
log "OS:                 ${OS_ID} ${OS_VERSION} (${OS_FAMILY})"
log "Host (server_name): ${DOMAIN}"
log "Mode:               ${MODE}"
if [[ "$MODE" == "static" ]]; then
  log "Web root path:      ${WEB_ROOT}"
else
  log "Upstream:           ${UPSTREAM}"
fi
log "Config file path:   ${CONF_FILE}"
log "Access log path:    /var/log/nginx/${DOMAIN}.access.log"
log "Error log path:     /var/log/nginx/${DOMAIN}.error.log"
echo

install_nginx
systemctl enable --now nginx

# ---------- write the server block ----------
if [[ -f "$CONF_FILE" ]]; then
  cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
  warn "Existing config backed up."
fi

if [[ "$MODE" == "static" ]]; then
  log "Creating web root at ${WEB_ROOT}"
  mkdir -p "$WEB_ROOT"
  if [[ ! -f "${WEB_ROOT}/index.html" ]]; then
    cat > "${WEB_ROOT}/index.html" <<EOF
<!doctype html>
<html><head><meta charset="utf-8"><title>${DOMAIN}</title></head>
<body><h1>${DOMAIN} is up</h1></body></html>
EOF
  fi
  chown -R "${WEB_USER}:${WEB_USER}" "$WEB_ROOT"
  # Fix SELinux context if enforcing (not usually the case on Amazon Linux)
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
    chcon -R -t httpd_sys_content_t "$WEB_ROOT" || true
  fi

  cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root ${WEB_ROOT};
    index index.html;

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # Cache static assets
    location ~* \.(css|js|png|jpg|jpeg|gif|svg|ico|woff2?)\$ {
        expires 7d;
        add_header Cache-Control "public";
    }

    server_tokens off;
}
EOF
else
  cat > "$CONF_FILE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    access_log /var/log/nginx/${DOMAIN}.access.log;
    error_log  /var/log/nginx/${DOMAIN}.error.log;

    location / {
        proxy_pass ${UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_read_timeout 60s;
    }

    server_tokens off;
}
EOF
fi

# ---------- enable site (Debian layout) ----------
if [[ "$LAYOUT" == "sites" ]]; then
  ln -sf "$CONF_FILE" "/etc/nginx/sites-enabled/${DOMAIN}"
  # Remove default site if it would conflict
  [[ -L /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default && warn "Removed default site."
fi

# ---------- test and reload ----------
log "Testing configuration..."
if nginx -t; then
  systemctl reload nginx
  log "nginx reloaded. Site ${DOMAIN} is live on port 80."
else
  die "nginx config test failed. Fix ${CONF_FILE} and re-run."
fi

# Allow nginx to reach the upstream if SELinux is enforcing
if [[ "$MODE" == "proxy" ]] && command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" == "Enforcing" ]]; then
  setsebool -P httpd_can_network_connect 1 && log "SELinux: enabled httpd_can_network_connect."
fi

# ---------- firewall (optional, only if active) ----------
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  ufw allow 'Nginx Full' >/dev/null && log "ufw: allowed Nginx Full."
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
  firewall-cmd --reload >/dev/null && log "firewalld: allowed http/https."
fi

echo
log "Done. Summary:"
echo "  Host:        ${DOMAIN}"
if [[ "$MODE" == "static" ]]; then
  echo "  Web root:    ${WEB_ROOT}"
else
  echo "  Upstream:    ${UPSTREAM}"
fi
echo "  Config path: ${CONF_FILE}"
echo
log "Next steps:"
echo "  - Point DNS for ${DOMAIN} to this server"
if [[ "$OS_FAMILY" == "debian" ]]; then
  echo "  - Add HTTPS:  apt install -y certbot python3-certbot-nginx && certbot --nginx -d ${DOMAIN}"
else
  echo "  - Add HTTPS:  install certbot (pip or snap), then: certbot --nginx -d ${DOMAIN}"
  echo "  - Open ports 80/443 in your EC2 security group"
fi
echo "  - Logs:       /var/log/nginx/${DOMAIN}.{access,error}.log"
