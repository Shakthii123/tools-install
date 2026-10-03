#!/bin/bash
# Installs Docker + containerd (with SystemdCgroup enabled for Kubernetes).
# Supports: Ubuntu, Debian, Amazon Linux 2, Amazon Linux 2023.

# Exit immediately if a command exits with a non-zero status
set -e

run_step() {
    echo "======== $1 ========"
    sleep 2
}

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root or with sudo"
    exit 1
fi

# Remove any carriage returns from this script (in case it was edited on Windows)
SELF="${BASH_SOURCE[0]}"
[[ -f "$SELF" ]] && sed -i 's/\r$//' "$SELF"

# ---------------------------------------------------------------------------
# OS detection (reads /etc/os-release without sourcing it, so we don't
# overwrite variables in a parent script when this file is sourced)
# ---------------------------------------------------------------------------
os_field() { grep -E "^$1=" /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"'; }

OS_ID="$(os_field ID)"
OS_ID_LIKE="$(os_field ID_LIKE)"
OS_VERSION_ID="$(os_field VERSION_ID)"
OS_CODENAME="$(os_field VERSION_CODENAME)"

case "$OS_ID" in
    ubuntu|debian)
        FAMILY="debian"
        ;;
    amzn)
        FAMILY="amazon"
        ;;
    *)
        if [[ "$OS_ID_LIKE" == *debian* || "$OS_ID_LIKE" == *ubuntu* ]]; then
            FAMILY="debian"
            OS_ID="ubuntu"
        else
            err "Unsupported OS: ${OS_ID:-unknown}. This script supports Ubuntu, Debian and Amazon Linux."
            exit 1
        fi
        ;;
esac
log "Detected OS: $OS_ID $OS_VERSION_ID (family: $FAMILY)"

# Package manager helper for the Amazon Linux family
if command -v dnf &>/dev/null; then
    PKG=dnf
else
    PKG=yum
fi

install_docker_debian() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    # util-linux-extra only exists on newer Ubuntu/Debian; not fatal if missing
    apt-get install -y util-linux-extra || true

    mkdir -p /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${OS_ID}/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    if [[ -z "$OS_CODENAME" ]]; then
        OS_CODENAME="$(lsb_release -cs)"
    fi
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    apt-get install docker-compose
}

install_docker_amazon() {
    # Docker's own repo does not officially support Amazon Linux, so use
    # Amazon's "docker" package (it pulls in containerd as a dependency).
    $PKG install -y docker containerd
}

run_step "1. Installing Docker Engine"
if command -v docker &>/dev/null; then
    log "Docker already installed: $(docker --version)"
else
    log "Installing Docker..."
    if [[ "$FAMILY" == "debian" ]]; then
        install_docker_debian
    else
        install_docker_amazon
    fi
fi
echo ""

run_step "2. Starting containerd and Docker"
systemctl enable --now containerd
systemctl enable --now docker
if systemctl is-active --quiet docker; then
    log "Docker daemon is running"
else
    err "Failed to start Docker daemon"
    exit 1
fi
echo ""

run_step "3. Create containerd configuration"
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
echo ""

run_step "4. Edit /etc/containerd/config.toml"
sed -i -e 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
log "SystemdCgroup enabled"
echo ""

run_step "5. Restarting containerd and Docker"
systemctl restart containerd
systemctl restart docker
systemctl enable docker containerd
if systemctl is-active --quiet docker && systemctl is-active --quiet containerd; then
    log "containerd and Docker restarted successfully"
else
    err "Failed to restart containerd/Docker"
    exit 1
fi
echo ""

run_step "6. Check Docker Status"
systemctl status docker --no-pager | cat || true

run_step "7. Adding current user to the Docker group"

# Get the actual user (not root)
if [[ -n "${SUDO_USER:-}" ]]; then
    DOCKER_USER="$SUDO_USER"
else
    DOCKER_USER="root"
fi

if [[ "$DOCKER_USER" != "root" ]]; then
    if id -nG "$DOCKER_USER" | grep -qw docker; then
        log "User '$DOCKER_USER' is already in the docker group"
    else
        usermod -aG docker "$DOCKER_USER"
        log "User '$DOCKER_USER' added to docker group"
        log "Please log out and log back in, or run: newgrp docker"
    fi
else
    warn "Running as root, skipping user group addition"
fi

echo ""
run_step "8. Testing Docker"
if docker run --rm hello-world &>/dev/null; then
    log "Docker test successful!"
else
    warn "Docker test failed (no internet access to Docker Hub, or the daemon needs a moment)."
fi

log "Docker installation complete!"
