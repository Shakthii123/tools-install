#!/usr/bin/env bash
#
# kops-setup.sh - Install kops + kubectl and create a Kubernetes cluster on AWS
#
# Usage:
#   ./kops-setup.sh install     Install kubectl, kops (and AWS CLI on Linux if missing)
#   ./kops-setup.sh create      Create S3 state bucket + cluster, wait until healthy
#   ./kops-setup.sh all         install + create
#   ./kops-setup.sh validate    Validate an existing cluster
#   ./kops-setup.sh delete      Delete the cluster (asks for confirmation)
#
# Every setting below can be overridden with an environment variable, e.g.:
#   CLUSTER_NAME=dev.k8s.local NODE_COUNT=3 AWS_REGION=eu-west-1 ./kops-setup.sh all
#
# Prerequisites:
#   - AWS credentials configured (`aws configure` or env vars / SSO profile)
#   - The IAM user/role needs: EC2, ELB, Auto Scaling, IAM, S3, SQS, EventBridge,
#     and Route53 (only if you use a real DNS name instead of gossip DNS).
#
set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
# Names ending in ".k8s.local" use gossip DNS (no Route53 hosted zone needed).
# For a real domain use e.g. CLUSTER_NAME=k8s.example.com (needs a Route53 zone).
CLUSTER_NAME="${CLUSTER_NAME:-demo.k8s.local}"
AWS_REGION="${AWS_REGION:-us-east-1}"
ZONES="${ZONES:-${AWS_REGION}a,${AWS_REGION}b,${AWS_REGION}c}"        # worker node zones
CONTROL_PLANE_ZONES="${CONTROL_PLANE_ZONES:-${AWS_REGION}a}"          # 1 zone = 1 control-plane node
NODE_COUNT="${NODE_COUNT:-2}"
NODE_SIZE="${NODE_SIZE:-t3.medium}"
CONTROL_PLANE_SIZE="${CONTROL_PLANE_SIZE:-t3.medium}"
K8S_VERSION="${K8S_VERSION:-}"                                        # empty = kops default
KOPS_VERSION="${KOPS_VERSION:-}"                                      # empty = latest release
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_rsa.pub}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VALIDATE_TIMEOUT="${VALIDATE_TIMEOUT:-15m}"
ASSUME_YES="${ASSUME_YES:-false}"                                     # true = skip prompts
KOPS_STATE_BUCKET="${KOPS_STATE_BUCKET:-}"                            # empty = auto-generated

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  read -r -p "$1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

SUDO=""
detect_sudo() {
  if [[ ! -w "$INSTALL_DIR" ]]; then
    have sudo || die "$INSTALL_DIR is not writable and sudo is not available. Set INSTALL_DIR to a writable path."
    SUDO="sudo"
  fi
}

detect_platform() {
  case "$(uname -s)" in
    Linux)  OS="linux" ;;
    Darwin) OS="darwin" ;;
    *) die "Unsupported OS: $(uname -s). Use Linux or macOS (or WSL on Windows)." ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

verify_sha256() {  # verify_sha256 <file> <expected_hash>
  local file="$1" expected="$2" actual
  if have sha256sum; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi
  [[ "$actual" == "$expected" ]] || die "Checksum mismatch for $file"
}

# --------------------------------------------------------------------------
# Installers
# --------------------------------------------------------------------------
install_kubectl() {
  if have kubectl; then
    log "kubectl already installed: $(kubectl version --client 2>/dev/null | head -n1)"
    return
  fi
  log "Installing kubectl..."
  local tmp ver
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "$tmp/kubectl" "https://dl.k8s.io/release/${ver}/bin/${OS}/${ARCH}/kubectl"
  verify_sha256 "$tmp/kubectl" "$(curl -fsSL "https://dl.k8s.io/release/${ver}/bin/${OS}/${ARCH}/kubectl.sha256")"
  $SUDO install -m 0755 "$tmp/kubectl" "$INSTALL_DIR/kubectl"
  log "Installed kubectl ${ver}"
}

install_kops() {
  local ver="$KOPS_VERSION"
  if [[ -z "$ver" ]]; then
    ver="$(curl -fsSL https://api.github.com/repos/kubernetes/kops/releases/latest \
            | grep '"tag_name"' | head -n1 | cut -d '"' -f 4 || true)"
    [[ -n "$ver" ]] || die "Could not determine latest kops version (GitHub rate limit?). Set KOPS_VERSION=v1.xx.x"
  fi

  if have kops && [[ "$(kops version 2>/dev/null)" == *"${ver#v}"* ]]; then
    log "kops ${ver} already installed"
    return
  fi

  log "Installing kops ${ver}..."
  local tmp url
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  url="https://github.com/kubernetes/kops/releases/download/${ver}/kops-${OS}-${ARCH}"
  curl -fsSL -o "$tmp/kops" "$url"
  if curl -fsSL -o "$tmp/kops.sha256" "${url}.sha256" 2>/dev/null; then
    verify_sha256 "$tmp/kops" "$(awk '{print $1}' "$tmp/kops.sha256")"
  else
    warn "No checksum file found for kops ${ver}; skipping verification."
  fi
  $SUDO install -m 0755 "$tmp/kops" "$INSTALL_DIR/kops"
  log "Installed $(kops version | head -n1)"
}

