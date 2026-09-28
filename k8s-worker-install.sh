#!/bin/bash
#
# k8s-worker-install.sh
# Prepares a Kubernetes worker node and (optionally) joins it to a cluster on:
#   - Ubuntu / Debian
#   - Amazon Linux 2 / 2023
# Requires docker-install.sh in the same directory. Safe to re-run.
#
# Usage:
#   sudo ./k8s-worker-install.sh                       # install/prepare only
#   sudo ./k8s-worker-install.sh kubeadm join 10.0.0.5:6443 --token abcd.xyz \
#        --discovery-token-ca-cert-hash sha256:xxxx    # install (if needed) + join
#
# The join command is printed by k8s-master-install.sh, or generate a new one
# on the master with:  sudo kubeadm token create --print-join-command

# Exit immediately if a command exits with a non-zero status
set -e

K8S_MINOR="${K8S_MINOR:-v1.30}"

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
# Optional join command (accepts separate args or one quoted string)
# ---------------------------------------------------------------------------
JOIN_ARGS=()
if [[ $# -gt 0 ]]; then
    read -ra JOIN_ARGS <<< "$*"
    if [[ "${JOIN_ARGS[0]}" == "sudo" ]]; then
        JOIN_ARGS=("${JOIN_ARGS[@]:1}")
    fi
    if [[ "${JOIN_ARGS[0]:-}" != "kubeadm" || "${JOIN_ARGS[1]:-}" != "join" ]]; then
        err "Arguments must be the full 'kubeadm join ...' command from the master."
        err "Example: $0 kubeadm join 1.2.3.4:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
        exit 1
    fi
fi

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

ALREADY_JOINED=false
[[ -f /etc/kubernetes/kubelet.conf ]] && ALREADY_JOINED=true

# ---------------------------------------------------------------------------
# Container runtime
# ---------------------------------------------------------------------------
run_step "0. Container runtime (Docker + containerd)"
if command -v docker &>/dev/null && grep -qs 'SystemdCgroup = true' /etc/containerd/config.toml; then
    log "Docker/containerd already configured, skipping docker-install.sh"
elif [[ "$ALREADY_JOINED" == "true" ]]; then
    warn "Node already joined; not touching the container runtime"
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
echo ""

# ---------------------------------------------------------------------------
# Kernel modules / sysctl (persistent)
# ---------------------------------------------------------------------------
run_step "3. Enable kernel modules and sysctl settings"
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
# Join (optional)
# ---------------------------------------------------------------------------
run_step "4. Join the Kubernetes Cluster"
# NOTE: workers do NOT have /etc/kubernetes/admin.conf - that file is created
# by 'kubeadm init' on the master only. The worker joins with the token/hash.
if [[ ${#JOIN_ARGS[@]} -eq 0 ]]; then
    log "No join command given - node is prepared but NOT joined yet."
    echo ""
    echo "  When you're ready, get a fresh command on the master:"
    echo "    sudo kubeadm token create --print-join-command"
    echo "  then run it here through this script:"
    echo "    sudo $0 kubeadm join <master-ip>:6443 --token <token> \\"
    echo "         --discovery-token-ca-cert-hash sha256:<hash>"
    echo "  (or simply run that 'kubeadm join ...' command with sudo)."
elif [[ "$ALREADY_JOINED" == "true" ]]; then
    warn "This node is already joined (/etc/kubernetes/kubelet.conf exists), skipping join."
    warn "To re-join: sudo kubeadm reset -f, then run this script again."
else
    "${JOIN_ARGS[@]}"
    log "Joined the cluster"
fi
echo ""

run_step "5. Verify Installation"
echo "This node does not run kubectl against the cluster by default."
echo "To verify, run 'kubectl get nodes' on the master - this worker"
echo "should show up with STATUS 'Ready' shortly after joining."
echo ""

echo "========================================================="
if [[ ${#JOIN_ARGS[@]} -eq 0 ]]; then
    echo " Worker node prepared. Run again with the join command"
    echo " from the master when you are ready to join."
else
    echo " Installation Complete!"
    echo " This worker node has joined the cluster."
    echo " Verify with 'kubectl get nodes' on the master."
fi
echo "========================================================="
