#!/bin/bash
#
# minikube-install.sh
# Installs Docker, kubectl and Minikube and starts a 2-node cluster on:
#   - Ubuntu / Debian
#   - Amazon Linux 2 / 2023   (x86_64 and arm64/Graviton)
# Requires docker-install.sh in the same directory. Safe to re-run.
#
# Usage:  sudo ./minikube-install.sh

# Exit immediately if a command exits with a non-zero status
set -e

K8S_MINOR="${K8S_MINOR:-1.30}"
K8S_VERSION="${K8S_VERSION:-v1.30.0}"

run_step() {
    echo "======== $1 ========"
    sleep 3
}

log()  { echo -e "\033[1;32m[+]\033[0m $*"; }
warn() { echo -e "\033[1;33m[!]\033[0m $*"; }
err()  { echo -e "\033[1;31m[x]\033[0m $*" >&2; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root or with sudo"
    exit 1
fi

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Remove any carriage returns from this script (in case it was edited on Windows)
sed -i 's/\r$//' "$SCRIPT_PATH"

# ---------------------------------------------------------------------------
# OS / architecture detection
# ---------------------------------------------------------------------------
os_field() { grep -E "^$1=" /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"'; }
OS_ID="$(os_field ID)"
OS_ID_LIKE="$(os_field ID_LIKE)"

case "$OS_ID" in
    ubuntu|debian|amzn) ;;
    *)
        if [[ "$OS_ID_LIKE" != *debian* ]]; then
            err "Unsupported OS '${OS_ID:-unknown}'. Supported: Ubuntu, Debian, Amazon Linux."
            exit 1
        fi
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

echo "Starting Minikube installation on $(os_field PRETTY_NAME) ($ARCH)..."

# The non-root user who will run minikube
ACTUAL_USER="${SUDO_USER:-root}"

# Run a command as ACTUAL_USER, with the docker group active even if the
# user was only just added to it (no re-login needed).
as_user() {
    if [[ "$ACTUAL_USER" != "root" ]]; then
        sudo -u "$ACTUAL_USER" -H sg docker -c "$(printf '%q ' "$@")"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------
run_step "0. Docker"
if command -v docker &>/dev/null && grep -qs 'SystemdCgroup = true' /etc/containerd/config.toml; then
    log "Docker already configured, skipping docker-install.sh"
elif [[ -f "$SCRIPT_DIR/docker-install.sh" ]]; then
    chmod +x "$SCRIPT_DIR/docker-install.sh"
    . "$SCRIPT_DIR/docker-install.sh"
else
    err "docker-install.sh not found in $SCRIPT_DIR"
    exit 1
fi

run_step "1. Checking Prerequisites"

if ! command -v docker &>/dev/null; then
    err "Docker is not installed!"
    exit 1
fi
log "Docker found: $(docker --version)"

if ! systemctl is-active --quiet docker; then
    warn "Docker daemon is not running. Starting it..."
    systemctl start docker
    sleep 2
fi

if [[ "$ACTUAL_USER" != "root" ]]; then
    if id -nG "$ACTUAL_USER" | grep -qw docker; then
        log "User '$ACTUAL_USER' is in docker group"
    else
        warn "User '$ACTUAL_USER' is NOT in docker group. Adding..."
        usermod -aG docker "$ACTUAL_USER"
        log "Log out and back in later for the group change to apply everywhere"
    fi
fi
echo ""

run_step "2. Disabling Swap (Required by Kubernetes)"
swapoff -a
sed -i '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
log "Swap disabled"
echo ""

run_step "3. Installing kubectl"
if command -v kubectl &>/dev/null; then
    log "kubectl already installed: $(kubectl version --client 2>/dev/null | head -n1)"
else
    KVER="$(curl -fsSL "https://dl.k8s.io/release/stable-${K8S_MINOR}.txt")"
    log "Installing kubectl ${KVER}..."
    TMP="$(mktemp)"
    curl -fsSL -o "$TMP" "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl"
    install -m 0755 "$TMP" /usr/local/bin/kubectl
    rm -f "$TMP"
    log "kubectl installed"
fi
echo ""

run_step "4. Installing Minikube"
if command -v minikube &>/dev/null; then
    log "minikube already installed: $(minikube version 2>/dev/null | head -n1)"
else
    log "Installing minikube..."
    TMP="$(mktemp)"
    curl -fsSL -o "$TMP" "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-${ARCH}"
    install -m 0755 "$TMP" /usr/local/bin/minikube
    rm -f "$TMP"
    log "minikube installed"
fi
echo ""

run_step "5. Checking Versions"
log "Versions:"
echo "  - $(docker --version)"
echo "  - kubectl $(kubectl version --client 2>/dev/null | head -n1)"
echo "  - $(minikube version | head -n1)"
echo ""

run_step "6. Starting Minikube Cluster (2 nodes)"
log "Starting minikube as user: $ACTUAL_USER"
MK_ARGS=(--nodes=2 --driver=docker "--kubernetes-version=${K8S_VERSION}" --addons=metrics-server,dashboard)
if [[ "$ACTUAL_USER" == "root" ]]; then
    warn "Running as root - minikube needs --force for the docker driver. Prefer running via sudo from a normal user."
    MK_ARGS+=(--force)
fi
as_user minikube start "${MK_ARGS[@]}"
echo ""

run_step "7. Configuring Worker Nodes"
as_user kubectl label node minikube-m02 kubernetes.io/role=worker1 --overwrite
log "Worker node labeled"
echo ""

run_step "8. Verifying Cluster"
log "Cluster status:"
as_user minikube status
echo ""
log "Nodes:"
as_user kubectl get nodes

echo ""
log "Minikube installation complete!"
echo ""
echo "  kubectl get pods -A                          # List all pods"
echo "  minikube dashboard                           # Open web dashboard"
echo "  minikube stop                                # Stop the cluster"
echo "  minikube delete                              # Delete the cluster"
echo "  kubectl apply -f <your-deployment>.yaml      # Deploy your app"
echo ""
echo "Restart the Terminal (or run 'newgrp docker') and start using Minikube"
