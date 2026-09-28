#!/bin/bash
#
# k8s-master-install.sh
# Sets up a single-node Kubernetes control plane (kubeadm + Flannel) on:
#   - Ubuntu / Debian
#   - Amazon Linux 2 / 2023
# Requires docker-install.sh in the same directory. Safe to re-run.
#
# Usage:  sudo ./k8s-master-install.sh

# Exit immediately if a command exits with a non-zero status
set -e

K8S_MINOR="${K8S_MINOR:-v1.30}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

run_step() {
    echo "=== $1 ==="
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
# OS detection
# ---------------------------------------------------------------------------
os_field() { grep -E "^$1=" /etc/os-release | head -n1 | cut -d= -f2- | tr -d '"'; }
OS_ID="$(os_field ID)"
OS_ID_LIKE="$(os_field ID_LIKE)"

case "$OS_ID" in
    ubuntu|debian) FAMILY="debian" ;;
    amzn)          FAMILY="amazon" ;;
    *)
        if [[ "$OS_ID_LIKE" == *debian* ]]; then
            FAMILY="debian"
        else
            err "Unsupported OS '${OS_ID:-unknown}'. Supported: Ubuntu, Debian, Amazon Linux."
            exit 1
        fi
        ;;
esac
log "Detected OS: $OS_ID (family: $FAMILY)"

if command -v dnf &>/dev/null; then PKG=dnf; else PKG=yum; fi

# The non-root user who invoked sudo (kubeconfig will be set up for them)
TARGET_USER="${SUDO_USER:-root}"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

# ---------------------------------------------------------------------------
# Container runtime (Docker + containerd with SystemdCgroup)
# ---------------------------------------------------------------------------
run_step "0. Container runtime (Docker + containerd)"
if command -v docker &>/dev/null && grep -qs 'SystemdCgroup = true' /etc/containerd/config.toml; then
    log "Docker/containerd already configured, skipping docker-install.sh"
elif [[ -f "$SCRIPT_DIR/docker-install.sh" ]]; then
    chmod +x "$SCRIPT_DIR/docker-install.sh"
    . "$SCRIPT_DIR/docker-install.sh"
else
    err "docker-install.sh not found in $SCRIPT_DIR"
    exit 1
fi
echo ""

# ---------------------------------------------------------------------------
# Swap
# ---------------------------------------------------------------------------
run_step "1. Disabling Swap (Required by Kubernetes)"
swapoff -a
sed -i '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
log "Swap disabled"
echo ""

# ---------------------------------------------------------------------------
# Kubernetes packages
# ---------------------------------------------------------------------------
run_step "2. Installing kubelet, kubeadm and kubectl"
if command -v kubeadm &>/dev/null && command -v kubelet &>/dev/null && command -v kubectl &>/dev/null; then
    log "Kubernetes packages already installed: $(kubeadm version -o short)"
elif [[ "$FAMILY" == "debian" ]]; then
    apt-get update
    apt-get install -y apt-transport-https ca-certificates curl gpg
    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" \
        | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
    apt-get update
    apt-get install -y kubelet kubeadm kubectl
    apt-mark hold kubelet kubeadm kubectl
else
    # Amazon Linux: SELinux must not block the kubelet / container runtime
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" == "Enforcing" ]]; then
        setenforce 0
        sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        log "SELinux set to permissive"
    fi
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    $PKG install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
    $PKG install -y iproute-tc || true   # 'tc' is checked by kubeadm preflight
fi
# kubeadm starts the kubelet itself; enabling is enough
systemctl enable kubelet
log "kubelet, kubeadm & kubectl ready"
echo ""

run_step "3. Checking Versions"
log "Versions:"
echo "  - $(docker --version)"
echo "  - kubectl $(kubectl version --client 2>/dev/null | head -n1)"
echo "  - kubeadm $(kubeadm version -o short)"
echo "  - kubelet $(kubelet --version)"
echo ""

# ---------------------------------------------------------------------------
# Kernel modules / sysctl (persistent)
# ---------------------------------------------------------------------------
run_step "4. Enable kernel modules and sysctl settings"
printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null
log "Kernel modules loaded and sysctl applied (persistent across reboots)"
echo ""

# ---------------------------------------------------------------------------
# Cluster init
# ---------------------------------------------------------------------------
run_step "5. Initialize the Cluster (Run only on master)"
if [[ -f /etc/kubernetes/admin.conf ]]; then
    warn "Cluster already initialized (/etc/kubernetes/admin.conf exists), skipping kubeadm init"
    warn "To start over: sudo kubeadm reset -f && sudo rm -rf /etc/cni/net.d"
else
    kubeadm init --pod-network-cidr="$POD_CIDR"
fi
echo ""

run_step "6. Set up kubeconfig for $TARGET_USER"
mkdir -p "$USER_HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$USER_HOME/.kube"
export KUBECONFIG=/etc/kubernetes/admin.conf
log "kubeconfig installed at $USER_HOME/.kube/config"
echo ""

run_step "7. Install Flannel (Run only on master)"
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
echo ""

run_step "8. Verify Installation"
kubectl get pods --all-namespaces
echo ""

run_step "9. Generate Worker Join Command"
JOIN_CMD="$(kubeadm token create --print-join-command)"
JOIN_FILE="$USER_HOME/kubeadm_join_command.sh"
echo "$JOIN_CMD" > "$JOIN_FILE"
chmod 700 "$JOIN_FILE"
chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$JOIN_FILE"
log "Join command saved to $JOIN_FILE"
echo ""

echo "========================================================="
echo " Installation Complete!"
echo " Next steps:"
echo " 1. On each worker, run k8s-worker-install.sh with the join"
echo "    command below (or run it later - tokens last 24 hours;"
echo "    re-run this script or 'kubeadm token create"
echo "    --print-join-command' for a fresh one):"
echo ""
echo "    sudo ./k8s-worker-install.sh $JOIN_CMD"
echo ""
echo " 2. On AWS, allow TCP 6443 (workers -> master) and 10250"
echo "    (between nodes) in the security group."
echo "========================================================="
echo "Restart the terminal (or run 'newgrp docker') so group changes apply."