install_awscli() {
  if have aws; then
    log "AWS CLI already installed: $(aws --version 2>&1 | head -n1)"
    return
  fi
  if [[ "$OS" != "linux" ]]; then
    die "AWS CLI not found. Install it first (macOS: 'brew install awscli')."
  fi
  have unzip || die "'unzip' is required to install the AWS CLI. Install it and re-run."
  log "Installing AWS CLI v2..."
  local tmp arch
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  [[ "$ARCH" == "arm64" ]] && arch="aarch64" || arch="x86_64"
  curl -fsSL -o "$tmp/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip"
  unzip -q "$tmp/awscliv2.zip" -d "$tmp"
  ${SUDO:-} "$tmp/aws/install" --update
  log "Installed $(aws --version 2>&1 | head -n1)"
}

do_install() {
  have curl || die "curl is required."
  detect_platform
  detect_sudo
  install_awscli
  install_kubectl
  install_kops
}

# --------------------------------------------------------------------------
# Cluster operations
# --------------------------------------------------------------------------
preflight() {
  have aws     || die "aws CLI not found. Run: $0 install"
  have kops    || die "kops not found. Run: $0 install"
  have kubectl || die "kubectl not found. Run: $0 install"

  export AWS_DEFAULT_REGION="$AWS_REGION"
  local account
  account="$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    || die "AWS credentials are not configured or have expired. Run 'aws configure' (or 'aws sso login')."

  KOPS_STATE_BUCKET="${KOPS_STATE_BUCKET:-kops-state-${account}-${AWS_REGION}}"
  export KOPS_STATE_STORE="s3://${KOPS_STATE_BUCKET}"
}

ensure_ssh_key() {
  if [[ -f "$SSH_PUBLIC_KEY" ]]; then
    return
  fi
  log "No SSH public key at $SSH_PUBLIC_KEY - generating one..."
  local private="${SSH_PUBLIC_KEY%.pub}"
  mkdir -p "$(dirname "$private")"
  ssh-keygen -t rsa -b 4096 -N "" -f "$private" -C "kops-${CLUSTER_NAME}" >/dev/null
}

ensure_state_bucket() {
  if aws s3api head-bucket --bucket "$KOPS_STATE_BUCKET" 2>/dev/null; then
    log "State bucket s3://${KOPS_STATE_BUCKET} already exists"
    return
  fi

  log "Creating state bucket s3://${KOPS_STATE_BUCKET}..."
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$KOPS_STATE_BUCKET" --region "$AWS_REGION" >/dev/null
  else
    aws s3api create-bucket --bucket "$KOPS_STATE_BUCKET" --region "$AWS_REGION" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi

  aws s3api put-bucket-versioning --bucket "$KOPS_STATE_BUCKET" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption --bucket "$KOPS_STATE_BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  aws s3api put-public-access-block --bucket "$KOPS_STATE_BUCKET" \
    --public-access-block-configuration \
    'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'
}

print_summary() {
  cat <<EOF

  Cluster name        : ${CLUSTER_NAME}
  Region              : ${AWS_REGION}
  Worker zones        : ${ZONES}
  Control-plane zones : ${CONTROL_PLANE_ZONES}
  Worker nodes        : ${NODE_COUNT} x ${NODE_SIZE}
  Control-plane size  : ${CONTROL_PLANE_SIZE}
  Kubernetes version  : ${K8S_VERSION:-<kops default>}
  State store         : ${KOPS_STATE_STORE}
  SSH public key      : ${SSH_PUBLIC_KEY}

EOF
}

do_create() {
  preflight
  log "Cluster configuration:"
  print_summary
  confirm "Create this cluster? (this will launch billable AWS resources)" || die "Aborted."

  ensure_ssh_key
  ensure_state_bucket

  if kops get cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
    warn "Cluster ${CLUSTER_NAME} already exists in the state store - skipping 'create cluster'."
  else
    local args=(
      create cluster
      --name "$CLUSTER_NAME"
      --cloud aws
      --zones "$ZONES"
      --control-plane-zones "$CONTROL_PLANE_ZONES"
      --node-count "$NODE_COUNT"
      --node-size "$NODE_SIZE"
      --control-plane-size "$CONTROL_PLANE_SIZE"
      --ssh-public-key "$SSH_PUBLIC_KEY"
    )
    [[ -n "$K8S_VERSION" ]] && args+=(--kubernetes-version "$K8S_VERSION")

    log "Creating cluster spec..."
    kops "${args[@]}"
  fi

  log "Applying cluster (this provisions the AWS resources)..."
  kops update cluster --name "$CLUSTER_NAME" --yes --admin

  do_validate
}

do_validate() {
  preflight
  log "Waiting up to ${VALIDATE_TIMEOUT} for the cluster to become ready..."
  kops validate cluster --name "$CLUSTER_NAME" --wait "$VALIDATE_TIMEOUT"
  log "Cluster is ready. Try: kubectl get nodes"
}

do_delete() {
  preflight
  warn "This will DESTROY cluster ${CLUSTER_NAME} and all its AWS resources."
  confirm "Are you sure?" || die "Aborted."
  kops delete cluster --name "$CLUSTER_NAME" --yes
  log "Cluster deleted. The state bucket s3://${KOPS_STATE_BUCKET} was left in place."
}

usage() {
  sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
case "${1:-help}" in
  install)  do_install ;;
  create)   do_create ;;
  all)      do_install; do_create ;;
  validate) do_validate ;;
  delete)   do_delete ;;
  help|-h|--help) usage ;;
  *) usage; exit 1 ;;
esac
